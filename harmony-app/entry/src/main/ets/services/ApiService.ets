import http from '@ohos.net.http';
import { Session, SessionModel, SessionStatus } from '../models/Session';
import { FileInfo } from '../models/FileInfo';
import { ConnectionConfig, Provider, ProviderModel } from '../models/ConnectionConfig';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';

interface CreateSessionBody { workDir?: string; }

export interface FileBrowseResult {
  entries: FileInfo[];
  currentPath: string;
  parentPath: string;
}

export interface MessagesPage {
  messages: Record<string, Object>[];
  nextCursor: string;
  hasMore: boolean;
}

/** 会话状态/上下文用量（来自 inspection 接口） */
export interface SessionInspection {
  permissionMode: string;
  model: string;
  contextPercent: number;
  contextTokens: number;
  contextMax: number;
}

export class ApiService {
  private baseUrl: string = '';
  private token: string = '';
  private currentHost: string = '';
  private currentPort: number = 0;
  private scheme: string = 'http';
  private httpClient: http.HttpRequest = http.createHttp();
  // HarmonyOS 的 HttpRequest 不适合并发复用：这里把请求串行化，避免相互打断和频繁建连
  private tail: Promise<void> = Promise.resolve();
  // 地址探测结果缓存：正常刷新不必每次重新探测（60s 内复用）
  private resolvedHost: string = '';
  private resolvedAt: number = 0;
  // 请求代际：切地址时递增，旧请求立即作废，避免慢请求拖住新地址的队列
  private queueGeneration: number = 0;

  private static readonly RESOLVE_TTL_MS: number = 60000;

  private originFor(host: string, port: number, scheme: string): string {
    if (scheme === 'https') {
      return (port && port !== 443) ? 'https://' + host + ':' + port : 'https://' + host;
    }
    return 'http://' + host + ':' + port;
  }

  setConnection(host: string, port: number, token: string, scheme: string = 'http'): void {
    const mode: string = scheme === 'https' ? 'https' : 'http';
    const nextUrl: string = this.originFor(host, port, mode);
    const changed: boolean = nextUrl !== this.baseUrl;
    this.baseUrl = nextUrl;
    this.token = token;
    this.currentHost = host;
    this.currentPort = port;
    this.scheme = mode;
    AppStorage.setOrCreate('connectionScheme', mode);
    if (changed) {
      this.queueGeneration++;
      this.resolvedHost = '';
      this.resolvedAt = 0;
      this.resetHttpClient();
    }
  }

  private resetHttpClient(): void {
    // 销毁旧 client 会中断在飞请求，尽快释放串行队列
    try {
      this.httpClient.destroy();
    } catch (e) {
    }
    this.httpClient = http.createHttp();
  }

  clearConnection(): void {
    this.baseUrl = '';
    this.token = '';
    this.currentHost = '';
    this.currentPort = 0;
    this.scheme = 'http';
    AppStorage.setOrCreate('connectionScheme', 'http');
    this.invalidateResolution();
    this.queueGeneration++;
    this.resetHttpClient();
  }

  getBaseUrl(): string { return this.baseUrl; }
  getCurrentHost(): string { return this.currentHost; }
  getCurrentPort(): number { return this.currentPort; }
  getScheme(): string { return this.scheme; }

  /** 地址/网络可能已变化，让下一次 ensureConnection 重新探测。 */
  invalidateResolution(): void {
    this.resolvedHost = '';
    this.resolvedAt = 0;
  }

  /** 对当前地址做一次轻量探活（独立短超时，不占用串行队列）。 */
  async healthCheckCurrent(): Promise<boolean> {
    if (!this.currentHost || this.currentPort <= 0) {
      return false;
    }
    const ok: boolean = await this.probe(this.currentHost, this.currentPort, this.scheme);
    if (ok) {
      AppStorage.setOrCreate('pcReachable', true);
    }
    return ok;
  }

  async healthCheck(): Promise<boolean> {
    try {
      const data = await this.request('GET', '/health', undefined, false) as Record<string, Object>;
      return data && (data['status'] as string) === 'ok';
    } catch (err) {
      Logger.warn('healthCheck failed: ' + (err as Error).message);
      return false;
    }
  }

