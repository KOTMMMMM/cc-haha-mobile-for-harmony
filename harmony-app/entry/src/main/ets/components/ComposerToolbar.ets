import { WebSocketService } from '../services/WebSocketService';
import { ApiService, SessionInspection } from '../services/ApiService';
import { promptAction } from '@kit.ArkUI';
import { Logger } from '../utils/Logger';

interface PermOption { mode: string; label: string; }
interface EffortOption { level: string; label: string; }
interface WsSetPermissionMode { type: string; mode: string; }
interface WsSetRuntimeConfig { type: string; providerId: string; modelId: string; effortLevel?: string; }

const PERM_OPTIONS: PermOption[] = [
  { mode: 'default', label: '询问权限' },
  { mode: 'acceptEdits', label: '自动接受' },
  { mode: 'plan', label: '计划模式' },
  { mode: 'bypassPermissions', label: '跳过' },
  { mode: 'dontAsk', label: '不询问' }
];

const EFFORT_OPTIONS: EffortOption[] = [
  { level: 'low', label: '低' },
  { level: 'medium', label: '中' },
  { level: 'high', label: '高' },
  { level: 'xhigh', label: '超高' },
  { level: 'max', label: '最大' }
];

/**
 * 输入框上方工具栏（对齐 cc-haha）：权限模式 / 工作目录 / 上下文占用 / 模型 / 思考强度
 */
@Component
export struct ComposerToolbar {
  @Prop @Watch('onSessionChanged') sessionId: string = '';
  @Prop @Watch('onGeneratingChanged') isGenerating: boolean = false;
  @StorageLink('wsService') wsService: WebSocketService = new WebSocketService();
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  // 聊天页顶部「刷新」同时刷新工具栏状态（上下文/模型/权限模式）
  @StorageLink('chatRefresh') @Watch('onExternalRefresh') chatRefresh: number = 0;
  @State permissionMode: string = 'default';
  @State modelLabel: string = '';
  @State effortLevel: string = 'max';
  @State contextPercent: number = -1;
  @State contextTokens: number = 0;
  @State contextMax: number = 0;
  @State cwdLabel: string = '';
  private providerId: string = '';
  private modelId: string = '';
  private menuProviderIds: string[] = [];
  private menuModelIds: string[] = [];
  private menuLabels: string[] = [];
  private loadSeq: number = 0;
  private refreshAttempts: number = 0;
  private sessionMissing: boolean = false;

  aboutToAppear(): void {
    this.loadProviders();
    this.scheduleRefresh();
  }

  onSessionChanged(): void {
    this.permissionMode = 'default';
    this.modelLabel = '';
    this.effortLevel = 'max';
    this.contextPercent = -1;
    this.contextTokens = 0;
    this.contextMax = 0;
    this.cwdLabel = '';
    this.providerId = '';
    this.modelId = '';
    this.sessionMissing = false;
    this.loadProviders();
    this.scheduleRefresh();
  }

  /** 页面刚出现时 ApiService 可能还没拿到连接配置，或历史分页正在占用服务端，失败后自动重试 */
  private scheduleRefresh(): void {
    this.refreshAttempts = 0;
    this.retryRefresh(this.sessionId);
  }

  private async retryRefresh(sid: string): Promise<void> {
    if (!sid || sid !== this.sessionId || this.sessionMissing) { return; }
    this.refreshAttempts++;
    if (this.menuModelIds.length === 0) {
      // 启动早期连接配置可能尚未就绪，模型菜单拉取失败后随重试补拉
      this.loadProviders();
    }
    const ok = await this.refreshStatus();
    if (!ok && !this.sessionMissing && this.refreshAttempts < 8 && sid === this.sessionId) {
      setTimeout(() => { this.retryRefresh(sid); }, 5000);
    }
  }

  private onExternalRefresh(): void {
    if (this.chatRefresh > 0) { this.scheduleRefresh(); }
  }

  onGeneratingChanged(): void {
    // 一轮结束后刷新上下文占用（稍等服务端落盘）
    if (!this.isGenerating) {
      setTimeout(() => { this.scheduleRefresh(); }, 1000);
    }
  }

  private async loadProviders(): Promise<void> {
    try {
      const providers = await this.apiService.getProviders();
      const pids: string[] = [];
      const mids: string[] = [];
      const labels: string[] = [];
      for (const p of providers) {
        for (const m of p.models) {
          pids.push(p.id);
          mids.push(m.id);
          labels.push(m.id);
        }
      }
      this.menuProviderIds = pids;
      this.menuModelIds = mids;
      this.menuLabels = labels;
    } catch (e) {
      Logger.warn('ComposerToolbar loadProviders failed: ' + (e as Error).message);
    }
  }

