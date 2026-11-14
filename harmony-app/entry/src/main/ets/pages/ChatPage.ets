import {
  MessageModel, MessageRole, ContentType, TextContent, ThinkingContent, ToolUseContent
} from '../models/Message';
import { MessageList } from '../components/MessageList';
import { InputBar } from '../components/InputBar';
import { ComposerToolbar } from '../components/ComposerToolbar';
import { ToolPermissionDialog, PermissionRequest } from '../components/PermissionDialog';
import { WebSocketService, WsEvent } from '../services/WebSocketService';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { HistoryStore } from '../services/HistoryStore';
import { AuthService } from '../services/AuthService';
import { NotificationService } from '../services/NotificationService';
import { BackgroundTaskService } from '../services/BackgroundTaskService';
import { AttachmentItem } from '../models/Attachment';
import { promptAction } from '@kit.ArkUI';
import router from '@ohos.router';
import { Logger } from '../utils/Logger';

interface WsAttachment { type: string; name: string; data: string; mimeType: string; }
interface WsUserMessage { type: string; content: string; attachments?: WsAttachment[]; }
interface WsPermissionResponse { type: string; requestId: string; allowed: boolean; }
interface WsStopMessage { type: string; }

@Component
export struct ChatPage {
  @StorageLink('wsService') wsService: WebSocketService = new WebSocketService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @StorageLink('historyStore') historyStore: HistoryStore = new HistoryStore();
  @StorageLink('authService') authService: AuthService = new AuthService();
  @StorageLink('notificationService') notificationService: NotificationService = new NotificationService();
  @StorageLink('backgroundTaskService') bgTaskService: BackgroundTaskService = new BackgroundTaskService();
  @StorageLink('appForeground') appForeground: boolean = true;
  @StorageLink('activeSessionId') @Watch('onActiveSessionChanged') activeSessionId: string = '';
  @StorageLink('chatRefresh') @Watch('onRefreshChanged') chatRefresh: number = 0;
  @StorageLink('invalidSessionId') @Watch('onInvalidSessionChanged') invalidSessionId: string = '';
  @State messages: MessageModel[] = [];
  @State isLoadingHistory: boolean = false;
  @State isLoadingMore: boolean = false;
  @State @Watch('onGeneratingChanged') isGenerating: boolean = false;
  @State hasMoreHistory: boolean = false;
  private oldestCursor: string = '';
  private historyHasMore: boolean = false;
  private permissionDialogController: CustomDialogController | null = null;
  private pendingPermissionRequest: PermissionRequest | null = null;
  private currentTurnAssistantId: string = '';
  private pendingResync: boolean = false;
  private turnNotified: boolean = false;
  private pageActive: boolean = true;
  private sendAt: number = 0;
  private firstEventLogged: boolean = false;
  private lastHistoryErrorAt: number = 0;
  // 每次进入/切换会话递增，迟到的本地读取或网络结果直接丢弃
  private historyToken: number = 0;

