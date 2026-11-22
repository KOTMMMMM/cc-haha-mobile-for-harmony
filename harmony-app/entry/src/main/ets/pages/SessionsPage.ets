import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import { SessionModel } from '../models/Session';
import { ChatRouteParams } from '../models/ChatRoute';
import { SessionCard } from '../components/SessionCard';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { HistoryStore } from '../services/HistoryStore';
import { AuthService } from '../services/AuthService';
import { SessionActivityMonitor, ActivityTarget } from '../services/SessionActivityMonitor';
import { Logger } from '../utils/Logger';
import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct SessionsContent {
  @StorageLink('theme') theme: string = 'light';
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('historyStore') historyStore: HistoryStore = new HistoryStore();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('activeSessionId') activeSessionId: string = '';
  @StorageLink('appForeground') @Watch('onForegroundChanged') appForeground: boolean = true;
  @StorageLink('sessionActivityMonitor') activityMonitor: SessionActivityMonitor = new SessionActivityMonitor();
  @StorageLink('sessionsRefresh') @Watch('onSessionsRefresh') sessionsRefresh: number = 0;
  @State sessions: SessionModel[] = [];
  @State isLoading: boolean = false;
  private reachRetryTimer: number = -1;
  private reachRetryCount: number = 0;
  private lastLoadErrorAt: number = 0;
  private refreshTimer: number = -1;
  private disposed: boolean = false;
  private activityListener: () => void = (): void => {};
  private static readonly ACTIVE_REFRESH_MS: number = 8000;
  private static readonly IDLE_REFRESH_MS: number = 30000;

  aboutToAppear(): void {
    this.disposed = false;
    this.activityListener = (): void => { this.applyActivityState(); };
    this.activityMonitor.onChange(this.activityListener);
    this.loadSessions();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.activityMonitor.offChange(this.activityListener);
    this.activityMonitor.stop();
  }

  /** WS 精确订阅更新后，刷新每个卡片的圆点 */
  private applyActivityState(): void {
    if (this.disposed) { return; }
    for (const s of this.sessions) { this.refreshSessionRunning(s); }
  }

  private refreshSessionRunning(s: SessionModel): void {
    const state: boolean | null = this.activityMonitor.getState(s.id);
    if (state === null) { s.refreshRunning(); } else { s.refreshRunning(state); }
  }

  private onForegroundChanged(): void {
    if (!this.appForeground) {
      this.activityMonitor.stop();
    } else if (!this.disposed) {
      this.loadSessions();
    }
  }

  /**
   * 前台列表轮询：有会话在运行就 8s 一次（圆点/消息数及时更新），
   * 全部空闲时退回 30s，避免无谓请求。
   */
  private scheduleNextRefresh(): void {
    if (this.refreshTimer >= 0) { clearTimeout(this.refreshTimer); }
    const delay: number = this.hasRunningSession()
      ? SessionsContent.ACTIVE_REFRESH_MS : SessionsContent.IDLE_REFRESH_MS;
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (this.appForeground && !this.isLoading) {
        this.loadSessions();
      } else {
        this.scheduleNextRefresh();
      }
    }, delay);
  }

  private hasRunningSession(): boolean {
    for (const s of this.sessions) {
      if (s.running) { return true; }
    }
    return false;
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
        this.refreshSessionRunning(next);
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
    // 优先使用 WS 精确订阅结果；未覆盖时才回退 60s 活动窗口
    this.refreshSessionRunning(target);
  }

  /** 冷启动时 Tailscale 可能还没 running：6s 间隔重试，覆盖扩展启动+建 TUN 的窗口。 */
  private scheduleReachRetry(): void {
    if (this.reachRetryCount >= 10 || this.reachRetryTimer >= 0) {
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
        this.activityMonitor.stop();
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
        if (config) {
          if (config.scheme === 'https') {
            // 公网（Cloudflare）并发 WebSocket 有限：活动监视会为多个会话各开一条 WSS，
            // 挤掉聊天页的主连接（表现为消息「未送达」）。远程模式只保留聊天页连接，
            // 运行圆点退回列表轮询/缓存状态。
            this.activityMonitor.stop();
          } else {
            // 对最近活跃的会话做精确运行状态订阅（服务端列表没有运行状态字段）
            this.activityMonitor.start(config.host, config.port, config.token,
              list.map((s: SessionModel): ActivityTarget => {
                return { id: s.id, lastActivityAt: s.lastActivityAt };
              }));
          }
        }
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
      this.activityMonitor.stop();
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
      if (!this.disposed) { this.scheduleNextRefresh(); }
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
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.isLoading && this.sessions.length === 0) {
        Column() {
          LoadingProgress().width(36).height(36).color(ThemeColors.primary)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .accessibilityLevel('yes').accessibilityText('正在加载会话')
      } else if (this.sessions.length === 0) {
        Column()
          .width('100%').height('100%')
          .accessibilityLevel('yes').accessibilityText('暂无会话')
      } else {
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
          ListItem() { Divider().height(88).color(Color.Transparent) }
        }.scrollBar(BarState.Off).width('100%').height('100%')
          .id('session-list')
      }

      Button('+').type(ButtonType.Circle).backgroundColor(ThemeColors.primary).fontColor(ThemeColors.onPrimary(this.theme))
        .fontSize(26).width(52).height(52)
        .margin({ right: 20, bottom: 20 })
        .accessibilityLevel('yes').accessibilityText('新建会话').id('new-session')
        .onClick(() => { this.createNewSession(); })
    }.width('100%').height('100%').backgroundColor(ThemeColors.pageBg(this.theme))
  }
}
