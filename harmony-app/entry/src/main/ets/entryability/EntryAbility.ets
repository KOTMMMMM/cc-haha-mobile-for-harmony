import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import { WebSocketService } from '../services/WebSocketService';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { AuthService } from '../services/AuthService';
import { HistoryStore } from '../services/HistoryStore';
import { NotificationService } from '../services/NotificationService';
import { BackgroundTaskService } from '../services/BackgroundTaskService';
import { TailscaleVpnService } from '../services/TailscaleVpnService';
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
    const tailscaleService = new TailscaleVpnService();
    tailscaleService.initialize(this.context);
    authService.initialize(this.context);
    historyStore.initialize(this.context).then(() => {
      authService.getTheme().then((t: string) => { AppStorage.setOrCreate('theme', t); });
    });
    // 首次启动申请通知授权（拒绝后可在设置页重新开启）
    notificationService.ensurePermission();
    AppStorage.setOrCreate('wsService', wsService);
    AppStorage.setOrCreate('apiService', apiService);
    AppStorage.setOrCreate('sessionService', sessionService);
    AppStorage.setOrCreate('authService', authService);
    AppStorage.setOrCreate('historyStore', historyStore);
    AppStorage.setOrCreate('notificationService', notificationService);
    AppStorage.setOrCreate('backgroundTaskService', backgroundTaskService);
    AppStorage.setOrCreate('tailscaleService', tailscaleService);
    AppStorage.setOrCreate('tailscaleState', 'idle');
    AppStorage.setOrCreate('tailscaleDetail', '');
    AppStorage.setOrCreate('tailscaleAuthUrl', '');
    AppStorage.setOrCreate('tailscaleSelfIp', '');
    AppStorage.setOrCreate('tailscaleRunning', false);
    AppStorage.setOrCreate('tailscaleAutoConnect', false);
    AppStorage.setOrCreate('tailscaleError', 0);
    AppStorage.setOrCreate('appForeground', true);
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
    });
  }

  onWindowStageDestroy(): void { Logger.info('EntryAbility onWindowStageDestroy'); }
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
