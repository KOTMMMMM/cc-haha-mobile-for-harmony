import { MessageModel, MessageRole, ContentType, TextContent, ThinkingContent, ToolUseContent, DeliveryState } from '../models/Message';
import { ToolCallCard } from './ToolCallCard';
import { ThinkingBlock } from './ThinkingBlock';
import { StreamingText } from './StreamingText';
import { MarkdownView } from './MarkdownView';
import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct ChatBubble {
  @StorageLink('theme') theme: string = 'light';
  @Prop message: MessageModel = new MessageModel(MessageRole.USER);
  @Prop hideProcess: boolean = false;
  @Prop showTurnHeader: boolean = false;
  @Prop turnStepCount: number = 0;
  @Prop turnCollapsed: boolean = true;
  onToggleTurn: () => void = () => {};
  onRetryMessage: (id: string) => void = () => {};

  build() {
    Row() {
      if (this.message.role === MessageRole.USER) { Blank() }

      Column() {
        // 本轮步骤组头：统一展开/收起该轮的思考与工具块
        if (this.showTurnHeader && this.turnStepCount > 0) {
          Row() {
            Text(this.turnCollapsed ? '▸' : '▾').fontSize(10)
              .fontColor(ThemeColors.textSecondary(this.theme)).accessibilityLevel('no')
            Text(this.turnStepCount + ' 个步骤').fontSize(11)
              .fontColor(ThemeColors.textSecondary(this.theme)).margin({ left: 4 })
            Blank()
          }
          .width('100%')
          .padding({ left: 6, right: 6, top: 2, bottom: 4 })
          .accessibilityLevel('yes')
          .accessibilityText((this.turnCollapsed ? '展开' : '收起') + '本轮 ' + this.turnStepCount + ' 个步骤')
          .id('turn-header-' + this.message.id)
          .onClick(() => { this.onToggleTurn(); })
        }

        if (!(this.hideProcess && !this.hasTextContent())) {
        Column() {
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
        .accessibilityDescription(this.message.role === MessageRole.SYSTEM ? '系统消息' : '')

        // 时间显示在气泡外，右下角
        Text(this.formatTime(this.message.timestamp))
          .fontSize(10)
          .fontColor(ThemeColors.textSecondary(this.theme))
          .margin({ top: 4 })

        // 本地发送状态：服务端无 ACK，不确定送达时明确显示并可点按重试
        if (this.message.role === MessageRole.USER && this.deliveryLabel().length > 0) {
          Text(this.deliveryLabel())
            .fontSize(10)
            .fontColor(this.message.delivery === DeliveryState.FAILED
              ? ThemeColors.dangerText(this.theme)
              : ThemeColors.textSecondary(this.theme))
            .margin({ top: 2 })
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .accessibilityLevel('yes')
            .accessibilityText(this.message.delivery === DeliveryState.FAILED ? '重新发送这条消息' : this.deliveryLabel())
            .id('delivery-' + this.message.id)
            .onClick(() => {
              if (this.message.delivery === DeliveryState.FAILED) { this.onRetryMessage(this.message.id); }
            })
        }
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
    if (this.message.role === MessageRole.USER) { return ThemeColors.userText(this.theme); }
    if (this.message.role === MessageRole.SYSTEM) { return ThemeColors.systemText(this.theme); }
    return ThemeColors.assistantText(this.theme);
  }

  private deliveryLabel(): string {
    switch (this.message.delivery) {
      case DeliveryState.SENDING: return '发送中';
      case DeliveryState.QUEUED: return '已排队';
      case DeliveryState.FAILED: return '未送达 · 重试';
      default: return '';
    }
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
      case MessageRole.USER: return ThemeColors.userBubble(this.theme);
      case MessageRole.ASSISTANT: return ThemeColors.assistantBubble(this.theme);
      case MessageRole.SYSTEM: return ThemeColors.systemBubble(this.theme);
      default: return ThemeColors.assistantBubble(this.theme);
    }
  }

  private formatTime(timestamp: number): string {
    const date = new Date(timestamp);
    return date.getHours().toString().padStart(2, '0') + ':' +
      date.getMinutes().toString().padStart(2, '0');
  }
}
