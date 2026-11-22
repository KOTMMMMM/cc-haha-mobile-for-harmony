import { ToolUseContent } from '../models/Message';
import { getToolStatusText } from '../models/ToolCall';
import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct ToolCallCard {
  @StorageLink('theme') theme: string = 'light';
  @Prop toolContent: ToolUseContent;
  @State isExpanded: boolean = false;

  build() {
    Column() {
      // 折叠态只保留一行：状态 + 工具名 + 状态文字 + 展开指示
      Row() {
        if (this.toolContent.status === 'running') {
          LoadingProgress().width(14).height(14).color(ThemeColors.primary)
        } else if (this.toolContent.status === 'completed' || this.toolContent.status === 'success') {
          Text('✓').fontSize(12).fontColor(ThemeColors.successText(this.theme)).fontWeight(FontWeight.Bold)
            .accessibilityLevel('no')
        } else {
          Text('✕').fontSize(12).fontColor(ThemeColors.dangerText(this.theme)).fontWeight(FontWeight.Bold)
            .accessibilityLevel('no')
        }

        Text(this.getDisplayName(this.toolContent.toolName))
          .fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.text(this.theme)).margin({ left: 6 })
        Blank()
        Text(getToolStatusText(this.toolContent.status))
          .fontSize(10).fontColor(this.statusColor())
        Text(this.isExpanded ? '▾' : '▸')
          .fontSize(10).fontColor(ThemeColors.textSecondary(this.theme)).margin({ left: 4 })
          .accessibilityLevel('no')
      }
      .width('100%').padding({ top: 6, bottom: 6, left: 10, right: 10 })
      .accessibilityLevel('yes')
      .accessibilityText(this.getDisplayName(this.toolContent.toolName) + '，' +
        getToolStatusText(this.toolContent.status) + (this.isExpanded ? '，已展开' : '，已收起'))
      .id('tool-' + (this.toolContent.toolId || this.toolContent.toolName))
      .onClick(() => { this.isExpanded = !this.isExpanded; })

      if (this.isExpanded) {
        Column() {
          Divider().height(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 10, right: 10 })

          Text('参数').fontSize(10).fontColor(ThemeColors.textSecondary(this.theme)).fontWeight(FontWeight.Medium)
            .margin({ top: 6, left: 10 }).width('100%')
          Text(JSON.stringify(this.toolContent.toolInput, null, 2))
            .fontSize(11).fontColor(ThemeColors.chipText(this.theme)).fontFamily('monospace')
            .padding({ left: 10, right: 10, top: 2, bottom: 6 }).width('100%').maxLines(10)

          if (this.toolContent.output && this.toolContent.output.length > 0) {
            Divider().height(0.5).color(ThemeColors.divider(this.theme)).margin({ left: 10, right: 10 })
            Text('输出').fontSize(10).fontColor(ThemeColors.textSecondary(this.theme)).fontWeight(FontWeight.Medium)
              .margin({ top: 6, left: 10 }).width('100%')
            Text(this.toolContent.output)
              .fontSize(11).fontColor(ThemeColors.chipText(this.theme)).fontFamily('monospace')
              .padding({ left: 10, right: 10, top: 2, bottom: 8 }).width('100%')
              .maxLines(20).backgroundColor(ThemeColors.neutralBg(this.theme))
          }
        }.width('100%')
      }
    }
    .width('100%')
    .backgroundColor(this.toolContent.status === 'error'
      ? ThemeColors.toolErrorBg(this.theme) : ThemeColors.toolBg(this.theme))
    .borderRadius(8)
    .border({ width: 1, color: this.statusColor(), style: BorderStyle.Solid })
    .margin({ top: 3, bottom: 3 })
  }

  private statusColor(): string {
    switch (this.toolContent.status) {
      case 'running': return ThemeColors.primary;
      case 'completed':
      case 'success': return ThemeColors.successText(this.theme);
      case 'error': return ThemeColors.dangerText(this.theme);
      default: return ThemeColors.textSecondary(this.theme);
    }
  }

  private getDisplayName(toolName: string): string {
    const map: Record<string, string> = {
      'Bash': '终端命令', 'Read': '读取文件', 'Write': '写入文件', 'Edit': '编辑文件',
      'Glob': '文件搜索', 'Grep': '内容搜索', 'Task': '子任务', 'TodoWrite': '待办列表',
      'WebFetch': '网页抓取', 'WebSearch': '网页搜索', 'Skill': '技能调用'
    };
    return map[toolName] ?? toolName;
  }
}
