// ============================================================================
// Claude Bridge - stdio communication with cc-haha CLI
//
// Spawns cc-haha in --print mode or --server mode, sends user messages,
// reads streaming responses, and converts them to our StreamEvent format
// for WebSocket delivery.
// ============================================================================

import type {
  Session,
  ChatMessage,
  ContentBlock,
  StreamEvent,
  NdJsonUserMessage,
  NdJsonAssistantEvent,
  Attachment,
} from './types.js';
import { v4 as uuidv4 } from 'uuid';
import {
  updateSessionStatus,
  getSession,
  addMessage,
  setCurrentMessageId,
} from './session-manager.js';

// ---------------------------------------------------------------------------
// Types for callback-based streaming
// ---------------------------------------------------------------------------

export type StreamCallback = (event: StreamEvent) => void;
export type PermissionCallback = (
  sessionId: string,
  requestId: string,
  tool: { name: string; input: Record<string, unknown>; description?: string },
  resolve: (decision: 'allow' | 'deny' | 'always') => void,
) => void;

// ---------------------------------------------------------------------------
// Active processes
// ---------------------------------------------------------------------------

const activeProcesses = new Map<string, AbortController>();

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SpawnedProc = any;

// ---------------------------------------------------------------------------
// Permission callback
// ---------------------------------------------------------------------------

let currentPermissionCallback: PermissionCallback = (
  _sessionId,
  _requestId,
  _tool,
  resolve,
) => {
  resolve('allow');
};

export function setPermissionCallback(cb: PermissionCallback): void {
  currentPermissionCallback = cb;
}

// ---------------------------------------------------------------------------
// Send a chat message to cc-haha and stream the response
// ---------------------------------------------------------------------------

export async function sendChatMessage(
  sessionId: string,
  userMessage: string,
  attachments: Attachment[] | undefined,
  onEvent: StreamCallback,
  claudeHahaPath: string,
): Promise<void> {
  const session = getSession(sessionId);
  if (!session) {
    onEvent({
      type: 'error',
      sessionId,
      code: 'session_not_found',
      message: 'Session ' + sessionId + ' not found',
    });
    return;
  }

  // Build content blocks
  const content: ContentBlock[] = [];

  if (attachments && attachments.length > 0) {
    for (const attachment of attachments) {
      if (attachment.mimeType.startsWith('image/')) {
        content.push({
          type: 'image',
          source: {
            type: 'base64',
            media_type: attachment.mimeType,
            data: attachment.data,
          },
        });
      } else {
        content.push({
          type: 'text',
          text: '\n[Attached file: ' + attachment.name + ' (' + attachment.mimeType + ', ' + (attachment.size / 1024).toFixed(1) + 'KB)]\n',
        });
      }
    }
  }

  content.push({
    type: 'text',
    text: userMessage,
  });

  // Create user message and add to history
  const userMsgId = uuidv4();
  const userChatMessage: ChatMessage = {
    id: userMsgId,
    role: 'user',
    content,
    timestamp: Date.now(),
  };
  addMessage(sessionId, userChatMessage);

  updateSessionStatus(sessionId, 'generating');

  // Build conversation context
  const conversationMessages: Array<{
    role: string;
    content: ContentBlock[];
  }> = [];

  for (const msg of session.messages) {
    if (msg.id === userMsgId) continue;
    conversationMessages.push({
      role: msg.role,
      content: msg.content,
    });
  }

  conversationMessages.push({
    role: 'user',
    content,
  });

  // Generate assistant message ID
  const assistantMessageId = uuidv4();
  setCurrentMessageId(sessionId, assistantMessageId);

  onEvent({
    type: 'stream_start',
    sessionId,
    messageId: assistantMessageId,
  });

  // Abort controller for stopping
  const abortController = new AbortController();
  activeProcesses.set(sessionId, abortController);

  try {
    await runWithCcHahaServer(
      session,
      conversationMessages,
      assistantMessageId,
      onEvent,
      claudeHahaPath,
      abortController.signal,
    );
  } catch (serverErr) {
    console.error(
      '[claude-bridge] Server mode failed for session ' + sessionId + ':',
      serverErr,
    );
    try {
      await runWithCcHahaPrint(
        session,
        conversationMessages,
        assistantMessageId,
        onEvent,
        claudeHahaPath,
        abortController.signal,
      );
    } catch (printErr) {
      console.error(
        '[claude-bridge] Print mode also failed for session ' + sessionId + ':',
        printErr,
      );
      onEvent({
        type: 'error',
        sessionId,
        code: 'claude_error',
        message: 'Failed to communicate with cc-haha: ' + (printErr as Error).message,
      });
      updateSessionStatus(sessionId, 'error');
      return;
    }
  }

  // Add assistant message to history
  const assistantMsg: ChatMessage = {
    id: assistantMessageId,
    role: 'assistant',
    content: [{ type: 'text', text: '' }],
    timestamp: Date.now(),
  };
  addMessage(sessionId, assistantMsg);

  updateSessionStatus(sessionId, 'idle');
  setCurrentMessageId(sessionId, null);
  activeProcesses.delete(sessionId);
}

