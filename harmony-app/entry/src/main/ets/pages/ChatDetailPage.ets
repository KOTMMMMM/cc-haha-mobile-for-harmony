import router from '@ohos.router';
import { ChatPage } from './ChatPage';
import { ChatRouteParams } from '../models/ChatRoute';
import { SessionService } from '../services/SessionService';
import { AuthService } from '../services/AuthService';
import { ThemeColors } from '../utils/ThemeUtil';

@Entry
@Component
struct ChatDetailPage {
  @StorageLink('theme') theme: string = 'light';
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('authService') authService: AuthService = new AuthService();
  // 标题跟随 Storage：ChatPage 收到 session_title_updated 后会更新它
  @StorageLink('activeSessionTitle') title: string = '对话';
  @State sessionId: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as ChatRouteParams;
    if (params && params.sessionId) {
      this.sessionId = params.sessionId;
      if (params.title && params.title.length > 0) {
        AppStorage.setOrCreate('activeSessionTitle', params.title);
      }
      // 必须在子组件 ChatPage 创建前写入，ChatPage 依赖它决定连接哪个会话
      this.sessionService.setCurrentSessionId(this.sessionId);
      this.authService.setCurrentSessionId(this.sessionId);
      AppStorage.setOrCreate('activeSessionId', this.sessionId);
    }
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(30).fontColor(ThemeColors.textStrong(this.theme))
          .width(44).height('100%').textAlign(TextAlign.Center)
          .accessibilityLevel('yes').accessibilityText('返回').id('chat-back')
          .onClick(() => { router.back(); })

        Text(this.title)
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(ThemeColors.textStrong(this.theme))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).textAlign(TextAlign.Center)

        Text('↻')
          .fontSize(17).fontColor(ThemeColors.primary)
          .width(44).height('100%').textAlign(TextAlign.Center)
          .accessibilityLevel('yes').accessibilityText('刷新').id('chat-refresh')
          .onClick(() => { AppStorage.setOrCreate('chatRefresh', Date.now()); })
      }
      .width('100%').height(48)
      .backgroundColor(ThemeColors.card(this.theme))
      .border({ width: { bottom: 0.5 }, color: ThemeColors.border(this.theme) })
      .alignItems(VerticalAlign.Center)

      Column() {
        ChatPage()
      }
      .layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.chatBg(this.theme))
  }
}
