import { MessageModel, MessageRole, ContentType, TextContent, ToolUseContent, DeliveryState } from '../models/Message';
import { MessageList } from '../components/MessageList';
import { InputBar } from '../components/InputBar';
import { ComposerToolbar } from '../components/ComposerToolbar';
import { ToolPermissionDialog, PermissionRequest } from '../components/PermissionDialog';
import { WebSocketService, WsEvent, WsEventHandler } from '../services/WebSocketService';
import { ApiService, MessagesPage } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { HistoryStore } from '../services/HistoryStore';
import { AuthService } from '../services/AuthService';
import { NotificationService } from '../services/NotificationService';
import { BackgroundTaskService } from '../services/BackgroundTaskService';
import { BackgroundTurnWatcher } from '../services/BackgroundTurnWatcher';
import { SessionActivityMonitor } from '../services/SessionActivityMonitor';
import { AttachmentItem } from '../models/Attachment';
import {
  contentToText, mergeMessages, parseServerMessages, lastAssistantSnippet, userDisplayText
} from '../services/chat/ChatHistoryUtils';
import {
  eventConfirmsDelivery, normalizeLoadedDelivery, resolvePendingDelivery
} from '../services/chat/SendReliability';
import { promptAction } from '@kit.ArkUI';
import router from '@ohos.router';
import { Logger } from '../utils/Logger';
import { ThemeColors } from '../utils/ThemeUtil';

interface WsAttachment { type: string; name: string; data: string; mimeType: string; }
interface WsUserMessage { type: string; content: string; attachments?: WsAttachment[]; }
interface WsPermissionResponse { type: string; requestId: string; allowed: boolean; remember?: boolean; }
interface WsStopMessage { type: string; }
interface QueuedSend { localId: string; text: string; attachments: AttachmentItem[]; }

@Component
export struct ChatPage {
  @StorageLink('theme') theme: string = 'light';
  @StorageLink('wsService') wsService: WebSocketService = new WebSocketService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('historyStore') historyStore: HistoryStore = new HistoryStore();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('notificationService') notificationService: NotificationService = new NotificationService();
  @StorageLink('backgroundTaskService') bgTaskService: BackgroundTaskService = new BackgroundTaskService();
  @StorageLink('sessionActivityMonitor') activityMonitor: SessionActivityMonitor = new SessionActivityMonitor();
  @StorageLink('appForeground') @Watch('onAppForegroundChanged') appForeground: boolean = true;
  @StorageLink('activeSessionId') @Watch('onActiveSessionChanged') activeSessionId: string = '';
  @StorageLink('chatRefresh') @Watch('onRefreshChanged') chatRefresh: number = 0;
  @StorageLink('invalidSessionId') @Watch('onInvalidSessionChanged') invalidSessionId: string = '';
  @State messages: MessageModel[] = [];
  @State isLoadingHistory: boolean = false;
  @State isLoadingMore: boolean = false;
  @State @Watch('onGeneratingChanged') isGenerating: boolean = false;
  @State hasMoreHistory: boolean = false;
  @State queuedCount: number = 0;
  private oldestCursor: string = '';
  private historyHasMore: boolean = false;
  private permissionDialogController: CustomDialogController | null = null;
  private pendingPermissionRequest: PermissionRequest | null = null;
  private permissionDialogVisible: boolean = false;
  private permissionTimer: number = -1;
  private readonly PERMISSION_TIMEOUT_MS: number = 60000;
  private currentTurnAssistantId: string = '';
  private pendingResync: boolean = false;
  private turnNotified: boolean = false;
  private pageActive: boolean = true;
  // 发送可靠性：待确认的本地消息、原文载荷（供重试）与本地排队队列
  private activeSendId: string = '';
  private pendingPayloads: Map<string, WsUserMessage> = new Map();
  private queuedSends: QueuedSend[] = [];
  private pumpTimer: number = -1;
  // 每个页面实例独立的处理器 owner：切换会话/重建页面时只清自己的监听
  private readonly wsOwner: string = 'chat-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8);
  private sendAt: number = 0;
  private firstEventLogged: boolean = false;
  private lastHistoryErrorAt: number = 0;
  // 每次进入/切换会话递增，迟到的本地读取或网络结果直接丢弃
  private historyToken: number = 0;
  // 流式 delta 合并刷新，避免每个 token 都复制数组并重绘整棵列表
  private syncTimer: number = -1;
  private syncPending: boolean = false;
  private readonly SYNC_THROTTLE_MS: number = 50;
  // 兜底对账：公网 WS 推送偶尔停更，每隔 5 秒静默拉一次最新页
  private lagPollTimer: number = -1;
  private lagPollBusy: boolean = false;
  private readonly LAG_POLL_MS: number = 5000;

  aboutToAppear(): void {
    this.pageActive = true;
    // 每个聊天页都是新实例：先清空上一个会话残留在全局里的消息，
    // 保证进入会话的首帧不会闪出之前的内容
    this.messages = [];
    this.sessionService.setMessages([]);
    this.setupWebSocketHandlers();
    // 断线自动恢复后补拉历史，避免错过断线期间的消息。
    // 生成中先记下待补拉，等本轮结束再拉；空闲时按页向前补到与本地重叠为止。
    this.wsService.setReconnectListener((sid: string): void => {
      if (!this.pageActive) { return; }
      if (!sid || sid !== this.activeSessionId) { return; }
      Logger.info('WS auto-reconnected, resync history');
      if (this.isGenerating) {
        this.pendingResync = true;
      } else {
        this.fetchLatestHistory(sid, true);
      }
    });
    const initialSessionId = this.activeSessionId;
    if (!initialSessionId) {
      this.activeSessionId = this.sessionService.getCurrentSessionId();
    }
    const sid = initialSessionId || this.activeSessionId;
    if (sid) {
      this.historyToken++;
      this.showLocalHistory(sid, this.historyToken);
      this.connectActiveSession();
    }
    this.startLagPoll();
  }

