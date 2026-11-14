import { MessageModel, MessageRole, ContentType, TextContent } from '../models/Message';
import { ChatBubble } from './ChatBubble';

interface TurnInfo {
  startIndex: number;
  endIndex: number;
  stepCount: number;
  label: string;
  preview: string;
}

@Component
export struct MessageList {
  @Link @Watch('onMessagesChanged') messages: MessageModel[];
  @Prop isLoading: boolean = false;
  @StorageLink('theme') theme: string = 'light';
  onLoadMore: () => void = () => {};
  private scroller: Scroller = new Scroller();
  private lastMessageCount: number = 0;
  private lastFirstIndex: number = 0;
  private lastScrollY: number = 0;
  private lastLastMessageId: string = '';
  private lastLastMessageRevision: number = 0;
  private firstMessageId: string = '';
  private popupTimer: number = -1;
  private followTimer: number = -1;
  @State collapsedTurns: boolean[] = [];
  @State showBackToLatest: boolean = false;
  @State activeTurnIndex: number = 0;
  @State turnPopupVisible: boolean = false;
  @State turnPopupTitle: string = '';
  @State turnPopupPreview: string = '';
  // 轮次结构缓存：每次消息变化只重算一次，避免每条消息都全量 getTurns() 造成 O(n²)
  private turnsCache: TurnInfo[] = [];
  private turnIndexByMsg: number[] = [];
  private firstAssistantFlags: boolean[] = [];

  aboutToAppear(): void {
    this.lastMessageCount = this.messages.length;
    this.lastLastMessageId = this.messages.length > 0 ? this.messages[this.messages.length - 1].id : '';
    this.lastLastMessageRevision = this.messages.length > 0 ? this.messages[this.messages.length - 1].revision : 0;
    this.firstMessageId = this.messages.length > 0 ? this.messages[0].id : '';
    this.rebuildTurnCache();
  }

  onMessagesChanged(): void {
    const newLastId = this.messages.length > 0 ? this.messages[this.messages.length - 1].id : '';
    const newLastRev = this.messages.length > 0 ? this.messages[this.messages.length - 1].revision : 0;
    const newFirstId = this.messages.length > 0 ? this.messages[0].id : '';
    // 会话切换/前置加载会改变首条消息，重置轮次折叠状态
    if (newFirstId !== this.firstMessageId) { this.collapsedTurns = []; }
    this.firstMessageId = newFirstId;
    if (this.messages.length > this.lastMessageCount) {
      // 只有“末尾消息变化”才是追加新消息；加载更早分页时末尾不变，不能滚到底
      if (newLastId !== this.lastLastMessageId) {
        // 未确认到达底部前先显示“回到最新”，onReachEnd 会隐藏
        this.showBackToLatest = true;
        // 长列表布局耗时较长，分多次尝试滚到底
        const lastIndex = this.messages.length + 1;
        setTimeout(() => { this.scroller.scrollToIndex(lastIndex, false, ScrollAlign.END); }, 100);
        setTimeout(() => { this.scroller.scrollToIndex(lastIndex, false, ScrollAlign.END); }, 600);
        setTimeout(() => { this.scroller.scrollToIndex(lastIndex, false, ScrollAlign.END); }, 1500);
      }
    } else if (newLastRev !== this.lastLastMessageRevision && !this.showBackToLatest) {
      // 同一条消息内流式追加文字：用户没上翻时跟随到底部（节流，避免每个 delta 都触发滚动）
      this.scheduleFollowBottom();
    }
    this.lastMessageCount = this.messages.length;
    this.lastLastMessageId = newLastId;
    this.lastLastMessageRevision = newLastRev;
    this.rebuildTurnCache();
  }

  /** 一次遍历重建轮次缓存与每条消息的 O(1) 查询表 */
  private rebuildTurnCache(): void {
    const msgs = this.messages;
    const turns: TurnInfo[] = [];
    const idxMap: number[] = [];
    const flags: boolean[] = [];
    for (let i = 0; i < msgs.length; i++) {
      idxMap.push(-1);
      flags.push(false);
      if (msgs[i].role === MessageRole.USER) {
        turns.push({
          startIndex: i, endIndex: msgs.length, stepCount: 0,
          label: '', preview: this.firstText(msgs[i])
        });
      }
    }
    if (turns.length === 0 && msgs.length > 0) {
      turns.push({
        startIndex: 0, endIndex: msgs.length, stepCount: 0,
        label: '', preview: this.firstText(msgs[0])
      });
    }
    for (let i = 0; i < turns.length; i++) {
      const start = turns[i].startIndex;
      const end = i + 1 < turns.length ? turns[i + 1].startIndex : msgs.length;
      let steps = 0;
      let firstAssistant = -1;
      for (let j = start; j < end; j++) {
        idxMap[j] = i;
        if (firstAssistant < 0 && msgs[j].role === MessageRole.ASSISTANT) { firstAssistant = j; }
        for (const c of msgs[j].contents) {
          if (c.type === ContentType.THINKING || c.type === ContentType.TOOL_USE) { steps++; }
        }
      }
      turns[i].endIndex = end;
      turns[i].stepCount = steps;
      turns[i].label = '第 ' + (i + 1) + ' / ' + turns.length + ' 轮';
      if (firstAssistant >= 0) { flags[firstAssistant] = true; }
    }
    this.turnsCache = turns;
    this.turnIndexByMsg = idxMap;
    this.firstAssistantFlags = flags;
  }

