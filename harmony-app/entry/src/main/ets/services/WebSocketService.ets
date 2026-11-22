import webSocket from '@ohos.net.webSocket';
import { util } from '@kit.ArkTS';
import { Logger } from '../utils/Logger';
import { Constants } from '../utils/Constants';

export type WsEvent = Record<string, Object>;
export type WsEventHandler = (event: Record<string, Object>) => void;

interface WsControlMessage { type: string; }

interface WsHandlerEntry {
  cb: WsEventHandler;
  owner: string;
}

/**
 * 新版 cc-haha WebSocket：每会话一条连接 /ws/<sessionId>?token=<h5Token>
 */
export class WebSocketService {
  private ws: webSocket.WebSocket | null = null;
  private handlers: Map<string, WsHandlerEntry[]> = new Map();
  private isConnected: boolean = false;
  private connectionState: string = 'disconnected';
  private host: string = '';
  private port: number = Constants.DEFAULT_PORT;
  private scheme: string = 'http';
  private token: string = '';
  private sessionId: string = '';
  private origin: string = '';
  private shouldReconnect: boolean = true;
  private reconnectAttempts: number = 0;
  private reconnectTimer: number = -1;
  private heartbeatTimer: number = -1;
  private watchdogTimer: number = -1;
  private pendingPingAt: number = 0;
  private isAutoReconnect: boolean = false;
  private reconnectCallback: ((sessionId: string) => void) | null = null;
  private connectionChangedCallbacks: Array<(connected: boolean) => void> = [];
  private stateChangeCallbacks: Array<(state: string) => void> = [];

  /** 自动重连成功后的回调（用于补拉离线期间的消息）；只保留一个，页面重建时覆盖 */
  setReconnectListener(cb: (sessionId: string) => void): void {
    this.reconnectCallback = cb;
  }

  onConnectionChanged(cb: (connected: boolean) => void): void {
    this.connectionChangedCallbacks.push(cb);
  }

  onConnectionStateChange(cb: (state: string) => void): void {
    this.stateChangeCallbacks.push(cb);
  }

  getConnectionState(): string { return this.connectionState; }
  getIsConnected(): boolean { return this.isConnected; }
  getSessionId(): string { return this.sessionId; }

  private setState(state: string): void {
    this.connectionState = state;
    this.stateChangeCallbacks.forEach(cb => cb(state));
  }

