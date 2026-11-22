import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct ThinkingBlock {
  @StorageLink('theme') theme: string = 'light';
  @Prop text: string = '';
  @Prop collapsed: boolean = true;
  @State isExpanded: boolean = false;

  aboutToAppear(): void { this.isExpanded = false; }

  build() {
    Column() {
      Row() {
        Text('思考').fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.thinkingText(this.theme))
        Blank()
        Text(this.isExpanded ? '▾' : '▸').fontSize(10)
          .fontColor(ThemeColors.textSecondary(this.theme)).accessibilityLevel('no')
      }
      .width('100%').padding({ top: 6, bottom: this.isExpanded ? 2 : 6, left: 10, right: 10 })
      .accessibilityLevel('yes')
      .accessibilityText((this.isExpanded ? '收起' : '展开') + '思考过程')
      .onClick(() => { this.isExpanded = !this.isExpanded; })

      if (this.isExpanded && this.text.length > 0) {
        Text(this.text)
          .fontSize(12).fontColor(ThemeColors.textSecondary(this.theme))
          .fontStyle(FontStyle.Italic).lineHeight(18)
          .padding({ left: 10, right: 10, bottom: 8 }).width('100%')
          .textOverflow({ overflow: TextOverflow.None }).maxLines(999)
      }
    }
    .width('100%')
    .backgroundColor(ThemeColors.thinkingBg(this.theme)).borderRadius(8)
    .border({ width: 1, color: ThemeColors.thinkingBorder(this.theme), style: BorderStyle.Solid })
    .margin({ top: 4, bottom: 4 })
  }
}