  private async refreshStatus(): Promise<boolean> {
    const sid = this.sessionId;
    if (!sid || this.apiService.getBaseUrl().length === 0) { return false; }
    const seq = ++this.loadSeq;
    let got = false;
    try {
      const sessions = await this.apiService.getSessions();
      if (seq !== this.loadSeq) { return got; }
      for (const s of sessions) {
        if (s.id !== sid) { continue; }
        got = true;
        if (s.workDir) { this.cwdLabel = this.lastPathSegment(s.workDir); }
        if (s.runtimeProviderId) { this.providerId = s.runtimeProviderId; }
        if (s.effortLevel) { this.effortLevel = s.effortLevel; }
        if (s.permissionMode) { this.permissionMode = s.permissionMode; }
        if (s.model) { this.applyModelDisplay(s.model); }
        break;
      }
    } catch (e) {
      Logger.warn('toolbar refresh sessions failed: ' + (e as Error).message);
    }
    try {
      const insp = await this.apiService.getInspection(sid);
      if (seq !== this.loadSeq) { return got; }
      if (insp) {
        got = true;
        if (insp.permissionMode.length > 0) { this.permissionMode = insp.permissionMode; }
        if (insp.model.length > 0) { this.applyModelDisplay(insp.model); }
        this.contextPercent = insp.contextPercent;
        this.contextTokens = insp.contextTokens;
        this.contextMax = insp.contextMax;
      }
    } catch (e) {
      const message: string = (e as Error).message;
      if (message === 'NOT_FOUND' || message.indexOf('Session not found') >= 0) {
        this.sessionMissing = true;
        AppStorage.setOrCreate('invalidSessionId', sid);
      }
    }
    return got;
  }

  /** 会话里的模型可能带 [1m] 后缀：显示完整名，菜单里匹配到供应商的模型 id */
  private applyModelDisplay(runtimeModel: string): void {
    this.modelLabel = runtimeModel;
    for (let i = 0; i < this.menuModelIds.length; i++) {
      if (runtimeModel === this.menuModelIds[i] || runtimeModel.startsWith(this.menuModelIds[i])) {
        this.modelId = this.menuModelIds[i];
        return;
      }
    }
    this.modelId = runtimeModel.replace(/\[\d+m\]$/, '');
  }

  private lastPathSegment(path: string): string {
    const parts = path.split('\\');
    const last = parts[parts.length - 1];
    return last && last.length > 0 ? last : path;
  }

