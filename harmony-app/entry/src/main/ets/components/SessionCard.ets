import { SessionModel } from '../models/Session';

@Component
export struct SessionCard {
  @ObjectLink session: SessionModel;
  @Prop isSelected: boolean = false;
  onTap: () => void = () => {};
  onDelete: () => void = () => {};
  @State offsetX: number = 0;
  private swipeThreshold: number = -120;

  build() {
    Stack() {
      Row() {
        Blank()
        Button('删除')
          .fontSize(14).fontColor('#FFFFFF').backgroundColor('#F44336')
          .width(80).height('100%')
          .onClick(() => { this.onDelete(); this.offsetX = 0; })
      }
      .width('100%').height('100%').backgroundColor('#F44336')

      Column() {
        Row() {
          Circle().width(8).height(8).fill((this.session.status === 'generating' || this.session.status === 'executing') ? '#4CAF50' : '#CCC')
          Text(this.session.getDisplayTitle())
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#333')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' }).margin({ left: 10 })
          Blank()
          Text(this.session.getRelativeTime()).fontSize(12).fontColor('#999')
        }
        .width('100%').margin({ bottom: 10 })

        Row() {
          Text(this.session.model)
            .fontSize(11).fontColor('#1677FF')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('rgba(22,119,255,0.1)').borderRadius(10)
          Text(this.session.messageCount + ' 条消息').fontSize(12).fontColor('#999').margin({ left: 12 })
          Blank()
          Text('#' + this.session.id.substring(0, 8)).fontSize(10).fontColor('#CCC')
        }.width('100%')
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
      .padding(16)
      .backgroundColor(this.isSelected ? '#E8F4FF' : '#FFFFFF')
      .border({ width: this.isSelected ? 1.5 : 0, color: '#1677FF' })
      .borderRadius(12)
      .offset({ x: this.offsetX, y: 0 })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
          .onActionUpdate((event: GestureEvent) => {
            if (event.offsetX < 0) { this.offsetX = Math.max(event.offsetX, this.swipeThreshold); }
          })
          .onActionEnd((event: GestureEvent) => {
            this.offsetX = this.offsetX < this.swipeThreshold / 2 ? this.swipeThreshold : 0;
          })
      )
      .onClick(() => { if (this.offsetX < 0) { this.offsetX = 0; } else { this.onTap(); } })
    }
    .width('100%').height(92).clip(true).borderRadius(12)
    .margin({ left: 16, right: 16, top: 6, bottom: 6 })
    .shadow({ radius: 4, color: 'rgba(0,0,0,0.06)', offsetX: 0, offsetY: 2 })
  }

  private getDisplayPath(workDir: string): string {
    if (!workDir || workDir.length === 0) { return '新会话'; }
    const parts = workDir.split('/');
    return parts[parts.length - 1] || workDir;
  }
}
