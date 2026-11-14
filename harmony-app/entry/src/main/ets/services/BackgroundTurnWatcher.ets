import { WebSocketService, WsEvent } from './WebSocketService';
import { ApiService } from './ApiService';
import { NotificationService } from './NotificationService';
import { BackgroundTaskService } from './BackgroundTaskService';
import { AuthService } from './AuthService';
import { parseServerMessages, lastAssistantSnippet } from './chat/ChatHistoryUtils';
import { Logger } from '../utils/Logger';

const OWNER: string = 'bg-turn-watcher';
const MAX_WATCH_MS: number = 30 * 60 * 1000;

/**
 * 离开「生成中」的聊天页时接管该会话的 WS：
 * 主 WebSocketService 是单连接，切换到其他会话会断开旧会话；
 * watcher 用独立连接等待这一轮完成并发出通知，避免后台完成事件丢失。
 */
export class BackgroundTurnWatcher {
  private ws: WebSocketService = new WebSocketService();
  private timer: number = -1;
  private sessionId: string = '';
  private title: string = '';
  private apiService: ApiService;
  private notificationService: NotificationService;
  private authService: AuthService;
  private bgTaskService: BackgroundTaskService;

  constructor(apiService: ApiService, notificationService: NotificationService,
              authService: AuthService, bgTaskService: BackgroundTaskService) {
    this.apiService = apiService;
    this.notificationService = notificationService;
    this.authService = authService;
    this.bgTaskService = bgTaskService;
  }

  isWatching(sessionId: string): boolean {
    return this.sessionId.length > 0 && this.sessionId === sessionId;
  }

  start(sessionId: string, title: string, host: string, port: number, token: string): void {
    if (!sessionId || !host || !token) { return; }
    if (this.isWatching(sessionId)) { return; }
    this.stop();
    this.sessionId = sessionId;
    this.title = title.length > 0 ? title : 'Claude Haha';
    this.setupHandlers();
    this.ws.connect(host, port, token, sessionId, 'http://' + host + ':' + port)
      .catch((error: Error): void => {
        Logger.warn('[BG] watcher connect failed: ' + error.message);
        this.stop();
      });
    this.timer = setTimeout((): void => { this.stop(); }, MAX_WATCH_MS);
    Logger.info('[BG] watching session ' + sessionId.substring(0, 8));
  }

  /** 不传 sessionId 时停止任意监听；传了就只在匹配时停止。 */
  stop(sessionId?: string): void {
    if (sessionId && this.sessionId.length > 0 && this.sessionId !== sessionId) { return; }
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.ws.clearHandlers(OWNER);
    this.ws.disconnect();
    this.sessionId = '';
    this.title = '';
  }

  private setupHandlers(): void {
    this.ws.clearHandlers(OWNER);
    const onFinished = (): void => { this.notifyAndStop(); };
    this.ws.on('message_complete', (_event: WsEvent): void => { onFinished(); }, OWNER);
    this.ws.on('status', (event: WsEvent): void => {
      if ((event.state as string) === 'idle') { onFinished(); }
    }, OWNER);
    this.ws.on('session_state', (event: WsEvent): void => {
      if ((event.turnState as string) !== 'running') { onFinished(); }
    }, OWNER);
  }

  private async notifyAndStop(): Promise<void> {
    const sid: string = this.sessionId;
    const title: string = this.title;
    if (!sid) { return; }
    this.stop();
    try {
      if (!(await this.authService.getNotifyOnComplete())) { return; }
      let body: string = '回复已完成，点击查看';
      try {
        const page = await this.apiService.getMessagesPage(sid);
        if (page.messages.length > 0) {
          body = lastAssistantSnippet(parseServerMessages(page.messages));
        }
      } catch (error) {
        Logger.debug('[BG] fetch snippet failed: ' + (error as Error).message);
      }
      await this.notificationService.notifyTurnComplete(title + ' · 回复完成', body);
    } catch (error) {
      Logger.warn('[BG] notify failed: ' + (error as Error).message);
    } finally {
      this.bgTaskService.stop();
    }
  }
}