  private permissionMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const opt of PERM_OPTIONS) {
      items.push({
        value: (this.permissionMode === opt.mode ? '✓ ' : '') + opt.label,
        action: (): void => { this.applyPermission(opt.mode); }
      });
    }
    return items;
  }

  private modelMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.menuModelIds.length === 0) {
      items.push({ value: '加载中…', action: (): void => {} });
      return items;
    }
    for (let i = 0; i < this.menuModelIds.length; i++) {
      const mid = this.menuModelIds[i];
      items.push({
        value: (this.modelId === mid ? '✓ ' : '') + this.menuLabels[i],
        action: (): void => { this.applyModel(i); }
      });
    }
    return items;
  }

  private effortMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const opt of EFFORT_OPTIONS) {
      items.push({
        value: (this.effortLevel === opt.level ? '✓ ' : '') + opt.label,
        action: (): void => { this.applyEffort(opt.level); }
      });
    }
    return items;
  }

  private permissionLabel(): string {
    for (const opt of PERM_OPTIONS) {
      if (opt.mode === this.permissionMode) { return opt.label; }
    }
    if (this.permissionMode === 'auto') { return '自动模式'; }
    return this.permissionMode.length > 0 ? this.permissionMode : '权限';
  }

  private permissionColor(): string {
    if (this.permissionMode === 'bypassPermissions') { return '#E54D42'; }
    if (this.permissionMode === 'plan') { return '#1677FF'; }
    if (this.permissionMode === 'acceptEdits') { return '#FA9D3B'; }
    return '#8C8C8C';
  }

  private effortLabel(): string {
    for (const opt of EFFORT_OPTIONS) {
      if (opt.level === this.effortLevel) { return opt.label; }
    }
    return this.effortLevel;
  }

  private contextColor(): string {
    if (this.contextPercent >= 90) { return '#E54D42'; }
    if (this.contextPercent >= 75) { return '#FA9D3B'; }
    return '#8C8C8C';
  }

  private applyPermission(mode: string): void {
    if (this.isGenerating) {
      promptAction.showToast({ message: '会话进行中，无法切换权限模式', duration: 1500 });
      return;
    }
    if (!this.wsService.getIsConnected()) {
      promptAction.showToast({ message: '连接已断开，请稍后重试', duration: 1500 });
      return;
    }
    const payload: WsSetPermissionMode = { type: 'set_permission_mode', mode: mode };
    this.wsService.send(payload);
    this.permissionMode = mode;
    promptAction.showToast({ message: '权限模式：' + this.permissionLabel(), duration: 1200 });
  }

  private applyModel(index: number): void {
    if (index < 0 || index >= this.menuModelIds.length) { return; }
    if (!this.wsService.getIsConnected()) {
      promptAction.showToast({ message: '连接已断开，请稍后重试', duration: 1500 });
      return;
    }
    const pid = this.menuProviderIds[index];
    const mid = this.menuModelIds[index];
    const payload: WsSetRuntimeConfig = {
      type: 'set_runtime_config', providerId: pid, modelId: mid
    };
    if (this.effortLevel.length > 0) { payload.effortLevel = this.effortLevel; }
    this.wsService.send(payload);
    this.providerId = pid;
    this.modelId = mid;
    this.modelLabel = mid;
    promptAction.showToast({ message: '已切换模型：' + mid, duration: 1200 });
    setTimeout(() => { this.refreshStatus(); }, 1500);
  }

  private applyEffort(level: string): void {
    if (!this.wsService.getIsConnected()) {
      promptAction.showToast({ message: '连接已断开，请稍后重试', duration: 1500 });
      return;
    }
    const pid = this.providerId;
    const mid = this.modelId.length > 0 ? this.modelId : this.modelLabel.replace(/\[\d+m\]$/, '');
    if (!pid || !mid) {
      promptAction.showToast({ message: '请先选择模型', duration: 1500 });
      return;
    }
    const payload: WsSetRuntimeConfig = {
      type: 'set_runtime_config', providerId: pid, modelId: mid, effortLevel: level
    };
    this.wsService.send(payload);
    this.effortLevel = level;
    promptAction.showToast({ message: '思考强度：' + this.effortLabel(), duration: 1200 });
  }

  private refreshContext(): void {
    if (this.contextTokens > 0 && this.contextMax > 0) {
      const used = Math.round(this.contextTokens / 1000) + 'K';
      const max = Math.round(this.contextMax / 1000) + 'K';
      promptAction.showToast({ message: '上下文用量 ' + used + ' / ' + max + '，刷新中…', duration: 1500 });
    }
    this.refreshStatus();
  }

  build() {
    Scroll() {
      Row() {
        // 权限模式
        Row() {
          Circle().width(6).height(6).fill(this.permissionColor())
          Text(this.permissionLabel()).fontSize(11).fontColor('#666').margin({ left: 5 })
          Text('▾').fontSize(9).fontColor('#999').margin({ left: 3 })
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('#F2F2F2').borderRadius(10)
        .margin({ right: 6 })
        .bindMenu(this.permissionMenu())

        // 工作目录
        if (this.cwdLabel.length > 0) {
          Text('📁 ' + this.cwdLabel)
            .fontSize(11).fontColor('#666')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 140 })
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('#F2F2F2').borderRadius(10)
            .margin({ right: 6 })
        }

        // 上下文占用
        Row() {
          Text(this.contextPercent >= 0 ? '◔ ' + this.contextPercent + '%' : '◔ --')
            .fontSize(11).fontColor(this.contextColor())
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('#F2F2F2').borderRadius(10)
        .margin({ right: 6 })
        .onClick(() => { this.refreshContext(); })

        // 模型
        Row() {
          Text(this.modelLabel.length > 0 ? this.modelLabel : '模型')
            .fontSize(11).fontColor('#1677FF').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 170 })
          Text('▾').fontSize(9).fontColor('#999').margin({ left: 3 })
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('#E8F4FF').borderRadius(10)
        .margin({ right: 6 })
        .bindMenu(this.modelMenu())

        // 思考强度
        Row() {
          Text('强度 ' + this.effortLabel()).fontSize(11).fontColor('#666')
          Text('▾').fontSize(9).fontColor('#999').margin({ left: 3 })
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('#F2F2F2').borderRadius(10)
        .bindMenu(this.effortMenu())
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ top: 6, bottom: 2 })
    .backgroundColor('#FFFFFF')
  }
}
