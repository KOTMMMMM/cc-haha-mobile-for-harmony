import router from '@ohos.router';
import { webview } from '@kit.ArkWeb';
import { promptAction } from '@kit.ArkUI';
import { TailscaleVpnService } from '../services/TailscaleVpnService';

/**
 * 应用内 Tailscale 登录：用 WebView 打开扩展给出的 authUrl，
 * 扩展轮询到 running 后自动关闭并回到设置页。
 */
@Entry
@Component
struct TailscaleLoginPage {
  @StorageLink('tailscaleService') tailscaleService: TailscaleVpnService = new TailscaleVpnService();
  @StorageLink('tailscaleState') @Watch('onStateChanged') tailscaleState: string = 'idle';
  @StorageLink('tailscaleAuthUrl') authUrl: string = '';
  @State url: string = '';
  @State detail: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private closed: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    const fromParams = params ? (params['url'] as string) : '';
    this.url = (fromParams && fromParams.length > 0) ? fromParams : this.authUrl;
    this.detail = this.url.length > 0 ? '' : '暂时没有登录链接，请先开启内置 Tailscale 并稍候重试。';
    this.tailscaleService.refreshStatus();
  }

  private onStateChanged(): void {
    if (this.closed) { return; }
    if (this.tailscaleState === 'running') {
      this.closed = true;
      promptAction.showToast({ message: 'Tailscale 已登录', duration: 1500 });
      setTimeout((): void => {
        router.back();
      }, 600);
    } else if (this.tailscaleState === 'failed' || this.tailscaleState === 'stale') {
      this.detail = '登录状态异常，请返回重试或改用浏览器打开。';
    }
  }

  private openInBrowser(): void {
    this.tailscaleService.openLogin().then((ok: boolean): void => {
      if (!ok) {
        promptAction.showToast({ message: '暂时没有可用的登录链接', duration: 2000 });
      }
    });
  }

  private refreshLink(): void {
    this.tailscaleService.refreshStatus();
    if (this.authUrl && this.authUrl.length > 0) {
      this.url = this.authUrl;
      this.detail = '';
    } else {
      this.detail = '暂时没有登录链接，请稍候再试。';
    }
  }

  build() {
    Column() {
      Row() {
        Text('‹').fontSize(32).fontWeight(FontWeight.Medium).fontColor('#333')
          .width(44).height('100%').textAlign(TextAlign.Center)
          .onClick(() => { router.back(); })

        Text('Tailscale 登录').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#333')
          .layoutWeight(1).margin({ left: 2 })

        Text('浏览器打开').fontSize(13).fontColor('#1677FF')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .onClick(() => { this.openInBrowser(); })

        Text('刷新').fontSize(13).fontColor('#1677FF')
          .padding({ left: 10, right: 12, top: 8, bottom: 8 })
          .onClick(() => { this.refreshLink(); })
      }
      .width('100%').height(52)
      .backgroundColor('#FFFFFF')
      .border({ width: { bottom: 0.5 }, color: '#E5E5E5' })
      .alignItems(VerticalAlign.Center)

      if (this.url.length > 0) {
        Web({ src: this.url, controller: this.controller })
          .width('100%').layoutWeight(1)
      } else {
        Column() {
          Text(this.detail).fontSize(14).fontColor('#666')
            .textAlign(TextAlign.Center).padding(24)
          Button('重新获取登录链接').type(ButtonType.Capsule).backgroundColor('#1677FF')
            .fontColor('#FFFFFF').height(42).onClick(() => { this.refreshLink(); })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%').backgroundColor('#F8F8F8')
  }
}
