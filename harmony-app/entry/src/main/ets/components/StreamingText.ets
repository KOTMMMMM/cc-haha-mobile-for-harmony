import { MarkdownView } from './MarkdownView';

@Component
export struct StreamingText {
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop textColor: string = '#333333';
  @State displayText: string = '';

  aboutToAppear(): void { this.displayText = this.text; }
  onTextChanged(): void { this.displayText = this.text; }

  build() {
    Column() {
      MarkdownView({ text: this.displayText, textColor: this.textColor, fontSize: 15 })
      Text('▍').fontSize(13).fontColor('#999').margin({ top: 2 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}
