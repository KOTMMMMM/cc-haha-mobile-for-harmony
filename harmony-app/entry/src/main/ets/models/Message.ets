/**
 * Message data model for chat messages (compatible with cc-haha pc-bridge protocol)
 */
export enum MessageRole { USER = 'user', ASSISTANT = 'assistant', SYSTEM = 'system' }
export enum ContentType { TEXT = 'text', THINKING = 'thinking', TOOL_USE = 'tool_use', TOOL_RESULT = 'tool_result' }

export interface TextContent { type: ContentType.TEXT; text: string; }
export interface ThinkingContent { type: ContentType.THINKING; text: string; collapsed: boolean; }
export interface ToolUseContent {
  type: ContentType.TOOL_USE;
  toolId: string;
  toolName: string;
  toolInput: Record<string, Object>;
  status: string;
  output?: string;
}
export interface ToolResultContent { type: ContentType.TOOL_RESULT; toolId: string; output: string; }

export type TextContentBlock = TextContent;
export type ThinkingContentBlock = ThinkingContent;
export type ToolUseContentBlock = ToolUseContent;
export type ContentBlock = TextContent | ThinkingContent | ToolUseContent | ToolResultContent;

export interface MsgUsage { inputTokens: number; outputTokens: number; cost?: number; }

/**
 * 本地发送状态。服务端没有 user_message 的 ACK：
 * - sending：已交给 WS，等待本轮首个事件确认；
 * - queued：生成中排队，等当前回合结束后自动发送；
 * - failed：断线/对账后确认未送达，点按可重试（不会自动重发）；
 * - sent：已确认；历史消息为空字符串。
 */
export enum DeliveryState {
  NONE = '',
  SENDING = 'sending',
  QUEUED = 'queued',
  FAILED = 'failed',
  SENT = 'sent'
}

export class MessageModel {
  id: string;
  /** 服务端消息 ID（历史消息）；本地乐观消息为空 */
  serverId: string = '';
  role: MessageRole;
  contents: ContentBlock[];
  timestamp: number;
  isStreaming: boolean;
  /** 本地发送状态；历史/助手消息通常为空 */
  delivery: DeliveryState = DeliveryState.NONE;
  /** 内容修订号：每次内容变化 +1，供 ForEach key 触发气泡重建（@Prop 不会感知对象内部变化） */
  revision: number = 0;
  model?: string;
  usage?: MsgUsage;

  constructor(role: MessageRole, id?: string) {
    this.id = id || 'msg-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8);
    this.role = role;
    this.contents = [];
    this.timestamp = Date.now();
    this.isStreaming = false;
  }

  appendText(text: string): void { this.addText(text); }
  addText(text: string): void {
    const last = this.contents.length > 0 ? this.contents[this.contents.length - 1] : null;
    if (last && last.type === ContentType.TEXT) { (last as TextContent).text += text; }
    else { this.contents.push({ type: ContentType.TEXT, text: text }); }
    this.revision++;
  }

  appendThinking(text: string): void { this.addThinking(text); }
  addThinking(text: string): void {
    const last = this.contents.length > 0 ? this.contents[this.contents.length - 1] : null;
    if (last && last.type === ContentType.THINKING) { (last as ThinkingContent).text += text; }
    else { this.contents.push({ type: ContentType.THINKING, text: text, collapsed: true }); }
    this.revision++;
  }

  addToolUse(toolId: string, toolName: string, toolInput: Record<string, Object>): ToolUseContent {
    const block: ToolUseContent = {
      type: ContentType.TOOL_USE, toolId: toolId, toolName: toolName,
      toolInput: toolInput, status: 'running'
    };
    this.contents.push(block);
    this.revision++;
    return block;
  }

  updateToolResult(toolId: string, output: string, isError?: boolean): void {
    for (let i = 0; i < this.contents.length; i++) {
      if (this.contents[i].type === ContentType.TOOL_USE && (this.contents[i] as ToolUseContent).toolId === toolId) {
        (this.contents[i] as ToolUseContent).status = isError ? 'error' : 'completed';
        (this.contents[i] as ToolUseContent).output = output;
        this.revision++;
        break;
      }
    }
  }

  updateToolStatus(toolId: string, status: string, output?: string): void {
    for (let i = 0; i < this.contents.length; i++) {
      if (this.contents[i].type === ContentType.TOOL_USE && (this.contents[i] as ToolUseContent).toolId === toolId) {
        (this.contents[i] as ToolUseContent).status = status;
        if (output) { (this.contents[i] as ToolUseContent).output = output; }
        this.revision++;
        break;
      }
    }
  }

  finalizeMessage(usage?: MsgUsage): void {
    this.isStreaming = false;
    if (usage) { this.usage = usage; }
    this.revision++;
  }

  setDelivery(state: DeliveryState): void {
    if (this.delivery !== state) {
      this.delivery = state;
      this.revision++;
    }
  }
}