  private scheduleFollowBottom(): void {
    if (this.followTimer !== -1) { return; }
    this.followTimer = setTimeout(() => {
      this.followTimer = -1;
      this.scroller.scrollToIndex(this.messages.length + 1, false, ScrollAlign.END);
    }, 120);
  }

  private firstText(msg: MessageModel): string {
    for (const c of msg.contents) {
      if (c.type === ContentType.TEXT) {
        const t = (c as TextContent).text;
        if (t && t.length > 0) {
          return t.length > 60 ? t.substring(0, 60) + '…' : t;
        }
      }
    }
    return '';
  }

  /** 轮次结构由 rebuildTurnCache() 维护，这里直接返回缓存 */
  private getTurns(): TurnInfo[] { return this.turnsCache; }

  private turnIndexForMessage(msgIndex: number): number {
    if (msgIndex < 0 || msgIndex >= this.turnIndexByMsg.length) { return -1; }
    return this.turnIndexByMsg[msgIndex];
  }

  private isTurnCollapsed(turnIndex: number): boolean {
    if (turnIndex < 0 || turnIndex >= this.collapsedTurns.length) { return true; }
    return this.collapsedTurns[turnIndex];
  }

  private messageHasText(msg: MessageModel): boolean {
    for (const c of msg.contents) {
      if (c.type === ContentType.TEXT && (c as TextContent).text.length > 0) { return true; }
    }
    return false;
  }

  /** 折叠状态下无需渲染的纯思考/工具消息：避免隐藏项仍占 padding/margin 形成大段空白 */
  private isHiddenProcessOnly(msg: MessageModel, index: number): boolean {
    if (msg.role !== MessageRole.ASSISTANT) { return false; }
    if (!this.isTurnCollapsed(this.turnIndexForMessage(index))) { return false; }
    return !this.messageHasText(msg);
  }

  private isFirstAssistantOfTurn(msgIndex: number): boolean {
    if (msgIndex < 0 || msgIndex >= this.messages.length) { return false; }
    if (this.messages[msgIndex].role !== MessageRole.ASSISTANT) { return false; }
    return msgIndex < this.firstAssistantFlags.length && this.firstAssistantFlags[msgIndex];
  }

  private turnStepCountForMessage(msgIndex: number): number {
    const turnIndex = this.turnIndexForMessage(msgIndex);
    if (turnIndex < 0 || turnIndex >= this.turnsCache.length) { return 0; }
    return this.turnsCache[turnIndex].stepCount;
  }

  private toggleTurn(turnIndex: number): void {
    if (turnIndex < 0) { return; }
    const turns = this.getTurns();
    let arr = this.collapsedTurns.slice();
    while (arr.length < turns.length) { arr.push(true); }
    arr[turnIndex] = !arr[turnIndex];
    this.collapsedTurns = arr;
  }

  private jumpToTurn(index: number): void {
    const turns = this.getTurns();
    if (index < 0 || index >= turns.length) { return; }
    const turn = turns[index];
    this.activeTurnIndex = index;
    // List 的 index 0 是顶部加载项，消息从 1 开始
    this.scroller.scrollToIndex(turn.startIndex + 1, true, ScrollAlign.START);
    this.turnPopupTitle = turn.label;
    this.turnPopupPreview = turn.preview;
    this.turnPopupVisible = true;
    if (this.popupTimer !== -1) { clearTimeout(this.popupTimer); }
    this.popupTimer = setTimeout(() => { this.turnPopupVisible = false; }, 2500);
  }

  private jumpToLatest(): void {
    this.scroller.scrollEdge(Edge.Bottom);
    this.showBackToLatest = false;
  }

  private markerColor(i: number): string {
    if (i === this.activeTurnIndex) { return '#1677FF'; }
    return this.theme === 'dark' ? '#555555' : '#D0D0D0';
  }