  private startLagPoll(): void {
    if (this.lagPollTimer !== -1) { return; }
    this.lagPollTimer = setInterval((): void => {
      this.pollLatestIfNeeded();
    }, this.LAG_POLL_MS);
  }

  /** 5 秒兜底：WS 推送停更时仍能对账到最新消息；避免与翻页/首屏加载并发。 */
  private async pollLatestIfNeeded(): Promise<void> {
    if (!this.pageActive || !this.appForeground || !this.activeSessionId) { return; }
    if (this.lagPollBusy || this.isLoadingHistory || this.isLoadingMore) { return; }
    this.lagPollBusy = true;
    try {
      await this.fetchLatestHistory(this.activeSessionId, false);
    } finally {
      this.lagPollBusy = false;
    }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.lagPollTimer !== -1) { clearInterval(this.lagPollTimer); this.lagPollTimer = -1; }
    if (this.pumpTimer !== -1) { clearTimeout(this.pumpTimer); this.pumpTimer = -1; }
    // 排队消息还没发出：退回输入框，避免离开后继续发送
    this.restoreQueuedToComposer('');
    this.cancelScheduledSync();
    // 离开页面时结束未决权限请求，避免服务端一直等待
    this.clearPermissionTimer();
    this.permissionDialogVisible = false;
    if (this.pendingPermissionRequest) {
      const requestId = this.pendingPermissionRequest.toolCallId;
      if (this.permissionDialogController) { this.permissionDialogController.close(); }
      this.sendPermissionDecision(requestId, false, false);
    }
    // 生成中退出时把会话交给后台 watcher，随后释放主 WS；
    // 非生成中直接移除本页面的处理器，避免旧页面继续改 UI。
    if (this.isGenerating) {
      this.handoffToBackgroundWatcher();
    } else {
      this.wsService.clearHandlers(this.wsOwner);
    }
    // 返回列表时立即刷新，避免标题/消息数/时间停留在旧值
    AppStorage.setOrCreate('sessionsRefresh', Date.now());
  }

  onActiveSessionChanged(): void {
    Logger.info('ChatPage active session changed: ' + this.activeSessionId);
    this.cancelScheduledSync();
    this.currentTurnAssistantId = '';
    this.isGenerating = false;
    this.pendingResync = false;
    this.restoreQueuedToComposer('排队消息已退回');
    this.activeSendId = '';
    this.pendingPayloads.clear();
    // 切会话先清空，避免旧消息在新历史加载完成前留在屏幕上
    this.messages = [];
    this.sessionService.setMessages([]);
    this.oldestCursor = '';
    this.historyHasMore = false;
    this.hasMoreHistory = false;
    this.historyToken++;
    if (this.activeSessionId) {
      this.showLocalHistory(this.activeSessionId, this.historyToken);
      for (const s of this.sessionService.getSessions()) {
        if (s.id === this.activeSessionId) {
          AppStorage.setOrCreate('activeSessionTitle', s.getDisplayTitle());
          break;
        }
      }
    }
    this.connectActiveSession();
  }

  onRefreshChanged(): void {
    this.refreshChat();
  }

  /** 服务端确认会话已不存在：清空当前会话并返回列表，避免继续轮询报错。 */
  private onInvalidSessionChanged(): void {
    const sid = this.invalidSessionId;
    if (!sid) { return; }
    AppStorage.setOrCreate('invalidSessionId', '');
    this.invalidSessionId = '';
    if (sid !== this.activeSessionId) { return; }
    const watcher: BackgroundTurnWatcher | null = this.getBgWatcher();
    if (watcher) { watcher.stop(sid); }
    this.cancelScheduledSync();
    this.clearPermissionTimer();
    this.pendingPermissionRequest = null;
    this.permissionDialogVisible = false;
    if (this.permissionDialogController) { this.permissionDialogController.close(); }
    this.isGenerating = false;
    this.queuedSends = [];
    this.queuedCount = 0;
    this.activeSendId = '';
    this.pendingPayloads.clear();
    this.wsService.disconnect();
    this.wsService.clearHandlers(this.wsOwner);
    this.sessionService.setCurrentSessionId('');
    this.authService.setCurrentSessionId('');
    AppStorage.setOrCreate('activeSessionId', '');
    AppStorage.setOrCreate('activeSessionTitle', '');
    AppStorage.setOrCreate('sessionsRefresh', Date.now());
    if (this.pageActive) {
      promptAction.showToast({ message: '会话已不存在，已返回列表', duration: 2200 });
      router.back();
    }
  }

  private onGeneratingChanged(): void {
    AppStorage.setOrCreate('chatGenerating', this.isGenerating);
  }

  /** 记录“发送 → 服务端首个事件”的耗时，用于区分上行/服务端/模型延迟 */
  private logFirstEvent(tag: string): void {
    if (this.firstEventLogged || this.sendAt <= 0) { return; }
    this.firstEventLogged = true;
    Logger.warn('[CC] first server event ' + tag + ' after ' + (Date.now() - this.sendAt) + 'ms');
  }

  private refreshChat(): void {
    this.currentTurnAssistantId = '';
    this.isGenerating = false;
    this.connectActiveSession();
  }

  private async connectActiveSession(): Promise<void> {
    const sid = this.activeSessionId;
    const token = this.historyToken;
    // 重新进入同一会话时取消后台 watcher，避免重复通知
    const watcher: BackgroundTurnWatcher | null = this.getBgWatcher();
    if (watcher && sid) { watcher.stop(sid); }
    if (!sid) {
      this.cancelScheduledSync();
      this.wsService.disconnect();
      this.sessionService.setMessages([]);
      this.syncMessages();
      this.isLoadingHistory = false;
      return;
    }
    // 从进入页面到地址探测完成之间也显示加载态，
    // 避免这段时间里空列表被误显示成「开始对话」
    this.isLoadingHistory = true;
    const config = await this.authService.getConnectionConfig();
    if (!config || !this.pageActive || token !== this.historyToken) {
      if (this.pageActive && token === this.historyToken) { this.isLoadingHistory = false; }
      return;
    }
    // 与列表页共用同一套地址选择（含 60s 探测缓存），避免行为分叉
    const reachable: boolean = await this.apiService.ensureConnection(config);
    if (!this.pageActive || token !== this.historyToken) { return; }
    if (!reachable) {
      // 所有地址都不可达：明确提示并停止，避免 HarmonyOS 建立“假连接”显示已连接却收不到数据
      this.wsService.disconnect();
      this.isGenerating = false;
      this.isLoadingHistory = false;
      AppStorage.setOrCreate('pcReachable', false);
      if (this.appForeground) {
        promptAction.showToast({ message: '无法连接电脑，请检查局域网或 Tailscale', duration: 2500 });
      }
      return;
    }
    const chosenHost: string = this.apiService.getCurrentHost();
    const scheme: string = config.scheme === 'https' ? 'https' : 'http';
    const origin = scheme + '://' + chosenHost + (scheme === 'https' ? '' : (':' + config.port));
    AppStorage.setOrCreate('pcActiveHost', chosenHost);
    AppStorage.setOrCreate('pcReachable', true);
    this.sessionService.setCurrentSessionId(sid);
    this.wsService.disconnect();
    this.wsService.clearHandlers(this.wsOwner);
    this.setupWebSocketHandlers();
    this.wsService.connect(chosenHost, config.port, config.token, sid, origin).catch((e: Error) => {
      // WS 失败可能意味着切网/地址失效，让下次重连前重新探测
      this.apiService.invalidateResolution();
      Logger.error('WS connect failed: ' + e.message);
    });
    // 本地缓存已经先显示了，这里只拉最新一页做增量合并
    this.fetchLatestHistory(sid);
  }

  /** 使用页面实例的 owner 注册，避免误清其他页面/后台监听 */
  private onWs(event: string, cb: WsEventHandler): void {
    this.wsService.on(event, cb, this.wsOwner);
  }

  private getBgWatcher(): BackgroundTurnWatcher | null {
    return AppStorage.get<BackgroundTurnWatcher>('backgroundTurnWatcher') ?? null;
  }

  /** 离开生成中的会话：watcher 用独立 WS 等待完成，避免切换会话后通知丢失。 */
  private handoffToBackgroundWatcher(): void {
    const sid: string = this.activeSessionId;
    const watcher: BackgroundTurnWatcher | null = this.getBgWatcher();
    if (!sid || !watcher) {
      this.wsService.clearHandlers(this.wsOwner);
      return;
    }
    const title: string = AppStorage.get<string>('activeSessionTitle') ?? '';
    this.authService.getConnectionConfig().then((config) => {
      if (this.pageActive) { return; }
      if (!config) {
        this.wsService.clearHandlers(this.wsOwner);
        return;
      }
      const host: string = this.apiService.getCurrentHost() || config.host;
      watcher.start(sid, title, host, config.port, config.token);
      // 只在主 WS 仍指向该会话时断开，避免误伤刚打开的新聊天页
      if (this.wsService.getSessionId() === sid) {
        this.wsService.disconnect();
      }
      this.wsService.clearHandlers(this.wsOwner);
    }).catch((error: Error) => {
      Logger.warn('handoff watcher failed: ' + error.message);
      this.wsService.clearHandlers(this.wsOwner);
    });
  }

  private setupWebSocketHandlers(): void {
    if (!this.wsService) { return; }
    // 页面可能被重建/多次进入，先清空本页面的旧处理器，避免同一个 delta 被追加多次
    this.wsService.clearHandlers(this.wsOwner);

    this.onWs('session_state', (event: WsEvent) => {
      const turnState = event.turnState as string;
      const wasGenerating = this.isGenerating;
      this.isGenerating = turnState === 'running';
      if (turnState === 'running') {
        this.turnNotified = false;
        this.activityMonitor.markRunning(this.activeSessionId);
        this.logFirstEvent('session_state');
      } else {
        this.activityMonitor.markIdle(this.activeSessionId);
        if (wasGenerating) {
          // 断线期间本轮已结束：sync_state 只回 session_state、不会补发 status idle，
          // 必须在这里收尾并触发历史对账，否则 pendingResync 会一直挂着。
          this.finalizeTurn();
        }
      }
    });

    this.onWs('status', (event: WsEvent) => {
      const state = event.state as string;
      this.isGenerating = state !== 'idle';
      if (state === 'idle') { this.finalizeTurn(); }
      else {
        this.activityMonitor.markRunning(this.activeSessionId);
        this.logFirstEvent('status');
      }
    });

    this.onWs('content_start', (event: WsEvent) => {
      const blockType = event.blockType as string;
      this.logFirstEvent('content_start');
      const msg = this.ensureAssistantMessage();
      msg.isStreaming = true;
      if (blockType === 'tool_use') {
        const toolUseId = (event.toolUseId as string) ?? '';
        const toolName = (event.toolName as string) ?? '';
        this.addOrUpdateTool(msg, toolUseId, toolName);
      }
      this.syncMessages();
    });

    this.onWs('content_delta', (event: WsEvent) => {
      const text = event.text as string;
      if (text) {
        this.logFirstEvent('content_delta');
        const msg = this.ensureAssistantMessage();
        msg.appendText(text);
        this.scheduleSync();
      }
      // toolInput 片段忽略，tool_use_complete 会带完整 input
    });

    this.onWs('tool_use_complete', (event: WsEvent) => {
      const msg = this.ensureAssistantMessage();
      const toolUseId = (event.toolUseId as string) ?? '';
      const toolName = (event.toolName as string) ?? '';
      const input = (event.input as Record<string, Object>) ?? (new Object() as Record<string, Object>);
      this.addOrUpdateTool(msg, toolUseId, toolName, input);
      this.syncMessages();
    });

    this.onWs('tool_result', (event: WsEvent) => {
      const toolUseId = (event.toolUseId as string) ?? '';
      const output = contentToText(event.content);
      const isError = (event.isError as boolean) ?? false;
      for (const m of this.sessionService.getMessages()) {
        m.updateToolResult(toolUseId, output, isError);
      }
      this.syncMessages();
    });

    this.onWs('thinking', (event: WsEvent) => {
      const text = event.text as string;
      if (text) {
        this.logFirstEvent('thinking');
        const msg = this.ensureAssistantMessage();
        msg.appendThinking(text);
        this.scheduleSync();
      }
    });

    this.onWs('permission_request', (event: WsEvent) => {
      const requestId = (event.requestId as string) ?? '';
      // 页面已离开时不再弹窗，直接拒绝避免服务端挂起
      if (!this.pageActive) {
        this.sendPermissionDecision(requestId, false, false);
        return;
      }
      this.pendingPermissionRequest = {
        toolCallId: requestId,
        toolName: (event.toolName as string) ?? ((event.displayName as string) ?? ''),
        toolInput: (event.input as object) ?? (new Object() as object),
        description: (event.description as string) ?? ''
      };
      this.showPermissionDialog();
    });

    this.onWs('message_complete', (event: WsEvent) => {
      const usage = event.usage as Record<string, Object>;
      const last = this.getCurrentAssistant();
      if (last) {
        if (usage) {
          last.finalizeMessage({
            inputTokens: (usage.input_tokens as number) ?? 0,
            outputTokens: (usage.output_tokens as number) ?? 0
          });
        } else {
          last.finalizeMessage();
        }
      }
      this.isGenerating = false;
      this.currentTurnAssistantId = '';
      this.flushSync();
      this.persistCurrent();
      this.activityMonitor.markIdle(this.activeSessionId);
      this.maybeNotifyTurnComplete();
      this.runPendingResync();
      this.pumpQueueSoon();
    });

    this.onWs('error', (event: WsEvent) => {
      this.isGenerating = false;
      this.activityMonitor.markIdle(this.activeSessionId);
      // 发送后立即报错：把待确认消息标成失败（不自动重发，等用户点按）
      if (this.activeSendId) {
        const failedId = this.activeSendId;
        this.activeSendId = '';
        const pending = this.sessionService.getMessageById(failedId);
        if (pending) { pending.setDelivery(DeliveryState.FAILED); }
      }
      const msg = new MessageModel(MessageRole.SYSTEM);
      msg.appendText((event.message as string) ?? '发生错误，请重试');
      this.sessionService.addMessage(msg);
      this.syncMessages();
      this.persistCurrent();
    });

    this.onWs('system_notification', (event: WsEvent) => {
      const subtype = event.subtype as string;
      if (subtype === 'session_state_changed') {
        const data = event.data as Record<string, Object>;
        const state = (data && data['state'] as string) ?? '';
        this.isGenerating = state === 'running';
        if (state === 'idle') { this.finalizeTurn(); }
      }
    });

    this.onWs('session_title_updated', (event: WsEvent) => {
      const title = event.title as string;
      const sid = event.sessionId as string;
      if (title && sid) {
        this.sessionService.updateSessionTitle(sid, title);
        if (sid === this.activeSessionId) {
          AppStorage.setOrCreate('activeSessionTitle', title);
        }
        // 列表页也使用服务端标题，通知它重新拉取
        AppStorage.setOrCreate('sessionsRefresh', Date.now());
      }
    });

    // 服务端没有 user_message ACK：本轮任一事件到达即视为该条已被接受
    this.onWs('*', (event: WsEvent) => {
      if (!this.activeSendId) { return; }
      const type = event.type as string;
      if (eventConfirmsDelivery(type, event)) {
        this.logFirstEvent(type);
        this.confirmActiveSend();
      }
    });
  }

  private finalizeTurn(): void {
    const last = this.getCurrentAssistant();
    if (last && last.isStreaming) { last.finalizeMessage(); }
    this.currentTurnAssistantId = '';
    this.flushSync();
    this.persistCurrent();
    this.activityMonitor.markIdle(this.activeSessionId);
    // 一轮结束后刷新列表的消息数/时间
    AppStorage.setOrCreate('sessionsRefresh', Date.now());
    this.maybeNotifyTurnComplete();
    this.runPendingResync();
    // 有排队消息时，本轮结束后自动发送下一条
    this.pumpQueueSoon();
  }

  /** 回复完成且 App 在后台时发通知（手表通过系统通知镜像接收） */
  private async maybeNotifyTurnComplete(): Promise<void> {
    if (this.turnNotified) { return; }
    this.turnNotified = true;
    try {
      if (!this.appForeground && (await this.authService.getNotifyOnComplete())) {
        const title = this.currentSessionTitle() + ' · 回复完成';
        const body = lastAssistantSnippet(this.sessionService.getMessages());
        await this.notificationService.notifyTurnComplete(title, body);
      }
    } catch (e) {
      Logger.warn('notify turn complete failed');
    } finally {
      this.bgTaskService.stop();
    }
  }

  private currentSessionTitle(): string {
    const target = this.sessionService.getCurrentSessionId();
    for (const s of this.sessionService.getSessions()) {
      if (s.id === target) {
        const t = s.getDisplayTitle();
        if (t && t.length > 0) { return t; }
      }
    }
    return 'cc-haha';
  }

  /** 断线发生在生成过程中：等这一轮结束后再补拉历史，避免把实时消息对象替换掉 */
  private runPendingResync(): void {
    if (!this.pendingResync) { return; }
    this.pendingResync = false;
    if (this.activeSessionId) { this.fetchLatestHistory(this.activeSessionId, true); }
  }

  private ensureAssistantMessage(): MessageModel {
    if (this.currentTurnAssistantId) {
      const m = this.sessionService.getMessageById(this.currentTurnAssistantId);
      if (m) { return m; }
    }
    const m = this.sessionService.createAssistantMessage();
    this.currentTurnAssistantId = m.id;
    return m;
  }

  private getCurrentAssistant(): MessageModel | null {
    if (this.currentTurnAssistantId) {
      const m = this.sessionService.getMessageById(this.currentTurnAssistantId);
      if (m) { return m; }
    }
    return this.sessionService.getLastAssistantMessage();
  }

  private addOrUpdateTool(msg: MessageModel, toolId: string, toolName: string,
                          input?: Record<string, Object>): void {
    for (const c of msg.contents) {
      if (c.type === ContentType.TOOL_USE && (c as ToolUseContent).toolId === toolId) {
        (c as ToolUseContent).toolName = toolName;
        if (input) { (c as ToolUseContent).toolInput = input; }
        return;
      }
    }
    const block = msg.addToolUse(toolId, toolName, input ?? (new Object() as Record<string, Object>));
    block.status = 'running';
  }

  private syncMessages(): void {
    if (!this.pageActive) { return; }
    this.messages = [...this.sessionService.getMessages()];
  }

  /** 流式 delta 高频到达：合并到 50ms 一次，避免每个 token 都复制数组并重绘列表 */
  private scheduleSync(): void {
    if (!this.pageActive) { return; }
    if (this.syncTimer !== -1) { this.syncPending = true; return; }
    this.syncMessages();
    this.syncTimer = setTimeout(() => {
      this.syncTimer = -1;
      if (this.syncPending) {
        this.syncPending = false;
        this.scheduleSync();
      }
    }, this.SYNC_THROTTLE_MS);
  }

  /** 结构性变化（完成/切换会话/离开页面）前立即落地，避免节流窗口内丢更新 */
  private flushSync(): void {
    if (this.syncTimer !== -1) { clearTimeout(this.syncTimer); this.syncTimer = -1; }
    this.syncPending = false;
    this.syncMessages();
  }

  private cancelScheduledSync(): void {
    if (this.syncTimer !== -1) { clearTimeout(this.syncTimer); this.syncTimer = -1; }
    this.syncPending = false;
  }

  /** 本地缓存优先：读取后立刻上屏，不等待网络 */
  private async showLocalHistory(sessionId: string, token: number): Promise<void> {
    if (!sessionId) { return; }
    const t0 = Date.now();
    try {
      const local = await this.historyStore.loadMessages(sessionId);
      if (!this.pageActive || token !== this.historyToken) { return; }
      if (local.length === 0 || this.messages.length > 0) { return; }
      local.sort((a: MessageModel, b: MessageModel): number => a.timestamp - b.timestamp);
      // queued 是不可能已发出的本地状态（进程被杀/页面销毁后残留）：降级为失败，交给用户重试
      normalizeLoadedDelivery(local);
      this.sessionService.setMessages(local);
      this.syncMessages();
      this.isLoadingHistory = false;
      Logger.info('local history ready: ' + local.length + ' msgs in ' + (Date.now() - t0) + 'ms');
    } catch (err) {
      Logger.warn('showLocalHistory failed: ' + (err as Error).message);
    }
  }

  private hasServerIdOverlap(remote: MessageModel[]): boolean {
    const localIds = new Set<string>();
    for (const m of this.sessionService.getMessages()) {
      if (m.serverId) { localIds.add(m.serverId); }
    }
    if (localIds.size === 0) { return false; }
    for (const m of remote) {
      if (m.serverId && localIds.has(m.serverId)) { return true; }
    }
    return false;
  }

  /** 用远端历史对账本地 sending 消息；sent 后清掉待确认状态，failed 保留载荷供重试 */
  private reconcileDeliveries(remote: MessageModel[], isGenerating: boolean): void {
    const local = this.sessionService.getMessages();
    const resolutions = resolvePendingDelivery(local, remote, isGenerating);
    if (resolutions.length === 0) { return; }
    for (const r of resolutions) {
      const m = this.sessionService.getMessageById(r.id);
      if (!m) { continue; }
      if (r.state === DeliveryState.SENT) {
        m.setDelivery(DeliveryState.SENT);
        this.pendingPayloads.delete(r.id);
        if (this.activeSendId === r.id) { this.activeSendId = ''; }
      } else if (r.state === DeliveryState.FAILED) {
        m.setDelivery(DeliveryState.FAILED);
        if (this.activeSendId === r.id) {
          this.activeSendId = '';
          this.isGenerating = false;
        }
      }
    }
  }

  /**
   * 和本地缓存增量合并。
   * deep=true（断线重连）时向前补拉最多 4 页，直到与本地缓存出现 serverId 重叠，
   * 避免断线期间超过一页的消息永久缺失。更早的分页仍由滚动到顶部按需加载。
   */
  private async fetchLatestHistory(sessionId: string, deep: boolean = false): Promise<void> {
    if (!sessionId) { return; }
    const token = this.historyToken;
    const t0 = Date.now();
    this.sessionService.setCurrentSessionId(sessionId);
    try {
      let page: MessagesPage = await this.apiService.getMessagesPage(sessionId);
      let remote: MessageModel[] = page.messages.length > 0 ? parseServerMessages(page.messages) : [];
      let cursor: string = page.nextCursor;
      let hasMore: boolean = page.hasMore && cursor.length > 0;
      let pagesFetched = 1;
      while (deep && pagesFetched < 4 && hasMore && !this.hasServerIdOverlap(remote)) {
        page = await this.apiService.getMessagesPage(sessionId, cursor);
        const older = page.messages.length > 0 ? parseServerMessages(page.messages) : [];
        remote = older.concat(remote);
        cursor = page.nextCursor;
        hasMore = page.hasMore && cursor.length > 0;
        pagesFetched++;
      }
      if (!this.pageActive || token !== this.historyToken) { return; }
      // 先对账再 merge：本地乐观消息被远端同文消息替换后，仍能正确清掉 sending/failed
      this.reconcileDeliveries(remote, this.isGenerating);
      const before = this.sessionService.getMessages();
      const merged = remote.length > 0 ? mergeMessages(before, remote) : before;
      this.sessionService.setMessages(merged);
      this.syncMessages();
      // 已经向上翻过页时保留原来的游标，避免重连把翻页位置重置到最新
      if (!this.oldestCursor) {
        this.oldestCursor = cursor;
        this.historyHasMore = hasMore;
        this.hasMoreHistory = this.historyHasMore;
      }
      if (remote.length > 0 && merged.length !== before.length) {
        this.historyStore.saveMessages(sessionId, merged);
      }
      Logger.info('remote merged: +' + Math.max(0, merged.length - before.length) +
        ' msgs pages=' + pagesFetched + ' in ' + (Date.now() - t0) + 'ms');
    } catch (err) {
      Logger.warn('fetchLatestHistory failed: ' + (err as Error).message);
      // 首屏没有任何缓存时，静默失败会让用户只看到空白页，明确提示一次
      const now = Date.now();
      if (this.pageActive && this.appForeground && this.messages.length === 0 &&
        now - this.lastHistoryErrorAt > 15000) {
        this.lastHistoryErrorAt = now;
        promptAction.showToast({ message: '历史加载失败，请检查连接后重试', duration: 2200 });
      }
    } finally {
      if (this.pageActive && token === this.historyToken) { this.isLoadingHistory = false; }
    }
  }

  private async persistCurrent(): Promise<void> {
    const sid = this.sessionService.getCurrentSessionId();
    if (sid) { await this.historyStore.saveMessages(sid, this.sessionService.getMessages()); }
  }

  private buildDisplayText(text: string, attachments: AttachmentItem[]): string {
    let display = text;
    for (const a of attachments) {
      const tag = a.type === 'image' ? '[图片] ' : '[文件] ';
      display = display.length > 0 ? display + '\n' + tag + a.name : tag + a.name;
    }
    return display;
  }

  private buildUserPayload(text: string, attachments: AttachmentItem[]): WsUserMessage {
    if (attachments.length > 0) {
      const atts: WsAttachment[] = [];
      for (const a of attachments) {
        atts.push({ type: a.type, name: a.name, data: a.data, mimeType: a.mimeType });
      }
      return { type: 'user_message', content: text, attachments: atts };
    }
    return { type: 'user_message', content: text };
  }

  private handleSendMessage(text: string, attachments: AttachmentItem[]): void {
    const sid = this.sessionService.getCurrentSessionId();
    if (!sid) { return; }
    // 断线时发送会静默失败（消息只留在本地），先提示并触发重连
    if (!this.wsService.getIsConnected()) {
      this.wsService.ensureAlive();
      promptAction.showToast({ message: '连接已断开，正在重连，请稍后重试', duration: 2000 });
      return;
    }
    const display = this.buildDisplayText(text, attachments);
    const msg = this.sessionService.addUserMessage(display);
    if (this.isGenerating) {
      // 生成中排队：仅本地排队，当前回合结束后自动发送（与服务端 H5 行为一致）
      msg.setDelivery(DeliveryState.QUEUED);
      this.queuedSends.push({ localId: msg.id, text: text, attachments: attachments });
      this.queuedCount = this.queuedSends.length;
      this.syncMessages();
      this.persistCurrent();
      promptAction.showToast({ message: '已排队', duration: 1500 });
      return;
    }
    this.dispatchPayload(this.buildUserPayload(text, attachments), msg);
  }

  /** 真正发出消息：记录待确认状态与原文载荷；flush 失败直接标失败，服务端未确认由对账兜底 */
  private dispatchPayload(payload: WsUserMessage, localMsg: MessageModel): void {
    this.currentTurnAssistantId = '';
    this.turnNotified = false;
    // 立刻置为生成中：这样用户发完马上切后台时，onBackground 能及时启动连续任务，
    // 保证完成事件和通知不会被系统冻结
    this.isGenerating = true;
    this.activityMonitor.markRunning(this.activeSessionId);
    localMsg.setDelivery(DeliveryState.SENDING);
    this.activeSendId = localMsg.id;
    this.pendingPayloads.set(localMsg.id, payload);
    this.syncMessages();
    this.persistCurrent();

    this.sendAt = Date.now();
    this.firstEventLogged = false;
    Logger.warn('[CC] user_message send start at ' + this.sendAt + ' len=' + payload.content.length);
    this.wsService.sendWithResult(payload).then((ok: boolean): void => {
      if (ok || !this.pageActive) { return; }
      if (this.activeSendId !== localMsg.id) { return; }
      this.markSendFailed(localMsg.id);
      promptAction.showToast({ message: '发送失败，点按消息可重试', duration: 2000 });
    });
  }

  private markSendFailed(localId: string): void {
    const m = this.sessionService.getMessageById(localId);
    if (m) { m.setDelivery(DeliveryState.FAILED); }
    if (this.activeSendId === localId) { this.activeSendId = ''; }
    this.isGenerating = false;
    this.activityMonitor.markIdle(this.activeSessionId);
    this.syncMessages();
    this.persistCurrent();
  }

  /** 本轮任一事件到达：确认前面的 user_message 已被服务端接受 */
  private confirmActiveSend(): void {
    if (!this.activeSendId) { return; }
    const m = this.sessionService.getMessageById(this.activeSendId);
    if (m) { m.setDelivery(DeliveryState.SENT); }
    this.pendingPayloads.delete(this.activeSendId);
    this.activeSendId = '';
    this.syncMessages();
    this.persistCurrent();
  }

  private pumpQueueSoon(): void {
    if (this.pumpTimer !== -1) { clearTimeout(this.pumpTimer); }
    this.pumpTimer = setTimeout(() => {
      this.pumpTimer = -1;
      this.pumpQueue();
    }, 150);
  }

  private pumpQueue(): void {
    if (!this.pageActive || this.isGenerating || this.queuedSends.length === 0) { return; }
    if (!this.wsService.getIsConnected()) { return; }
    const next = this.queuedSends.shift();
    this.queuedCount = this.queuedSends.length;
    if (!next) { return; }
    const m = this.sessionService.getMessageById(next.localId);
    if (!m) {
      this.pumpQueue();
      return;
    }
    this.dispatchPayload(this.buildUserPayload(next.text, next.attachments), m);
  }

  /** 停止/离开/切会话：排队消息退回输入框（不自动发送） */
  private restoreQueuedToComposer(toastMessage: string): void {
    if (this.queuedSends.length === 0) { return; }
    const ids = new Set<string>();
    const texts: string[] = [];
    for (const q of this.queuedSends) {
      ids.add(q.localId);
      if (q.text.trim().length > 0) { texts.push(q.text); }
    }
    this.queuedSends = [];
    this.queuedCount = 0;
    this.sessionService.setMessages(this.sessionService.getMessages().filter(m => !ids.has(m.id)));
    if (texts.length > 0) { AppStorage.setOrCreate('composerPrefill', texts.join('\n\n')); }
    this.syncMessages();
    this.persistCurrent();
    if (toastMessage) { promptAction.showToast({ message: toastMessage, duration: 1800 }); }
  }

  /** 用户主动取消排队：直接移除排队气泡 */
  private cancelQueued(): void {
    if (this.queuedSends.length === 0) { return; }
    const ids = new Set<string>();
    for (const q of this.queuedSends) { ids.add(q.localId); }
    this.queuedSends = [];
    this.queuedCount = 0;
    this.sessionService.setMessages(this.sessionService.getMessages().filter(m => !ids.has(m.id)));
    this.syncMessages();
    this.persistCurrent();
  }

  private handleStop(): void {
    // 停止当前回合时，排队消息不再自动发送，退回输入框
    this.restoreQueuedToComposer('已停止');
    const payload: WsStopMessage = { type: 'stop_generation' };
    this.wsService.send(payload);
  }

  private hasAttachmentMarker(m: MessageModel): boolean {
    for (const c of m.contents) {
      if (c.type !== ContentType.TEXT) { continue; }
      const lines = (c as TextContent).text.split('\n');
      for (const line of lines) {
        const t = line.trim();
        if (t.indexOf('[图片]') === 0 || t.indexOf('[文件]') === 0) { return true; }
      }
    }
    return false;
  }

  /** 点按失败消息重试：先核对远端，确认未送达才重发，避免重复 */
  private onRetryMessage(localId: string): void {
    const m = this.sessionService.getMessageById(localId);
    if (!m || m.delivery !== DeliveryState.FAILED) { return; }
    if (!this.wsService.getIsConnected()) {
      this.wsService.ensureAlive();
      promptAction.showToast({ message: '连接已断开，正在重连', duration: 1800 });
      return;
    }
    const payload = this.pendingPayloads.get(localId);
    if (!payload) {
      if (this.hasAttachmentMarker(m)) {
        promptAction.showToast({ message: '附件消息未保留，请在输入框重新发送', duration: 2200 });
        return;
      }
      const text = userDisplayText(m);
      if (!text) { return; }
      this.verifyThenRetry(m, { type: 'user_message', content: text });
      return;
    }
    this.verifyThenRetry(m, payload);
  }

  private verifyThenRetry(m: MessageModel, payload: WsUserMessage): void {
    const sid = this.sessionService.getCurrentSessionId();
    if (!sid) { return; }
    this.apiService.getMessagesPage(sid).then((page: MessagesPage): void => {
      if (!this.pageActive) { return; }
      const remote = parseServerMessages(page.messages);
      const res = resolvePendingDelivery([m], remote, false);
      if (res.length > 0 && res[0].state === DeliveryState.SENT) {
        m.setDelivery(DeliveryState.SENT);
        this.pendingPayloads.delete(m.id);
        this.syncMessages();
        this.persistCurrent();
        return;
      }
      this.dispatchPayload(payload, m);
    }).catch((err: Error): void => {
      Logger.warn('retry verify failed: ' + err.message);
      if (this.pageActive) { this.dispatchPayload(payload, m); }
    });
  }

  /** 滚动到顶部时加载更早的一页历史 */
  private async handleLoadMore(): Promise<void> {
    if (!this.historyHasMore || this.isLoadingMore || !this.oldestCursor) { return; }
    const sid = this.sessionService.getCurrentSessionId();
    if (!sid) { return; }
    this.isLoadingMore = true;
    try {
      const page = await this.apiService.getMessagesPage(sid, this.oldestCursor);
      if (!this.pageActive) { return; }
      if (page.messages.length > 0) {
        const older = parseServerMessages(page.messages);
        const merged = mergeMessages(this.sessionService.getMessages(), older);
        this.sessionService.setMessages(merged);
        this.syncMessages();
        this.historyStore.saveMessages(sid, merged);
      }
      this.oldestCursor = page.nextCursor;
      this.historyHasMore = page.hasMore && page.nextCursor.length > 0;
      this.hasMoreHistory = this.historyHasMore;
    } catch (err) {
      Logger.warn('loadMore failed: ' + (err as Error).message);
    } finally {
      this.isLoadingMore = false;
    }
  }

  private showPermissionDialog(): void {
    if (!this.pageActive || !this.pendingPermissionRequest || this.permissionDialogVisible) { return; }
    const request = this.pendingPermissionRequest;
    this.permissionDialogController = new CustomDialogController({
      builder: ToolPermissionDialog({
        request: request,
        onAllow: (requestId: string) => { this.sendPermissionDecision(requestId, true, false); },
        onDeny: (requestId: string) => { this.sendPermissionDecision(requestId, false, false); },
        // 服务端若支持 remember，会记住该工具；不支持时等价于允许一次
        onAlwaysAllow: (requestId: string) => { this.sendPermissionDecision(requestId, true, true); }
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      autoCancel: false,
      maskColor: ThemeColors.dialogMask('light')
    });
    this.permissionDialogVisible = true;
    this.permissionDialogController.open();
    this.startPermissionTimer(request.toolCallId);
  }

  private startPermissionTimer(requestId: string): void {
    this.clearPermissionTimer();
    this.permissionTimer = setTimeout(() => {
      this.permissionTimer = -1;
      if (!this.pendingPermissionRequest || this.pendingPermissionRequest.toolCallId !== requestId) { return; }
      // 超时自动拒绝，避免服务端一直挂起；用户可在电脑端重新触发
      this.sendPermissionDecision(requestId, false, false);
      if (this.permissionDialogController) { this.permissionDialogController.close(); }
      this.permissionDialogVisible = false;
      const msg = new MessageModel(MessageRole.SYSTEM);
      msg.appendText('权限请求超时，已自动拒绝；如需执行请在电脑端确认后重试');
      this.sessionService.addMessage(msg);
      this.flushSync();
    }, this.PERMISSION_TIMEOUT_MS);
  }

  private clearPermissionTimer(): void {
    if (this.permissionTimer !== -1) { clearTimeout(this.permissionTimer); this.permissionTimer = -1; }
  }

  private onAppForegroundChanged(): void {
    if (this.appForeground && this.pageActive && this.pendingPermissionRequest && !this.permissionDialogVisible) {
      this.showPermissionDialog();
    }
    // 后台期间本轮已结束：回前台补发本地排队消息
    if (this.appForeground && this.pageActive && !this.isGenerating && this.queuedSends.length > 0) {
      this.pumpQueueSoon();
    }
  }

  private sendPermissionDecision(requestId: string, allowed: boolean, remember: boolean): void {
    this.clearPermissionTimer();
    this.pendingPermissionRequest = null;
    this.permissionDialogVisible = false;
    if (!this.wsService || !requestId) { return; }
    const payload: WsPermissionResponse = { type: 'permission_response', requestId: requestId, allowed: allowed };
    if (remember) { payload.remember = true; }
    this.wsService.send(payload);
  }

  build() {
    Column() {
      MessageList({
        messages: $messages,
        isLoading: this.isLoadingHistory || this.isLoadingMore,
        onLoadMore: (): void => { this.handleLoadMore(); },
        onRetryMessage: (id: string): void => { this.onRetryMessage(id); }
      })

      if (this.activeSessionId) {
        ComposerToolbar({
          sessionId: this.activeSessionId,
          isGenerating: this.isGenerating
        })
      }

      InputBar({
        isGenerating: this.isGenerating,
        queuedCount: this.queuedCount,
        onSendMessage: (message: string, attachments: AttachmentItem[]): void => {
          this.handleSendMessage(message, attachments);
        },
        onStopGeneration: (): void => { this.handleStop(); },
        onCancelQueued: (): void => { this.cancelQueued(); }
      })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.chatBg(this.theme))
  }
}
