export type SessionStatus = 'idle' | 'generating' | 'executing' | 'error';

@Observed
export class SessionModel {
  id: string;
  title: string;
  workDir: string;
  status: SessionStatus;
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