  /**
   * 公共访问配对接口（无需登录）：用于 #pair= 链接的 /pair 与 /claim。
   * 始终走 HTTPS，独立短连接，不占用主 HTTP 队列。
   */
  async publicPairPost(host: string, port: number, path: string, body: Object): Promise<Record<string, Object>> {
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'User-Agent': 'cc-haha-mobile/1.0.0',
          'Origin': this.originFor(host, port, 'https')
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000
      };
      const resp = await client.request(this.originFor(host, port, 'https') + path, options);
      const text: string = resp.result as string;
      if (resp.responseCode >= 400) {
        let msg: string = 'HTTP ' + resp.responseCode;
        try {
          const errObj = JSON.parse(text) as Record<string, Object>;
          const e = errObj['error'] as string;
          if (e) { msg = e; }
        } catch (e) {
        }
        throw new Error(msg);
      }
      if (!text || text.length === 0) { return {}; }
      return JSON.parse(text) as Record<string, Object>;
    } finally {
      client.destroy();
    }
  }

  /**
   * 快速探测某个地址是否可达（独立短超时，不进入串行队列）。
   * 用于在局域网 IP / Tailscale IP 之间自动选择。
   */
  async probe(host: string, port: number, scheme: string = 'http'): Promise<boolean> {
    if (!host || port <= 0) { return false; }
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'cc-haha-mobile/1.0.0' },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 3500,
        readTimeout: 3500
      };
      const resp = await client.request(this.originFor(host, port, scheme) + '/health', options);
      if (resp.responseCode !== 200) { return false; }
      const body = resp.result as string;
      try {
        const data = JSON.parse(body) as Record<string, Object>;
        return (data['status'] as string) === 'ok';
      } catch (e) {
        return true;
      }
    } catch (err) {
      return false;
    } finally {
      client.destroy();
    }
  }

  async getSessions(): Promise<Session[]> {
    const data = await this.request('GET', '/api/sessions') as Record<string, Object>;
    const raw = (data && Array.isArray(data['sessions'])) ? data['sessions'] as Record<string, Object>[] : [];
    const sessions: Session[] = [];
    for (const item of raw) {
      sessions.push(this.mapSession(item));
    }
    return sessions;
  }

  async getSession(id: string): Promise<Session | null> {
    try {
      const data = await this.request('GET', '/api/sessions/' + id) as Record<string, Object>;
      if (!data) { return null; }
      return this.mapSession(data);
    } catch (err) {
      Logger.warn('getSession(' + id.substring(0, 8) + ') failed: ' + (err as Error).message);
      return null;
    }
  }

  /** 会话状态 + 上下文用量（包含权限模式、当前模型、上下文百分比） */
  async getInspection(sessionId: string): Promise<SessionInspection | null> {
    try {
      const data = await this.request('GET',
        '/api/sessions/' + sessionId + '/inspection?includeContext=1&contextOnly=1') as Record<string, Object>;
      const status = data['status'] as Record<string, Object>;
      const context = data['context'] as Record<string, Object>;
      const result: SessionInspection = {
        permissionMode: status ? ((status['permissionMode'] as string) ?? '') : '',
        model: status ? ((status['model'] as string) ?? '') : '',
        contextPercent: -1,
        contextTokens: 0,
        contextMax: 0
      };
      if (context) {
        const pct = context['percentage'] as number;
        result.contextPercent = typeof pct === 'number' ? Math.round(pct) : -1;
        result.contextTokens = (context['totalTokens'] as number) ?? 0;
        result.contextMax = (context['rawMaxTokens'] as number) ?? ((context['maxTokens'] as number) ?? 0);
      }
      return result;
    } catch (err) {
      const message: string = (err as Error).message;
      Logger.warn('getInspection failed: ' + message);
      // 会话被删除时向上传递，调用方可停止轮询并回列表
      if (message.indexOf('Session not found') >= 0 || message.indexOf('NOT_FOUND') >= 0) {
        throw new Error('NOT_FOUND');
      }
      return null;
    }
  }

  private mapSession(item: Record<string, Object>): SessionModel {
    const id = item.id as string ?? '';
    const workDir = item.workDir as string ?? '';
    const model = item.runtimeModelId as string ?? 'unknown';
    const title = item.title as string ?? '';
    const msgs = item.messageCount as number ?? 0;
    const s = new SessionModel(id, workDir, model, 'idle', msgs, title);
    s.createdAt = this.parseTime(item.createdAt as string);
    s.lastActivityAt = this.parseTime(item.modifiedAt as string);
    s.projectPath = item.projectPath as string ?? '';
    s.workspaceState = item.workspaceState as string ?? '';
    s.runtimeProviderId = item.runtimeProviderId as string ?? '';
    s.effortLevel = item.effortLevel as string ?? '';
    s.permissionMode = item.permissionMode as string ?? '';
    return s;
  }

  async createSession(workDir?: string): Promise<Session | null> {
    try {
      const body: CreateSessionBody = {};
      if (workDir) { body.workDir = workDir; }
      const data = await this.request('POST', '/api/sessions', body) as Record<string, Object>;
      const id = data['sessionId'] as string ?? '';
      if (!id) { return null; }
      const s = new SessionModel(id, data['workDir'] as string ?? workDir ?? '', 'unknown', 'idle', 0, '新会话');
      return s;
    } catch (err) {
      Logger.error('createSession failed: ' + (err as Error).message);
      return null;
    }
  }

  async deleteSession(id: string): Promise<boolean> {
    try {
      await this.request('DELETE', '/api/sessions/' + id);
      return true;
    } catch (err) {
      Logger.warn('deleteSession(' + id.substring(0, 8) + ') failed: ' + (err as Error).message);
      return false;
    }
  }

  async getMessages(sessionId: string): Promise<Record<string, Object>[]> {
    try {
      const data = await this.request('GET', '/api/sessions/' + sessionId + '/messages') as Record<string, Object>;
      const raw = (data && Array.isArray(data['messages'])) ? data['messages'] as Record<string, Object>[] : [];
      return raw;
    } catch (err) {
      Logger.warn('getMessages(' + sessionId.substring(0, 8) + ') failed: ' + (err as Error).message);
      return [];
    }
  }

  /** 新版服务端为游标分页：返回本页消息与向前翻页游标（参数名是 cursor） */
  async getMessagesPage(sessionId: string, before?: string): Promise<MessagesPage> {
    try {
      let path = '/api/sessions/' + sessionId + '/messages';
      if (before) { path += '?cursor=' + encodeURIComponent(before); }
      const data = await this.request('GET', path) as Record<string, Object>;
      const msgs = (data && Array.isArray(data['messages'])) ? data['messages'] as Record<string, Object>[] : [];
      const page = data['page'] as Record<string, Object>;
      let nextCursor = '';
      let hasMore = false;
      if (page) {
        nextCursor = page['nextCursor'] as string ?? '';
        hasMore = page['hasMore'] as boolean ?? false;
      }
      const result: MessagesPage = { messages: msgs, nextCursor: nextCursor, hasMore: hasMore };
      return result;
    } catch (err) {
      Logger.warn('getMessagesPage(' + sessionId.substring(0, 8) + ') failed: ' + (err as Error).message);
      const empty: MessagesPage = { messages: [], nextCursor: '', hasMore: false };
      return empty;
    }
  }

  async getProviders(): Promise<Provider[]> {
    try {
      const data = await this.request('GET', '/api/providers') as Record<string, Object>;
      const raw = (data && Array.isArray(data['providers'])) ? data['providers'] as Record<string, Object>[] : [];
      const providers: Provider[] = [];
      for (const item of raw) {
        // 注意：服务端会返回 apiKey，客户端刻意忽略，绝不落盘/展示
        const models: ProviderModel[] = [];
        const m = (item.models as Record<string, Object>) ?? {};
        const main = m['main'] as string ?? '';
        if (main) { models.push({ id: main, name: main, providerId: item.id as string ?? '' }); }
        for (const key of ['haiku', 'sonnet', 'opus']) {
          const mid = m[key] as string ?? '';
          if (mid && mid !== main) { models.push({ id: mid, name: mid, providerId: item.id as string ?? '' }); }
        }
        providers.push({ id: item.id as string ?? '', name: item.name as string ?? '', models: models });
      }
      return providers;
    } catch (err) {
      Logger.warn('getProviders failed: ' + (err as Error).message);
      return [];
    }
  }

  async browseFiles(path: string): Promise<FileBrowseResult | null> {
    try {
      let url = '/api/filesystem/browse?includeFiles=true';
      if (path && path.length > 0) { url += '&path=' + encodeURIComponent(path); }
      const data = await this.request('GET', url) as Record<string, Object>;
      const raw = (data && Array.isArray(data['entries'])) ? data['entries'] as Record<string, Object>[] : [];
      const entries: FileInfo[] = [];
      for (const item of raw) {
        const name = item.name as string ?? '';
        const p = item.path as string ?? '';
        const isDir = item.isDirectory as boolean ?? false;
        const extIndex = name.lastIndexOf('.');
        entries.push({
          name: name, path: p,
          type: isDir ? 'directory' : 'file',
          isDirectory: isDir,
          size: 0, modifiedAt: 0,
          extension: (!isDir && extIndex >= 0) ? name.substring(extIndex) : undefined
        });
      }
      return {
        entries: entries,
        currentPath: data['currentPath'] as string ?? path,
        parentPath: data['parentPath'] as string ?? ''
      };
    } catch (err) {
      Logger.warn('browseFiles(' + path + ') failed: ' + (err as Error).message);
      return null;
    }
  }

  private parseTime(value: string): number {
    if (!value) { return Date.now(); }
    const t = Date.parse(value);
    return isNaN(t) ? Date.now() : t;
  }

  /** 在多个候选地址中选第一个可达的（并行探测）；全部不可达返回空串。 */
  async pickReachableHost(baseHost: string, alternates: string[], port: number,
    scheme: string = 'http'): Promise<string> {
    const candidates: string[] = [];
    const add = (host: string): void => {
      if (host && candidates.indexOf(host) < 0) { candidates.push(host); }
    };
    add(baseHost);
    for (const host of alternates) { add(host); }
    if (candidates.length === 0) { return ''; }
    if (candidates.length === 1) {
      return (await this.probe(candidates[0], port, scheme)) ? candidates[0] : '';
    }
    return new Promise<string>((resolve: (host: string) => void): void => {
      let pending: number = candidates.length;
      let settled: boolean = false;
      for (const host of candidates) {
        this.probe(host, port, scheme).then((ok: boolean): void => {
          pending--;
          if (settled) { return; }
          if (ok) {
            settled = true;
            resolve(host);
          } else if (pending === 0) {
            settled = true;
            resolve('');
          }
        });
      }
    });
  }

  /**
   * 从已保存配置中选一个可达地址并设置为当前连接。
   * 并行探测主地址、上次成功地址和备用地址，适配局域网/Tailscale 切换。
   * 返回是否找到可达地址；不可达时不写入主地址，避免发起注定超时的请求。
   */
  async ensureConnection(config: ConnectionConfig | null): Promise<boolean> {
    if (!config) {
      return false;
    }
    // 60s 内复用上次探测结果，避免每次刷新都重新探测（LAN 不通时要等 3.5s）
    if (this.resolvedHost.length > 0 && this.baseUrl.length > 0 &&
      Date.now() - this.resolvedAt < ApiService.RESOLVE_TTL_MS) {
      return true;
    }
    // 公共访问（Cloudflare HTTPS）：固定单地址，不做局域网/Tailscale 备用探测
    if (config.scheme === 'https') {
      const remoteOk: boolean = await this.probe(config.host, config.port, 'https');
      if (remoteOk) {
        this.setConnection(config.host, config.port, config.token, 'https');
        this.resolvedHost = config.host;
        this.resolvedAt = Date.now();
        AppStorage.setOrCreate('pcActiveHost', config.host);
        AppStorage.setOrCreate('pcReachable', true);
        return true;
      }
      Logger.info('remote host unreachable: ' + config.host);
      this.invalidateResolution();
      if (this.baseUrl.length > 0) { this.clearConnection(); }
      AppStorage.setOrCreate('pcReachable', false);
      return false;
    }
    const alternates: string[] = [];
    const cached: string = AppStorage.get<string>('pcActiveHost') ?? '';
    if (cached) { alternates.push(cached); }
    if (config.alternates) {
      for (const host of config.alternates) { alternates.push(host); }
    }
    const host: string = await this.pickReachableHost(config.host, alternates, config.port, 'http');
    if (host.length > 0) {
      Logger.info('connect host ' + host + ' -> reachable');
      this.setConnection(host, config.port, config.token, 'http');
      this.resolvedHost = host;
      this.resolvedAt = Date.now();
      AppStorage.setOrCreate('pcActiveHost', host);
      AppStorage.setOrCreate('pcReachable', true);
      return true;
    }
    Logger.info('no reachable host (primary=' + config.host + ')');
    // 当前网络下没有可达地址（例如 Tailscale 尚未 running）：清掉旧地址，
    // 让调用方立即回退缓存，等连接恢复后由 sessionsRefresh 重新拉取。
    this.invalidateResolution();
    if (this.baseUrl.length > 0) {
      this.clearConnection();
    }
    AppStorage.setOrCreate('pcReachable', false);
    return false;
  }

  private async request(method: string, path: string, body?: Object, withAuth: boolean = true): Promise<Object> {
    const generation: number = this.queueGeneration;
    // 排队执行：同一时刻只有一个 HTTP 请求在飞
    const previous = this.tail;
    let releaseFn: () => void = (): void => {};
    const gate = new Promise<void>((resolve: (value: void) => void): void => {
      releaseFn = (): void => { resolve(); };
    });
    this.tail = previous.then((): Promise<void> => gate);
    await previous;
    // 切地址后，队列里针对旧地址的请求直接作废，不再占用新地址的队列
    if (generation !== this.queueGeneration) {
      releaseFn();
      throw new Error('连接已切换，请求已取消');
    }
    if (this.baseUrl.length === 0) {
      releaseFn();
      throw new Error('尚未配置连接，请稍后重试');
    }
    const url = this.baseUrl + path;
    const reqHeader: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': 'cc-haha-mobile/1.0.0'
    };
    if (this.scheme === 'https') {
      // 公共访问网关要求 Origin；原生 App 与浏览器 H5 使用同一来源
      reqHeader['Origin'] = this.baseUrl;
    }
    if (withAuth && this.token) { reqHeader['Authorization'] = 'Bearer ' + this.token; }
    const options: http.HttpRequestOptions = {
      method: method as http.RequestMethod, header: reqHeader,
      expectDataType: http.HttpDataType.STRING, connectTimeout: 5000, readTimeout: 30000
    };
    if (body) { options.extraData = body; }
    try {
      const response = await this.httpClient.request(url, options);
      const resultStr = response.result as string;
      if (response.responseCode === 401 || response.responseCode === 403) {
        throw new Error('认证失败（token 无效或无权限）');
      }
      if (response.responseCode >= 400) {
        let msg = 'HTTP ' + response.responseCode;
        try {
          const errObj = JSON.parse(resultStr) as Record<string, Object>;
          const e = errObj['error'] as string;
          const m = errObj['message'] as string;
          if (e) { msg = e + (m ? ': ' + m : ''); }
        } catch (e) {
          Logger.debug('error response body is not JSON');
        }
        throw new Error(msg);
      }
      if (!resultStr || resultStr.length === 0) { return new Object(); }
      return JSON.parse(resultStr) as Object;
    } catch (err) {
      if (err instanceof Error) { throw err; }
      // 底层网络错误：当前地址可能已失效（切网/PC 不可达），下次强制重探测。
      // 仅当该请求属于当前代际时才失效缓存，避免切地址时旧请求的回调清掉新结果。
      if (generation === this.queueGeneration) {
        this.invalidateResolution();
      }
      try {
        Logger.warn('http raw error ' + JSON.stringify(err));
      } catch (e) {
        Logger.warn('http raw error (unserializable)');
      }
      throw new Error('网络连接失败');
    } finally {
      releaseFn();
    }
  }

}
