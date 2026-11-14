@Component
export struct ConnectionStatus {
  @Prop connectionState: string = 'disconnected';
  @Prop pcHostname: string = '';
  @Prop isDark: boolean = false;
  onTap: () => void = () => {};
  onRefresh: () => void = () => {};

  build() {
    Row() {
      Circle().width(8).height(8).fill(this.getDotColor())
      Text(this.getStatusText()).fontSize(12).fontColor(this.getTextColor()).margin({ left: 6 })
      if (this.connectionState === 'connected' && this.pcHostname) {
        Text(' - ' + this.pcHostname).fontSize(12).fontColor('#999').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '50%' })
      }
      Blank()
      Text('↻ 刷新').fontSize(12).fontColor('#1677FF').padding({ left: 8, right: 8 })
        .onClick(() => { this.onRefresh(); })
      Text('>').fontSize(12).fontColor('#999')
    }
    .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.getBgColor())
    .border({ width: { bottom: 0.5 }, color: '#E5E5E5' })
    .onClick(() => { this.onTap(); })
  }

  private getDotColor(): string {
    switch (this.connectionState) {
      case 'connected': return '#4CAF50';
      case 'connecting': return '#FF9800';
      case 'disconnected': return '#F44336';
      default: return '#9E9E9E';
    }
  }

  private getStatusText(): string {
    switch (this.connectionState) {
      case 'connected': return '已连接';
      case 'connecting': return '连接中...';
      case 'disconnected': return '未连接';
      default: return '未知';
    }
  }

  private getTextColor(): string {
    switch (this.connectionState) {
      case 'connected': return '#4CAF50';
      case 'connecting': return '#FF9800';
      case 'disconnected': return '#F44336';
      default: return '#9E9E9E';
    }
  }

  private getBgColor(): string {
    switch (this.connectionState) {
      case 'connected': return 'rgba(76,175,80,0.05)';
      case 'connecting': return 'rgba(255,152,0,0.05)';
      case 'disconnected': return 'rgba(244,67,54,0.05)';
      default: return '#FAFAFA';
    }
  }
}
