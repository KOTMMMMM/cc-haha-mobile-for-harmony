import router from '@ohos.router';
import { WebSocketService } from '../services/WebSocketService';
import { AuthService } from '../services/AuthService';
import { ApiService } from '../services/ApiService';
import { NotificationService } from '../services/NotificationService';
import { TailscaleVpnService } from '../services/TailscaleVpnService';
import { Constants } from '../utils/Constants';
import { ThemeUtil, ThemeColors } from '../utils/ThemeUtil';
import { Logger } from '../utils/Logger';
import { promptAction } from '@kit.ArkUI';

@Component
struct InfoRowView {
  @StorageLink('theme') theme: string = 'light';
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label).fontSize(15).fontColor(ThemeColors.text(this.theme))
      Blank()
      Text(this.value).fontSize(13).fontColor(ThemeColors.textSecondary(this.theme))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '55%' })
    }.width('100%').height(50).padding({ left: 16, right: 16 })
  }
}

@Component
export struct SettingsContent {
  /** 与首页顶部连接条一致：基于实际可达性/WS 状态，由 Index 传入并响应更新 */
  @Prop connectionState: string = 'disconnected';
  @StorageLink('wsService') wsService: WebSocketService = new WebSocketService();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
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
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('activeSessionId') activeSessionId: string = '';
  @StorageLink('settingsRefresh') @Watch('onRefreshChanged') settingsRefresh: number = 0;
  @StorageLink('settingsHost') settingsHost: string = '';
  @StorageLink('settingsPort') settingsPort: number = 0;
  @State settingsScheme: string = 'http';
  @State altHostsLabel: string = '无';
  @State isReconnecting: boolean = false;
  @State notifyEnabled: boolean = true;

  aboutToAppear(): void { this.loadSettings(); }

  onRefreshChanged(): void { this.loadSettings(); }

  async loadSettings(): Promise<void> {
    const conn = await this.authService.getConnectionConfig();
    Logger.warn('[CC] loadSettings conn=' + (conn ? conn.host + ':' + conn.port : 'null'));
    if (conn) {
      this.settingsHost = conn.host;
      this.settingsPort = conn.port;
      this.settingsScheme = conn.scheme === 'https' ? 'https' : 'http';
      this.altHostsLabel = (conn.alternates && conn.alternates.length > 0)
        ? conn.alternates.join(' / ') : '无';
    }
    this.notifyEnabled = await this.authService.getNotifyOnComplete();
    this.tailscaleService.refreshStatus();
    // 设置页可能比首页更早发起请求；先确保连接地址可用
    await this.apiService.ensureConnection(conn);
  }

