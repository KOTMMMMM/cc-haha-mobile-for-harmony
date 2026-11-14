import router from '@ohos.router';
import { WebSocketService } from '../services/WebSocketService';
import { AuthService } from '../services/AuthService';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { NotificationService } from '../services/NotificationService';
import { TailscaleVpnService } from '../services/TailscaleVpnService';
import { Provider } from '../models/ConnectionConfig';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';
import { promptAction } from '@kit.ArkUI';

interface WsSetRuntimeConfig {
  type: string;
  providerId: string;
  modelId: string;
}

@Component
struct InfoRowView {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop isDark: boolean = false;

  build() {
    Row() {
      Text(this.label).fontSize(15).fontColor(this.isDark ? '#DDD' : '#333')
      Blank()
      Text(this.value).fontSize(14).fontColor('#999')
    }.width('100%').padding(14).backgroundColor(this.isDark ? '#1F1F1F' : '#FFFFFF')
      .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
  }
}

@Component
export struct SettingsContent {
  @StorageLink('wsService') wsService: WebSocketService = new WebSocketService();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('notificationService') notificationService: NotificationService = new NotificationService();
  @StorageLink('tailscaleService') tailscaleService: TailscaleVpnService = new TailscaleVpnService();
  @StorageLink('tailscaleState') tailscaleState: string = 'idle';
  @StorageLink('tailscaleDetail') tailscaleDetail: string = '';
  @StorageLink('tailscaleAuthUrl') tailscaleAuthUrl: string = '';
  @StorageLink('tailscaleSelfIp') tailscaleSelfIp: string = '';
  @StorageLink('tailscaleAutoConnect') tailscaleAutoConnect: boolean = false;
  @State tailscaleBusy: boolean = false;
  @State authKeyInput: string = '';
  @State authKeyBusy: boolean = false;
  @StorageLink('theme') theme: string = 'light';
  @StorageLink('activeSessionId') activeSessionId: string = '';
  @StorageLink('settingsRefresh') @Watch('onRefreshChanged') settingsRefresh: number = 0;
  @StorageLink('settingsHost') settingsHost: string = '';
  @StorageLink('settingsPort') settingsPort: number = 0;
  @State altHostsLabel: string = '无';
  @StorageLink('settingsTokenSet') settingsTokenSet: boolean = false;
  @State isReconnecting: boolean = false;
  @State modelOptions: SelectOption[] = [];
  @State modelIndex: number = -1;
  @State modelLabel: string = '未选择';
  @State notifyEnabled: boolean = true;
  private optionProviderIds: string[] = [];
  private optionModelIds: string[] = [];
  private optionLabels: string[] = [];

  aboutToAppear(): void { this.loadSettings(); }

  onRefreshChanged(): void { this.loadSettings(); }

  async loadSettings(): Promise<void> {
    const conn = await this.authService.getConnectionConfig();
    Logger.warn('[CC] loadSettings conn=' + (conn ? conn.host + ':' + conn.port : 'null'));
    if (conn) {
      this.settingsHost = conn.host;
      this.settingsPort = conn.port;
      this.settingsTokenSet = conn.token.length > 0;
      this.altHostsLabel = (conn.alternates && conn.alternates.length > 0)
        ? conn.alternates.join(' / ') : '无';
    }
    this.notifyEnabled = await this.authService.getNotifyOnComplete();
    this.tailscaleService.refreshStatus();
    // 设置页可能比首页更早发起请求；先确保连接地址可用再拉模型列表
    await this.apiService.ensureConnection(conn);
    await this.loadProviders();
  }

  private tailscaleStatusLabel(): string {
    if (this.tailscaleState === 'running') { return '已连接'; }
    if (this.tailscaleState === 'needs_login') { return '需要登录'; }
    if (this.tailscaleState === 'starting') { return '启动中'; }
    if (this.tailscaleState === 'stopping') { return '正在断开'; }
    if (this.tailscaleState === 'stopped' || this.tailscaleState === 'idle') { return '未启用'; }
    if (this.tailscaleState === 'stale') { return '无响应'; }
    return '失败';
  }

