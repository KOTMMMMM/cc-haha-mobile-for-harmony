import { Want } from '@kit.AbilityKit';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  tsAuthUrl,
  tsLoginWithAuthKey,
  tsNetworkChanged,
  tsRestartWithTun,
  tsStart,
  tsStatus,
  tsStop,
  tsTunFdProbe,
  tsVersion,
  tsVpnConfig
} from 'libtailscale_ohos_bridge.so';
import { emptyTailscaleStatus, TailscaleRequest, TailscaleStatus } from '../models/TailscaleStatus';

const DOMAIN: number = 0x0001;
const TAG: string = 'TailscaleVpn';
const BUNDLE_NAME: string = 'com.cchaha.harmony';
const DEFAULT_CONTROL_URL: string = 'https://controlplane.tailscale.com';
const VPN_EXISTS_ERROR_CODE: number = 2203002;
const STATUS_POLL_MS: number = 1000;
const CONFIG_RETRY_MS: number = 500;
const CREATE_RETRY_MS: number = 400;
const CREATE_MAX_ATTEMPTS: number = 6;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

function backendState(status: string): string {
  const match: RegExpMatchArray | null = status.match(/state=([^ |]+)/);
  return match === null ? '' : match[1];
}

function failureCode(status: string, fallback: number): number {
  const match: RegExpMatchArray | null = status.match(/code=(\d+)/);
  if (match !== null) {
    return Number(match[1]);
  }
  return fallback;
}

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private stopping: boolean = false;
  private controlUrl: string = DEFAULT_CONTROL_URL;
  private stateDir: string = '';
  private statusPath: string = '';
  private requestPath: string = '';
  private status: TailscaleStatus = emptyTailscaleStatus();
  private netConnection?: connection.NetConnection;
  private networkNotifyAt: number = 0;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VPN extension created');
    this.stateDir = `${this.context.filesDir}/tailscale`;
    const runtimeDir: string = `${this.context.filesDir}/tsvpn`;
    hilog.info(DOMAIN, TAG, 'filesDir=%{public}s', this.context.filesDir);
    this.statusPath = `${runtimeDir}/status.json`;
    this.requestPath = `${runtimeDir}/request.json`;
    this.ensureRuntimeDir(runtimeDir);
    this.writeStatus('starting', 'VPN 扩展已启动', '', '', '', '', 0);
    this.registerNetworkObserver();
    this.run().catch((error: Error): void => {
      hilog.error(DOMAIN, TAG, 'VPN extension run failed: %{public}s', error.message);
      this.writeStatus('failed', '内部错误：' + error.message, '', '', '', '', -1);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
    this.unregisterNetworkObserver();
    this.stopping = true;
    tsStop().catch((): void => {
    });
    this.destroyVpn();
  }

  /** Wi-Fi/蜂窝切换时通知 Go 后端刷新网络路径（否则只能等自身探测）。 */
  private registerNetworkObserver(): void {
    try {
      this.netConnection = connection.createNetConnection();
      this.netConnection.on('netAvailable', (handle: connection.NetHandle): void => {
        this.notifyNetworkChanged('netAvailable');
      });
      this.netConnection.on('netLost', (handle: connection.NetHandle): void => {
        this.notifyNetworkChanged('netLost');
      });
      this.netConnection.register((err: BusinessError): void => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'network observer register failed: %{public}d', err.code);
        }
      });
      hilog.info(DOMAIN, TAG, 'network observer registered');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'network observer unavailable: %{public}s', (error as Error).message);
    }
  }

  private unregisterNetworkObserver(): void {
    if (this.netConnection === undefined) { return; }
    try {
      this.netConnection.unregister((err: BusinessError): void => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'network observer unregister failed: %{public}d', err.code);
        }
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'network observer unregister exception: %{public}s',
        (error as Error).message);
    }
    this.netConnection = undefined;
  }

  private notifyNetworkChanged(reason: string): void {
    const now: number = Date.now();
    if (now - this.networkNotifyAt < 1500) {
      return;
    }
    this.networkNotifyAt = now;
    connection.getDefaultNet().then((net: connection.NetHandle): void => {
      if (!net || net.netId === 0) {
        return;
      }
      connection.getConnectionProperties(net).then((props: connection.ConnectionProperties): void => {
        const name: string = props.interfaceName ?? '';
        if (!name) {
          return;
        }
        tsNetworkChanged(name).then((reply: string): void => {
          hilog.info(DOMAIN, TAG, 'network changed (%{public}s) via %{public}s -> %{public}s',
            reason, name, reply);
        }).catch((error: Error): void => {
          hilog.warn(DOMAIN, TAG, 'network change notify failed: %{public}s', error.message);
        });
      }).catch((error: Error): void => {
        hilog.warn(DOMAIN, TAG, 'network properties failed: %{public}s', error.message);
      });
    }).catch((error: Error): void => {
      hilog.warn(DOMAIN, TAG, 'default net failed: %{public}s', error.message);
    });
  }

  private ensureRuntimeDir(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'create runtime dir failed: %{public}s', (error as Error).message);
    }
  }

  private readRequest(): TailscaleRequest {
    const fallback: TailscaleRequest = { action: 'start', controlUrl: DEFAULT_CONTROL_URL, createdAtMs: 0 };
    try {
      if (!fileIo.accessSync(this.requestPath)) {
        return fallback;
      }
      const parsed: TailscaleRequest = JSON.parse(fileIo.readTextSync(this.requestPath)) as TailscaleRequest;
      if (parsed.controlUrl && parsed.controlUrl.length > 0) {
        fallback.controlUrl = parsed.controlUrl;
      }
      fallback.action = parsed.action ?? 'start';
      fallback.createdAtMs = parsed.createdAtMs ?? 0;
      if (parsed.authKey && parsed.authKey.length > 0) {
        fallback.authKey = parsed.authKey;
      }
      return fallback;
    } catch (error) {
      return fallback;
    }
  }

  /** Auth Key 用完后立即从 request.json 中清除，避免密钥长期留在磁盘。 */
  private sanitizeRequest(): void {
    try {
      const request: TailscaleRequest = this.readRequest();
      const clean: TailscaleRequest = {
        action: request.action,
        controlUrl: request.controlUrl,
        createdAtMs: request.createdAtMs
      };
      const file: fileIo.File = fileIo.openSync(this.requestPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(clean));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'sanitize request failed');
    }
  }

  private stopRequested(): boolean {
    try {
      if (!fileIo.accessSync(this.requestPath)) {
        return false;
      }
      const parsed: TailscaleRequest = JSON.parse(fileIo.readTextSync(this.requestPath)) as TailscaleRequest;
      return parsed.action === 'stop';
    } catch (error) {
      return false;
    }
  }

  private writeStatus(state: string, detail: string, authUrl: string, ipv4: string, ipv6: string,
    routes: string, errorCode: number): void {
    this.status.state = state;
    this.status.detail = detail;
    this.status.authUrl = authUrl;
    this.status.selfIpv4 = ipv4;
    this.status.selfIpv6 = ipv6;
    this.status.routes = routes;
    this.status.errorCode = errorCode;
    this.status.updatedAtMs = Date.now();
    this.status.heartbeatAt = this.status.updatedAtMs;
    this.writeStatusFile();
  }

  private writeHeartbeat(): void {
    this.status.heartbeatAt = Date.now();
    this.status.updatedAtMs = this.status.heartbeatAt;
    this.writeStatusFile();
  }

  private writeStatusFile(): void {
    try {
      const temporaryPath: string = `${this.statusPath}.tmp`;
      const file: fileIo.File = fileIo.openSync(temporaryPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(this.status));
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(temporaryPath, this.statusPath);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'write status failed: %{public}s', (error as Error).message);
    }
  }

  private deviceModel(): string {
    const model: string = deviceInfo.productModel;
    return model && model.length > 0 ? model : 'harmonyos-next';
  }

  private osVersion(): string {
    const fullName: string = deviceInfo.osFullName;
    return fullName && fullName.length > 0 ? fullName : deviceInfo.displayVersion;
  }

  private async run(): Promise<void> {
    const request: TailscaleRequest = this.readRequest();
    this.controlUrl = request.controlUrl;
    if (request.action === 'stop') {
      this.writeStatus('stopped', '未启动', '', '', '', '', 0);
      return;
    }

    this.status.engineVersion = tsVersion();
    hilog.info(DOMAIN, TAG, 'engine=%{public}s', this.status.engineVersion);
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    } catch (error) {
      const code: number = (error as BusinessError).code ?? -1;
      this.writeStatus('failed', '无法创建 VPN 连接对象', '', '', '', '', code);
      return;
    }

    const probeConfig: vpnExtension.VpnConfig = this.buildProbeConfig();
    const probeFd: number = await this.createVpnWithRetry(probeConfig, true);
    if (probeFd < 0 || this.stopping) {
      return;
    }
    this.tunFd = probeFd;
    try {
      await this.vpnConnection.protectProcessNet();
      hilog.info(DOMAIN, TAG, 'extension process sockets protected from VPN');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'protectProcessNet unavailable: %{public}s', (error as Error).message);
    }

    const startReply: string = await tsStart(
      this.stateDir, this.deviceModel(), this.osVersion(), this.controlUrl);
    hilog.info(DOMAIN, TAG, 'backend start: %{public}s', startReply);
    if (startReply.startsWith('FAILED')) {
      this.writeStatus('failed', startReply, '', '', '', '', failureCode(startReply, -1));
      return;
    }

    let authUrl: string = '';
    let running: boolean = false;
    // 后端刚启动时会短暂处于 NoState/Starting；若此时立刻请求交互登录，
    // 会打断本地节点密钥的自动重连，导致每次重启都要重新登录。
    // 只有连续 NeedsLogin 超过该阈值，才认为确实需要浏览器登录。
    const NEEDS_LOGIN_GRACE_MS: number = 5000;
    let needsLoginSince: number = 0;
    let authKeyAttempted: boolean = false;
    for (let attempt: number = 0; attempt < 3600 && !this.stopping; attempt++) {
      if (this.stopRequested()) {
        await this.shutdown();
        return;
      }
      hilog.info(DOMAIN, TAG, 'poll status');
      const statusText: string = await tsStatus();
      hilog.info(DOMAIN, TAG, 'status=%{public}s', statusText.slice(0, 160));
      const state: string = backendState(statusText);
      if (statusText.startsWith('FAILED')) {
        this.writeStatus('failed', statusText, authUrl, '', '', '', failureCode(statusText, -1));
        return;
      }
      if (state === 'Running') {
        running = true;
        break;
      }
      if (state === 'NeedsLogin') {
        if (needsLoginSince === 0) {
          needsLoginSince = Date.now();
        }
      } else {
        needsLoginSince = 0;
      }
      // 用户提供了 Auth Key：优先用它登录，不再弹浏览器
      if (state === 'NeedsLogin' && !authKeyAttempted) {
        const pending: TailscaleRequest = this.readRequest();
        if (pending.authKey && pending.authKey.length > 0) {
          authKeyAttempted = true;
          hilog.info(DOMAIN, TAG, 'auth key login requested');
          const reply: string = await tsLoginWithAuthKey(pending.authKey);
          hilog.info(DOMAIN, TAG, 'auth key login: %{public}s', reply.slice(0, 80));
          this.sanitizeRequest();
          if (reply.startsWith('FAILED')) {
            this.writeStatus('failed', 'Auth Key 登录失败：' + reply, '', '', '', '',
              failureCode(reply, -1));
            return;
          }
          await sleep(STATUS_POLL_MS);
          continue;
        }
      }
      if (!authUrl && needsLoginSince > 0 && Date.now() - needsLoginSince >= NEEDS_LOGIN_GRACE_MS) {
        hilog.info(DOMAIN, TAG, 'poll auth url');
        const loginUrl: string = await tsAuthUrl();
        hilog.info(DOMAIN, TAG, 'auth=%{public}s', loginUrl.slice(0, 120));
        if (loginUrl.startsWith('http')) {
          authUrl = loginUrl;
          this.writeStatus('needs_login', '需要在浏览器完成 Tailscale 登录', authUrl, '', '', '', 0);
        } else if (loginUrl.startsWith('FAILED')) {
          // 后端可能仍在初始化，继续等待下一轮；只有超时才报错。
          hilog.warn(DOMAIN, TAG, 'auth url not ready yet');
        }
      }
      this.writeStatus(authUrl.length > 0 ? 'needs_login' : 'starting',
        authUrl.length > 0 ? '等待 Tailscale 登录' : '正在启动 Tailscale 后端',
        authUrl, '', '', '', 0);
      await sleep(STATUS_POLL_MS);
    }
    if (!running || this.stopping) {
      if (!this.stopping) {
        this.writeStatus('failed', 'Tailscale 登录超时', authUrl, '', '', '', -1);
      }
      return;
    }

    const configText: string = await this.waitForVpnConfig();
    if (configText.startsWith('FAILED')) {
      this.writeStatus('failed', configText, authUrl, '', '', '', failureCode(configText, -1));
      return;
    }
    const parts: string[] = configText.split('|');
    if (parts.length < 2 || parts[0].length === 0) {
      this.writeStatus('failed', 'VPN 配置无效', authUrl, '', '', '', -1);
      return;
    }

    await this.destroyVpn();
    const productionConfig: vpnExtension.VpnConfig = this.buildProductionConfig(parts);
    const productionFd: number = await this.createVpnWithRetry(productionConfig, false);
    if (productionFd < 0 || this.stopping) {
      return;
    }
    this.tunFd = productionFd;
    const probe: string = tsTunFdProbe(productionFd);
    if (!probe.startsWith('OK')) {
      this.writeStatus('failed', 'TUN 描述符校验失败：' + probe, authUrl, parts[0],
        parts[1], parts.length > 2 ? parts[2] : '', -1);
      return;
    }

    const restartReply: string = await tsRestartWithTun(
      this.stateDir, this.deviceModel(), this.osVersion(), this.controlUrl, productionFd);
    hilog.info(DOMAIN, TAG, 'backend restart: %{public}s', restartReply);
    if (restartReply.startsWith('FAILED')) {
      this.writeStatus('failed', restartReply, authUrl, parts[0], parts[1],
        parts.length > 2 ? parts[2] : '', failureCode(restartReply, -1));
      return;
    }

    let tunnelRunning: boolean = false;
    for (let attempt: number = 0; attempt < 120 && !this.stopping; attempt++) {
      const statusText: string = await tsStatus();
      if (statusText.startsWith('FAILED')) {
        this.writeStatus('failed', statusText, authUrl, parts[0], parts[1],
          parts.length > 2 ? parts[2] : '', failureCode(statusText, -1));
        return;
      }
      if (backendState(statusText) === 'Running') {
        tunnelRunning = true;
        break;
      }
      await sleep(CONFIG_RETRY_MS);
    }
    if (!tunnelRunning) {
      this.writeStatus('failed', 'VPN 后端未进入 Running', authUrl, parts[0], parts[1],
        parts.length > 2 ? parts[2] : '', -1);
      return;
    }

    this.writeStatus('running', 'Tailscale 已连接', '', parts[0], parts[1],
      parts.length > 2 ? parts[2] : '', 0);
    hilog.info(DOMAIN, TAG, 'Tailscale running, self=%{public}s', parts[0]);

    while (!this.stopping) {
      if (this.stopRequested()) {
        break;
      }
      // 外部 TUN 运行后 TSBackendStatus 可能阻塞；心跳不依赖它。
      this.writeHeartbeat();
      await sleep(STATUS_POLL_MS);
    }
    await this.shutdown();
  }

  private async waitForVpnConfig(): Promise<string> {
    let last: string = 'FAILED | VPN config | backend not ready';
    for (let attempt: number = 0; attempt < 60 && !this.stopping; attempt++) {
      last = await tsVpnConfig();
      if (!last.startsWith('FAILED')) {
        return last;
      }
      await sleep(CONFIG_RETRY_MS);
    }
    return last;
  }

  private async shutdown(): Promise<void> {
    this.stopping = true;
    this.writeStatus('stopping', '正在断开 Tailscale', this.status.authUrl,
      this.status.selfIpv4, this.status.selfIpv6, this.status.routes, 0);
    try {
      await tsStop();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'backend stop failed: %{public}s', (error as Error).message);
    }
    await this.destroyVpn();
    this.writeStatus('stopped', 'Tailscale 已断开', '', '', '', '', 0);
  }

  private async destroyVpn(): Promise<void> {
    if (this.vpnConnection === undefined) {
      return;
    }
    try {
      await this.vpnConnection.destroy();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'destroy VPN failed: %{public}s', (error as Error).message);
    }
    this.tunFd = -1;
  }

  private async createVpnWithRetry(config: vpnExtension.VpnConfig, probe: boolean): Promise<number> {
    if (this.vpnConnection === undefined) {
      return -1;
    }
    let lastCode: number = -1;
    for (let attempt: number = 0; attempt < CREATE_MAX_ATTEMPTS && !this.stopping; attempt++) {
      try {
        const fd: number = await this.vpnConnection.create(config);
        hilog.info(DOMAIN, TAG, 'VPN create success fd=%{public}d probe=%{public}s',
          fd, probe ? 'true' : 'false');
        return fd;
      } catch (error) {
        const code: number = (error as BusinessError).code ?? -1;
        lastCode = code;
        if (code === VPN_EXISTS_ERROR_CODE) {
          this.writeStatus('failed', '已有其他 VPN（如 ClashBox）正在运行，请先在系统中断开它',
            this.status.authUrl, '', '', '', code);
          return -1;
        }
        hilog.warn(DOMAIN, TAG, 'VPN create failed code=%{public}d attempt=%{public}d', code, attempt);
        await sleep(CREATE_RETRY_MS);
      }
    }
    this.writeStatus('failed', '创建 VPN 接口失败', this.status.authUrl, '', '', '', lastCode);
    return -1;
  }

  private buildProbeConfig(): vpnExtension.VpnConfig {
    const addresses: vpnExtension.LinkAddress[] = [{
      address: { address: '192.0.2.1', family: 1 },
      prefixLength: 32
    }];
    const routes: vpnExtension.RouteInfo[] = [{
      interface: 'vpn-tun',
      destination: { address: { address: '192.0.2.0', family: 1 }, prefixLength: 24 },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: false
    }];
    return {
      addresses: addresses,
      routes: routes,
      dnsAddresses: [],
      searchDomains: [],
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isInternal: true,
      isBlocking: false,
      trustedApplications: [BUNDLE_NAME]
    };
  }

  private buildProductionConfig(parts: string[]): vpnExtension.VpnConfig {
    const addresses: vpnExtension.LinkAddress[] = [{
      address: { address: parts[0], family: 1 },
      prefixLength: 32
    }];
    const routes: vpnExtension.RouteInfo[] = [{
      interface: 'vpn-tun',
      destination: { address: { address: '100.64.0.0', family: 1 }, prefixLength: 10 },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: false
    }];
    const hasIpv6: boolean = parts.length > 1 && parts[1].length > 0;
    if (hasIpv6) {
      addresses.push({
        address: { address: parts[1], family: 2 },
        prefixLength: 128
      });
      routes.push({
        interface: 'vpn-tun',
        destination: { address: { address: 'fd7a:115c:a1e0::', family: 2 }, prefixLength: 48 },
        gateway: { address: '::', family: 2 },
        hasGateway: false,
        isDefaultRoute: false
      });
    }
    if (parts.length > 2 && parts[2].length > 0) {
      const dynamicRoutes: string[] = parts[2].split(',');
      for (const routeText of dynamicRoutes) {
        const prefixParts: string[] = routeText.split('/');
        if (prefixParts.length !== 2) {
          continue;
        }
        const prefixLength: number = Number(prefixParts[1]);
        if (prefixLength === 0) {
          // 不做 exit node：跳过默认路由，避免控制/DERP 流量绕回隧道。
          continue;
        }
        const family: number = prefixParts[0].includes(':') ? 2 : 1;
        routes.push({
          interface: 'vpn-tun',
          destination: { address: { address: prefixParts[0], family: family }, prefixLength: prefixLength },
          gateway: { address: family === 2 ? '::' : '0.0.0.0', family: family },
          hasGateway: false,
          isDefaultRoute: false
        });
      }
    }
    return {
      addresses: addresses,
      routes: routes,
      dnsAddresses: [],
      searchDomains: [],
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: hasIpv6,
      isInternal: true,
      isBlocking: false,
      trustedApplications: [BUNDLE_NAME]
    };
  }
}
