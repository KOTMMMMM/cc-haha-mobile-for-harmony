import { ToolUseContent } from '../models/Message';
import { getToolColor, getToolStatusText } from '../models/ToolCall';

@Component
export struct ToolCallCard {
  @Prop toolContent: ToolUseContent;
  @State isExpanded: boolean = false;

  build() {
    Column() {
      // 折叠态只保留一行：状态 + 工具名 + 状态标签 + 展开指示
      Row() {
        if (this.toolContent.status === 'running') {
          LoadingProgress().width(14).height(14).color('#2196F3')
        } else if (this.toolContent.status === 'completed' || this.toolContent.status === 'success') {
          Text('OK').fontSize(12).fontColor('#4CAF50').fontWeight(FontWeight.Bold)
        } else {
          Text('X').fontSize(12).fontColor('#F44336').fontWeight(FontWeight.Bold)
        }

        Text(this.getDisplayName(this.toolContent.toolName))
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#555').margin({ left: 6 })
        Blank()
        Text(getToolStatusText(this.toolContent.status))
          .fontSize(10).fontColor(getToolColor(this.toolContent.status))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 }).borderRadius(8)
          .backgroundColor(this.getStatusBg())
        Text(this.isExpanded ? '▾' : '▸')
          .fontSize(10).fontColor('#999').margin({ left: 4 })
      }
      .width('100%').padding({ top: 6, bottom: 6, left: 10, right: 10 })
      .onClick(() => { this.isExpanded = !this.isExpanded; })

      if (this.isExpanded) {
        Column() {
          Divider().height(0.5).color('#EEE').margin({ left: 10, right: 10 })

          Text('参数:').fontSize(10).fontColor('#999').fontWeight(FontWeight.Medium)
            .margin({ top: 6, left: 10 }).width('100%')
          Text(JSON.stringify(this.toolContent.toolInput, null, 2))
            .fontSize(11).fontColor('#666').fontFamily('monospace')
            .padding({ left: 10, right: 10, top: 2, bottom: 6 }).width('100%').maxLines(10)

          if (this.toolContent.output && this.toolContent.output.length > 0) {
            Divider().height(0.5).color('#EEE').margin({ left: 10, right: 10 })
            Text('输出:').fontSize(10).fontColor('#999').fontWeight(FontWeight.Medium)
              .margin({ top: 6, left: 10 }).width('100%')
            Text(this.toolContent.output)
              .fontSize(11).fontColor('#666').fontFamily('monospace')
              .padding({ left: 10, right: 10, top: 2, bottom: 8 }).width('100%')
              .maxLines(20).backgroundColor('#FAFAFA')
          }
        }.width('100%')
      }
    }
    .width('100%')
    .backgroundColor(this.toolContent.status === 'error' ? '#FFF5F5' : '#F8FBFF')
    .borderRadius(8)
    .border({ width: 1, color: getToolColor(this.toolContent.status), style: BorderStyle.Solid })
    .margin({ top: 3, bottom: 3 })
  }

  private getDisplayName(toolName: string): string {
    const map: Record<string, string> = {
      'Bash': '终端命令', 'Read': '读取文件', 'Write': '写入文件', 'Edit': '编辑文件',
      'Glob': '文件搜索', 'Grep': '内容搜索', 'Task': '子任务', 'TodoWrite': '待办列表',
      'WebFetch': '网页抓取', 'WebSearch': '网页搜索', 'Skill': '技能调用'
    };
    return map[toolName] ?? toolName;
  }

  private getStatusBg(): string {
    switch (this.toolContent.status) {
      case 'running': return 'rgba(33,150,243,0.1)';
      case 'success': return 'rgba(76,175,80,0.1)';
      case 'error': return 'rgba(244,67,54,0.1)';
      default: return 'rgba(158,158,158,0.1)';
    }
  }
}