  private async toggleTailscale(on: boolean): Promise<void> {
    if (this.tailscaleBusy) { return; }
    this.tailscaleBusy = true;
    try {
      await this.tailscaleService.setEnabled(on);
    } finally {
      this.tailscaleBusy = false;
    }
  }

  private async loginWithAuthKey(): Promise<void> {
    const key: string = this.authKeyInput.trim();
    if (key.length === 0) {
      promptAction.showToast({ message: '请输入 Auth Key', duration: 2000 });
      return;
    }
    this.authKeyBusy = true;
    try {
      await this.tailscaleService.loginWithAuthKey(key);
      this.authKeyInput = '';
      promptAction.showToast({ message: '已提交 Auth Key，等待连接', duration: 2000 });
    } finally {
      this.authKeyBusy = false;
    }
  }

  private async openTailscaleLogin(): Promise<void> {
    this.tailscaleService.refreshStatus();
    const url: string = this.tailscaleAuthUrl;
    if (!url) {
      promptAction.showToast({ message: '暂时没有登录链接，请稍候重试', duration: 2000 });
      return;
    }
    router.pushUrl({
      url: 'pages/TailscaleLoginPage',
      params: { url: url }
    }).catch((e: Error) => {
      Logger.warn('open Tailscale login page failed: ' + e.message);
    });
  }

  private async toggleNotify(isOn: boolean): Promise<void> {
    this.notifyEnabled = isOn;
    await this.authService.setNotifyOnComplete(isOn);
    if (isOn) {
      const ok = await this.notificationService.ensurePermission();
      if (!ok) {
        promptAction.showToast({ message: '通知权限未开启，请在系统设置中允许通知', duration: 2500 });
      }
    }
  }

  async loadProviders(): Promise<void> {
    try {
      const providers = await this.apiService.getProviders();
      if (providers.length === 0) { return; }
      const opts: SelectOption[] = [];
      const pids: string[] = [];
      const mids: string[] = [];
      const labels: string[] = [];
      for (const p of providers) {
        for (const m of p.models) {
          const label = p.name + ' / ' + m.name;
          opts.push({ value: label });
          pids.push(p.id);
          mids.push(m.id);
          labels.push(label);
        }
      }
      this.modelOptions = opts;
      this.optionProviderIds = pids;
      this.optionModelIds = mids;
      this.optionLabels = labels;
      // 对齐当前会话已使用的模型（直接查会话详情，避免依赖会话列表是否已加载）
      let currentModel = '';
      if (this.activeSessionId) {
        const cur = await this.apiService.getSession(this.activeSessionId);
        if (cur) { currentModel = cur.model; }
      }
      if (currentModel) {
        for (let i = 0; i < mids.length; i++) {
          // 会话里可能带 "[1m]" 等后缀，用前缀匹配
          if (mids[i] === currentModel || currentModel.startsWith(mids[i])) {
            this.modelIndex = i;
            this.modelLabel = labels[i];
            break;
          }
        }
        if (this.modelIndex < 0) { this.modelLabel = currentModel; }
      }
    } catch (e) {
      Logger.warn('loadProviders failed: ' + (e as Error).message);
    }
  }

  private applyModel(index: number): void {
    if (index < 0 || index >= this.optionModelIds.length) { return; }
    const payload: WsSetRuntimeConfig = {
      type: 'set_runtime_config',
      providerId: this.optionProviderIds[index],
      modelId: this.optionModelIds[index]
    };
    this.wsService.send(payload);
    this.modelIndex = index;
    this.modelLabel = this.optionLabels[index];
    Logger.warn('[CC] set runtime model -> ' + this.optionModelIds[index]);
  }

  async reconnect(): Promise<void> {
    this.isReconnecting = true;
    try {
      this.wsService.disconnect();
      const conn = await this.authService.getConnectionConfig();
      if (conn && this.activeSessionId) {
        this.apiService.setConnection(conn.host, conn.port, conn.token);
        this.wsService.connect(conn.host, conn.port, conn.token, this.activeSessionId, conn.origin ?? '');
      }
    } catch (e) {
      Logger.error('Reconnect failed', (e as Error).message);
    } finally { this.isReconnecting = false; }
  }