  aboutToAppear(): void {
    this.pageActive = true;
    // 每个聊天页都是新实例：先清空上一个会话残留在全局里的消息，
    // 保证进入会话的首帧不会闪出之前的内容
    this.messages = [];
    this.sessionService.setMessages([]);
    this.setupWebSocketHandlers();
    // 断线自动恢复后补拉历史，避免错过断线期间的消息
    this.wsService.setReconnectListener((sid: string): void => {
      if (!this.pageActive) { return; }
      if (!sid || sid !== this.activeSessionId) { return; }
      Logger.info('WS auto-reconnected, resync history');
      if (this.isGenerating) {
        this.pendingResync = true;
      } else {
        this.fetchLatestHistory(sid);
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
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    // 非生成中退出时移除页面事件处理器，避免旧页面继续改 UI；
    // 生成中保留处理器，让回复完成通知仍能触发（服务端会继续跑完这一轮）。
    if (!this.isGenerating) {
      this.wsService.clearHandlers();
    }
    // 返回列表时立即刷新，避免标题/消息数/时间停留在旧值
    AppStorage.setOrCreate('sessionsRefresh', Date.now());
  }

  onActiveSessionChanged(): void {
    Logger.info('ChatPage active session changed: ' + this.activeSessionId);
    this.currentTurnAssistantId = '';
    this.isGenerating = false;
    this.pendingResync = false;
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
    this.isGenerating = false;
    this.wsService.disconnect();
    this.wsService.clearHandlers();
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
    promptAction.showToast({ message: '已刷新', duration: 1200 });
  }

  private async connectActiveSession(): Promise<void> {
    const sid = this.activeSessionId;
    const token = this.historyToken;
    if (!sid) {
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
    const origin = 'http://' + chosenHost + ':' + config.port;
    AppStorage.setOrCreate('pcActiveHost', chosenHost);
    AppStorage.setOrCreate('pcReachable', true);
    this.sessionService.setCurrentSessionId(sid);
    this.wsService.disconnect();
    this.wsService.clearHandlers();
    this.setupWebSocketHandlers();
    this.wsService.connect(chosenHost, config.port, config.token, sid, origin).catch((e: Error) => {
      // WS 失败可能意味着切网/地址失效，让下次重连前重新探测
      this.apiService.invalidateResolution();
      Logger.error('WS connect failed: ' + e.message);
    });
    // 本地缓存已经先显示了，这里只拉最新一页做增量合并
    this.fetchLatestHistory(sid);
  }

  private setupWebSocketHandlers(): void {
    if (!this.wsService) { return; }
    // 页面可能被重建/多次进入，先清空旧处理器，避免同一个 delta 被追加多次
    this.wsService.clearHandlers();

    this.wsService.on('session_state', (event: WsEvent) => {
      const turnState = event.turnState as string;
      this.isGenerating = turnState === 'running';
      if (turnState === 'running') {
        this.turnNotified = false;
        this.logFirstEvent('session_state');
      }
    });

    this.wsService.on('status', (event: WsEvent) => {
      const state = event.state as string;
      this.isGenerating = state !== 'idle';
      if (state === 'idle') { this.finalizeTurn(); }
      else { this.logFirstEvent('status'); }
    });

    this.wsService.on('content_start', (event: WsEvent) => {
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

    this.wsService.on('content_delta', (event: WsEvent) => {
      const text = event.text as string;
      if (text) {
        this.logFirstEvent('content_delta');
        const msg = this.ensureAssistantMessage();
        msg.appendText(text);
        this.syncMessages();
      }
      // toolInput 片段忽略，tool_use_complete 会带完整 input
    });

    this.wsService.on('tool_use_complete', (event: WsEvent) => {
      const msg = this.ensureAssistantMessage();
      const toolUseId = (event.toolUseId as string) ?? '';
      const toolName = (event.toolName as string) ?? '';
      const input = (event.input as Record<string, Object>) ?? (new Object() as Record<string, Object>);
      this.addOrUpdateTool(msg, toolUseId, toolName, input);
      this.syncMessages();
    });

    this.wsService.on('tool_result', (event: WsEvent) => {
      const toolUseId = (event.toolUseId as string) ?? '';
      const output = this.contentToText(event.content);
      const isError = (event.isError as boolean) ?? false;
      for (const m of this.sessionService.getMessages()) {
        m.updateToolResult(toolUseId, output, isError);
      }
      this.syncMessages();
    });

    this.wsService.on('thinking', (event: WsEvent) => {
      const text = event.text as string;
      if (text) {
        this.logFirstEvent('thinking');
        const msg = this.ensureAssistantMessage();
        msg.appendThinking(text);
        this.syncMessages();
      }
    });

    this.wsService.on('permission_request', (event: WsEvent) => {
      this.pendingPermissionRequest = {
        toolCallId: (event.requestId as string) ?? '',
        toolName: (event.toolName as string) ?? ((event.displayName as string) ?? ''),
        toolInput: (event.input as object) ?? (new Object() as object),
        description: (event.description as string) ?? ''
      };
      this.showPermissionDialog();
    });

    this.wsService.on('message_complete', (event: WsEvent) => {
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
      this.syncMessages();
      this.persistCurrent();
      this.maybeNotifyTurnComplete();
      this.runPendingResync();
    });

    this.wsService.on('error', (event: WsEvent) => {
      this.isGenerating = false;
      const msg = new MessageModel(MessageRole.SYSTEM);
      msg.appendText((event.message as string) ?? '发生错误，请重试');
      this.sessionService.addMessage(msg);
      this.syncMessages();
      this.persistCurrent();
    });

    this.wsService.on('system_notification', (event: WsEvent) => {
      const subtype = event.subtype as string;
      if (subtype === 'session_state_changed') {
        const data = event.data as Record<string, Object>;
        const state = (data && data['state'] as string) ?? '';
        this.isGenerating = state === 'running';
        if (state === 'idle') { this.finalizeTurn(); }
      }
    });

    this.wsService.on('session_title_updated', (event: WsEvent) => {
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
  }

  private finalizeTurn(): void {
    const last = this.getCurrentAssistant();
    if (last && last.isStreaming) { last.finalizeMessage(); }
    this.currentTurnAssistantId = '';
    this.syncMessages();
    this.persistCurrent();
    // 一轮结束后刷新列表的消息数/时间
    AppStorage.setOrCreate('sessionsRefresh', Date.now());
    this.maybeNotifyTurnComplete();
    this.runPendingResync();
  }

  /** 回复完成且 App 在后台时发通知（手表通过系统通知镜像接收） */
  private async maybeNotifyTurnComplete(): Promise<void> {
    if (this.turnNotified) { return; }
    this.turnNotified = true;
    try {
      if (!this.appForeground && (await this.authService.getNotifyOnComplete())) {
        const title = this.currentSessionTitle() + ' · 回复完成';
        const body = this.lastAssistantSnippet();
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

  private lastAssistantSnippet(): string {
    const msgs = this.sessionService.getMessages();
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role !== MessageRole.ASSISTANT) { continue; }
      let text = '';
      for (const c of msgs[i].contents) {
        if (c.type === ContentType.TEXT) { text += (c as TextContent).text; }
      }
      text = text.trim();
      if (text.length === 0) { continue; }
      // 去掉 Markdown 标记与换行，通知里保持一行
      text = text.replace(/[#*`>_~\-]/g, '').replace(/\s+/g, ' ').trim();
      return text.length > 120 ? text.substring(0, 120) + '…' : text;
    }
    return '回复已完成，点击查看';
  }

  /** 断线发生在生成过程中：等这一轮结束后再补拉历史，避免把实时消息对象替换掉 */
  private runPendingResync(): void {
    if (!this.pendingResync) { return; }
    this.pendingResync = false;
    if (this.activeSessionId) { this.fetchLatestHistory(this.activeSessionId); }
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

  private contentToText(contentObj: Object): string {
    if (contentObj === undefined || contentObj === null) { return ''; }
    if (typeof contentObj === 'string') { return contentObj as string; }
    const arr = contentObj as Record<string, Object>[];
    if (Array.isArray(arr)) {
      const parts: string[] = [];
      for (const b of arr) {
        const t = b.text as string;
        if (t) { parts.push(t); continue; }
        const c = b.content as string;
        if (c) { parts.push(c); }
      }
      return parts.join('\n');
    }
    try {
      return JSON.stringify(contentObj);
    } catch (e) {
      Logger.debug('contentToText stringify failed: ' + (e as Error).message);
      return '';
    }
  }

  private syncMessages(): void {
    if (!this.pageActive) { return; }
    this.messages = [...this.sessionService.getMessages()];
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
      this.sessionService.setMessages(local);
      this.syncMessages();
      this.isLoadingHistory = false;
      Logger.info('local history ready: ' + local.length + ' msgs in ' + (Date.now() - t0) + 'ms');
    } catch (err) {
      Logger.warn('showLocalHistory failed: ' + (err as Error).message);
    }
  }

  /** 只拉最新一页，和本地缓存增量合并；更早的分页由滚动到顶部时按需加载 */
  private async fetchLatestHistory(sessionId: string): Promise<void> {
    if (!sessionId) { return; }
    const token = this.historyToken;
    const t0 = Date.now();
    this.sessionService.setCurrentSessionId(sessionId);
    try {
      const page = await this.apiService.getMessagesPage(sessionId);
      if (!this.pageActive || token !== this.historyToken) { return; }
      const remote = page.messages.length > 0 ? this.parseServerMessages(page.messages) : [];
      const before = this.sessionService.getMessages();
      const merged = remote.length > 0 ? this.mergeMessages(before, remote) : before;
      this.sessionService.setMessages(merged);
      this.syncMessages();
      // 已经向上翻过页时保留原来的游标，避免重连把翻页位置重置到最新
      if (!this.oldestCursor) {
        this.oldestCursor = page.nextCursor;
        this.historyHasMore = page.hasMore && page.nextCursor.length > 0;
        this.hasMoreHistory = this.historyHasMore;
      }
      if (remote.length > 0 && merged.length > before.length) {
        this.historyStore.saveMessages(sessionId, merged);
      }
      Logger.info('remote latest merged: +' + Math.max(0, merged.length - before.length) +
        ' msgs in ' + (Date.now() - t0) + 'ms');
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

  private messageKey(m: MessageModel): string {
    let text = '';
    for (const c of m.contents) {
      if (c.type === ContentType.TEXT) { text += (c as TextContent).text; }
      else if (c.type === ContentType.THINKING) { text += (c as ThinkingContent).text; }
      else if (c.type === ContentType.TOOL_USE) {
        const t = c as ToolUseContent;
        // 工具调用必须带上唯一 ID，否则同名工具会被误判为重复
        text += 'tool:' + t.toolName + ':' + t.toolId;
      }
    }
    if (text.length > 0) { return m.role + '|' + text; }
    return m.role + '|' + Math.floor(m.timestamp / 60000);
  }

  private mergeMessages(local: MessageModel[], remote: MessageModel[]): MessageModel[] {
    const merged: MessageModel[] = [];
    const keys = new Set<string>();
    let remoteMin = 0;
    let remoteMax = 0;
    for (let i = 0; i < remote.length; i++) {
      const m = remote[i];
      keys.add(this.messageKey(m));
      merged.push(m);
      if (i === 0 || m.timestamp < remoteMin) { remoteMin = m.timestamp; }
      if (i === 0 || m.timestamp > remoteMax) { remoteMax = m.timestamp; }
    }
    for (const m of local) {
      // 只有与远端页时间窗重叠的消息才可能重复。
      // 几千条旧消息直接跳过文本比较，避免 O(本地条数 × 远端条数) 的字符串扫描。
      const nearRemote = remote.length > 0 &&
        m.timestamp >= remoteMin - 600000 && m.timestamp <= remoteMax + 600000;
      if (nearRemote) {
        const k = this.messageKey(m);
        if (keys.has(k)) { continue; }
        if (m.role === MessageRole.USER) {
          // 附件文件名在服务端会被重命名，不能作为去重依据：只比较去掉附件标记后的正文
          const lt = this.userDisplayText(m);
          let dup = false;
          if (lt.length > 0) {
            for (const r of merged) {
              if (r.role !== MessageRole.USER) { continue; }
              if (Math.abs(r.timestamp - m.timestamp) > 600000) { continue; }
              if (this.userDisplayText(r) === lt) { dup = true; break; }
            }
          }
          if (dup) { continue; }
        }
        if (m.role === MessageRole.ASSISTANT) {
          const lt = this.concatAssistantText(m);
          // 流式过程中切换会话/刷新会把同一轮拆成「历史前缀 + 实时后缀」多条消息，
          // 内容上互相包含时按“谁更完整保留谁”去重，避免同一条回复显示两遍。
          if (lt.length >= 12) {
            let containedByRemote = false;
            for (const r of merged) {
              if (r.role !== MessageRole.ASSISTANT) { continue; }
              if (Math.abs(r.timestamp - m.timestamp) >= 600000) { continue; }
              const rt = this.concatAssistantText(r);
              if (rt.length >= 12 && rt.indexOf(lt) >= 0) {
                containedByRemote = true;
                break;
              }
            }
            if (containedByRemote) { continue; }
            for (let i = merged.length - 1; i >= 0; i--) {
              const r = merged[i];
              if (r.role !== MessageRole.ASSISTANT) { continue; }
              if (Math.abs(r.timestamp - m.timestamp) >= 600000) { continue; }
              const rt = this.concatAssistantText(r);
              if (rt.length >= 12 && rt.length < lt.length && lt.indexOf(rt) >= 0) {
                keys.delete(this.messageKey(r));
                merged.splice(i, 1);
              }
            }
          }
        }
        keys.add(k);
      }
      merged.push(m);
    }
    merged.sort((a, b) => a.timestamp - b.timestamp);
    return merged;
  }

  private concatAssistantText(m: MessageModel): string {
    let text = '';
    for (const c of m.contents) {
      if (c.type === ContentType.TEXT) { text += (c as TextContent).text; }
    }
    return text;
  }

  /** 用户消息去重用的正文：去掉图片/文件附件标记行（文件名不可靠） */
  private userDisplayText(m: MessageModel): string {
    let text = '';
    for (const c of m.contents) {
      if (c.type === ContentType.TEXT) { text += (c as TextContent).text; }
    }
    const lines = text.split('\n');
    const kept: string[] = [];
    for (const line of lines) {
      const t = line.trim();
      if (t.indexOf('[图片]') === 0 || t.indexOf('[文件]') === 0 || t.indexOf('[Image: source:') === 0) {
        continue;
      }
      kept.push(line);
    }
    return kept.join('\n').trim();
  }

  private parseServerMessages(rawList: Record<string, Object>[]): MessageModel[] {
    const result: MessageModel[] = [];
    // 服务端历史把整轮拆成多条记录：assistant(thinking) / assistant(text) / tool_use / tool_result。
    // 客户端实时流式时一轮只有一条 assistant 消息（回合内不发 message_complete），
    // 因此历史也必须按“两条 user 记录之间合成一条 assistant”来解析，才能与本地消息去重。
    let current: MessageModel | null = null;

    for (const raw of rawList) {
      const type = raw.type as string;
      const ts = this.parseTime(raw.timestamp as string);
      if (type === 'user') {
        const msg = new MessageModel(MessageRole.USER, raw.id as string);
        msg.timestamp = ts;
        this.appendContentBlocks(msg, raw.content);
        result.push(msg);
        current = null;
      } else if (type === 'assistant') {
        if (!current) {
          current = new MessageModel(MessageRole.ASSISTANT, raw.id as string);
          current.timestamp = ts;
          current.model = raw.model as string;
          result.push(current);
        }
        this.appendContentBlocks(current, raw.content);
        const usage = raw.usage as Record<string, Object>;
        if (usage && !current.usage) {
          current.usage = {
            inputTokens: (usage.input_tokens as number) ?? 0,
            outputTokens: (usage.output_tokens as number) ?? 0
          };
        }
      } else if (type === 'tool_use') {
        if (!current) {
          current = new MessageModel(MessageRole.ASSISTANT);
          current.timestamp = ts;
          result.push(current);
        }
        const blocks = raw.content as Record<string, Object>[];
        if (Array.isArray(blocks)) {
          for (const b of blocks) {
            if ((b.type as string) === 'tool_use') {
              current.addToolUse(
                (b.id as string) ?? '', (b.name as string) ?? '',
                (b.input as Record<string, Object>) ?? (new Object() as Record<string, Object>)
              );
            }
          }
        }
      } else if (type === 'tool_result') {
        const blocks = raw.content as Record<string, Object>[];
        if (Array.isArray(blocks)) {
          for (const b of blocks) {
            if ((b.type as string) === 'tool_result') {
              const id = (b.tool_use_id as string) ?? '';
              const output = this.contentToText(b.content);
              const isErr = (b.is_error as boolean) ?? false;
              for (const m of result) { m.updateToolResult(id, output, isErr); }
            }
          }
        }
      }
    }
    return result;
  }

  private appendContentBlocks(msg: MessageModel, contentObj: Object): void {
    if (contentObj === undefined || contentObj === null) { return; }
    if (typeof contentObj === 'string') { msg.appendText(contentObj as string); return; }
    const blocks = contentObj as Record<string, Object>[];
    if (!Array.isArray(blocks)) { return; }
    for (const b of blocks) {
      const bt = b.type as string;
      if (bt === 'text') {
        const t = (b.text as string) ?? '';
        // 服务端把附件存成 [Image: source: <本地路径>] 文本块；
        // 还原成与本地发送时一致的「[图片] 文件名」，既隐藏本机路径，也能和本地消息正确去重。
        if (t.indexOf('[Image: source:') === 0) {
          const close = t.lastIndexOf(']');
          const path = close > 0 ? t.substring(0, close) : t;
          const sep = Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
          let name = sep >= 0 ? path.substring(sep + 1) : 'image';
          // 服务端上传后会给文件名加 UUID 前缀，显示时去掉
          if (name.length > 37 && name.charAt(8) === '-' && name.charAt(13) === '-' &&
              name.charAt(18) === '-' && name.charAt(23) === '-' && name.charAt(36) === '-') {
            name = name.substring(37);
          }
          let hasText = false;
          for (const c of msg.contents) {
            if (c.type === ContentType.TEXT && (c as TextContent).text.length > 0) { hasText = true; }
          }
          msg.appendText((hasText ? '\n' : '') + '[图片] ' + name);
          continue;
        }
        msg.appendText(t);
      } else if (bt === 'thinking') {
        msg.appendThinking((b.thinking as string) ?? (b.text as string) ?? '');
      }
    }
  }

  private parseTime(value: string): number {
    if (!value) { return Date.now(); }
    const t = Date.parse(value);
    return isNaN(t) ? Date.now() : t;
  }

  private async persistCurrent(): Promise<void> {
    const sid = this.sessionService.getCurrentSessionId();
    if (sid) { await this.historyStore.saveMessages(sid, this.sessionService.getMessages()); }
  }

  private handleSendMessage(text: string, attachments: AttachmentItem[]): void {
    if (this.isGenerating) { return; }
    const sid = this.sessionService.getCurrentSessionId();
    if (!sid) { return; }
    // 断线时发送会静默失败（消息只留在本地），先提示并触发重连
    if (!this.wsService.getIsConnected()) {
      this.wsService.ensureAlive();
      promptAction.showToast({ message: '连接已断开，正在重连，请稍后重试', duration: 2000 });
      return;
    }
    this.currentTurnAssistantId = '';
    this.turnNotified = false;
    // 立刻置为生成中：这样用户发完马上切后台时，onBackground 能及时启动连续任务，
    // 保证完成事件和通知不会被系统冻结
    this.isGenerating = true;

    // 本地展示时把附件名附在消息里
    let display = text;
    for (const a of attachments) {
      const tag = a.type === 'image' ? '[图片] ' : '[文件] ';
      display = display.length > 0 ? display + '\n' + tag + a.name : tag + a.name;
    }
    this.sessionService.addUserMessage(display);
    this.syncMessages();
    this.persistCurrent();

    this.sendAt = Date.now();
    this.firstEventLogged = false;
    Logger.warn('[CC] user_message send start at ' + this.sendAt + ' len=' + text.length);
    if (attachments.length > 0) {
      const atts: WsAttachment[] = [];
      for (const a of attachments) {
        atts.push({ type: a.type, name: a.name, data: a.data, mimeType: a.mimeType });
      }
      const payload: WsUserMessage = { type: 'user_message', content: text, attachments: atts };
      this.wsService.send(payload);
    } else {
      const payload: WsUserMessage = { type: 'user_message', content: text };
      this.wsService.send(payload);
    }
  }

  private handleStop(): void {
    const payload: WsStopMessage = { type: 'stop_generation' };
    this.wsService.send(payload);
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
        const older = this.parseServerMessages(page.messages);
        const merged = this.mergeMessages(this.sessionService.getMessages(), older);
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
    if (!this.pendingPermissionRequest) { return; }
    this.permissionDialogController = new CustomDialogController({
      builder: ToolPermissionDialog({
        request: this.pendingPermissionRequest,
        onAllow: (requestId: string) => { this.sendPermissionDecision(requestId, true); },
        onDeny: (requestId: string) => { this.sendPermissionDecision(requestId, false); },
        onAlwaysAllow: (requestId: string) => { this.sendPermissionDecision(requestId, true); }
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      autoCancel: false,
      maskColor: 'rgba(0,0,0,0.6)'
    });
    this.permissionDialogController.open();
  }

  private sendPermissionDecision(requestId: string, allowed: boolean): void {
    if (!this.wsService || !requestId) { return; }
    const payload: WsPermissionResponse = { type: 'permission_response', requestId: requestId, allowed: allowed };
    this.wsService.send(payload);
  }

  build() {
    Column() {
      MessageList({
        messages: $messages,
        isLoading: this.isLoadingHistory || this.isLoadingMore,
        onLoadMore: (): void => { this.handleLoadMore(); }
      })

      if (this.activeSessionId) {
        ComposerToolbar({
          sessionId: this.activeSessionId,
          isGenerating: this.isGenerating
        })
      }

      InputBar({
        sessionId: this.sessionService.getCurrentSessionId(),
        isGenerating: this.isGenerating,
        onSendMessage: (message: string, attachments: AttachmentItem[]): void => {
          this.handleSendMessage(message, attachments);
        },
        onStopGeneration: (): void => { this.handleStop(); }
      })
    }
    .width('100%').height('100%').backgroundColor('#F0F0F0')
  }
}
