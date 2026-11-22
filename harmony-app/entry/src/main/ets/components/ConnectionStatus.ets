import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct ConnectionStatus {
  @StorageLink('theme') theme: string = 'light';
  @Prop connectionState: string = 'disconnected';
  @Prop pcHostname: string = '';
  onTap: () => void = () => {};
  onRefresh: () => void = () => {};

  build() {
    Row() {
      Circle().width(8).height(8).fill(this.dotColor())
      Text(this.statusText()).fontSize(12).fontColor(this.statusColor()).margin({ left: 6 })
      if (this.connectionState === 'connected' && this.pcHostname) {
        Text('· ' + this.pcHostname).fontSize(12).fontColor(ThemeColors.textSecondary(this.theme))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '60%' }).margin({ left: 6 })
          .accessibilityLevel('no')
      }
      Blank()
      Text('↻').fontSize(16).fontColor(ThemeColors.primary)
        .width(44).height(44).textAlign(TextAlign.Center)
        .accessibilityLevel('yes').accessibilityText('刷新连接').id('conn-refresh')
        .onClick(() => { this.onRefresh(); })
      Text('›').fontSize(16).fontColor(ThemeColors.textSecondary(this.theme))
        .margin({ left: 2, right: 6 }).accessibilityLevel('no')
    }
    .width('100%').padding({ left: 16, right: 4 })
    .backgroundColor(ThemeColors.card(this.theme))
    .border({ width: { bottom: 0.5 }, color: ThemeColors.divider(this.theme) })
    .accessibilityLevel('yes')
    .accessibilityText(this.accessibilitySummary())
    .id('conn-status')
    .onClick(() => { this.onTap(); })
  }

  private statusText(): string {
    switch (this.connectionState) {
      case 'connected': return '已连接';
      case 'connecting': return '连接中';
      case 'disconnected': return '未连接';
      default: return '未知';
    }
  }

  private statusColor(): string {
    switch (this.connectionState) {
      case 'connected': return ThemeColors.successText(this.theme);
      case 'connecting': return ThemeColors.warningText(this.theme);
      case 'disconnected': return ThemeColors.dangerText(this.theme);
      default: return ThemeColors.textSecondary(this.theme);
    }
  }

  private dotColor(): string {
    switch (this.connectionState) {
      case 'connected': return ThemeColors.successDot(this.theme);
      case 'connecting': return ThemeColors.warningDot(this.theme);
      case 'disconnected': return ThemeColors.dangerDot(this.theme);
      default: return ThemeColors.textTertiary(this.theme);
    }
  }

  private accessibilitySummary(): string {
    const host: string = this.connectionState === 'connected' && this.pcHostname ? '，' + this.pcHostname : '';
    return '连接状态：' + this.statusText() + host + '，点击打开设置';
  }
}