  connect(host: string, port: number, token: string, sessionId: string, origin: string = ''): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (!sessionId) {
        reject(new Error('sessionId is required'));
        return;
      }
      this.host = host;
      this.port = port;
      this.scheme = AppStorage.get<string>('connectionScheme') === 'https' ? 'https' : 'http';
      this.token = token;
      this.sessionId = sessionId;
      this.origin = origin;
      this.shouldReconnect = true;
      this.reconnectAttempts = 0;
      this.isAutoReconnect = false;
      this.setState('connecting');
      this.doConnect(resolve, reject);
    });
  }

  private buildUrl(): string {
    if (this.scheme === 'https') {
      // 与官方原生客户端一致：远程连接不在 query 里带 token，凭证只走 Authorization 头；
      // 公共访问网关对浏览器式 token 参数会直接断开（表现为客户端 WS error）。
      const authority: string = this.port && this.port !== 443
        ? this.host + ':' + this.port : this.host;
      return 'wss://' + authority + Constants.WS_PATH +
        encodeURIComponent(this.sessionId) + '?media=ref';
    }
    return 'ws://' + this.host + ':' + this.port + Constants.WS_PATH +
      encodeURIComponent(this.sessionId) + '?token=' + encodeURIComponent(this.token);
  }

  private doConnect(resolve?: (v: void) => void, reject?: (e: Error) => void): void {
    this.closeSocket();
    const socket = webSocket.createWebSocket();
    this.ws = socket;
    // 旧连接的 close 事件是异步到达的，若迟到会把新连接引用清空并触发额外的重连，
    // 造成同时存在多条存活连接、每个事件被处理多次（表现为流式文字重复）。
    // 所有回调都先校验自己仍是当前连接，否则直接忽略。
    const isCurrent = (): boolean => this.ws === socket;
    const url = this.buildUrl();
    Logger.warn('[CC] WS connecting ' + url.slice(0, url.indexOf('?')) + ' origin=' + this.origin);

    const onConnect = (err: Object, value: boolean): void => {
      if (!isCurrent()) { return; }
      if (err) {
        Logger.warn('[CC] WS connect error ' + JSON.stringify(err));
        this.isConnected = false;
        this.setState('disconnected');
        this.notifyConnectionChanged();
        if (reject) { reject(new Error('Connection failed')); }
        this.scheduleReconnect();
        return;
      }
      Logger.warn('[CC] WS connected');
      const wasAutoReconnect = this.isAutoReconnect;
      this.isAutoReconnect = false;
      this.isConnected = true;
      this.reconnectAttempts = 0;
      this.pendingPingAt = 0;
      this.setState('connected');
      this.notifyConnectionChanged();
      this.sendControl('sync_state');
      this.startHeartbeat();
      if (resolve) { resolve(); }
      // 自动恢复的连接：通知页面补拉断线期间错过的消息
      if (wasAutoReconnect && this.reconnectCallback) {
        this.reconnectCallback(this.sessionId);
      }
    };

    // 局域网直连：HarmonyOS 自动发送的 Origin 为 http://host（不带端口），
    // 需在 cc-haha 的 h5Access.allowedOrigins 中加入该 Origin。
    // 公共访问（HTTPS）：与非原生浏览器一致，显式带 Bearer 与 Origin 头。
    if (this.scheme === 'https') {
      // 只带 Authorization：HarmonyOS 会自动添加 Origin，手动再带会形成重复头导致握手失败
      const headers: Record<string, string> = {
        'Authorization': 'Bearer ' + this.token
      };
      const options: webSocket.WebSocketRequestOptions = { header: headers };
      socket.connect(url, options, onConnect);
    } else {
      socket.connect(url, onConnect);
    }

    socket.on('message', (err: Object, value: string | ArrayBuffer) => {
      if (!isCurrent() || err) { return; }
      try {
        let txt: string;
        if (typeof value === 'string') {
          txt = value;
        } else {
          const decoder = new util.TextDecoder('utf-8');
          txt = decoder.decodeWithStream(new Uint8Array(value as ArrayBuffer), { stream: false });
        }
        const msg = JSON.parse(txt) as Record<string, Object>;
        const eventType = msg.type as string;
        if (eventType === 'pong') { this.pendingPingAt = 0; }
        const cbs = this.handlers.get(eventType);
        if (cbs) { cbs.forEach(entry => entry.cb(msg)); }
        const allCbs = this.handlers.get('*');
        if (allCbs) { allCbs.forEach(entry => entry.cb(msg)); }
      } catch (e) {
        Logger.warn('Failed to parse WS message');
      }
    });

    socket.on('close', (err: Object, value: webSocket.CloseResult) => {
      // 已被 closeSocket/新连接替换掉的旧 socket，其 close 事件必须忽略
      if (!isCurrent()) { return; }
      Logger.warn('[CC] WS closed code=' + value.code + ' reason=' + value.reason);
      this.isConnected = false;
      this.setState('disconnected');
      this.notifyConnectionChanged();
      this.ws = null;
      this.stopHeartbeat();
      if (this.shouldReconnect) { this.scheduleReconnect(); }
    });

    socket.on('error', (err: Error) => {
      if (!isCurrent()) { return; }
      // HarmonyOS 在连接正常时也可能回调一次空 error，不能据此判定断线；
      // 以 close 事件为准，避免误伤已建立的连接。
      Logger.warn('[CC] WS error ' + (err ? err.message : 'unknown'));
    });
  }

  private sendControl(type: string): void {
    const msg: WsControlMessage = { type: type };
    this.send(msg);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    // 每 30 秒 ping 一次
    this.heartbeatTimer = setInterval(() => {
      if (!this.isConnected) { return; }
      this.pendingPingAt = Date.now();
      this.sendControl('ping');
    }, Constants.HEARTBEAT_INTERVAL_MS);
    // 每 5 秒检查 pong 是否超时（Tailscale 链路慢时放宽到 20 秒，避免误判断线）
    this.watchdogTimer = setInterval(() => {
      if (this.pendingPingAt > 0 && (Date.now() - this.pendingPingAt) > Constants.WS_PONG_TIMEOUT_MS) {
        Logger.warn('WebSocket pong timeout, reconnecting');
        this.pendingPingAt = 0;
        this.closeSocket();
        this.isConnected = false;
        this.setState('connecting');
        this.notifyConnectionChanged();
        this.isAutoReconnect = true;
        this.doConnect();
      }
    }, 5000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) { clearInterval(this.heartbeatTimer); this.heartbeatTimer = -1; }
    if (this.watchdogTimer !== -1) { clearInterval(this.watchdogTimer); this.watchdogTimer = -1; }
    this.pendingPingAt = 0;
  }

  private scheduleReconnect(): void {
    if (!this.shouldReconnect || !this.sessionId) { return; }
    if (this.reconnectTimer !== -1) { return; }
    // 不限次数：指数退避封顶 10 秒，断网/后台恢复后能一直自动重连
    const delay = Math.min(
      Constants.WS_RECONNECT_BASE_MS * Math.pow(2, Math.min(this.reconnectAttempts, 4)),
      Constants.WS_RECONNECT_MAX_MS
    );
    this.reconnectAttempts++;
    Logger.info('WebSocket reconnecting in ' + delay + 'ms');
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (this.shouldReconnect && this.sessionId) {
        this.isAutoReconnect = true;
        this.doConnect();
      }
    }, delay);
  }

  /**
   * 前台恢复/疑似断线时调用：
   * - 未连接：立即重连；
   * - 已连接：立刻发一次 ping，由 watchdog 判断连接是否还活着。
   */
  ensureAlive(): void {
    if (!this.sessionId) { return; }
    if (!this.isConnected) {
      Logger.info('ensureAlive: reconnect now');
      this.shouldReconnect = true;
      if (this.reconnectTimer !== -1) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = -1;
      }
      this.isAutoReconnect = true;
      this.doConnect();
      return;
    }
    this.pendingPingAt = Date.now();
    this.sendControl('ping');
  }

  private closeSocket(): void {
    if (this.ws) {
      try { this.ws.close(); } catch (e) {
        Logger.debug('WS close ignored: ' + (e as Error).message);
      }
      this.ws = null;
    }
  }

  disconnect(): void {
    this.shouldReconnect = false;
    this.stopHeartbeat();
    if (this.reconnectTimer !== -1) { clearTimeout(this.reconnectTimer); this.reconnectTimer = -1; }
    this.closeSocket();
    this.isConnected = false;
    this.setState('disconnected');
    this.notifyConnectionChanged();
    this.sessionId = '';
  }

  send(data: Object): void {
    this.sendWithResult(data);
  }

  /**
   * 发送并等待底层 flush 结果。
   * 只代表数据已交给 WebSocket，不代表服务端已接受（服务端无 ACK，需靠事件/历史对账）。
   */
  sendWithResult(data: Object): Promise<boolean> {
    return new Promise<boolean>((resolve: (ok: boolean) => void): void => {
      if (!this.ws || !this.isConnected) {
        Logger.warn('Cannot send: not connected');
        resolve(false);
        return;
      }
      const t0 = Date.now();
      try {
        this.ws.send(JSON.stringify(data), (err: Object) => {
          if (err) {
            Logger.error('Send failed ' + JSON.stringify(err) + ' after ' + (Date.now() - t0) + 'ms');
            resolve(false);
          } else {
            Logger.warn('[CC] send flushed in ' + (Date.now() - t0) + 'ms');
            resolve(true);
          }
        });
      } catch (e) {
        Logger.error('Send exception ' + (e as Error).message);
        resolve(false);
      }
    });
  }

  on(event: string, callback: WsEventHandler, owner: string = ''): void {
    const cbs = this.handlers.get(event) || [];
    cbs.push({ cb: callback, owner: owner });
    this.handlers.set(event, cbs);
  }

  off(event: string, callback: WsEventHandler): void {
    const cbs = this.handlers.get(event);
    if (cbs) {
      const kept = cbs.filter(entry => entry.cb !== callback);
      if (kept.length > 0) { this.handlers.set(event, kept); }
      else { this.handlers.delete(event); }
    }
  }

  /** 不传 owner 时清空所有；传 owner 时只清理该页面/模块的处理器，避免误伤后台监听。 */
  clearHandlers(owner?: string): void {
    if (owner === undefined) {
      this.handlers.clear();
      return;
    }
    const keys: string[] = [];
    this.handlers.forEach((_value: WsHandlerEntry[], key: string) => { keys.push(key); });
    for (const key of keys) {
      const list = this.handlers.get(key) || [];
      const kept = list.filter(entry => entry.owner !== owner);
      if (kept.length > 0) { this.handlers.set(key, kept); }
      else { this.handlers.delete(key); }
    }
  }

  offConnectionChanged(cb: (connected: boolean) => void): void {
    const idx = this.connectionChangedCallbacks.indexOf(cb);
    if (idx >= 0) { this.connectionChangedCallbacks.splice(idx, 1); }
  }

  offConnectionStateChange(cb: (state: string) => void): void {
    const idx = this.stateChangeCallbacks.indexOf(cb);
    if (idx >= 0) { this.stateChangeCallbacks.splice(idx, 1); }
  }

  private notifyConnectionChanged(): void {
    this.connectionChangedCallbacks.forEach(cb => cb(this.isConnected));
  }
}
