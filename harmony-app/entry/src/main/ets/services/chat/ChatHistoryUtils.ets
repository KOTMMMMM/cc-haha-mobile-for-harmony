import {
  MessageModel, MessageRole, ContentType, TextContent, ThinkingContent, ToolUseContent
} from '../../models/Message';

/**
 * 聊天历史解析 / 合并的纯逻辑。
 * 从 ChatPage 抽出，便于单测，也避免页面文件继续膨胀。
 */

export function contentToText(contentObj: Object): string {
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
    return '';
  }
}

export function parseTime(value: string): number {
  if (!value) { return Date.now(); }
  const t = Date.parse(value);
  return isNaN(t) ? Date.now() : t;
}

export function messageKey(m: MessageModel): string {
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

export function concatAssistantText(m: MessageModel): string {
  let text = '';
  for (const c of m.contents) {
    if (c.type === ContentType.TEXT) { text += (c as TextContent).text; }
  }
  return text;
}

/** 用户消息去重用的正文：去掉图片/文件附件标记行（文件名不可靠） */
export function userDisplayText(m: MessageModel): string {
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

function decCount(map: Map<string, number>, key: string): void {
  const n = map.get(key) ?? 0;
  if (n <= 1) { map.delete(key); } else { map.set(key, n - 1); }
}

/**
 * 合并本地缓存与服务端历史。
 * 去重按「一对一消费」计数：远端有两条相同的“继续”、本地也有两条时不会互相吞掉。
 * 优先用 serverId 精确匹配；文本只作为本地乐观消息（无 serverId）的兜底。
 */
export function mergeMessages(local: MessageModel[], remote: MessageModel[]): MessageModel[] {
  const merged: MessageModel[] = [];
  const keyCounts: Map<string, number> = new Map();
  const userTextCounts: Map<string, number> = new Map();
  const serverIds: Set<string> = new Set();
  let remoteMin = 0;
  let remoteMax = 0;
  for (let i = 0; i < remote.length; i++) {
    const m = remote[i];
    const k = messageKey(m);
    keyCounts.set(k, (keyCounts.get(k) ?? 0) + 1);
    if (m.role === MessageRole.USER) {
      const t = userDisplayText(m);
      if (t.length > 0) { userTextCounts.set(t, (userTextCounts.get(t) ?? 0) + 1); }
    }
    if (m.serverId) { serverIds.add(m.serverId); }
    merged.push(m);
    if (i === 0 || m.timestamp < remoteMin) { remoteMin = m.timestamp; }
    if (i === 0 || m.timestamp > remoteMax) { remoteMax = m.timestamp; }
  }
  for (const m of local) {
    // 同一服务端消息已由远端提供时，以远端版本为准
    if (m.serverId && serverIds.has(m.serverId)) { continue; }
    // 只有与远端页时间窗重叠的消息才可能重复。
    // 几千条旧消息直接跳过文本比较，避免 O(本地条数 × 远端条数) 的字符串扫描。
    const nearRemote = remote.length > 0 &&
      m.timestamp >= remoteMin - 600000 && m.timestamp <= remoteMax + 600000;
    if (nearRemote) {
      const k = messageKey(m);
      if ((keyCounts.get(k) ?? 0) > 0) {
        decCount(keyCounts, k);
        if (m.role === MessageRole.USER) {
          const t = userDisplayText(m);
          if (t.length > 0 && (userTextCounts.get(t) ?? 0) > 0) { decCount(userTextCounts, t); }
        }
        continue;
      }
      if (m.role === MessageRole.USER) {
        // 附件文件名在服务端会被重命名，不能作为去重依据：只比较去掉附件标记后的正文。
        // 一对一消费计数，避免把用户连续发送的两条相同指令误判为重复。
        const lt = userDisplayText(m);
        if (lt.length > 0 && (userTextCounts.get(lt) ?? 0) > 0) {
          decCount(userTextCounts, lt);
          continue;
        }
      }
      if (m.role === MessageRole.ASSISTANT) {
        const lt = concatAssistantText(m);
        // 流式过程中切换会话/刷新会把同一轮拆成「历史前缀 + 实时后缀」多条消息，
        // 内容上互相包含时按“谁更完整保留谁”去重，避免同一条回复显示两遍。
        if (lt.length >= 12) {
          let containedByRemote = false;
          for (const r of merged) {
            if (r.role !== MessageRole.ASSISTANT) { continue; }
            if (Math.abs(r.timestamp - m.timestamp) >= 600000) { continue; }
            const rt = concatAssistantText(r);
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
            const rt = concatAssistantText(r);
            if (rt.length >= 12 && rt.length < lt.length && lt.indexOf(rt) >= 0) {
              decCount(keyCounts, messageKey(r));
              merged.splice(i, 1);
            }
          }
        }
      }
    }
    merged.push(m);
  }
  merged.sort((a, b) => a.timestamp - b.timestamp);
  return merged;
}

export function appendContentBlocks(msg: MessageModel, contentObj: Object): void {
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

export function parseServerMessages(rawList: Record<string, Object>[]): MessageModel[] {
  const result: MessageModel[] = [];
  // 服务端历史把整轮拆成多条记录：assistant(thinking) / assistant(text) / tool_use / tool_result。
  // 客户端实时流式时一轮只有一条 assistant 消息（回合内不发 message_complete），
  // 因此历史也必须按“两条 user 记录之间合成一条 assistant”来解析，才能与本地消息去重。
  let current: MessageModel | null = null;

  for (const raw of rawList) {
    const type = raw.type as string;
    const ts = parseTime(raw.timestamp as string);
    if (type === 'user') {
      const serverId = (raw.id as string) ?? '';
      const msg = new MessageModel(MessageRole.USER, serverId || undefined);
      msg.serverId = serverId;
      msg.timestamp = ts;
      appendContentBlocks(msg, raw.content);
      result.push(msg);
      current = null;
    } else if (type === 'assistant') {
      if (!current) {
        const serverId = (raw.id as string) ?? '';
        current = new MessageModel(MessageRole.ASSISTANT, serverId || undefined);
        current.serverId = serverId;
        current.timestamp = ts;
        current.model = raw.model as string;
        result.push(current);
      }
      appendContentBlocks(current, raw.content);
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
            const output = contentToText(b.content);
            const isErr = (b.is_error as boolean) ?? false;
            for (const m of result) { m.updateToolResult(id, output, isErr); }
          }
        }
      }
    }
  }
  return result;
}

/** 通知摘要：取最后一条 assistant 的纯文本，去掉 Markdown 标记并限长 */
export function lastAssistantSnippet(messages: MessageModel[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role !== MessageRole.ASSISTANT) { continue; }
    let text = '';
    for (const c of messages[i].contents) {
      if (c.type === ContentType.TEXT) { text += (c as TextContent).text; }
    }
    text = text.trim();
    if (text.length === 0) { continue; }
    text = text.replace(/[#*`>_~\-]/g, '').replace(/\s+/g, ' ').trim();
    return text.length > 120 ? text.substring(0, 120) + '…' : text;
  }
  return '回复已完成，点击查看';
}
