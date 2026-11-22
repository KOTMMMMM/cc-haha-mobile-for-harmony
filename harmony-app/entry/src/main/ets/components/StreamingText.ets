import { MarkdownView } from './MarkdownView';
import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct StreamingText {
  @StorageLink('theme') theme: string = 'light';
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop textColor: string = ThemeColors.text('light');
  @State displayText: string = '';

  aboutToAppear(): void { this.displayText = this.text; }
  onTextChanged(): void { this.displayText = this.text; }

  build() {
    Column() {
      MarkdownView({ text: this.displayText, textColor: this.textColor, fontSize: 15 })
      Text('▍').fontSize(13).fontColor(ThemeColors.textSecondary(this.theme)).margin({ top: 2 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}
