import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import { SessionModel } from '../models/Session';
import { ChatRouteParams } from '../models/ChatRoute';
import { SessionCard } from '../components/SessionCard';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { HistoryStore } from '../services/HistoryStore';
import { AuthService } from '../services/AuthService';
import { Logger } from '../utils/Logger';

@Component
export struct SessionsContent {
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('historyStore') historyStore: HistoryStore = new HistoryStore();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('activeSessionId') activeSessionId: string = '';
  @StorageLink('appForeground') appForeground: boolean = true;
  @StorageLink('sessionsRefresh') @Watch('onSessionsRefresh') sessionsRefresh: number = 0;
  @State sessions: SessionModel[] = [];
  @State isLoading: boolean = false;
  private reachRetryTimer: number = -1;
  private reachRetryCount: number = 0;
  private lastLoadErrorAt: number = 0;
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    this.loadSessions();
    this.startPeriodicRefresh();
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  /** 前台每 30s 拉一次列表：新会话/标题/消息数在无推送时也能自动更新。 */
  private startPeriodicRefresh(): void {
    if (this.refreshTimer >= 0) { return; }
    this.refreshTimer = setInterval((): void => {
      if (this.appForeground && !this.isLoading) {
        this.loadSessions();
      }
    }, 30000);
  }

  /** 用新数据原位更新已有卡片实例（配合 @Observed/@ObjectLink，避免 key 抖动）。 */
  private applySessions(list: SessionModel[]): void {
    const existing: Map<string, SessionModel> = new Map<string, SessionModel>();
    for (const s of this.sessions) { existing.set(s.id, s); }
    const merged: SessionModel[] = [];
    for (const next of list) {
      const old = existing.get(next.id);
      if (old) {
        this.copySession(old, next);
        merged.push(old);
      } else {
        merged.push(next);
      }
    }
    this.sessions = merged;
    this.sessionService.setSessions(merged);
  }

  private copySession(target: SessionModel, source: SessionModel): void {
    target.title = source.title;
    target.workDir = source.workDir;
    target.status = source.status;
    target.model = source.model;
    target.createdAt = source.createdAt;
    target.lastActivityAt = source.lastActivityAt;
    target.messageCount = source.messageCount;
    target.projectPath = source.projectPath;
    target.workspaceState = source.workspaceState;
    target.runtimeProviderId = source.runtimeProviderId;
    target.effortLevel = source.effortLevel;
    target.permissionMode = source.permissionMode;
  }

  /** 冷启动时 Tailscale 可能还没 running：短间隔重试几次，恢复后自动上屏。 */
  private scheduleReachRetry(): void {
    if (this.reachRetryCount >= 5 || this.reachRetryTimer >= 0) {
      return;
    }
    this.reachRetryCount++;
    this.reachRetryTimer = setTimeout(() => {
      this.reachRetryTimer = -1;
      this.loadSessions();
    }, 6000);
  }

  private onSessionsRefresh(): void { this.loadSessions(); }

  async loadSessions(): Promise<void> {
    this.isLoading = true;
    try {
      const config = await this.authService.getConnectionConfig();
      const reachable: boolean = await this.apiService.ensureConnection(config);
      if (!reachable) {
        // 当前网络没有可达地址（如 Tailscale 尚未 running），直接上缓存，
        // 等连接建立后由 sessionsRefresh 或下面的重试再拉取。
        const local = await this.historyStore.loadSessions();
        if (local.length > 0) {
          this.applySessions(local);
        }
        this.scheduleReachRetry();
        return;
      }
      this.reachRetryCount = 0;
      const list = await this.apiService.getSessions();
      if (list.length > 0) {
        this.applySessions(list);
        this.historyStore.saveSessions(list);
        this.clearStaleActive(list);
        if (!this.activeSessionId) { this.selectSession(list[0]); }
      } else {
        const local = await this.historyStore.loadSessions();
        if (local.length > 0) {
          this.applySessions(local);
        }
      }
    } catch (e) {
      Logger.error('Failed to load sessions', (e as Error).message);
      const local = await this.historyStore.loadSessions();
      if (local.length > 0) {
        this.applySessions(local);
      }
      const now = Date.now();
      if (now - this.lastLoadErrorAt > 15000) {
        this.lastLoadErrorAt = now;
        promptAction.showToast({ message: '加载会话失败，已显示本地缓存', duration: 2000 });
      }
      this.scheduleReachRetry();
    } finally {
      this.isLoading = false;
    }
  }

