import preferences from '@ohos.data.preferences';
import { fileIo } from '@kit.CoreFileKit';
import { MessageModel, MessageRole, MsgUsage, ContentBlock, DeliveryState } from '../models/Message';
import { SessionModel, Session } from '../models/Session';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';

interface StoredMessage {
  id: string;
  role: string;
  timestamp: number;
  model: string;
  usage: MsgUsage | null;
  contents: ContentBlock[];
  /** 服务端消息 ID（断线补拉时用于判断与本地缓存重叠） */
  serverId?: string;
  /** 本地发送状态（sending/queued/failed/sent） */
  delivery?: string;
}

function parseDelivery(value: string | undefined): DeliveryState {
  switch (value) {
    case 'sending': return DeliveryState.SENDING;
    case 'queued': return DeliveryState.QUEUED;
    case 'failed': return DeliveryState.FAILED;
    case 'sent': return DeliveryState.SENT;
    default: return DeliveryState.NONE;
  }
}

interface StoredSession {
  id: string;
  title: string;
  workDir: string;
  status: string;
  model: string;
  createdAt: number;
  lastActivityAt: number;
  messageCount: number;
  projectPath: string;
  workspaceState: string;
}

/**
 * 聊天历史本地持久化。
 *
 * v6 起从 Preferences 迁移到 filesDir 下的独立 JSON 文件：
 * Preferences 不适合存几 MB 的聊天记录（本次迁移前 prefs 已达 3.9MB），
 * 迁移时一次性删除旧的 hist_* 键，随后由服务端重新填充。
 */
export class HistoryStore {
  private prefs: preferences.Preferences | null = null;
  private dir: string = '';
  // 进程内会话缓存：再次进入同一会话时不必重新解析大文件
  private memCache: Map<string, MessageModel[]> = new Map<string, MessageModel[]>();
  private cacheOrder: string[] = [];
  private readonly MAX_MESSAGES: number = 2000;
  private readonly MAX_MESSAGE_BYTES: number = 8 * 1024 * 1024;
  private readonly READ_SIZE_LIMIT: number = 16 * 1024 * 1024;
  private readonly MAX_SESSIONS: number = 200;