  async handleLogout(): Promise<void> {
    this.wsService.disconnect();
    try {
      await this.tailscaleService.setEnabled(false);
    } catch (error) {
      Logger.warn('stop tailscale on logout failed: ' + (error as Error).message);
    }
    await this.authService.logout();
    router.replaceUrl({ url: 'pages/PairingPage' });
  }

  private toggleTheme(isOn: boolean): void {
    this.authService.setTheme(isOn ? 'dark' : 'light');
  }

  build() {
    List() {
      ListItem() { this.SectionHeader('连接') }
      ListItem() {
        InfoRowView({ label: '状态', value: this.wsService.getIsConnected() ? '已连接' : '未连接', isDark: this.theme === 'dark' })
      }
      ListItem() {
        InfoRowView({ label: '电脑地址', value: this.settingsHost || '未配置', isDark: this.theme === 'dark' })
      }
      ListItem() {
        InfoRowView({ label: '备用地址', value: this.altHostsLabel, isDark: this.theme === 'dark' })
      }
      ListItem() {
        InfoRowView({ label: '端口', value: this.settingsPort > 0 ? String(this.settingsPort) : '未配置', isDark: this.theme === 'dark' })
      }
      ListItem() {
        InfoRowView({ label: 'H5 令牌', value: this.settingsTokenSet ? '已配置' : '未配置', isDark: this.theme === 'dark' })
      }
      ListItem() {
        InfoRowView({ label: '当前会话', value: this.activeSessionId ? this.activeSessionId.substring(0, 8) : '未选择', isDark: this.theme === 'dark' })
      }
      ListItem() {
        Row() {
          Text('连接').fontSize(15).fontColor('#333')
          Blank()
          Button('重新配对').type(ButtonType.Capsule).backgroundColor('#F5F5F5').fontColor('#333')
            .height(32).margin({ right: 8 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/PairingPage' }).catch((e: Error) => {
                Logger.warn('open pairing page failed: ' + e.message);
              });
            })
          if (this.isReconnecting) {
            LoadingProgress().width(20).height(20).color('#1677FF')
          } else {
            Button('重新连接').type(ButtonType.Capsule).backgroundColor('#E8F4FF').fontColor('#1677FF')
              .height(32).onClick(() => { this.reconnect(); })
          }
        }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
      }