  async createNewSession(): Promise<void> {
    try {
      const session = await this.apiService.createSession();
      if (session) {
        this.sessions = [session, ...this.sessions];
        this.sessionService.setSessions(this.sessions);
        this.historyStore.saveSessions(this.sessions);
        this.openSession(session);
      }
    } catch (e) {
      Logger.error('Failed to create session', (e as Error).message);
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    try {
      await this.apiService.deleteSession(sessionId);
      this.sessions = this.sessions.filter(s => s.id !== sessionId);
      this.sessionService.setSessions(this.sessions);
      this.sessionService.removeSession(sessionId);
      this.historyStore.deleteMessages(sessionId);
      this.historyStore.saveSessions(this.sessions);
      if (this.sessionService.getCurrentSessionId() === sessionId) {
        this.authService.setCurrentSessionId('');
        AppStorage.setOrCreate('activeSessionId', '');
      }
    } catch (e) {
      Logger.error('Failed to delete session', (e as Error).message);
    }
  }

  /** 当前会话已被删除时清掉，避免继续显示高亮/轮询不存在的会话。 */
  private clearStaleActive(list: SessionModel[]): void {
    if (!this.activeSessionId) { return; }
    for (const s of list) {
      if (s.id === this.activeSessionId) { return; }
    }
    this.sessionService.setCurrentSessionId('');
    this.authService.setCurrentSessionId('');
    AppStorage.setOrCreate('activeSessionId', '');
    AppStorage.setOrCreate('activeSessionTitle', '');
  }

  /** 只记录当前会话（用于列表高亮），不进入聊天页 */
  private selectSession(session: SessionModel): void {
    this.sessionService.setCurrentSessionId(session.id);
    this.authService.setCurrentSessionId(session.id);
    AppStorage.setOrCreate('activeSessionId', session.id);
    AppStorage.setOrCreate('activeSessionTitle', session.getDisplayTitle());
  }

  /** 微信式进入：点击会话 push 独立聊天页，返回后仍在列表 */
  private openSession(session: SessionModel): void {
    this.selectSession(session);
    const params: ChatRouteParams = {
      sessionId: session.id,
      title: session.getDisplayTitle()
    };
    router.pushUrl({ url: 'pages/ChatDetailPage', params: params }).catch((e: Error) => {
      Logger.error('Failed to open chat page', e.message);
    });
  }

  build() {
    Stack() {
      if (this.isLoading && this.sessions.length === 0) {
        Column() {
          LoadingProgress().width(36).height(36).color('#1677FF')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.sessions.length === 0) {
        Column() {
          Text('暂无会话').fontSize(20).fontWeight(FontWeight.Bold).margin({ bottom: 8 })
          Text('新建一个会话开始使用').fontSize(14).fontColor('#999').margin({ bottom: 24 })
          Button('新建会话').type(ButtonType.Capsule).backgroundColor('#1677FF').fontColor(Color.White)
            .width('60%').height(44).onClick(() => { this.createNewSession(); })
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Column() {
          Row() {
            Text('会话').fontSize(18).fontWeight(FontWeight.Bold)
            Blank()
            Text(this.sessions.length + ' 个活动').fontSize(12).fontColor('#999')
          }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

          List() {
            ForEach(this.sessions, (session: SessionModel) => {
              ListItem() {
                SessionCard({
                  session: session,
                  isSelected: session.id === this.activeSessionId,
                  onTap: () => { this.openSession(session); },
                  onDelete: () => { this.deleteSession(session.id); }
                })
              }
            }, (s: SessionModel) => s.id)
            ListItem() { Divider().height(80).color(Color.Transparent) }
          }.scrollBar(BarState.Off).layoutWeight(1).width('100%')

          Button('+').type(ButtonType.Circle).backgroundColor('#1677FF').fontColor(Color.White)
            .fontSize(28).width(56).height(56)
            .position({ x: '85%', y: '88%' })
            .onClick(() => { this.createNewSession(); })
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%').backgroundColor('#F8F8F8')
  }
}
