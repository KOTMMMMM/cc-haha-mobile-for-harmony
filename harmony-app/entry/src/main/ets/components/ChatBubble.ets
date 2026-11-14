import { MessageModel, MessageRole, ContentType, TextContent, ThinkingContent, ToolUseContent } from '../models/Message';
import { ToolCallCard } from './ToolCallCard';
import { ThinkingBlock } from './ThinkingBlock';
import { StreamingText } from './StreamingText';
import { MarkdownView } from './MarkdownView';

@Component
export struct ChatBubble {
  @Prop message: MessageModel = new MessageModel(MessageRole.USER);
  @Prop isLast: boolean = false;
  @Prop hideProcess: boolean = false;
  @Prop showTurnHeader: boolean = false;
  @Prop turnStepCount: number = 0;
  @Prop turnCollapsed: boolean = true;
  onToggleTurn: () => void = () => {};

  build() {
    Row() {
      if (this.message.role === MessageRole.USER) { Blank() }

      Column() {
        // 本轮步骤组头：统一展开/收起该轮的思考与工具块
        if (this.showTurnHeader && this.turnStepCount > 0) {
          Row() {
            Text(this.turnCollapsed ? '▸' : '▾').fontSize(10).fontColor('#999')
            Text('本轮 ' + this.turnStepCount + ' 个步骤').fontSize(11).fontColor('#888').margin({ left: 4 })
            Blank()
            Text(this.turnCollapsed ? '展开过程' : '收起过程').fontSize(11).fontColor('#1677FF')
          }
          .width('100%')
          .padding({ left: 6, right: 6, top: 2, bottom: 4 })
          .onClick(() => { this.onToggleTurn(); })
        }

        if (!(this.hideProcess && !this.hasTextContent())) {
        Column() {
          if (this.message.role === MessageRole.SYSTEM) {
            Text('系统')
              .fontSize(10).fontColor('#888').margin({ bottom: 4 })
          }

          if (this.hideProcess) {
            // 折叠状态只显示文字：合并成一个 Markdown 视图，
            // 避免多个相邻 MarkdownView 在流式高频重建时高度测量滞后而互相重叠。
            if (this.message.isStreaming) {
              StreamingText({ text: this.joinedText(), textColor: this.userTextColor() })
            } else {
              MarkdownView({ text: this.joinedText(), textColor: this.userTextColor(), fontSize: 15 })
            }
          } else {
            ForEach(this.message.contents, (content: Object, index: number) => {
              Column() {
                if ((content as TextContent).type === ContentType.TEXT) {
                  if (this.message.role === MessageRole.USER || !this.message.isStreaming ||
                      index < this.message.contents.length - 1) {
                    MarkdownView({
                      text: (content as TextContent).text,
                      textColor: this.userTextColor(),
                      fontSize: 15
                    })
                  } else {
                    StreamingText({
                      text: (content as TextContent).text,
                      textColor: this.userTextColor()
                    })
                  }
                } else if ((content as ThinkingContent).type === ContentType.THINKING) {
                  if (!this.hideProcess) {
                    ThinkingBlock({
                      text: (content as ThinkingContent).text,
                      collapsed: (content as ThinkingContent).collapsed
                    })
                  }
                } else if ((content as ToolUseContent).type === ContentType.TOOL_USE) {
                  if (!this.hideProcess) {
                    ToolCallCard({ toolContent: content as ToolUseContent })
                  }
                }
              }
            }, (content: Object, index: number): string => {
              const c = content as TextContent | ThinkingContent | ToolUseContent;
              return c.type + '_' + index;
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius(16)
        .backgroundColor(this.getMessageBg())
        .shadow(this.message.role === MessageRole.ASSISTANT ? {
          radius: 4, color: 'rgba(0,0,0,0.05)', offsetX: 0, offsetY: 1
        } : undefined)

        // 时间显示在气泡外，右下角
        Text(this.formatTime(this.message.timestamp))
          .fontSize(10)
          .fontColor('#999999')
          .margin({ top: 4 })
        }
      }
      .width('78%')
      .alignItems(HorizontalAlign.End)

      if (this.message.role !== MessageRole.USER) { Blank() }
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ left: 26, right: 12, top: 4, bottom: 4 })
  }

  private userTextColor(): string {
    return this.message.role === MessageRole.USER ? '#FFFFFF' : '#333333';
  }

  private hasTextContent(): boolean {
    for (const c of this.message.contents) {
      if (c.type === ContentType.TEXT && (c as TextContent).text.length > 0) { return true; }
    }
    return false;
  }

  /** 折叠状态下的可见文字：按顺序拼接本轮所有文字块 */
  private joinedText(): string {
    const parts: string[] = [];
    for (const c of this.message.contents) {
      if (c.type === ContentType.TEXT) {
        const t = (c as TextContent).text;
        if (t.length > 0) { parts.push(t); }
      }
    }
    return parts.join('\n\n');
  }

  private getMessageBg(): string {
    switch (this.message.role) {
      case MessageRole.USER: return '#1677FF';
      case MessageRole.ASSISTANT: return '#FFFFFF';
      case MessageRole.SYSTEM: return '#F5F5F5';
      default: return '#FFFFFF';
    }
  }

  private formatTime(timestamp: number): string {
    const date = new Date(timestamp);
    return date.getHours().toString().padStart(2, '0') + ':' +
      date.getMinutes().toString().padStart(2, '0');
  }
}