  build() {
    Column() {
      if (this.messages.length === 0) {
        Column() {
          if (this.isLoading) {
            LoadingProgress().width(36).height(36).color('#1677FF')
            Text('正在加载会话…').fontSize(14).fontColor('#999').margin({ top: 12 })
          } else {
            Text('开始对话').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#333').margin({ bottom: 8 })
            Text('向您的 AI 编程助手发送消息').fontSize(14).fontColor('#999')
          }
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Stack() {
          Row() {
            // 左侧轮次导航（与列表并排，避免拦截列表滚动）
            Scroll() {
              Column() {
                ForEach(this.getTurns(), (turn: TurnInfo, i: number) => {
                  Row() {
                    Divider()
                      .width(i === this.activeTurnIndex ? 15 : 9)
                      .height(i === this.activeTurnIndex ? 3 : 2)
                      .color(this.markerColor(i))
                  }
                  .width(24).height(14)
                  .justifyContent(FlexAlign.Center)
                  .onClick(() => { this.jumpToTurn(i); })
                }, (turn: TurnInfo, i: number): string => 'turn_' + i)
              }
              .width(24).padding({ top: 10, bottom: 10 })
            }
            .width(24).height('100%').scrollBar(BarState.Off)

            // 消息列表 + 回到最新按钮
            Stack({ alignContent: Alignment.BottomEnd }) {
              List({ scroller: this.scroller }) {
                ListItem() {
                  if (this.isLoading) {
                    Row() {
                      LoadingProgress().width(20).height(20).color('#999')
                      Text('加载更多...').fontSize(12).fontColor('#999').margin({ left: 8 })
                    }
                    .width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 8 })
                  }
                }

                ForEach(this.messages, (msg: MessageModel, index: number) => {
                  if (this.isHiddenProcessOnly(msg, index) && !this.isFirstAssistantOfTurn(index)) {
                    // 折叠状态下纯思考/工具消息不渲染内容，但保留 ListItem 以维持索引与轮次定位
                    ListItem() {}
                  } else {
                    ListItem() {
                      ChatBubble({
                        message: msg,
                        isLast: index === this.messages.length - 1,
                        hideProcess: msg.role === MessageRole.ASSISTANT && this.isTurnCollapsed(this.turnIndexForMessage(index)),
                        showTurnHeader: this.isFirstAssistantOfTurn(index),
                        turnStepCount: this.turnStepCountForMessage(index),
                        turnCollapsed: this.isTurnCollapsed(this.turnIndexForMessage(index)),
                        onToggleTurn: (): void => { this.toggleTurn(this.turnIndexForMessage(index)); }
                      })
                    }
                    .margin({ top: index === 0 ? 8 : 4 })
                  }
                }, (msg: MessageModel): string => msg.id + '#' + msg.revision)

                ListItem() { Divider().height(16).color(Color.Transparent) }
              }
              .width('100%').height('100%')
              .scrollBar(BarState.Off)
              .onScroll((scrollOffset: number, scrollState: ScrollState) => {
                const y = this.scroller.currentOffset().yOffset;
                if (y < this.lastScrollY - 0.2) { this.showBackToLatest = true; }
                this.lastScrollY = y;
                if (scrollState === ScrollState.Idle && !this.isLoading && y < 100) {
                  this.onLoadMore();
                }
              })
              .onReachEnd(() => { this.showBackToLatest = false; })
              .onScrollIndex((start: number, end: number) => {
                // 首个可见项索引变小 = 往历史方向翻，显示“回到最新”
                if (start < this.lastFirstIndex) { this.showBackToLatest = true; }
                this.lastFirstIndex = start;
                const mi = start - 1;
                if (mi < 0) { return; }
                const turns = this.getTurns();
                for (let i = turns.length - 1; i >= 0; i--) {
                  if (turns[i].startIndex <= mi) { this.activeTurnIndex = i; break; }
                }
              })

              if (this.showBackToLatest) {
                Row() {
                  Text('↓').fontSize(14).fontColor('#1677FF').margin({ right: 4 })
                  Text('回到最新').fontSize(13).fontColor('#1677FF')
                }
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor(this.theme === 'dark' ? '#2A2A2A' : '#FFFFFF')
                .borderRadius(18)
                .shadow({ radius: 8, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 2 })
                .margin({ right: 16, bottom: 12 })
                .onClick(() => { this.jumpToLatest(); })
              }
            }
            .layoutWeight(1).height('100%')
          }
          .width('100%').height('100%')

          // 轮次提示浮层
          if (this.turnPopupVisible) {
            Column() {
              Text(this.turnPopupTitle)
                .fontSize(12).fontWeight(FontWeight.Medium)
                .fontColor(this.theme === 'dark' ? '#DDD' : '#333')
              if (this.turnPopupPreview.length > 0) {
                Text(this.turnPopupPreview)
                  .fontSize(12).fontColor('#666').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
              }
            }
            .width(220).padding(12)
            .backgroundColor(this.theme === 'dark' ? '#2A2A2A' : '#FFFFFF')
            .borderRadius(10)
            .shadow({ radius: 8, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 2 })
            .position({ x: 28, y: 96 })
          }
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').layoutWeight(1)
  }
}
