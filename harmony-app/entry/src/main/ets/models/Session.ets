export type SessionStatus = 'idle' | 'generating' | 'executing' | 'error';

/** 服务端没有显式的运行状态：modifiedAt 在生成/工具执行期间持续刷新，据此判断活跃。 */
const RUNNING_WINDOW_MS: number = 60 * 1000;

@Observed
export class SessionModel {
  id: string;
  title: string;
  workDir: string;
  status: SessionStatus;
  /** 列表轮询时刷新，供圆点直接响应（时间窗口无法自行触发重绘） */
  running: boolean = false;
  model: string;
  createdAt: number;
  lastActivityAt: number;
  messageCount: number;
  projectPath: string;
  workspaceState: string;
  runtimeProviderId: string;
  effortLevel: string;
  permissionMode: string;

  constructor(id: string, workDir: string, model: string,
              status: SessionStatus = 'idle', messageCount: number = 0,
              title: string = '') {
    this.id = id;
    this.title = title;
    this.workDir = workDir;
    this.model = model;
    this.status = status;
    this.messageCount = messageCount;
    this.createdAt = Date.now();
    this.lastActivityAt = Date.now();
    this.projectPath = '';
    this.workspaceState = '';
    this.runtimeProviderId = '';
    this.effortLevel = '';
    this.permissionMode = '';
  }

  updateActivity(): void { this.lastActivityAt = Date.now(); }

  /**
   * 本地启发式：服务端状态 + 最近活动时间。
   * 仅在 WS 精确订阅尚未覆盖该会话时使用（长时间工具执行可能提前判空闲）。
   */
  isRunningHeuristic(): boolean {
    if (this.status === 'generating' || this.status === 'executing') { return true; }
    // 空会话的 modifiedAt 也是“刚刚”，但并未生成，必须排除
    if (this.messageCount <= 0) { return false; }
    return this.lastActivityAt > 0 && Date.now() - this.lastActivityAt < RUNNING_WINDOW_MS;
  }

  isRunning(): boolean { return this.isRunningHeuristic(); }

  /**
   * 刷新圆点状态。
   * authoritative：WS 精确订阅结果（true/false）；未提供时回退本地启发式。
   */
  refreshRunning(authoritative?: boolean): void {
    this.running = authoritative === undefined ? this.isRunningHeuristic() : authoritative;
  }

  getDisplayTitle(): string {
    if (this.title && this.title.length > 0) { return this.title; }
    if (this.workDir && this.workDir.length > 0) {
      const parts = this.workDir.split('\\');
      const last = parts[parts.length - 1];
      if (last && last.length > 0) { return last; }
    }
    return '会话';
  }

  getRelativeTime(): string {
    const diff = Date.now() - this.lastActivityAt;
    if (diff < 60000) { return '刚刚'; }
    if (diff < 3600000) { return Math.floor(diff / 60000) + '分钟前'; }
    if (diff < 86400000) { return Math.floor(diff / 3600000) + '小时前'; }
    return Math.floor(diff / 86400000) + '天前';
  }
}

export type Session = SessionModel;