  async initialize(context: Context): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, Constants.PREFERENCES_NAME);
      this.dir = `${context.filesDir}/history`;
      this.ensureDir();
      await this.cleanLegacyPreferences();
    } catch (err) {
      Logger.error('HistoryStore init failed: ' + (err as Error).message);
    }
  }

  private ensureDir(): void {
    try {
      if (this.dir.length > 0 && !fileIo.accessSync(this.dir)) {
        fileIo.mkdirSync(this.dir, true);
      }
    } catch (err) {
      Logger.error('HistoryStore create dir failed: ' + (err as Error).message);
    }
  }

  /** 一次性清理旧版 Preferences 中的聊天缓存，释放 prefs 体积。 */
  private async cleanLegacyPreferences(): Promise<void> {
    if (!this.prefs) { return; }
    try {
      const all = await this.prefs.getAll() as Record<string, Object>;
      const keys = Object.keys(all);
      let removed = 0;
      for (const key of keys) {
        if (key.startsWith('hist_msgs_') || key === 'hist_sessions' || key === 'hist_cache_version') {
          await this.prefs.delete(key);
          removed++;
        }
      }
      if (removed > 0) {
        await this.prefs.flush();
        Logger.info('HistoryStore cleared legacy preference entries: ' + removed);
      }
    } catch (err) {
      Logger.warn('HistoryStore legacy cleanup failed: ' + (err as Error).message);
    }
  }

  private msgPath(sessionId: string): string { return `${this.dir}/msgs-${sessionId}.json`; }
  private sessionsPath(): string { return `${this.dir}/sessions.json`; }

  private writeText(path: string, text: string): void {
    const temporaryPath: string = path + '.tmp';
    const file: fileIo.File = fileIo.openSync(temporaryPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
    try {
      if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
    } catch (err) {
      Logger.warn('HistoryStore replace failed: ' + (err as Error).message);
    }
    fileIo.renameSync(temporaryPath, path);
  }

  private readText(path: string): string {
    if (!fileIo.accessSync(path)) { return ''; }
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (stat.size > this.READ_SIZE_LIMIT) {
      Logger.warn('HistoryStore read skipped, file too large: ' + stat.size);
      return '';
    }
    return fileIo.readTextSync(path);
  }

  /** 写入进程内缓存，最多保留 4 个最近会话，避免占用过多内存 */
  private putMemCache(sessionId: string, messages: MessageModel[]): void {
    this.memCache.set(sessionId, messages.slice());
    this.cacheOrder = this.cacheOrder.filter((k: string): boolean => k !== sessionId);
    this.cacheOrder.push(sessionId);
    while (this.cacheOrder.length > 4) {
      const oldest = this.cacheOrder.shift();
      if (oldest) { this.memCache.delete(oldest); }
    }
  }

  async saveMessages(sessionId: string, messages: MessageModel[]): Promise<void> {
    if (!this.dir || !sessionId) { return; }
    try {
      let slice: MessageModel[] = messages;
      if (slice.length > this.MAX_MESSAGES) {
        slice = slice.slice(slice.length - this.MAX_MESSAGES);
      }
      const list: StoredMessage[] = [];
      for (const m of slice) {
        list.push({
          id: m.id, role: m.role, timestamp: m.timestamp,
          model: m.model ?? '', usage: m.usage ?? null, contents: m.contents,
          serverId: m.serverId, delivery: m.delivery
        });
      }
      let json: string = JSON.stringify(list);
      while (json.length > this.MAX_MESSAGE_BYTES && list.length > 100) {
        list.splice(0, Math.ceil(list.length / 2));
        json = JSON.stringify(list);
      }
      this.writeText(this.msgPath(sessionId), json);
      this.putMemCache(sessionId, slice);
      Logger.debug('history saved: sess=' + sessionId.substring(0, 8) +
        ' msgs=' + list.length + ' bytes=' + json.length);
    } catch (err) {
      Logger.warn('HistoryStore saveMessages failed: ' + (err as Error).message);
    }
  }

  async loadMessages(sessionId: string): Promise<MessageModel[]> {
    if (!this.dir || !sessionId) { return []; }
    const cached = this.memCache.get(sessionId);
    if (cached) {
      this.putMemCache(sessionId, cached);
      return cached.slice();
    }
    try {
      const json: string = this.readText(this.msgPath(sessionId));
      if (!json) { return []; }
      const raw = JSON.parse(json) as StoredMessage[];
      const result: MessageModel[] = [];
      for (const r of raw) {
        const roleStr = r.role;
        const role = roleStr === 'assistant' ? MessageRole.ASSISTANT
          : (roleStr === 'system' ? MessageRole.SYSTEM : MessageRole.USER);
        const msg = new MessageModel(role, r.id);
        msg.timestamp = r.timestamp;
        msg.model = r.model;
        msg.usage = r.usage ?? undefined;
        msg.serverId = r.serverId ?? '';
        msg.delivery = parseDelivery(r.delivery);
        if (Array.isArray(r.contents)) { msg.contents = r.contents; }
        msg.isStreaming = false;
        result.push(msg);
      }
      this.putMemCache(sessionId, result);
      return result;
    } catch (err) {
      Logger.warn('HistoryStore loadMessages failed: ' + (err as Error).message);
      return [];
    }
  }

  async deleteMessages(sessionId: string): Promise<void> {
    if (!this.dir || !sessionId) { return; }
    this.memCache.delete(sessionId);
    this.cacheOrder = this.cacheOrder.filter((k: string): boolean => k !== sessionId);
    try {
      const path: string = this.msgPath(sessionId);
      if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
    } catch (err) {
      Logger.warn('HistoryStore deleteMessages failed: ' + (err as Error).message);
    }
  }

  async saveSessions(sessions: Session[]): Promise<void> {
    if (!this.dir) { return; }
    try {
      const limited: Session[] = sessions.length > this.MAX_SESSIONS
        ? sessions.slice(0, this.MAX_SESSIONS) : sessions;
      const list: StoredSession[] = [];
      for (const s of limited) {
        list.push({
          id: s.id, title: s.title, workDir: s.workDir, status: s.status, model: s.model,
          createdAt: s.createdAt, lastActivityAt: s.lastActivityAt, messageCount: s.messageCount,
          projectPath: s.projectPath, workspaceState: s.workspaceState
        });
      }
      this.writeText(this.sessionsPath(), JSON.stringify(list));
    } catch (err) {
      Logger.warn('HistoryStore saveSessions failed: ' + (err as Error).message);
    }
  }

  async loadSessions(): Promise<Session[]> {
    if (!this.dir) { return []; }
    try {
      const json: string = this.readText(this.sessionsPath());
      if (!json) { return []; }
      const raw = JSON.parse(json) as StoredSession[];
      const result: Session[] = [];
      for (const r of raw) {
        const s = new SessionModel(
          r.id, r.workDir, r.model,
          (r.status as 'idle' | 'generating' | 'executing' | 'error') ?? 'idle',
          r.messageCount, r.title ?? ''
        );
        s.createdAt = r.createdAt;
        s.lastActivityAt = r.lastActivityAt;
        s.projectPath = r.projectPath ?? '';
        s.workspaceState = r.workspaceState ?? '';
        result.push(s);
      }
      return result;
    } catch (err) {
      Logger.warn('HistoryStore loadSessions failed: ' + (err as Error).message);
      return [];
    }
  }
}
