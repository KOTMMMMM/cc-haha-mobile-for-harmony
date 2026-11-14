import router from '@ohos.router';
import { ConnectionStatus } from '../components/ConnectionStatus';
import { SessionsContent } from './SessionsPage';
import { SettingsContent } from './SettingsPage';
import { WebSocketService } from '../services/WebSocketService';
import { AuthService } from '../services/AuthService';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { TailscaleVpnService } from '../services/TailscaleVpnService';
import { Logger } from '../utils/Logger';

@Entry
@Component
struct Index {
  @StorageLink('wsService') wsService: WebSocketService = new WebSocketService();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('tailscaleService') tailscaleService: TailscaleVpnService = new TailscaleVpnService();
  @StorageLink('theme') theme: string = 'light';
  @State currentTabIndex: number = 0;
  @State connectionState: string = 'disconnected';
  @StorageLink('pcReachable') pcReachable: boolean = false;
  @StorageLink('pcActiveHost') pcHostname: string = '';
  @StorageLink('tailscaleState') tailscaleState: string = 'idle';
  private healthTimer: number = -1;
  // 固定引用，页面重建时才能从全局 WS 上注销，避免回调累积
  private readonly connectionStateListener: (state: string) => void = (state: string): void => {
    this.connectionState = state;
  };

  aboutToAppear(): void {
    Logger.info('Index page appeared');
    if (this.wsService) {
      this.connectionState = this.wsService.getConnectionState();
      this.wsService.onConnectionStateChange(this.connectionStateListener);
    }
    this.checkAuth();
    this.startHealthMonitor();
  }

  aboutToDisappear(): void {
    if (this.healthTimer >= 0) {
      clearInterval(this.healthTimer);
      this.healthTimer = -1;
    }
    if (this.wsService) {
      this.wsService.offConnectionStateChange(this.connectionStateListener);
    }
  }

  /** 前台每 30s 轻量探活：PC 离线或切网时及时更新横幅并重新选地址。 */
  private startHealthMonitor(): void {
    if (this.healthTimer >= 0) { return; }
    this.healthTimer = setInterval((): void => {
      this.checkHealth();
    }, 30000);
  }

  private async checkHealth(): Promise<void> {
    if (AppStorage.get<boolean>('appForeground') === false) { return; }
    if (this.apiService.getBaseUrl().length === 0) {
      const config = await this.authService.getConnectionConfig();
      const reachable: boolean = await this.apiService.ensureConnection(config);
      if (reachable) { AppStorage.setOrCreate('sessionsRefresh', Date.now()); }
      return;
    }
    const ok: boolean = await this.apiService.healthCheckCurrent();
    if (ok) { return; }
    // 当前地址失效：强制重探测（可能从局域网切到 Tailscale 或反之）
    const previousHost: string = this.apiService.getCurrentHost();
    this.apiService.invalidateResolution();
    const config = await this.authService.getConnectionConfig();
    const reachable: boolean = await this.apiService.ensureConnection(config);
    if (!reachable) {
      AppStorage.setOrCreate('pcReachable', false);
      return;
    }
    AppStorage.setOrCreate('sessionsRefresh', Date.now());
    if (this.apiService.getCurrentHost() !== previousHost) {
      AppStorage.setOrCreate('chatRefresh', Date.now());
    }
  }

  async checkAuth(): Promise<void> {
    if (this.authService) {
      const isAuthed = await this.authService.isAuthenticated();
      if (!isAuthed) {
        router.replaceUrl({ url: 'pages/PairingPage' });
      } else {
        const config = await this.authService.getConnectionConfig();
        if (config) {
          this.pcHostname = config.hostname ?? config.host;
          // 与列表页使用同一套可达性选择，避免把选好的 Tailscale 地址
          // 覆盖回不可达的局域网地址。
          await this.apiService.ensureConnection(config);
          // WebSocket 由 ChatPage 按当前会话建立（新版为 /ws/<sessionId>）
          this.tailscaleService.ensureConnected();
        }
        // 恢复上次打开会话
        const sid = await this.authService.getCurrentSessionId();
        if (sid) {
          this.sessionService.setCurrentSessionId(sid);
          AppStorage.setOrCreate('activeSessionId', sid);
        }
      }
    }
  }

  /** 列表页没有 WS，但 REST 可用时也应显示“已连接”，避免误报未连接。 */
  private displayConnectionState(): string {
    if (this.connectionState === 'connected' || this.pcReachable) {
      return 'connected';
    }
    // 冷启动 Tailscale 还在建网时不要显示红色“未连接”
    if (this.tailscaleState === 'starting') {
      return 'connecting';
    }
    return this.connectionState;
  }

  build() {
    Column() {
      ConnectionStatus({
        connectionState: this.displayConnectionState(),
        pcHostname: this.pcHostname,
        isDark: this.theme === 'dark',
        onTap: () => { this.currentTabIndex = 1; },
        onRefresh: () => {
          AppStorage.setOrCreate('chatRefresh', Date.now());
          AppStorage.setOrCreate('sessionsRefresh', Date.now());
        }
      })

      // 微信式导航：会话列表是首页，点击会话 push 独立聊天页（覆盖底部 Tab），返回后回到列表
      Tabs({ barPosition: BarPosition.End, index: this.currentTabIndex }) {
        TabContent() { SessionsContent() }
          .tabBar(this.TabBar('会话', 0))

        TabContent() { SettingsContent() }
          .tabBar(this.TabBar('设置', 1))
      }
      .barWidth('100%').barHeight(56).scrollable(false)
      .onChange((index: number) => {
        this.currentTabIndex = index;
        if (index === 1) {
          AppStorage.setOrCreate('settingsRefresh', Date.now());
        } else {
          // 切回会话页时拉一次最新列表（标题/消息数/时间可能已变化）
          AppStorage.setOrCreate('sessionsRefresh', Date.now());
        }
      })
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(this.theme === 'dark' ? '#141414' : '#F8F8F8')
  }

  @Builder TabBar(title: string, index: number) {
    Column() {
      Text(this.getTabIcon(index)).fontSize(22)
        .fontColor(this.currentTabIndex === index ? '#1677FF' : (this.theme === 'dark' ? '#666' : '#999'))
      Text(title).fontSize(10)
        .fontColor(this.currentTabIndex === index ? '#1677FF' : (this.theme === 'dark' ? '#666' : '#999'))
        .margin({ top: 2 })
    }
    .padding({ top: 4, bottom: 4 }).width('100%')
    .alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
    .onClick(() => { this.currentTabIndex = index; })
  }

  private getTabIcon(index: number): string {
    const icons: string[] = ['S', 'ST'];
    return icons[index] || '';
  }
}
