import { SessionModel } from '../models/Session';
import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct SessionCard {
  @ObjectLink session: SessionModel;
  @StorageLink('theme') theme: string = 'light';
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
          .fontSize(13).fontColor(ThemeColors.onPrimary(this.theme)).backgroundColor(ThemeColors.dangerDot(this.theme))
          .width(80).height('100%')
          .accessibilityLevel('yes').accessibilityText('删除会话').id('delete-session-' + this.session.id)
          .onClick(() => { this.onDelete(); this.offsetX = 0; })
      }
      .width('100%').height('100%').backgroundColor(ThemeColors.dangerDot(this.theme))

      Column() {
        Row() {
          Circle().width(8).height(8)
            .fill(this.session.running ? ThemeColors.successDot(this.theme) : ThemeColors.textTertiary(this.theme))
            .accessibilityLevel('no')
          Text(this.session.getDisplayTitle())
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(ThemeColors.textStrong(this.theme))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1).margin({ left: 10 })
          Text(this.session.getRelativeTime()).fontSize(11).fontColor(ThemeColors.textSecondary(this.theme))
            .margin({ left: 8 })
        }
        .width('100%').margin({ bottom: 6 })

        Row() {
          Text(this.session.model).fontSize(11).fontColor(ThemeColors.textSecondary(this.theme))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('·').fontSize(11).fontColor(ThemeColors.textTertiary(this.theme)).margin({ left: 6, right: 6 })
          Text(this.session.messageCount.toString()).fontSize(11).fontColor(ThemeColors.textSecondary(this.theme))
          Blank()
        }.width('100%')
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isSelected ? ThemeColors.selectedCard(this.theme) : ThemeColors.card(this.theme))
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
      .accessibilityLevel('yes')
      .accessibilityText(this.session.getDisplayTitle() + '，' + (this.session.running ? '运行中' : '空闲') +
        '，' + this.session.messageCount + ' 条消息，' + this.session.getRelativeTime())
      .id('session-card-' + this.session.id)
      .onClick(() => { if (this.offsetX < 0) { this.offsetX = 0; } else { this.onTap(); } })
    }
    .width('100%').height(76).clip(true).borderRadius(12)
    .margin({ left: 16, right: 16, top: 4, bottom: 4 })
  }
}
