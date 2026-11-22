import { WebSocketService, WsEvent } from './WebSocketService';
import { Logger } from '../utils/Logger';

export interface ActivityTarget {
  id: string;
  lastActivityAt: number;
}

const OWNER_PREFIX: string = 'activity-';
/** 列表只对最近活跃的若干会话做精确订阅，避免为全部会话维持长连接 */
const MAX_TARGETS: number = 10;
/** 探测连接在该时间内没收到 session_state 就关闭，等下一轮列表刷新再探 */
const PROBE_TIMEOUT_MS: number = 6000;
/** 收到 idle 后延迟关闭，避免和紧随其后的状态事件竞争 */
const CLOSE_DELAY_MS: number = 800;
/** 已确认空闲的会话至少间隔这么久再探测，避免按列表 8s 刷新反复建连 */
const REPROBE_INTERVAL_MS: number = 30000;

/**
 * 会话运行状态精确订阅。
 *
 * 服务端 /api/sessions 没有运行状态字段，modifiedAt 在长时间工具执行时也不刷新，
 * 仅靠 60 秒活动窗口会把仍在运行的会话误判为空闲（圆点提前变灰）。
 * 这里为最近活跃的会话建立轻量 WS：连上即发 sync_state，读取 session_state.turnState，
 * 运行中的会话保持连接直到 status idle / message_complete；空闲会话收到状态后立即断开，
 * 下一轮列表刷新再探测。ChatPage / BackgroundTurnWatcher 也会直接标记运行/结束。
 */
export class SessionActivityMonitor {
  private conns: Map<string, WebSocketService> = new Map();
  private probeTimers: Map<string, number> = new Map();
  private lastProbeAt: Map<string, number> = new Map();
  private running: Set<string> = new Set();
  private known: Set<string> = new Set();
  private targets: ActivityTarget[] = [];
  private host: string = '';
  private port: number = 0;
  private token: string = '';
  private active: boolean = false;
  private listeners: Array<() => void> = [];

  onChange(cb: () => void): void { this.listeners.push(cb); }