// ---------------------------------------------------------------------------
// Run cc-haha via --server mode (HTTP-based communication)
// ---------------------------------------------------------------------------

async function runWithCcHahaServer(
  session: Session,
  messages: Array<{ role: string; content: ContentBlock[] }>,
  assistantMessageId: string,
  onEvent: StreamCallback,
  claudeHahaPath: string,
  signal: AbortSignal,
): Promise<void> {
  const serverPort = await findFreePort();

  console.log(
    '[claude-bridge] Starting cc-haha server on port ' + serverPort + ' for session ' + session.id,
  );

  const proc = spawn({
    cmd: ['bun', 'run', claudeHahaPath],
    args: ['--server', '--port', String(serverPort)],
    cwd: session.workDir,
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      ...process.env,
      HOME: process.env.HOME || process.env.USERPROFILE || '/root',
    },
  });

  // Read stderr for logging
  const stderrDecoder = new TextDecoder();
  const stderrReader = proc.stderr?.getReader();
  if (stderrReader) {
    (async () => {
      try {
        while (true) {
          const { done, value } = await stderrReader.read();
          if (done) break;
          console.log(
            '[claude-bridge][stderr][' + session.id + '] ' + stderrDecoder.decode(value),
          );
        }
      } catch {
        // Stream closed
      }
    })();
  }

  // Wait for server to be ready
  await waitForServer('http://127.0.0.1:' + serverPort + '/health', 15000);

  console.log(
    '[claude-bridge] cc-haha server ready on port ' + serverPort,
  );

  // Send conversation via cc-haha's API
  const requestBody = JSON.stringify({
    model: session.model,
    messages: messages.map((m) => ({
      role: m.role,
      content: m.content,
    })),
    stream: true,
    max_tokens: 8192,
  });

  const response = await fetch(
    'http://127.0.0.1:' + serverPort + '/v1/messages',
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      },
      body: requestBody,
      signal: signal,
    },
  );

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      'cc-haha server returned ' + response.status + ': ' + errorText,
    );
  }

  // Parse SSE stream
  const reader = response.body?.getReader();
  if (!reader) {
    throw new Error('No response body from cc-haha server');
  }

  const textDecoder = new TextDecoder();
  let buffer = '';
  let fullContent = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += textDecoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
      if (line.startsWith('data: ')) {
        const jsonStr = line.slice(6).trim();
        if (jsonStr === '[DONE]') {
          break;
        }

        try {
          const event = JSON.parse(jsonStr);
          fullContent = processCcHahaServerEvent(
            event,
            session.id,
            assistantMessageId,
            fullContent,
            onEvent,
          );
        } catch {
          // Skip unparseable lines
        }
      }
    }
  }

  // Send completion
  onEvent({
    type: 'message_complete',
    sessionId: session.id,
    messageId: assistantMessageId,
    usage: { input: 0, output: 0 },
  });

  // Clean up: stop the server
  try {
    proc.kill('SIGTERM');
    console.log(
      '[claude-bridge] Stopped cc-haha server for session ' + session.id,
    );
  } catch {
    // Process may already be dead
  }
}

