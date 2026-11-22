import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import resourceManager from '@ohos.resourceManager';
import { Configuration } from '@ohos.app.ability.Configuration';
import { WebSocketService } from '../services/WebSocketService';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { AuthService } from '../services/AuthService';
import { HistoryStore } from '../services/HistoryStore';
import { NotificationService } from '../services/NotificationService';
import { BackgroundTaskService } from '../services/BackgroundTaskService';
import { BackgroundTurnWatcher } from '../services/BackgroundTurnWatcher';
import { SessionActivityMonitor } from '../services/SessionActivityMonitor';
import { TailscaleVpnService } from '../services/TailscaleVpnService';
import { ThemeUtil } from '../utils/ThemeUtil';
import { Logger } from '../utils/Logger';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('EntryAbility onCreate');
    const wsService = new WebSocketService();
    const apiService = new ApiService();
    const sessionService = new SessionService();
    const authService = new AuthService();
    const historyStore = new HistoryStore();
    const notificationService = new NotificationService();
    notificationService.initialize(this.context);
    const backgroundTaskService = new BackgroundTaskService();
    backgroundTaskService.initialize(this.context);
    const sessionActivityMonitor = new SessionActivityMonitor();
    const backgroundTurnWatcher = new BackgroundTurnWatcher(
      apiService, notificationService, authService, backgroundTaskService, sessionActivityMonitor);
    const tailscaleService = new TailscaleVpnService();
    tailscaleService.initialize(this.context);
    // 首帧先按系统配色，读到用户偏好后再覆盖（默认跟随系统）
    ThemeUtil.apply(ThemeUtil.MODE_SYSTEM, this.readSystemDark());
    authService.initialize(this.context).then((): void => {
      authService.getTheme().then((mode: string): void => {
        ThemeUtil.apply(mode, this.readSystemDark());
      });
    });
    historyStore.initialize(this.context);
    // 首次启动申请通知授权（拒绝后可在设置页重新开启）
    notificationService.ensurePermission();
    AppStorage.setOrCreate('wsService', wsService);
    AppStorage.setOrCreate('apiService', apiService);
    AppStorage.setOrCreate('sessionService', sessionService);
    AppStorage.setOrCreate('authService', authService);
    AppStorage.setOrCreate('historyStore', historyStore);
    AppStorage.setOrCreate('notificationService', notificationService);
    AppStorage.setOrCreate('backgroundTaskService', backgroundTaskService);
    AppStorage.setOrCreate('backgroundTurnWatcher', backgroundTurnWatcher);
    AppStorage.setOrCreate('sessionActivityMonitor', sessionActivityMonitor);
    AppStorage.setOrCreate('tailscaleService', tailscaleService);
    AppStorage.setOrCreate('tailscaleState', 'idle');
    AppStorage.setOrCreate('tailscaleDetail', '');
    AppStorage.setOrCreate('tailscaleAuthUrl', '');
    AppStorage.setOrCreate('tailscaleSelfIp', '');
    AppStorage.setOrCreate('tailscaleRunning', false);
    AppStorage.setOrCreate('tailscaleAutoConnect', false);
    AppStorage.setOrCreate('tailscaleError', 0);
    AppStorage.setOrCreate('appForeground', true);
    // 排队消息退回输入框的暂存键（InputBar 监听）
    AppStorage.setOrCreate('composerPrefill', '');
    Logger.info('Global services initialized');
  }

  onDestroy(): void {
    Logger.info('EntryAbility onDestroy');
    const wsService = AppStorage.get<WebSocketService>('wsService');
    if (wsService) wsService.disconnect();
    Logger.info('EntryAbility destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info('EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error('Failed to load content', JSON.stringify(err));
        return;
      }
      Logger.info('Content loaded successfully');
      // 键盘避让：默认 OFFSET 会把整页（含聊天标题栏）上移导致空白/标题消失，
      // 改为 RESIZE 让消息区压缩、输入框与标题栏保持可见。
      try {
        const mainWindow = windowStage.getMainWindowSync();
        mainWindow.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
        Logger.info('Keyboard avoid mode set to RESIZE');
      } catch (err) {
        Logger.warn('set keyboard avoid mode failed: ' + (err as Error).message);
      }
    });
  }

  onWindowStageDestroy(): void { Logger.info('EntryAbility onWindowStageDestroy'); }

  /** 读取系统当前配色（resourceManager 的 ColorMode：DARK=0）。 */
  private readSystemDark(): boolean {
    try {
      const config = this.context.resourceManager.getConfigurationSync();
      return config.colorMode === resourceManager.ColorMode.DARK;
    } catch (err) {
      Logger.warn('read system color mode failed: ' + (err as Error).message);
      return false;
    }
  }

  /** 系统深浅色切换：仅“跟随系统”模式需要实时生效。 */
  onConfigurationUpdate(newConfig: Configuration): void {
    const systemDark: boolean = ThemeUtil.isDarkConfiguration(newConfig);
    AppStorage.setOrCreate('systemDark', systemDark);
    const mode: string = AppStorage.get<string>('themeMode') ?? ThemeUtil.MODE_SYSTEM;
    if (mode !== ThemeUtil.MODE_SYSTEM) { return; }
    AppStorage.setOrCreate('theme', ThemeUtil.resolve(mode, systemDark));
    Logger.info('System color mode changed, theme=' + (AppStorage.get<string>('theme') ?? ''));
  }

  onForeground(): void {
    Logger.info('EntryAbility onForeground');
    AppStorage.setOrCreate('appForeground', true);
    // 从后台恢复：断线时重新探测局域网/Tailscale 地址并重连，已连接则探活
    const wsService = AppStorage.get<WebSocketService>('wsService');
    if (wsService) {
      if (wsService.getConnectionState() !== 'connected') {
        AppStorage.setOrCreate('chatRefresh', Date.now());
      } else {
        wsService.ensureAlive();
      }
    }
    const bgTask = AppStorage.get<BackgroundTaskService>('backgroundTaskService');
    if (bgTask) { bgTask.stop(); }
    const tsService = AppStorage.get<TailscaleVpnService>('tailscaleService');
    if (tsService) {
      tsService.refreshStatus();
      tsService.ensureConnected();
    }
  }
  onBackground(): void {
    Logger.info('EntryAbility onBackground');
    AppStorage.setOrCreate('appForeground', false);
    // 生成中退到后台：申请连续任务，保证能收到完成事件并发出通知
    const generating = AppStorage.get<boolean>('chatGenerating') === true;
    if (!generating) { return; }
    const authService = AppStorage.get<AuthService>('authService');
    const bgTask = AppStorage.get<BackgroundTaskService>('backgroundTaskService');
    if (!authService || !bgTask) { return; }
    authService.getNotifyOnComplete().then((enabled: boolean) => {
      if (enabled) { bgTask.start(); }
    });
  }
}
