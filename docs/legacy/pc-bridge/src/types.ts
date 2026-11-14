// ============================================================================
// Shared type definitions for the PC Bridge server
// ============================================================================

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

export type SessionStatus = 'idle' | 'generating' | 'executing' | 'error';

export interface Session {
  id: string;
  workDir: string;
  status: SessionStatus;
  model: string;
  createdAt: number;
  process: { pid: number } | null;
  messages: ChatMessage[];
  currentMessageId: string | null;
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export interface TextContent {
  type: 'text';
  text: string;
}

export interface ImageContent {
  type: 'image';
  source: {
    type: 'base64';
    media_type: string;
    data: string;
  };
}

export type ContentBlock = TextContent | ImageContent;

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: ContentBlock[];
  timestamp: number;
  usage?: {
    input: number;
    output: number;
  };
}

export interface Attachment {
  name: string;
  mimeType: string;
  data: string;
  size: number;
}

// ---------------------------------------------------------------------------
// Streaming Events (internal bridge protocol)
// ---------------------------------------------------------------------------

export interface StreamEvent {
  type:
    | 'stream_start'
    | 'stream_delta'
    | 'thinking'
    | 'tool_use'
    | 'tool_result'
    | 'message_complete'
    | 'error'
    | 'status'
    | 'permission_request';
  sessionId: string;
  [key: string]: unknown;
}

export interface StreamStartEvent extends StreamEvent {
  type: 'stream_start';
  messageId: string;
}

export interface StreamDeltaEvent extends StreamEvent {
  type: 'stream_delta';
  messageId: string;
  content: string;
}

export interface ThinkingEvent extends StreamEvent {
  type: 'thinking';
  content: string;
}

export interface ToolUseEvent extends StreamEvent {
  type: 'tool_use';
  tool: ToolInfo;
}

export interface ToolResultEvent extends StreamEvent {
  type: 'tool_result';
  toolId: string;
  output: string;
}

export interface MessageCompleteEvent extends StreamEvent {
  type: 'message_complete';
  messageId: string;
  usage?: {
    input: number;
    output: number;
  };
}

export interface ErrorEvent extends StreamEvent {
  type: 'error';
  code: string;
  message: string;
}

export interface StatusEvent extends StreamEvent {
  type: 'status';
  status: SessionStatus;
}

export interface PermissionRequestEvent extends StreamEvent {
  type: 'permission_request';
  requestId: string;
  tool: ToolInfo;
}

// ---------------------------------------------------------------------------
// Tool
// ---------------------------------------------------------------------------

export interface ToolInfo {
  name: string;
  input: Record<string, unknown>;
  status: 'pending' | 'running' | 'completed' | 'error';
  description?: string;
}

// ---------------------------------------------------------------------------
// WebSocket Messages (mobile <-> server)
// ---------------------------------------------------------------------------

export type WsClientMessage =
  | WsChatMessage
  | WsPermissionMessage
  | WsStopMessage
  | WsResumeMessage;

export interface WsChatMessage {
  type: 'chat';
  sessionId: string;
  message: string;
  attachments?: Attachment[];
}

export interface WsPermissionMessage {
  type: 'permission';
  sessionId: string;
  requestId: string;
  decision: 'allow' | 'deny' | 'always';
}

export interface WsStopMessage {
  type: 'stop';
  sessionId: string;
}

export interface WsResumeMessage {
  type: 'resume';
  sessionId: string;
}

export type WsServerMessage =
  | { type: 'connected'; sessionId: string }
  | StreamStartEvent
  | StreamDeltaEvent
  | ThinkingEvent
  | ToolUseEvent
  | ToolResultEvent
  | MessageCompleteEvent
  | ErrorEvent
  | StatusEvent
  | PermissionRequestEvent;

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

export interface PairingRequest {
  deviceName: string;
  deviceId: string;
}

export interface PairingVerifyRequest {
  deviceId: string;
  code: string;
}

export interface PairingCode {
  code: string;
  deviceId: string;
  deviceName: string;
  expiresAt: number;
  verified: boolean;
}

export interface JwtPayload {
  deviceId: string;
  deviceName: string;
  iat: number;
  exp: number;
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

export interface ApiResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
  code?: string;
}

export interface CreateSessionRequest {
  workDir?: string;
  model?: string;
}

export interface FileInfo {
  name: string;
  path: string;
  type: 'file' | 'directory';
  size?: number;
  modifiedAt?: number;
}

export interface ModelProvider {
  id: string;
  name: string;
  models: ModelInfo[];
}

export interface ModelInfo {
  id: string;
  name: string;
  maxTokens?: number;
}

// ---------------------------------------------------------------------------
// NDJSON protocol messages (cc-haha stdio)
// ---------------------------------------------------------------------------

export interface NdJsonUserMessage {
  type: 'user';
  message: {
    role: 'user';
    content: Array<{
      type: 'text';
      text: string;
    }>;
  };
}

export interface NdJsonAssistantEvent {
  type: 'assistant' | 'stream_event' | 'result' | 'system' | 'error';
  message?: {
    id?: string;
    role?: 'assistant';
    content?: Array<{
      type: string;
      text?: string;
      name?: string;
      input?: Record<string, unknown>;
      id?: string;
    }>;
    stop_reason?: string;
    model?: string;
    usage?: {
      input_tokens: number;
      output_tokens: number;
    };
  };
  error?: string;
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

export interface DiscoveryBroadcast {
  type: 'cc-haha-bridge';
  port: number;
  hostname: string;
  version: string;
  serverName: string;
  timestamp: number;
}
