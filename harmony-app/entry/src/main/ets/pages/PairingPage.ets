import router from '@ohos.router';
import { pasteboard } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { ApiService } from '../services/ApiService';
import { AuthService } from '../services/AuthService';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';

/**
 * 连接新版 cc-haha：粘贴桌面端 H5 链接，或手动填 host/port/H5 Token。
 */
@Entry
@Component
struct PairingPage {
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

  async connect(): Promise<void> {
    if (this.isConnecting) { return; }
    this.errorMessage = '';
    const host = this.manualHost.trim();
    const port = parseInt(this.manualPort, 10);
    const token = this.token.trim();
    if (!host) { this.errorMessage = '请输入 PC 地址（局域网 IP / Tailscale IP / 主机名）'; return; }
    if (isNaN(port) || port <= 0 || port > 65535) { this.errorMessage = '端口无效'; return; }
    if (!token) { this.errorMessage = '请输入 H5 Token（或直接粘贴 H5 链接）'; return; }

    this.isConnecting = true;
    try {
      this.apiService.setConnection(host, port, token);
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
        host: host, port: port, token: token, hostname: host, origin: origin,
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
          this.errorMessage = '';
          return true;
        }
      } catch (e) {
      }
      this.errorMessage = '二维码内容缺少 host 或 token';
      return false;
    }
    const qIndex = link.indexOf('?');
    if (qIndex < 0) {
      // 也接受 serverUrl 形式的 URL：http://host:port/#/?serverUrl=...
      this.errorMessage = '内容格式不正确，应包含 ?serverUrl=...&h5Token=...';
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
      Text('连接 cc-haha').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#333').margin({ top: 28, bottom: 6 })
      Text('新版桌面端：设置 → H5 访问 → 启用并复制链接').fontSize(13).fontColor('#999').margin({ bottom: 20 })

      Column() {
        Text('方式一：扫码 / 粘贴 H5 链接').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#333').width('100%').margin({ bottom: 8 })
        Row() {
          Button('扫码配对').type(ButtonType.Capsule).backgroundColor('#1677FF').fontColor('#FFFFFF')
            .layoutWeight(1).height(40).onClick(() => { this.scanPairingCode(); })
          Button('从剪贴板导入').type(ButtonType.Capsule).backgroundColor('#E8F4FF').fontColor('#1677FF')
            .layoutWeight(1).height(40).margin({ left: 10 }).onClick(() => { this.importFromClipboard(); })
        }.width('100%').margin({ bottom: 10 })
        TextArea({ placeholder: 'http://192.168.1.20:3456/?serverUrl=...&h5Token=...', text: this.linkText })
          .width('100%').height(88).fontSize(12).backgroundColor('#F5F5F5').borderRadius(8)
          .padding(10).onChange((v: string) => { this.linkText = v; })
        Button('解析链接').type(ButtonType.Capsule).backgroundColor('#E8F4FF').fontColor('#1677FF')
          .width('100%').height(40).margin({ top: 10 }).onClick(() => { this.applyLink(); })
      }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12).margin({ bottom: 14 })

      Column() {
        Text('方式二：手动填写').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#333').width('100%').margin({ bottom: 8 })
        TextInput({ placeholder: 'PC 地址（局域网 IP / 100.x.x.x / 主机名）', text: this.manualHost })
          .width('100%').height(44).fontSize(14).borderRadius(8).backgroundColor('#F5F5F5')
          .margin({ bottom: 10 }).onChange((v: string) => { this.manualHost = v; })
        TextInput({ placeholder: '端口（如 3456 / 65499）', text: this.manualPort })
          .width('100%').height(44).fontSize(14).type(InputType.Number).borderRadius(8).backgroundColor('#F5F5F5')
          .margin({ bottom: 10 }).onChange((v: string) => { this.manualPort = v; })
        TextInput({ placeholder: '备用地址（可选，如离开家用的 Tailscale IP）', text: this.altHost })
          .width('100%').height(44).fontSize(14).borderRadius(8).backgroundColor('#F5F5F5')
          .margin({ bottom: 10 }).onChange((v: string) => { this.altHost = v; })
        TextInput({ placeholder: 'H5 Token（h5_...）', text: this.token })
          .width('100%').height(44).fontSize(14).borderRadius(8).backgroundColor('#F5F5F5')
          .margin({ bottom: 10 }).onChange((v: string) => { this.token = v; })
        TextInput({ placeholder: 'Origin（H5 链接里的 serverUrl，如 http://192.168.1.20:65499）', text: this.originUrl })
          .width('100%').height(44).fontSize(13).borderRadius(8).backgroundColor('#F5F5F5')
          .onChange((v: string) => { this.originUrl = v; })
      }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12).margin({ bottom: 14 })

      Text('Tailscale：客户端已内置。首次在设置页开启并登录后会自动连接；地址填 PC 的 Tailscale IP（如 100.64.0.1）。与 ClashBox 等 VPN 不能同时开启。').fontSize(12).fontColor('#999').lineHeight(18).width('100%').margin({ bottom: 14 })

      if (this.errorMessage) {
        Text(this.errorMessage).fontSize(13).fontColor('#F44336').width('100%').padding(10)
          .backgroundColor('rgba(244,67,54,0.08)').borderRadius(8).margin({ bottom: 12 })
      }

      Button(this.isConnecting ? '连接中...' : '连接').type(ButtonType.Capsule).backgroundColor('#1677FF')
        .fontColor('#FFFFFF').fontSize(16).fontWeight(FontWeight.Medium).width('100%').height(46)
        .enabled(!this.isConnecting).opacity(this.isConnecting ? 0.6 : 1)
        .onClick(() => { this.connect(); })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 32 })
    }
    .width('100%').height('100%').backgroundColor('#F8F8F8').scrollBar(BarState.Off)
  }
}