  offChange(cb: () => void): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) { this.listeners.splice(idx, 1); }
  }

  /** true=运行中，false=已确认空闲，null=尚未探测到（UI 回退本地启发式） */
  getState(sessionId: string): boolean | null {
    if (this.running.has(sessionId)) { return true; }
    if (this.known.has(sessionId)) { return false; }
    return null;
  }

  markRunning(sessionId: string): void {
    if (!sessionId) { return; }
    this.known.add(sessionId);
    this.setRunning(sessionId, true);
    // 列表可见时会为它建立/复用精确订阅；不可见时等下次 start() 补上
    this.ensureConn(sessionId, true);
  }

  markIdle(sessionId: string): void {
    if (!sessionId) { return; }
    this.known.add(sessionId);
    this.setRunning(sessionId, false);
  }

  /**
   * 列表加载/刷新时调用：更新候选会话并补齐探测连接。
   * 同一 host/token 下重复调用只做增量更新，不会重建运行中的连接。
   */
  start(host: string, port: number, token: string, targets: ActivityTarget[]): void {
    if (!host || !token) { return; }
    const changed: boolean = !this.active || host !== this.host || port !== this.port || token !== this.token;
    this.host = host;
    this.port = port;
    this.token = token;
    this.active = true;
    if (changed) {
      this.closeAll();
      this.running.clear();
      this.known.clear();
      this.lastProbeAt.clear();
    }
    this.targets = targets;
    this.syncTargets();
  }

  stop(): void {
    this.active = false;
    this.closeAll();
    this.running.clear();
    this.known.clear();
    this.lastProbeAt.clear();
    this.emit();
  }

  private emit(): void {
    for (const cb of this.listeners) { cb(); }
  }

  /** 返回状态是否发生变化 */
  private setRunning(sessionId: string, value: boolean): boolean {
    const had: boolean = this.running.has(sessionId);
    if (had === value) { return false; }
    if (value) { this.running.add(sessionId); } else { this.running.delete(sessionId); }
    this.emit();
    return true;
  }

  private syncTargets(): void {
    if (!this.active) { return; }
    const sorted: ActivityTarget[] = this.targets.slice();
    sorted.sort((a: ActivityTarget, b: ActivityTarget): number => b.lastActivityAt - a.lastActivityAt);
    const keep: Set<string> = new Set();
    for (let i = 0; i < sorted.length && keep.size < MAX_TARGETS; i++) {
      keep.add(sorted[i].id);
    }
    // 运行中的会话即使不在最近 10 个内也保持订阅
    for (const id of this.running) { keep.add(id); }

    for (const id of Array.from(this.conns.keys())) {
      if (!keep.has(id)) { this.closeConn(id); }
    }
    for (const id of keep) {
      this.ensureConn(id);
    }
  }

  private ensureConn(sessionId: string, force: boolean = false): void {
    if (!this.active || !sessionId) { return; }
    if (this.conns.has(sessionId)) { return; }
    if (!force) {
      const last: number = this.lastProbeAt.get(sessionId) ?? 0;
      if (last > 0 && Date.now() - last < REPROBE_INTERVAL_MS) { return; }
    }
    const ws = new WebSocketService();
    this.conns.set(sessionId, ws);
    this.lastProbeAt.set(sessionId, Date.now());
    const owner: string = OWNER_PREFIX + sessionId;

    ws.on('session_state', (event: WsEvent): void => {
      this.clearProbeTimer(sessionId);
      this.known.add(sessionId);
      this.lastProbeAt.set(sessionId, Date.now());
      const isRunning: boolean = (event.turnState as string) === 'running';
      this.setRunning(sessionId, isRunning);
      if (!isRunning) { this.closeConnLater(sessionId); }
    }, owner);
    ws.on('status', (event: WsEvent): void => {
      this.clearProbeTimer(sessionId);
      this.known.add(sessionId);
      this.lastProbeAt.set(sessionId, Date.now());
      const state: string = event.state as string;
      if (state === 'idle') {
        this.setRunning(sessionId, false);
        this.closeConnLater(sessionId);
      } else {
        this.setRunning(sessionId, true);
      }
    }, owner);
    ws.on('message_complete', (_event: WsEvent): void => {
      this.known.add(sessionId);
      this.lastProbeAt.set(sessionId, Date.now());
      this.setRunning(sessionId, false);
      this.closeConnLater(sessionId);
    }, owner);
    ws.on('permission_request', (_event: WsEvent): void => {
      this.known.add(sessionId);
      this.lastProbeAt.set(sessionId, Date.now());
      this.setRunning(sessionId, true);
    }, owner);
    const markRunning = (_event: WsEvent): void => {
      this.known.add(sessionId);
      this.lastProbeAt.set(sessionId, Date.now());
      this.setRunning(sessionId, true);
    };
    ws.on('content_start', markRunning, owner);
    ws.on('content_delta', markRunning, owner);
    ws.on('thinking', markRunning, owner);
    ws.on('tool_use_complete', markRunning, owner);
    ws.on('tool_result', markRunning, owner);

    const origin: string = 'http://' + this.host + ':' + this.port;
    ws.connect(this.host, this.port, this.token, sessionId, origin).catch((e: Error): void => {
      Logger.warn('[ACT] connect failed ' + sessionId.substring(0, 8) + ': ' + e.message);
      this.closeConnLater(sessionId);
    });

    const timer: number = setTimeout((): void => {
      this.probeTimers.delete(sessionId);
      if (!this.running.has(sessionId)) { this.closeConn(sessionId); }
    }, PROBE_TIMEOUT_MS);
    this.probeTimers.set(sessionId, timer);
  }

  private clearProbeTimer(sessionId: string): void {
    const timer: number = this.probeTimers.get(sessionId) ?? -1;
    if (timer !== -1) {
      clearTimeout(timer);
      this.probeTimers.delete(sessionId);
    }
  }

  private closeConnLater(sessionId: string): void {
    setTimeout((): void => {
      if (!this.running.has(sessionId)) { this.closeConn(sessionId); }
    }, CLOSE_DELAY_MS);
  }

  private closeConn(sessionId: string): void {
    this.clearProbeTimer(sessionId);
    const ws: WebSocketService | undefined = this.conns.get(sessionId);
    if (!ws) { return; }
    this.conns.delete(sessionId);
    ws.clearHandlers(OWNER_PREFIX + sessionId);
    ws.disconnect();
  }

  private closeAll(): void {
    for (const id of Array.from(this.conns.keys())) { this.closeConn(id); }
  }
}
