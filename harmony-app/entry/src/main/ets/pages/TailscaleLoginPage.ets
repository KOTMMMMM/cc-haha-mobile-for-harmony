import router from '@ohos.router';
import { webview } from '@kit.ArkWeb';
import { promptAction } from '@kit.ArkUI';
import { TailscaleVpnService } from '../services/TailscaleVpnService';
import { ThemeColors } from '../utils/ThemeUtil';

/**
 * 应用内 Tailscale 登录：用 WebView 打开扩展给出的 authUrl，
 * 扩展轮询到 running 后自动关闭并回到设置页。
 */
@Entry
@Component
struct TailscaleLoginPage {
  @StorageLink('theme') theme: string = 'light';
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
    this.detail = this.url.length > 0 ? '' : '请先开启内置 Tailscale';
    this.tailscaleService.refreshStatus();
  }

  private onStateChanged(): void {
    if (this.closed) { return; }
    if (this.tailscaleState === 'running') {
      this.closed = true;
      setTimeout((): void => {
        router.back();
      }, 600);
    } else if (this.tailscaleState === 'failed' || this.tailscaleState === 'stale') {
      this.detail = '登录状态异常';
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
      this.detail = '请稍候重试';
    }
  }

  build() {
    Column() {
      Row() {
        Text('‹').fontSize(30).fontColor(ThemeColors.textStrong(this.theme))
          .width(44).height('100%').textAlign(TextAlign.Center)
          .accessibilityLevel('yes').accessibilityText('返回').id('ts-login-back')
          .onClick(() => { router.back(); })

        Text('Tailscale 登录').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.textStrong(this.theme))
          .layoutWeight(1).textAlign(TextAlign.Center)

        Text('↻').fontSize(17).fontColor(ThemeColors.primary)
          .width(44).height('100%').textAlign(TextAlign.Center)
          .accessibilityLevel('yes').accessibilityText('刷新登录链接').id('ts-login-refresh')
          .onClick(() => { this.refreshLink(); })
      }
      .width('100%').height(48)
      .backgroundColor(ThemeColors.card(this.theme))
      .border({ width: { bottom: 0.5 }, color: ThemeColors.divider(this.theme) })
      .alignItems(VerticalAlign.Center)

      if (this.url.length > 0) {
        Web({ src: this.url, controller: this.controller })
          .width('100%').layoutWeight(1)
      } else {
        Column() {
          Text(this.detail).fontSize(14).fontColor(ThemeColors.textSecondary(this.theme))
            .textAlign(TextAlign.Center).padding({ left: 24, right: 24, bottom: 16 })
            .accessibilityLevel('yes').accessibilityText('暂无登录链接')
          Button('在浏览器打开').type(ButtonType.Capsule).backgroundColor(ThemeColors.primarySoft(this.theme))
            .fontColor(ThemeColors.primary).height(44)
            .accessibilityLevel('yes').accessibilityText('在浏览器打开').id('ts-login-browser')
            .onClick(() => { this.openInBrowser(); })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.pageBg(this.theme))
  }
}
