import { WebSocketService } from '../services/WebSocketService';
import { ApiService, SessionInspection } from '../services/ApiService';
import { promptAction } from '@kit.ArkUI';
import { Logger } from '../utils/Logger';
import { ThemeColors } from '../utils/ThemeUtil';

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
  @StorageLink('theme') theme: string = 'light';
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
    if (this.permissionMode === 'bypassPermissions') { return ThemeColors.dangerText(this.theme); }
    if (this.permissionMode === 'plan') { return ThemeColors.primary; }
    if (this.permissionMode === 'acceptEdits') { return ThemeColors.warningText(this.theme); }
    return ThemeColors.textSecondary(this.theme);
  }

  private effortLabel(): string {
    for (const opt of EFFORT_OPTIONS) {
      if (opt.level === this.effortLevel) { return opt.label; }
    }
    return this.effortLevel;
  }

  private contextColor(): string {
    if (this.contextPercent >= 85) { return ThemeColors.dangerText(this.theme); }
    if (this.contextPercent >= 70) { return ThemeColors.warningText(this.theme); }
    return ThemeColors.textSecondary(this.theme);
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
  }

  private refreshContext(): void {
    this.refreshStatus();
  }

  build() {
    Scroll() {
      Row() {
        // 权限模式
        Row() {
          Circle().width(6).height(6).fill(this.permissionColor()).accessibilityLevel('no')
          Text(this.permissionLabel()).fontSize(11)
            .fontColor(ThemeColors.textSecondary(this.theme)).margin({ left: 5 })
          Text('▾').fontSize(9).fontColor(ThemeColors.textTertiary(this.theme)).margin({ left: 3 })
            .accessibilityLevel('no')
        }
        .height(40).alignItems(VerticalAlign.Center)
        .padding({ left: 4, right: 12 })
        .accessibilityLevel('yes').accessibilityText('权限模式：' + this.permissionLabel())
        .id('composer-permission')
        .bindMenu(this.permissionMenu())

        // 工作目录
        if (this.cwdLabel.length > 0) {
          Text(this.cwdLabel)
            .fontSize(11).fontColor(ThemeColors.textSecondary(this.theme))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 140 })
            .height(40).padding({ left: 4, right: 12 })
            .accessibilityLevel('yes').accessibilityText('工作目录：' + this.cwdLabel)
            .id('composer-cwd')
        }

        // 上下文占用：接近上限时变色提示，避免首字延迟和渲染卡顿
        Row() {
          Text(this.contextPercent >= 0 ? this.contextPercent + '%' : '--')
            .fontSize(11).fontColor(this.contextColor())
          if (this.contextPercent >= 85) {
            Text('!').fontSize(11).fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.dangerText(this.theme)).margin({ left: 2 })
              .accessibilityLevel('no')
          }
        }
        .height(40).alignItems(VerticalAlign.Center)
        .padding({ left: 4, right: 12 })
        .accessibilityLevel('yes')
        .accessibilityText('上下文 ' + (this.contextPercent >= 0 ? this.contextPercent + '%' : '未知') + '，点击刷新')
        .id('composer-context')
        .onClick(() => { this.refreshContext(); })

        // 模型
        Row() {
          Text(this.modelLabel.length > 0 ? this.modelLabel : '模型')
            .fontSize(11).fontColor(ThemeColors.primary).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 170 })
          Text('▾').fontSize(9).fontColor(ThemeColors.textTertiary(this.theme)).margin({ left: 3 })
            .accessibilityLevel('no')
        }
        .height(40).alignItems(VerticalAlign.Center)
        .padding({ left: 4, right: 12 })
        .accessibilityLevel('yes').accessibilityText('模型：' + (this.modelLabel.length > 0 ? this.modelLabel : '未选择'))
        .id('composer-model')
        .bindMenu(this.modelMenu())

        // 思考强度
        Row() {
          Text('强度 ' + this.effortLabel()).fontSize(11)
            .fontColor(ThemeColors.textSecondary(this.theme))
          Text('▾').fontSize(9).fontColor(ThemeColors.textTertiary(this.theme)).margin({ left: 3 })
            .accessibilityLevel('no')
        }
        .height(40).alignItems(VerticalAlign.Center)
        .padding({ left: 4, right: 12 })
        .accessibilityLevel('yes').accessibilityText('思考强度：' + this.effortLabel())
        .id('composer-effort')
        .bindMenu(this.effortMenu())
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 4 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .backgroundColor(ThemeColors.card(this.theme))
  }
}
