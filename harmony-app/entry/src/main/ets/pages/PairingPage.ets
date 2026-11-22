import router from '@ohos.router';
import { pasteboard } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { ApiService } from '../services/ApiService';
import { AuthService } from '../services/AuthService';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';
import { ThemeColors } from '../utils/ThemeUtil';

interface PairRequestBody {
  secret: string;
  name: string;
  clientType: string;
}

interface ClaimRequestBody {
  id: string;
  claimSecret: string;
}

/**
 * 连接新版 cc-haha：粘贴桌面端 H5 链接，或手动填 host/port/H5 Token。
 */
@Entry
@Component
struct PairingPage {
  @StorageLink('theme') theme: string = 'light';
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @State manualHost: string = '';
  @State manualPort: string = Constants.DEFAULT_PORT.toString();
  @State altHost: string = '';
  @State token: string = '';
  @State originUrl: string = '';
  @State linkText: string = '';
  @State isConnecting: boolean = false;
  @State errorMessage: string = '';
  @State pairStatus: string = '';
  @State manualExpanded: boolean = false;
  // 新公共访问配对（https://<tunnel>/remote#pair=…）
  @State remotePairing: boolean = false;
  @State remoteHost: string = '';
  @State remotePort: number = 443;
  private pairSecret: string = '';
  private pageActive: boolean = true;

  aboutToAppear(): void { this.pageActive = true; }
  aboutToDisappear(): void { this.pageActive = false; }

  /** 链接一键连接：先解析回填，再走统一连接流程 */
  private async connectFromLink(): Promise<void> {
    if (this.isConnecting) { return; }
    if (!this.applyLink()) { return; }
    await this.connect();
  }

