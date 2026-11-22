import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import preferences from '@ohos.data.preferences';
import { emptyTailscaleStatus, TailscaleRequest, TailscaleStatus } from '../models/TailscaleStatus';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';

const BUNDLE_NAME: string = 'com.cchaha.harmony';
const ABILITY_NAME: string = 'TailscaleVpnExtensionAbility';
const MODULE_NAME: string = 'entry';
const CONTROL_URL: string = 'https://controlplane.tailscale.com';
const KEY_AUTO_CONNECT: string = 'tailscale_auto_connect';
const KEY_ENABLED: string = 'tailscale_enabled';
const POLL_INTERVAL_MS: number = 1000;
const HEARTBEAT_FRESH_MS: number = 6000;

export class TailscaleVpnService {
  private context?: common.UIAbilityContext;
  private prefs?: preferences.Preferences;
  private pollTimer: number = -1;
  private enabled: boolean = false;
  private autoConnect: boolean = false;
  private lastRunning: boolean = false;
  private startInFlight: boolean = false;
  private lastStartAt: number = 0;
  private bootstrapped: boolean = false;
  private ready: Promise<void> = Promise.resolve();
  // 心跳过期时自动重启扩展，指数退避避免抖动
  private restartAttempts: number = 0;
  private lastRestartAt: number = 0;
  // 重启/冷启动后给扩展留出启动和写心跳的时间，避免把旧状态误判为 stale 而连续重启
  private restartGraceUntil: number = 0;
  private readonly RESTART_BASE_MS: number = 2000;
  private readonly RESTART_MAX_MS: number = 30000;
  private readonly RESTART_GRACE_MS: number = 15000;

  initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    Logger.info('[TS] filesDir=' + context.filesDir);
    this.ready = this.loadPreferences();
    return this.ready;
  }

  private async loadPreferences(): Promise<void> {
    try {
      if (!this.context) {
        return;
      }
      this.prefs = await preferences.getPreferences(this.context, Constants.PREFERENCES_NAME);
      this.enabled = await this.prefs.get(KEY_ENABLED, false) as boolean;
      this.autoConnect = await this.prefs.get(KEY_AUTO_CONNECT, false) as boolean;
    } catch (error) {
      Logger.warn('[TS] preferences init failed: ' + (error as Error).message);
    }
    AppStorage.setOrCreate('tailscaleAutoConnect', this.autoConnect);
    // 冷启动时 ensureConnected() 会显式拉起扩展；先给 15s 宽限，
    // 不要让状态文件里的旧心跳触发 forceRestart 打断首次启动。
    this.restartGraceUntil = Date.now() + this.RESTART_GRACE_MS;
    this.startPolling();
    this.refreshStatus();
  }

  isAutoConnectEnabled(): boolean {
    return this.autoConnect;
  }

  async setEnabled(on: boolean): Promise<void> {
    await this.ready;
    await this.setPreference(KEY_ENABLED, on);
    await this.setPreference(KEY_AUTO_CONNECT, on);
    this.enabled = on;
    this.autoConnect = on;
    this.restartAttempts = 0;
    this.lastRestartAt = 0;
    AppStorage.setOrCreate('tailscaleAutoConnect', on);
    if (on) {
      await this.startExtension();
    } else {
      await this.stopExtension();
    }
  }

  /** 设置页「重启」：跳过退避，立即停掉并重新拉起扩展 */
  async restart(): Promise<void> {
    await this.ready;
    this.restartAttempts = 0;
    this.lastRestartAt = 0;
    this.bootstrapped = true;
    await this.forceRestart();
  }

  async ensureConnected(): Promise<void> {
    await this.ready;
    if (!this.autoConnect) {
      return;
    }
    if (!this.bootstrapped) {
      // 冷启动时旧扩展可能已被系统回收，但状态文件心跳仍然新鲜；
      // 首次必须显式请求启动，已运行时系统会返回 16000001。
      this.bootstrapped = true;
      await this.startExtension();
      return;
    }
    const status = this.readStatus();
    if (status.state === 'needs_login' && this.isFresh(status)) {
      this.applyStatus(status);
      return;
    }
    if (this.startInFlight) {
      return;
    }
    // 冷启动时状态文件可能来自已被系统回收的旧扩展；直接请求启动，
    // 已运行时 startVpnExtensionAbility 会返回 16000001，不会重启后端。
    await this.startExtension();
  }

  /**
   * 用 Tailscale Auth Key 登录：key 写入 request.json，扩展在 NeedsLogin 时
   * 读取并调用后端登录，随后立即清除磁盘上的 key。
   */
  async loginWithAuthKey(key: string): Promise<void> {
    await this.ready;
    if (!this.context) {
      return;
    }
    const trimmed: string = key.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.ensureRuntimeDir();
    this.writeRequest('start', trimmed);
    this.lastStartAt = 0;
    await this.startExtension(trimmed);
    this.startPolling();
  }

  async openLogin(): Promise<boolean> {
    const status = this.readStatus();
    if (!this.context || !status.authUrl || !status.authUrl.startsWith('http')) {
      return false;
    }
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: status.authUrl
      };
      await this.context.startAbility(want);
      return true;
    } catch (error) {
      Logger.warn('[TS] open login failed: ' + (error as Error).message);
      return false;
    }
  }

  refreshStatus(): void {
    this.applyStatus(this.readStatus());
  }

  private async startExtension(authKey?: string): Promise<void> {
    if (!this.context || this.startInFlight || Date.now() - this.lastStartAt < 4000) {
      return;
    }
    this.startInFlight = true;
    this.lastStartAt = Date.now();
    try {
      this.ensureRuntimeDir();
      this.writeRequest('start', authKey);
      const want: Want = {
        bundleName: BUNDLE_NAME,
        moduleName: MODULE_NAME,
        abilityName: ABILITY_NAME
      };
      await vpnExtension.startVpnExtensionAbility(want);
      Logger.info('[TS] VPN extension start requested');
      AppStorage.setOrCreate('tailscaleState', 'starting');
      AppStorage.setOrCreate('tailscaleDetail', '正在启动 Tailscale');
      AppStorage.setOrCreate('tailscaleRunning', false);
      this.startPolling();
    } catch (error) {
      const code: number = (error as BusinessError).code ?? -1;
      // 16000001: ability already running or not found; keep polling status.
      Logger.warn('[TS] start extension failed code=' + code + ' ' + (error as Error).message);
      if (code !== 16000001) {
        AppStorage.setOrCreate('tailscaleState', 'failed');
        AppStorage.setOrCreate('tailscaleDetail', '启动 Tailscale 扩展失败：' + (error as Error).message);
        AppStorage.setOrCreate('tailscaleError', code);
      }
      this.startPolling();
    } finally {
      this.startInFlight = false;
    }
  }

  /** 停掉无响应的扩展进程后重新拉起；由 applyStatus 的 stale 检测或设置页手动触发。 */
  private async forceRestart(): Promise<void> {
    if (!this.context || this.startInFlight) {
      return;
    }
    this.startInFlight = true;
    this.lastRestartAt = Date.now();
    const want: Want = {
      bundleName: BUNDLE_NAME,
      moduleName: MODULE_NAME,
      abilityName: ABILITY_NAME
    };
    try {
      try {
        await vpnExtension.stopVpnExtensionAbility(want);
      } catch (error) {
        Logger.debug('[TS] stop before restart ignored: ' + (error as Error).message);
      }
      await this.sleep(400);
      this.ensureRuntimeDir();
      this.writeRequest('start');
      await vpnExtension.startVpnExtensionAbility(want);
      this.restartGraceUntil = Date.now() + this.RESTART_GRACE_MS;
      Logger.info('[TS] extension restart requested attempt=' + this.restartAttempts);
      AppStorage.setOrCreate('tailscaleState', 'starting');
      AppStorage.setOrCreate('tailscaleDetail', 'Tailscale 无响应，正在重启');
      AppStorage.setOrCreate('tailscaleRunning', false);
      this.startPolling();
    } catch (error) {
      const code: number = (error as BusinessError).code ?? -1;
      Logger.warn('[TS] restart extension failed code=' + code + ' ' + (error as Error).message);
    } finally {
      this.startInFlight = false;
    }
  }

  private async stopExtension(): Promise<void> {
    if (!this.context) {
      return;
    }
    this.restartAttempts = 0;
    this.lastRestartAt = 0;
    this.ensureRuntimeDir();
    this.writeRequest('stop');
    const deadline: number = Date.now() + 3000;
    while (Date.now() < deadline) {
      const status = this.readStatus();
      if (status.state === 'stopped' || status.state === 'idle') {
        break;
      }
      await this.sleep(200);
    }
    try {
      const want: Want = {
        bundleName: BUNDLE_NAME,
        moduleName: MODULE_NAME,
        abilityName: ABILITY_NAME
      };
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (error) {
      Logger.warn('[TS] stop extension failed: ' + (error as Error).message);
    }
    AppStorage.setOrCreate('tailscaleState', 'stopped');
    AppStorage.setOrCreate('tailscaleDetail', 'Tailscale 已关闭');
    AppStorage.setOrCreate('tailscaleRunning', false);
    AppStorage.setOrCreate('tailscaleAuthUrl', '');
    AppStorage.setOrCreate('tailscaleSelfIp', '');
  }

  private startPolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval((): void => {
      this.refreshStatus();
    }, POLL_INTERVAL_MS);
  }

  private applyStatus(status: TailscaleStatus): void {
    const stale: boolean = status.state !== 'idle' && status.state !== 'stopped' &&
      status.heartbeatAt > 0 && Date.now() - status.heartbeatAt > HEARTBEAT_FRESH_MS;
    const state: string = stale ? 'stale' : status.state;
    const detail: string = stale ? 'Tailscale 扩展无响应' : status.detail;
    AppStorage.setOrCreate('tailscaleState', state);
    AppStorage.setOrCreate('tailscaleDetail', detail);
    AppStorage.setOrCreate('tailscaleAuthUrl', status.authUrl);
    AppStorage.setOrCreate('tailscaleSelfIp', status.selfIpv4);
    AppStorage.setOrCreate('tailscaleError', status.errorCode);
    const running: boolean = state === 'running';
    AppStorage.setOrCreate('tailscaleRunning', running);
    if (running) {
      this.restartAttempts = 0;
    } else if (stale && this.autoConnect && !this.startInFlight &&
      Date.now() >= this.restartGraceUntil &&
      AppStorage.get<boolean>('appForeground') === true) {
      const delay: number = Math.min(
        this.RESTART_BASE_MS * Math.pow(2, Math.min(this.restartAttempts, 4)),
        this.RESTART_MAX_MS);
      if (Date.now() - this.lastRestartAt >= delay) {
        this.restartAttempts++;
        this.forceRestart();
      }
    }
    if (running && !this.lastRunning) {
      const foreground: boolean = AppStorage.get<boolean>('appForeground') === true;
      if (foreground) {
        AppStorage.setOrCreate('chatRefresh', Date.now());
        // Tailscale 刚恢复时首页/列表可能还在用不可达的局域网地址，重新拉取
        AppStorage.setOrCreate('sessionsRefresh', Date.now());
      }
    }
    this.lastRunning = running;
  }

  private readStatus(): TailscaleStatus {
    const fallback: TailscaleStatus = emptyTailscaleStatus();
    if (!this.context) {
      return fallback;
    }
    const path: string = this.statusPath();
    try {
      if (!fileIo.accessSync(path)) {
        return fallback;
      }
      return JSON.parse(fileIo.readTextSync(path)) as TailscaleStatus;
    } catch (error) {
      return fallback;
    }
  }

  private isFresh(status: TailscaleStatus): boolean {
    return status.heartbeatAt > 0 && Date.now() - status.heartbeatAt <= HEARTBEAT_FRESH_MS;
  }

  private writeRequest(action: string, authKey?: string): void {
    const request: TailscaleRequest = {
      action: action,
      controlUrl: CONTROL_URL,
      createdAtMs: Date.now()
    };
    if (authKey && authKey.length > 0) {
      request.authKey = authKey;
    }
    const path: string = this.requestPath();
    const temporaryPath: string = `${path}.tmp`;
    try {
      const file: fileIo.File = fileIo.openSync(temporaryPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(request));
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(temporaryPath, path);
    } catch (error) {
      Logger.warn('[TS] write request failed: ' + (error as Error).message);
    }
  }

  private ensureRuntimeDir(): void {
    if (!this.context) {
      return;
    }
    const dir: string = `${this.context.filesDir}/tsvpn`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (error) {
      Logger.warn('[TS] create runtime dir failed: ' + (error as Error).message);
    }
  }

  private statusPath(): string {
    return this.context ? `${this.context.filesDir}/tsvpn/status.json` : '';
  }

  private requestPath(): string {
    return this.context ? `${this.context.filesDir}/tsvpn/request.json` : '';
  }

  private async setPreference(key: string, value: boolean): Promise<void> {
    if (!this.prefs) {
      return;
    }
    try {
      await this.prefs.put(key, value);
      await this.prefs.flush();
    } catch (error) {
      Logger.warn('[TS] save preference failed: ' + (error as Error).message);
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
