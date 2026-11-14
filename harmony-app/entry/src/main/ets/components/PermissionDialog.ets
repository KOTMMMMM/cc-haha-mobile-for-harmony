export interface PermissionRequest {
  toolCallId: string;
  toolName: string;
  toolInput: object;
  description?: string;
}

@CustomDialog
export struct ToolPermissionDialog {
  controller: CustomDialogController;
  request: PermissionRequest | null = null;
  onAllow: (toolCallId: string) => void = (s: string) => {};
  onDeny: (toolCallId: string) => void = (s: string) => {};
  onAlwaysAllow: (toolCallId: string) => void = (s: string) => {};

  build() {
    Column() {
      Text('权限请求').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#333').margin({ top: 20, bottom: 12 })
      Text('(!)').fontSize(40).margin({ bottom: 12 })
      Text('Claude 想要执行:').fontSize(14).fontColor('#666').margin({ bottom: 4 })
      Text(this.request ? this.getDisplayName(this.request.toolName) : '')
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1677FF').margin({ bottom: 12 })

      if (this.hasToolInput()) {
        Text('参数:').fontSize(12).fontColor('#999').margin({ bottom: 4 }).width('100%')
        Text(this.getToolInputString()).fontSize(11).fontColor('#666').fontFamily('monospace')
          .padding(12).width('100%').backgroundColor('#F5F5F5').borderRadius(8)
          .maxLines(8).textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Divider().height(1).color('#EEE')

      Button() { Text('始终允许').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF') }
        .type(ButtonType.Capsule).backgroundColor('#1677FF').width('80%').height(44).margin({ top: 16, bottom: 8 })
        .onClick(() => { if (this.request) { this.onAlwaysAllow(this.request.toolCallId); } this.controller.close(); })

      Button() { Text('允许一次').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1677FF') }
        .type(ButtonType.Capsule).backgroundColor('#E8F4FF').width('80%').height(44).margin({ bottom: 8 })
        .onClick(() => { if (this.request) { this.onAllow(this.request.toolCallId); } this.controller.close(); })

      Button() { Text('拒绝').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#999') }
        .type(ButtonType.Capsule).backgroundColor('#F5F5F5').width('80%').height(44).margin({ bottom: 20 })
        .onClick(() => { if (this.request) { this.onDeny(this.request.toolCallId); } this.controller.close(); })
    }
    .width('100%').alignItems(HorizontalAlign.Center)
  }

  private hasToolInput(): boolean {
    if (!this.request || !this.request.toolInput) { return false; }
    const s = JSON.stringify(this.request.toolInput);
    return s.length > 0 && s !== '{}';
  }

  private getToolInputString(): string {
    if (!this.request || !this.request.toolInput) { return ''; }
    return JSON.stringify(this.request.toolInput, null, 1);
  }

  private getDisplayName(toolName: string): string {
    const map: Record<string, string> = {
      'Bash': '终端命令 (Bash)', 'Read': '读取文件 (Read)',
      'Write': '写入文件 (Write)', 'Edit': '编辑文件 (Edit)',
      'Glob': '文件搜索 (Glob)', 'Grep': '内容搜索 (Grep)',
      'Task': '子任务 (Task)', 'WebFetch': '网页抓取 (WebFetch)'
    };
    return map[toolName] ?? toolName;
  }
}