  private connectionStatusLabel(): string {
    if (this.connectionState === 'connected') { return '已连接'; }
    if (this.connectionState === 'connecting') { return '连接中'; }
    return '未连接';
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

  private async restartTailscale(): Promise<void> {
    if (this.tailscaleBusy) { return; }
    this.tailscaleBusy = true;
    try {
      await this.tailscaleService.restart();
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
      promptAction.showToast({ message: '已提交', duration: 1500 });
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

  private async testNotification(): Promise<void> {
    const enabled: boolean = await this.notificationService.ensurePermission();
    if (!enabled) {
      promptAction.showToast({ message: '通知权限未开启，请先在系统设置中允许', duration: 2200 });
      return;
    }
    await this.notificationService.notifyTurnComplete('Claude Haha · 测试通知', '通知权限正常');
  }

  async reconnect(): Promise<void> {
    this.isReconnecting = true;
    try {
      this.wsService.disconnect();
      const conn = await this.authService.getConnectionConfig();
      if (conn && this.activeSessionId) {
        this.apiService.setConnection(conn.host, conn.port, conn.token, conn.scheme ?? 'http');
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

  /** 选择后立即按当前系统配色重算，无需等下一次系统切换回调。 */
  private setThemeMode(mode: string): void {
    const systemDark: boolean = AppStorage.get<boolean>('systemDark') ?? false;
    ThemeUtil.apply(mode, systemDark);
    this.authService.setTheme(ThemeUtil.normalizeMode(mode));
  }

  private openPairing(): void {
    router.pushUrl({ url: 'pages/PairingPage' }).catch((e: Error) => {
      Logger.warn('open pairing page failed: ' + e.message);
    });
  }

  build() {
    Scroll() {
      Column() {
        this.SectionTitle('连接')
        Column() {
          InfoRowView({ label: '状态', value: this.connectionStatusLabel() })
          Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
          InfoRowView({
            label: '地址',
            value: !this.settingsHost ? '未配置'
              : (this.settingsScheme === 'https'
                ? ('https://' + this.settingsHost)
                : (this.settingsHost + ':' + this.settingsPort))
          })
          Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
          InfoRowView({ label: '备用地址', value: this.altHostsLabel })
          Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
          Row() {
            Text('重新连接').fontSize(15).fontColor(ThemeColors.text(this.theme))
            Blank()
            if (this.isReconnecting) {
              LoadingProgress().width(18).height(18).color(ThemeColors.primary)
            } else {
              Text('↻').fontSize(15).fontColor(ThemeColors.primary).accessibilityLevel('no')
            }
          }
          .width('100%').height(50).padding({ left: 16, right: 16 })
          .accessibilityLevel('yes').accessibilityText('重新连接').id('settings-reconnect')
          .onClick(() => { this.reconnect(); })
          Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
          Row() {
            Text('重新配对').fontSize(15).fontColor(ThemeColors.text(this.theme))
            Blank()
            Text('›').fontSize(16).fontColor(ThemeColors.textSecondary(this.theme)).accessibilityLevel('no')
          }
          .width('100%').height(50).padding({ left: 16, right: 16 })
          .accessibilityLevel('yes').accessibilityText('重新配对').id('settings-repair')
          .onClick(() => { this.openPairing(); })
        }
        .width('100%').backgroundColor(ThemeColors.card(this.theme)).borderRadius(12).clip(true)
        .margin({ left: 16, right: 16 })

        this.SectionTitle('Tailscale')
        Column() {
          Row() {
            Text('内置 Tailscale').fontSize(15).fontColor(ThemeColors.text(this.theme))
            Blank()
            if (this.tailscaleBusy) {
              LoadingProgress().width(20).height(20).color(ThemeColors.primary)
            } else {
              Toggle({ type: ToggleType.Switch, isOn: this.tailscaleAutoConnect })
                .accessibilityLevel('yes').accessibilityText('内置 Tailscale').id('ts-toggle')
                .onChange((isOn: boolean) => { this.toggleTailscale(isOn); })
            }
          }
          .width('100%').height(50).padding({ left: 16, right: 16 })
          Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
          InfoRowView({ label: '状态', value: this.tailscaleStatusLabel() })
          if (this.tailscaleSelfIp.length > 0) {
            Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
            InfoRowView({ label: 'IP', value: this.tailscaleSelfIp })
          }
          if (this.tailscaleAutoConnect) {
            Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
            Row() {
              Text('重启').fontSize(15).fontColor(ThemeColors.text(this.theme))
              Blank()
              Text('↻').fontSize(15).fontColor(ThemeColors.primary).accessibilityLevel('no')
            }
            .width('100%').height(50).padding({ left: 16, right: 16 })
            .accessibilityLevel('yes').accessibilityText('重启 Tailscale').id('ts-restart')
            .onClick(() => { this.restartTailscale(); })
          }
          if (this.tailscaleState === 'needs_login' && this.tailscaleAuthUrl.length > 0) {
            Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
            Row() {
              Text('登录').fontSize(15).fontColor(ThemeColors.text(this.theme))
              Blank()
              Text('›').fontSize(16).fontColor(ThemeColors.textSecondary(this.theme)).accessibilityLevel('no')
            }
            .width('100%').height(50).padding({ left: 16, right: 16 })
            .accessibilityLevel('yes').accessibilityText('连接 Tailscale 账号').id('ts-login')
            .onClick(() => { this.openTailscaleLogin(); })
          }
          if (this.tailscaleState === 'needs_login') {
            Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
            Row() {
              TextInput({ placeholder: 'Auth Key', text: this.authKeyInput })
                .type(InputType.Password).layoutWeight(1).height(38).fontSize(13)
                .fontColor(ThemeColors.text(this.theme)).placeholderColor(ThemeColors.placeholder(this.theme))
                .backgroundColor(ThemeColors.inputBg(this.theme)).borderRadius(8)
                .accessibilityLevel('yes').accessibilityText('Auth Key').id('ts-authkey')
                .onChange((v: string) => { this.authKeyInput = v; })
              Button(this.authKeyBusy ? '提交中' : '登录')
                .type(ButtonType.Capsule).backgroundColor(ThemeColors.primary)
                .fontColor(ThemeColors.onPrimary(this.theme)).height(38).margin({ left: 8 })
                .enabled(!this.authKeyBusy)
                .accessibilityLevel('yes').accessibilityText('用 Auth Key 登录').id('ts-authkey-submit')
                .onClick(() => { this.loginWithAuthKey(); })
            }
            .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          if (this.tailscaleDetail.length > 0 && this.tailscaleState !== 'running') {
            Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
            Text(this.tailscaleDetail).fontSize(12).lineHeight(17).maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.tailscaleState === 'failed'
                ? ThemeColors.dangerText(this.theme) : ThemeColors.textSecondary(this.theme))
              .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 10 })
          }
        }
        .width('100%').backgroundColor(ThemeColors.card(this.theme)).borderRadius(12).clip(true)
        .margin({ left: 16, right: 16 })

        this.SectionTitle('通知')
        Column() {
          Row() {
            Text('回复完成通知').fontSize(15).fontColor(ThemeColors.text(this.theme))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.notifyEnabled })
              .accessibilityLevel('yes').accessibilityText('回复完成通知').id('notify-toggle')
              .onChange((isOn: boolean) => { this.toggleNotify(isOn); })
          }
          .width('100%').height(50).padding({ left: 16, right: 16 })
          if (this.notifyEnabled) {
            Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
            Row() {
              Text('测试通知').fontSize(15).fontColor(ThemeColors.text(this.theme))
              Blank()
              Text('›').fontSize(16).fontColor(ThemeColors.textSecondary(this.theme)).accessibilityLevel('no')
            }
            .width('100%').height(50).padding({ left: 16, right: 16 })
            .accessibilityLevel('yes').accessibilityText('发送测试通知').id('notify-test')
            .onClick(() => { this.testNotification(); })
          }
        }
        .width('100%').backgroundColor(ThemeColors.card(this.theme)).borderRadius(12).clip(true)
        .margin({ left: 16, right: 16 })

        Column() {
          Row() {
            this.ThemeModeButton('跟随系统', ThemeUtil.MODE_SYSTEM)
            this.ThemeModeButton('浅色', ThemeUtil.MODE_LIGHT)
            this.ThemeModeButton('深色', ThemeUtil.MODE_DARK)
          }.width('100%').padding(12)
        }
        .width('100%').backgroundColor(ThemeColors.card(this.theme)).borderRadius(12).clip(true)
        .margin({ left: 16, right: 16, top: 20 })

        this.SectionTitle('关于')
        Column() {
          InfoRowView({ label: '版本', value: Constants.APP_VERSION })
          Divider().strokeWidth(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 16 })
          Row() {
            Text('断开连接并退出').fontSize(15).fontColor(ThemeColors.dangerText(this.theme))
          }
          .width('100%').height(50).justifyContent(FlexAlign.Center)
          .accessibilityLevel('yes').accessibilityText('断开连接并退出').id('settings-logout')
          .onClick(() => { this.handleLogout(); })
        }
        .width('100%').backgroundColor(ThemeColors.card(this.theme)).borderRadius(12).clip(true)
        .margin({ left: 16, right: 16 })

        Divider().height(32).color(Color.Transparent)
      }
      .width('100%')
    }
    .scrollBar(BarState.Off).width('100%').height('100%').backgroundColor(ThemeColors.pageBg(this.theme))
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      if (isVisible) { this.loadSettings(); }
    })
  }

  @Builder SectionTitle(title: string) {
    Text(title).fontSize(12).fontColor(ThemeColors.textSecondary(this.theme))
      .width('100%').padding({ left: 16, right: 16, top: 20, bottom: 6 })
  }

  @Builder ThemeModeButton(label: string, mode: string) {
    Button(label).type(ButtonType.Capsule).height(36).fontSize(13).layoutWeight(1)
      .backgroundColor(this.themeMode === mode ? ThemeColors.primary : ThemeColors.chipBg(this.theme))
      .fontColor(this.themeMode === mode ? ThemeColors.onPrimary(this.theme) : ThemeColors.text(this.theme))
      .margin({ right: mode === ThemeUtil.MODE_DARK ? 0 : 8 })
      .accessibilityLevel('yes')
      .accessibilityText('外观 ' + label + (this.themeMode === mode ? '，已选中' : ''))
      .id('theme-' + mode)
      .onClick(() => { this.setThemeMode(mode); })
  }
}
