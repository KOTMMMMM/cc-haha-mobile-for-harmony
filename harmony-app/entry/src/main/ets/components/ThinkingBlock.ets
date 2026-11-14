@Component
export struct ThinkingBlock {
  @Prop text: string = '';
  @Prop collapsed: boolean = true;
  @State isExpanded: boolean = false;

  aboutToAppear(): void { this.isExpanded = false; }

  build() {
    Column() {
      Row() {
        Text('思考过程').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#9C27B0')
        Blank()
        Text(this.isExpanded ? '收起' : '展开').fontSize(11).fontColor('#999')
      }
      .width('100%').padding({ top: 6, bottom: this.isExpanded ? 2 : 6, left: 10, right: 10 })
      .onClick(() => { this.isExpanded = !this.isExpanded; })

      if (this.isExpanded && this.text.length > 0) {
        Text(this.text)
          .fontSize(12).fontColor('#888').fontStyle(FontStyle.Italic).lineHeight(18)
          .padding({ left: 10, right: 10, bottom: 8 }).width('100%')
          .textOverflow({ overflow: TextOverflow.None }).maxLines(999)
      }
    }
    .width('100%')
    .backgroundColor('rgba(156,39,176,0.05)').borderRadius(8)
    .border({ width: 1, color: 'rgba(156,39,176,0.15)', style: BorderStyle.Solid })
    .margin({ top: 4, bottom: 4 })
  }
}