  async connect(): Promise<void> {
    if (this.isConnecting) { return; }
    if (this.remotePairing) {
      await this.connectRemote();
      return;
    }
    this.errorMessage = '';
    const host = this.manualHost.trim();
    const port = parseInt(this.manualPort, 10);
    const token = this.token.trim();
    if (!host) { this.errorMessage = '请填写地址'; return; }
    if (isNaN(port) || port <= 0 || port > 65535) { this.errorMessage = '端口无效'; return; }
    if (!token) { this.errorMessage = '请填写 H5 Token'; return; }

    this.isConnecting = true;
    try {
      this.apiService.setConnection(host, port, token, 'http');
      const healthy = await this.apiService.healthCheck();
      if (!healthy) {
        this.errorMessage = '无法连接该地址，请检查 PC 端 cc-haha 是否开启 H5 访问、端口是否正确';
        return;
      }
      // 校验 token 权限
      await this.apiService.getSessions();
      const origin = this.originUrl.trim() || ('http://' + host + ':' + port);
      const alt = this.altHost.trim();
      const alternates: string[] = alt.length > 0 ? [alt] : [];
      await this.authService.setConnectionConfig({
        host: host, port: port, token: token, scheme: 'http', hostname: host, origin: origin,
        alternates: alternates.length > 0 ? alternates : undefined
      });
      router.replaceUrl({ url: 'pages/Index' });
    } catch (err) {
      Logger.error('Connect failed: ' + (err as Error).message);
      this.errorMessage = '连接失败：' + (err as Error).message + '（请确认 H5 Token 正确且未重新生成）';
    } finally {
      this.isConnecting = false;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => { resolve(); }, ms);
    });
  }

  /** 公共访问配对：pair → 等待桌面批准 → claim 拿 native Bearer token → 保存 HTTPS 连接 */
  private async connectRemote(): Promise<void> {
    const host = this.remoteHost;
    const port = this.remotePort;
    const secret = this.pairSecret;
    if (!host || !secret) { this.errorMessage = '配对链接无效'; return; }
    this.isConnecting = true;
    this.errorMessage = '';
    this.pairStatus = '正在请求电脑授权…';
    try {
      const pairBody: PairRequestBody = {
        secret: secret,
        name: 'cc-haha App · HarmonyOS',
        clientType: 'native'
      };
      const pair = await this.apiService.publicPairPost(host, port, '/api/public-access/pair', pairBody);
      const id = pair['id'] as string ?? '';
      const claimSecret = pair['claimSecret'] as string ?? '';
      if (!id || !claimSecret) {
        throw new Error('电脑返回了无效的配对请求，请升级电脑端后重试');
      }
      this.pairStatus = '请在电脑上批准这台手机，批准后会自动连接';
      const deadline = Date.now() + 300000;
      let nativeToken = '';
      while (this.pageActive && Date.now() < deadline) {
        const claimBody: ClaimRequestBody = { id: id, claimSecret: claimSecret };
        const claim = await this.apiService.publicPairPost(host, port, '/api/public-access/claim', claimBody);
        const status = claim['status'] as string ?? '';
        if (status === 'rejected') {
          throw new Error('电脑拒绝了这次连接，请重新生成配对链接后重试');
        }
        if (status === 'approved') {
          const token = claim['token'] as string ?? '';
          const tokenType = claim['tokenType'] as string ?? '';
          const deviceId = claim['deviceId'] as string ?? '';
          const expiresAt = claim['expiresAt'] as number;
          if (!token.startsWith('native_') || tokenType !== 'Bearer' || !deviceId ||
            !(expiresAt > Date.now())) {
            throw new Error('电脑没有返回有效的 App 授权，请升级电脑端并重新配对');
          }
          nativeToken = token;
          break;
        }
        if (status !== 'pending') {
          throw new Error('无法确认电脑的授权状态，请重新配对');
        }
        await this.delay(1500);
      }
      if (!nativeToken) {
        throw new Error('等待授权已超时，请在电脑上生成新的配对链接后重试');
      }
      this.pairStatus = '已授权，正在连接…';
      const origin = 'https://' + (port !== 443 ? host + ':' + port : host);
      await this.authService.setConnectionConfig({
        host: host, port: port, token: nativeToken, scheme: 'https', hostname: host, origin: origin
      });
      this.apiService.setConnection(host, port, nativeToken, 'https');
      await this.apiService.getSessions();
      if (this.pageActive) {
        router.replaceUrl({ url: 'pages/Index' });
      }
    } catch (err) {
      Logger.error('Remote pairing failed: ' + (err as Error).message);
      this.errorMessage = '配对失败：' + (err as Error).message;
    } finally {
      this.isConnecting = false;
      this.pairStatus = '';
    }
  }

  /** 解析 H5 链接或 JSON 载荷；成功返回 true 并填充表单。 */
  private applyLink(): boolean {
    const link = this.linkText.trim();
    if (!link) { this.errorMessage = '请粘贴 H5 链接'; return false; }
    // 兼容扫码/剪贴板里的 JSON：{host, port, token, alt}
    if (link.startsWith('{')) {
      try {
        const obj = JSON.parse(link) as Record<string, Object>;
        const host = (obj['host'] as string) ?? '';
        const token = (obj['token'] as string) ?? (obj['h5Token'] as string) ?? '';
        const alt = (obj['alt'] as string) ?? (obj['tailscaleHost'] as string) ?? '';
        const portNum = obj['port'] as number;
        if (host && token) {
          this.manualHost = host;
          if (typeof portNum === 'number' && portNum > 0) { this.manualPort = portNum.toString(); }
          this.token = token;
          this.altHost = alt;
          this.originUrl = 'http://' + host + ':' + this.manualPort;
          this.remotePairing = false;
          this.pairStatus = '';
          this.errorMessage = '';
          return true;
        }
      } catch (e) {
      }
      this.errorMessage = '二维码内容缺少 host 或 token';
      return false;
    }
    // 新版公共访问配对链接：https://<tunnel>/remote#pair=<一次性secret>
    const hashIndex = link.indexOf('#');
    if (hashIndex >= 0) {
      const hash = link.substring(hashIndex + 1);
      if (hash.startsWith('pair=')) {
        if (hash.indexOf('&') >= 0) {
          this.errorMessage = '配对码无效';
          return false;
        }
        const secret = decodeURIComponent(hash.substring(5)).trim();
        const base = link.substring(0, hashIndex);
        if (!base.startsWith('https://') || !secret) {
          this.errorMessage = '远程配对链接必须使用 HTTPS';
          return false;
        }
        let rest = base.substring(8);
        let path = '';
        const slash = rest.indexOf('/');
        if (slash >= 0) {
          path = rest.substring(slash);
          rest = rest.substring(0, slash);
        }
        if (path !== '' && path !== '/' && path !== '/remote') {
          this.errorMessage = '配对链接路径不正确';
          return false;
        }
        let host = rest;
        let port = 443;
        const colon = rest.lastIndexOf(':');
        if (colon > 0) {
          const parsed = parseInt(rest.substring(colon + 1), 10);
          if (isNaN(parsed) || parsed <= 0 || parsed > 65535) {
            this.errorMessage = '配对链接端口无效';
            return false;
          }
          host = rest.substring(0, colon);
          port = parsed;
        }
        if (!host) {
          this.errorMessage = '配对链接缺少主机地址';
          return false;
        }
        this.remotePairing = true;
        this.remoteHost = host;
        this.remotePort = port;
        this.pairSecret = secret;
        this.pairStatus = '';
        this.errorMessage = '';
        return true;
      }
      // 旧版 #/?serverUrl=… 形式继续走下方查询参数解析
    }
    this.remotePairing = false;
    const qIndex = link.indexOf('?');
    if (qIndex < 0) {
      // 也接受 serverUrl 形式的 URL：http://host:port/#/?serverUrl=...
      this.errorMessage = '链接格式不正确';
      return false;
    }
    const query = link.substring(qIndex + 1);
    const params = query.split('&');
    let serverUrl = '';
    let token = '';
    let alt = '';
    for (const p of params) {
      const eq = p.indexOf('=');
      if (eq < 0) { continue; }
      const k = p.substring(0, eq);
      const v = p.substring(eq + 1);
      if (k === 'serverUrl') { serverUrl = decodeURIComponent(v); }
      else if (k === 'h5Token' || k === 'token') { token = decodeURIComponent(v); }
      else if (k === 'alt' || k === 'tailscaleHost') { alt = decodeURIComponent(v); }
    }
    let endpoint = serverUrl;
    if (endpoint) {
      this.originUrl = serverUrl;
    } else {
      endpoint = link;
    }
    let su = endpoint;
    if (su.startsWith('http://')) { su = su.substring(7); }
    else if (su.startsWith('https://')) { su = su.substring(8); }
    const slash = su.indexOf('/');
    if (slash >= 0) { su = su.substring(0, slash); }
    const colon = su.lastIndexOf(':');
    if (colon > 0) {
      this.manualHost = su.substring(0, colon);
      this.manualPort = su.substring(colon + 1);
    } else {
      this.manualHost = su;
    }
    if (token) { this.token = token; }
    if (alt) { this.altHost = alt; }
    if (!this.manualHost || !this.token) {
      this.errorMessage = '未能从内容解析出地址或 token';
      return false;
    }
    this.errorMessage = '';
    return true;
  }

  private async importFromClipboard(): Promise<void> {
    try {
      const text = pasteboard.getSystemPasteboard().getDataSync().getPrimaryText();
      if (!text || text.trim().length === 0) {
        this.errorMessage = '剪贴板为空';
        return;
      }
      this.linkText = text.trim();
      if (this.applyLink()) {
        await this.connect();
      }
    } catch (e) {
      this.errorMessage = '读取剪贴板失败';
    }
  }

  private async scanPairingCode(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false
      };
      const result = await scanBarcode.startScanForResult(context, options);
      const value = result.originalValue;
      if (!value) {
        this.errorMessage = '未识别到二维码内容';
        return;
      }
      this.linkText = value;
      if (this.applyLink()) {
        await this.connect();
      }
    } catch (e) {
      // 用户取消扫码也会进入这里，不当作错误提示
      Logger.warn('scan cancelled or failed');
    }
  }

  build() {
    Scroll() {
      Column() {
        Text('连接 cc-haha').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.textStrong(this.theme)).margin({ top: 28, bottom: 20 })

        Row() {
          Button('扫码').type(ButtonType.Capsule).backgroundColor(ThemeColors.primary)
            .fontColor(ThemeColors.onPrimary(this.theme))
            .layoutWeight(1).height(48)
            .accessibilityLevel('yes').accessibilityText('扫码配对').id('pair-scan')
            .onClick(() => { this.scanPairingCode(); })
          Button('从剪贴板导入').type(ButtonType.Capsule)
            .backgroundColor(ThemeColors.primarySoft(this.theme)).fontColor(ThemeColors.primary)
            .layoutWeight(1).height(48).margin({ left: 10 })
            .accessibilityLevel('yes').accessibilityText('从剪贴板导入').id('pair-clipboard')
            .onClick(() => { this.importFromClipboard(); })
        }.width('100%').margin({ bottom: 16 })

        Column() {
          TextArea({ placeholder: 'H5 链接', text: this.linkText })
            .width('100%').height(80).fontSize(13).fontColor(ThemeColors.text(this.theme))
            .placeholderColor(ThemeColors.placeholder(this.theme))
            .backgroundColor(ThemeColors.inputBg(this.theme)).borderRadius(8)
            .padding(10).onChange((v: string) => { this.linkText = v; })
            .accessibilityLevel('yes').accessibilityText('H5 链接').id('pair-link')
          Button(this.isConnecting ? '连接中' : '连接').type(ButtonType.Capsule)
            .backgroundColor(ThemeColors.primary).fontColor(ThemeColors.onPrimary(this.theme))
            .width('100%').height(44).margin({ top: 10 })
            .enabled(!this.isConnecting).opacity(this.isConnecting ? 0.6 : 1)
            .accessibilityLevel('yes').accessibilityText('用链接连接').id('pair-connect')
            .onClick(() => { this.connectFromLink(); })
        }.width('100%').padding(16).backgroundColor(ThemeColors.card(this.theme)).borderRadius(12).margin({ bottom: 12 })

        Column() {
          Row() {
            Text('手动填写').fontSize(15).fontColor(ThemeColors.text(this.theme))
            Blank()
            Text(this.manualExpanded ? '▾' : '▸').fontSize(10)
              .fontColor(ThemeColors.textSecondary(this.theme)).accessibilityLevel('no')
          }
          .width('100%').height(48)
          .accessibilityLevel('yes')
          .accessibilityText((this.manualExpanded ? '收起' : '展开') + '手动填写')
          .id('pair-manual-toggle')
          .onClick(() => { this.manualExpanded = !this.manualExpanded; })

          if (this.manualExpanded) {
            TextInput({ placeholder: 'IP 或主机名', text: this.manualHost })
              .width('100%').height(44).fontSize(14).fontColor(ThemeColors.text(this.theme))
              .placeholderColor(ThemeColors.placeholder(this.theme))
              .borderRadius(8).backgroundColor(ThemeColors.inputBg(this.theme))
              .margin({ bottom: 10 }).onChange((v: string) => { this.manualHost = v; })
              .accessibilityLevel('yes').accessibilityText('IP 或主机名').id('pair-manual-host')
            TextInput({ placeholder: '端口', text: this.manualPort })
              .width('100%').height(44).fontSize(14).fontColor(ThemeColors.text(this.theme))
              .placeholderColor(ThemeColors.placeholder(this.theme))
              .type(InputType.Number).borderRadius(8).backgroundColor(ThemeColors.inputBg(this.theme))
              .margin({ bottom: 10 }).onChange((v: string) => { this.manualPort = v; })
              .accessibilityLevel('yes').accessibilityText('端口').id('pair-manual-port')
            TextInput({ placeholder: '备用地址（可选）', text: this.altHost })
              .width('100%').height(44).fontSize(14).fontColor(ThemeColors.text(this.theme))
              .placeholderColor(ThemeColors.placeholder(this.theme))
              .borderRadius(8).backgroundColor(ThemeColors.inputBg(this.theme))
              .margin({ bottom: 10 }).onChange((v: string) => { this.altHost = v; })
              .accessibilityLevel('yes').accessibilityText('备用地址').id('pair-manual-alt')
            TextInput({ placeholder: 'H5 Token', text: this.token })
              .width('100%').height(44).fontSize(14).fontColor(ThemeColors.text(this.theme))
              .placeholderColor(ThemeColors.placeholder(this.theme))
              .borderRadius(8).backgroundColor(ThemeColors.inputBg(this.theme))
              .margin({ bottom: 10 }).onChange((v: string) => { this.token = v; })
              .accessibilityLevel('yes').accessibilityText('H5 Token').id('pair-manual-token')
            TextInput({ placeholder: 'Origin（可选）', text: this.originUrl })
              .width('100%').height(44).fontSize(13).fontColor(ThemeColors.text(this.theme))
              .placeholderColor(ThemeColors.placeholder(this.theme))
              .borderRadius(8).backgroundColor(ThemeColors.inputBg(this.theme))
              .margin({ bottom: 10 }).onChange((v: string) => { this.originUrl = v; })
              .accessibilityLevel('yes').accessibilityText('Origin').id('pair-manual-origin')
            Button(this.isConnecting ? '连接中' : '连接').type(ButtonType.Capsule)
              .backgroundColor(ThemeColors.primary).fontColor(ThemeColors.onPrimary(this.theme))
              .width('100%').height(44)
              .enabled(!this.isConnecting).opacity(this.isConnecting ? 0.6 : 1)
              .accessibilityLevel('yes').accessibilityText('用手动填写的信息连接').id('pair-manual-connect')
              .onClick(() => { this.connect(); })
          }
        }.width('100%').padding({ left: 16, right: 16 }).backgroundColor(ThemeColors.card(this.theme)).borderRadius(12)

        if (this.pairStatus) {
          Text(this.pairStatus).fontSize(13).fontColor(ThemeColors.primary).width('100%').padding(10)
            .backgroundColor(ThemeColors.primarySoft(this.theme)).borderRadius(8).margin({ top: 12 })
            .accessibilityLevel('yes').accessibilityText('配对状态：' + this.pairStatus)
        }
        if (this.errorMessage) {
          Text(this.errorMessage).fontSize(13).fontColor(ThemeColors.dangerText(this.theme)).width('100%').padding(10)
            .backgroundColor(ThemeColors.errorBg(this.theme)).borderRadius(8).margin({ top: 12 })
        }

        Divider().height(32).color(Color.Transparent)
      }
      .width('100%').padding({ left: 16, right: 16 })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.pageBg(this.theme)).scrollBar(BarState.Off)
  }
}