// ---------------------------------------------------------------------------
// Process an SSE event from cc-haha's server API
// ---------------------------------------------------------------------------

function processCcHahaServerEvent(
  event: Record<string, unknown>,
  sessionId: string,
  messageId: string,
  fullContent: string,
  onEvent: StreamCallback,
): string {
  const type = event['type'] as string | undefined;

  switch (type) {
    case 'content_block_start': {
      const contentBlock = event['content_block'] as
        | { type: string; text?: string }
        | undefined;
      if (contentBlock?.type === 'text' && contentBlock.text) {
        fullContent += contentBlock.text;
        onEvent({
          type: 'stream_delta',
          sessionId,
          messageId,
          content: contentBlock.text,
        });
      }
      break;
    }
    case 'content_block_delta': {
      const delta = event['delta'] as
        | { type: string; text?: string }
        | undefined;
      if (delta?.type === 'text_delta' && delta.text) {
        fullContent += delta.text;
        onEvent({
          type: 'stream_delta',
          sessionId,
          messageId,
          content: delta.text,
        });
      }
      break;
    }
    case 'content_block_stop': {
      break;
    }
    case 'message_delta': {
      const delta = event['delta'] as { stop_reason?: string } | undefined;
      if (delta?.stop_reason) {
        console.log(
          '[claude-bridge] Message stop reason: ' + delta.stop_reason,
        );
      }
      break;
    }
    case 'message_stop': {
      break;
    }
    default:
      break;
  }

  return fullContent;
}

// ---------------------------------------------------------------------------
// Run cc-haha in --print mode (stdio-based fallback)
// ---------------------------------------------------------------------------

async function runWithCcHahaPrint(
  session: Session,
  messages: Array<{ role: string; content: ContentBlock[] }>,
  assistantMessageId: string,
  onEvent: StreamCallback,
  claudeHahaPath: string,
  signal: AbortSignal,
): Promise<void> {
  console.log(
    '[claude-bridge] Starting cc-haha in --print mode for session ' + session.id,
  );

  const proc = spawn({
    cmd: ['bun', 'run', claudeHahaPath],
    args: ['--print', '--output-format', 'stream-json'],
    cwd: session.workDir,
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
    env: {
      ...process.env,
      HOME: process.env.HOME || process.env.USERPROFILE || '/root',
    },
  });

  // Read stderr
  const stderrDecoder = new TextDecoder();
  const stderrReader = proc.stderr?.getReader();
  if (stderrReader) {
    (async () => {
      try {
        while (true) {
          const { done, value } = await stderrReader.read();
          if (done) break;
          console.log(
            '[claude-bridge][print][stderr][' + session.id + '] ' + stderrDecoder.decode(value),
          );
        }
      } catch {
        // Stream closed
      }
    })();
  }

  // Send messages via stdin as NDJSON
  const stdinWriter = proc.stdin?.getWriter();
  if (!stdinWriter) {
    throw new Error('Failed to get stdin writer for cc-haha process');
  }

  for (const msg of messages) {
    const ndjson: NdJsonUserMessage = {
      type: 'user',
      message: {
        role: 'user',
        content: msg.content.map((block) => {
          if (block.type === 'text') {
            return { type: 'text', text: block.text };
          }
          if (block.type === 'image') {
            return {
              type: 'text',
              text: '[Image: ' + block.source.media_type + ']',
            } as { type: 'text'; text: string };
          }
          return { type: 'text', text: '' };
        }),
      },
    };

    const line = JSON.stringify(ndjson) + '\n';
    await stdinWriter.write(new TextEncoder().encode(line));
  }

  await stdinWriter.close();

  // Parse NDJSON stream from stdout
  const stdoutDecoder = new TextDecoder();
  const stdoutReader = proc.stdout?.getReader();
  if (!stdoutReader) {
    throw new Error('Failed to get stdout reader for cc-haha process');
  }

  let buffer = '';
  let fullContent = '';

  while (true) {
    const { done, value } = await stdoutReader.read();
    if (done) break;

    buffer += stdoutDecoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const event: NdJsonAssistantEvent = JSON.parse(trimmed);
        fullContent = processNdJsonEvent(
          event,
          session.id,
          assistantMessageId,
          fullContent,
          onEvent,
        );
      } catch {
        // Skip unparseable lines
      }
    }
  }

  const exitCode = await proc.exited;
  console.log(
    '[claude-bridge] cc-haha --print exited with code ' + exitCode + ' for session ' + session.id,
  );

  onEvent({
    type: 'message_complete',
    sessionId: session.id,
    messageId: assistantMessageId,
    usage: { input: 0, output: 0 },
  });
}