      ListItem() { Divider().height(8).color(Color.Transparent) }
      ListItem() { this.SectionHeader('Tailscale 网络') }
      ListItem() {
        Row() {
          Column() {
            Text('内置 Tailscale').fontSize(15).fontColor('#333')
            Text('开启后自动连接 tailnet，不再需要打开卓易通或另一个 Tailscale App；与 ClashBox 等 VPN 不能同时开启')
              .fontSize(11).fontColor('#999').margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.tailscaleBusy) {
            LoadingProgress().width(22).height(22).color('#1677FF')
          } else {
            Toggle({ type: ToggleType.Switch, isOn: this.tailscaleAutoConnect })
              .onChange((isOn: boolean) => { this.toggleTailscale(isOn); })
          }
        }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
      }
      ListItem() {
        InfoRowView({ label: '状态', value: this.tailscaleStatusLabel(), isDark: this.theme === 'dark' })
      }
      if (this.tailscaleSelfIp.length > 0) {
        ListItem() {
          InfoRowView({ label: 'Tailscale IP', value: this.tailscaleSelfIp, isDark: this.theme === 'dark' })
        }
      }
      if (this.tailscaleState === 'needs_login' && this.tailscaleAuthUrl.length > 0) {
        ListItem() {
          Row() {
            Text('需要在 Tailscale 完成登录').fontSize(13).fontColor('#666').layoutWeight(1)
            Button('应用内登录').type(ButtonType.Capsule).backgroundColor('#E8F4FF').fontColor('#1677FF')
              .height(32).onClick(() => { this.openTailscaleLogin(); })
          }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
        }
      }
      if (this.tailscaleState === 'needs_login') {
        ListItem() {
          Column() {
            Text('或使用 Auth Key 登录（Tailscale 后台生成 tskey-auth-...）')
              .fontSize(12).fontColor('#999').width('100%').margin({ bottom: 8 })
            Row() {
              TextInput({ placeholder: 'tskey-auth-...', text: this.authKeyInput })
                .type(InputType.Password).layoutWeight(1).height(40).fontSize(13)
                .backgroundColor('#F5F5F5').borderRadius(8)
                .onChange((v: string) => { this.authKeyInput = v; })
              Button(this.authKeyBusy ? '提交中...' : '登录')
                .type(ButtonType.Capsule).backgroundColor('#1677FF').fontColor('#FFFFFF')
                .height(36).margin({ left: 8 }).enabled(!this.authKeyBusy)
                .onClick(() => { this.loginWithAuthKey(); })
            }.width('100%')
          }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
        }
      }
      if (this.tailscaleDetail.length > 0 && this.tailscaleState !== 'running') {
        ListItem() {
          Text(this.tailscaleDetail).fontSize(12)
            .fontColor(this.tailscaleState === 'failed' ? '#F44336' : '#999')
            .width('100%').padding(14).backgroundColor('#FFFFFF')
        }
      }

      ListItem() { Divider().height(8).color(Color.Transparent) }
      ListItem() { this.SectionHeader('通知') }
      ListItem() {
        Row() {
          Column() {
            Text('回复完成通知').fontSize(15).fontColor('#333')
            Text('回复结束后提醒；手表通过系统通知同步接收').fontSize(11).fontColor('#999').margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.notifyEnabled })
            .onChange((isOn: boolean) => { this.toggleNotify(isOn); })
        }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
      }

      ListItem() { Divider().height(8).color(Color.Transparent) }
      ListItem() { this.SectionHeader('模型') }
      ListItem() {
        Row() {
          Text('模型').fontSize(15).fontColor('#333')
          Blank()
          if (this.modelOptions.length > 0) {
            Select(this.modelOptions)
              .selected(this.modelIndex)
              .value(this.modelLabel)
              .font({ size: 13 })
              .fontColor('#1677FF')
              .onSelect((index: number, value: string) => { this.applyModel(index); })
          } else {
            Text('加载中...').fontSize(13).fontColor('#999')
          }
        }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
      }

      ListItem() { Divider().height(8).color(Color.Transparent) }
      ListItem() { this.SectionHeader('外观') }
      ListItem() {
        Row() {
          Text('深色模式').fontSize(15).fontColor('#333')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.theme === 'dark' })
            .onChange((isOn: boolean) => { this.toggleTheme(isOn); })
        }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
      }

      ListItem() { Divider().height(8).color(Color.Transparent) }
      ListItem() { this.SectionHeader('关于') }
      ListItem() { InfoRowView({ label: '版本', value: Constants.APP_VERSION, isDark: this.theme === 'dark' }) }
      ListItem() { InfoRowView({ label: 'SDK 版本', value: 'API 12', isDark: this.theme === 'dark' }) }

      ListItem() { Divider().height(24).color(Color.Transparent) }
      ListItem() {
        Button('断开连接并退出').type(ButtonType.Capsule).backgroundColor('#FFF5F5').fontColor('#F44336')
          .width('60%').height(44).onClick(() => { this.handleLogout(); })
      }.width('100%').align(Alignment.Center).margin({ bottom: 32 })
    }
    .scrollBar(BarState.Off).width('100%').height('100%').backgroundColor(this.theme === 'dark' ? '#141414' : '#F8F8F8')
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      if (isVisible) { this.loadSettings(); }
    })
  }

  @Builder SectionHeader(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#999')
      .width('100%').padding({ left: 16, top: 14, bottom: 8 })
  }
}