// ---------------------------------------------------------------------------
// Process a single NDJSON event from cc-haha's stdout
// ---------------------------------------------------------------------------

function processNdJsonEvent(
  event: NdJsonAssistantEvent,
  sessionId: string,
  messageId: string,
  fullContent: string,
  onEvent: StreamCallback,
): string {
  switch (event.type) {
    case 'stream_event': {
      const msg = event.message;
      if (!msg || !msg.content) break;

      for (const block of msg.content) {
        if (block.type === 'text' && block.text) {
          fullContent += block.text;
          onEvent({
            type: 'stream_delta',
            sessionId,
            messageId,
            content: block.text,
          });
        } else if (block.type === 'tool_use') {
          onEvent({
            type: 'tool_use',
            sessionId,
            tool: {
              name: block.name || 'unknown',
              input: block.input || {},
              status: 'running',
            },
          });
        }
      }
      break;
    }
    case 'assistant': {
      const msg = event.message;
      if (msg?.content) {
        for (const block of msg.content) {
          if (block.type === 'text' && block.text && !fullContent.includes(block.text)) {
            fullContent += block.text;
            onEvent({
              type: 'stream_delta',
              sessionId,
              messageId,
              content: block.text,
            });
          }
        }
      }
      break;
    }
    case 'result': {
      if (event.message?.usage) {
        onEvent({
          type: 'message_complete',
          sessionId,
          messageId,
          usage: {
            input: event.message.usage.input_tokens,
            output: event.message.usage.output_tokens,
          },
        });
      }
      break;
    }
    case 'system': {
      if (event.message?.content?.[0]?.text) {
        onEvent({
          type: 'thinking',
          sessionId,
          content: event.message.content[0].text,
        });
      }
      break;
    }
    case 'error': {
      onEvent({
        type: 'error',
        sessionId,
        code: 'claude_error',
        message: event.error || 'Unknown error from cc-haha',
      });
      break;
    }
  }

  return fullContent;
}

// ---------------------------------------------------------------------------
// Stop current generation
// ---------------------------------------------------------------------------

export function stopGeneration(sessionId: string): void {
  const controller = activeProcesses.get(sessionId);
  if (controller) {
    controller.abort();
    activeProcesses.delete(sessionId);
    console.log('[claude-bridge] Stopped generation for session ' + sessionId);
  }
}

// ---------------------------------------------------------------------------
// Utility: find a free TCP port
// ---------------------------------------------------------------------------

async function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const net = require('node:net');
    const server = net.createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      const port = addr ? addr.port : 0;
      server.close(() => resolve(port));
    });
  });
}

// ---------------------------------------------------------------------------
// Utility: wait for HTTP server to be ready
// ---------------------------------------------------------------------------

async function waitForServer(
  url: string,
  timeoutMs: number,
): Promise<void> {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    try {
      const response = await fetch(url, {
        signal: AbortSignal.timeout(2000),
      });
      if (response.ok || response.status === 404) {
        return;
      }
    } catch {
      // Server not ready yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }

  throw new Error('Server at ' + url + ' did not become ready within ' + timeoutMs + 'ms');
}
