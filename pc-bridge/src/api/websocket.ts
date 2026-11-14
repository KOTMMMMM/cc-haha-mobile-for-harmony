// ============================================================================
// WebSocket Handler - real-time bidirectional communication with mobile app
// ============================================================================

import type { Server as HttpServer, IncomingMessage } from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import type { Config } from '../config.js';
import type {
  WsClientMessage,
  WsServerMessage,
  StreamEvent,
  PermissionRequestEvent,
} from '../types.js';
import { verifyJwt, extractJwt, type JwtPayload } from '../auth.js';
import {
  getSession,
  createSession,
  updateSessionStatus,
} from '../session-manager.js';
import {
  sendChatMessage,
  stopGeneration,
  setPermissionCallback,
} from '../claude-bridge.js';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let wss: WebSocketServer | null = null;

const sessionClients = new Map<string, Set<WebSocket>>();

interface ClientInfo {
  ws: WebSocket;
  jwtPayload: JwtPayload;
  subscribedSessionIds: Set<string>;
  alive: boolean;
}
const clients = new Map<WebSocket, ClientInfo>();

let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

const permissionRequests = new Map<
  string,
  {
    resolve: (decision: 'allow' | 'deny' | 'always') => void;
    timer: ReturnType<typeof setTimeout>;
    sessionId: string;
  }
>();

// ---------------------------------------------------------------------------
// Start WebSocket server
// ---------------------------------------------------------------------------

export function startWebSocketServer(
  httpServer: HttpServer,
  config: Config,
): void {
  console.log('[websocket] Starting WebSocket server...');

  wss = new WebSocketServer({
    server: httpServer,
    maxPayload: 50 * 1024 * 1024,
  });

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    handleConnection(ws, req, config);
  });

  wss.on('error', (err: Error) => {
    console.error('[websocket] Server error:', err);
  });

  // Heartbeat every 30 seconds
  heartbeatTimer = setInterval(() => {
    if (!wss) return;

    for (const client of wss.clients) {
      const info = clients.get(client);
      if (!info) continue;

      if (!info.alive) {
        console.log('[websocket] Client heartbeat timeout, terminating');
        client.terminate();
        continue;
      }

      info.alive = false;
      try {
        client.ping();
      } catch {
        // Client may be disconnecting
      }
    }
  }, 30_000);

  if (heartbeatTimer.unref) {
    heartbeatTimer.unref();
  }

  console.log('[websocket] WebSocket server started');
}

// ---------------------------------------------------------------------------
// Handle new WebSocket connection
// ---------------------------------------------------------------------------

function handleConnection(
  ws: WebSocket,
  req: IncomingMessage,
  config: Config,
): void {
  const token = extractJwt(req);

  if (!token) {
    console.log('[websocket] Connection rejected: no token provided');
    sendWs(ws, {
      type: 'error',
      sessionId: '',
      code: 'unauthorized',
      message: 'Authentication required. Provide ?token=JWT parameter.',
    });
    ws.close(4001, 'Authentication required');
    return;
  }

  const jwtResult = verifyJwt(token, config.jwtSecret);

  if (!jwtResult.valid || !jwtResult.payload) {
    console.log(
      '[websocket] Connection rejected: invalid token (' + jwtResult.error + ')',
    );
    sendWs(ws, {
      type: 'error',
      sessionId: '',
      code: 'unauthorized',
      message: 'Authentication failed: ' + jwtResult.error,
    });
    ws.close(4001, 'Authentication failed');
    return;
  }

  const payload = jwtResult.payload;
  console.log(
    '[websocket] Client connected: device="' + payload.deviceName + '" (' + payload.deviceId + ')',
  );

  const clientInfo: ClientInfo = {
    ws,
    jwtPayload: payload,
    subscribedSessionIds: new Set(),
    alive: true,
  };
  clients.set(ws, clientInfo);

  ws.on('pong', () => {
    const info = clients.get(ws);
    if (info) {
      info.alive = true;
    }
  });

  ws.on('message', (data: Buffer | ArrayBuffer | Buffer[]) => {
    handleIncomingMessage(ws, data, config);
  });

  ws.on('close', (code: number, reason: Buffer) => {
    console.log(
      '[websocket] Client disconnected: device="' + payload.deviceName + '" (code: ' + code + ', reason: ' + reason.toString() + ')',
    );

    const info = clients.get(ws);
    if (info) {
      for (const sessionId of info.subscribedSessionIds) {
        const sessionSet = sessionClients.get(sessionId);
        if (sessionSet) {
          sessionSet.delete(ws);
          if (sessionSet.size === 0) {
            sessionClients.delete(sessionId);
          }
        }
      }
    }

    clients.delete(ws);
  });

  ws.on('error', (err: Error) => {
    console.error(
      '[websocket] Client error (device="' + payload.deviceName + '"): ' + err.message,
    );
  });
}

// ---------------------------------------------------------------------------
// Handle incoming WebSocket messages
// ---------------------------------------------------------------------------

function handleIncomingMessage(
  ws: WebSocket,
  data: Buffer | ArrayBuffer | Buffer[],
  config: Config,
): void {
  try {
    const raw = Buffer.isBuffer(data)
      ? data.toString('utf8')
      : data instanceof ArrayBuffer
        ? new TextDecoder().decode(data)
        : Buffer.concat(data).toString('utf8');

    const message: WsClientMessage = JSON.parse(raw);

    console.log(
      '[websocket] Received: type=' + message.type + ', sessionId=' + message.sessionId,
    );

    switch (message.type) {
      case 'chat':
        handleChatMessage(ws, message, config);
        break;
      case 'permission':
        handlePermissionMessage(message);
        break;
      case 'stop':
        handleStopMessage(message);
        break;
      case 'resume':
        handleResumeMessage(ws, message, config);
        break;
      default:
        console.warn('[websocket] Unknown message type: ' + (message as { type: string }).type);
        sendWs(ws, {
          type: 'error',
          sessionId: (message as { sessionId?: string }).sessionId || '',
          code: 'unknown_message_type',
          message: 'Unknown message type: ' + (message as { type: string }).type,
        });
    }
  } catch (err) {
    console.error('[websocket] Failed to parse message:', err);
    sendWs(ws, {
      type: 'error',
      sessionId: '',
      code: 'parse_error',
      message: 'Failed to parse message: ' + (err as Error).message,
    });
  }
}

// ---------------------------------------------------------------------------
// Handle chat message
// ---------------------------------------------------------------------------

async function handleChatMessage(
  ws: WebSocket,
  message: { sessionId: string; message: string; attachments?: Array<{ name: string; mimeType: string; data: string; size: number }> },
  config: Config,
): Promise<void> {
  const { sessionId, message: userMessage, attachments } = message;

  let session = getSession(sessionId);
  if (!session) {
    const result = createSession(undefined, undefined, config.claudeHahaPath);
    if ('error' in result) {
      sendWs(ws, {
        type: 'error',
        sessionId,
        code: 'session_error',
        message: result.error,
      });
      return;
    }
    session = result;
  }

  subscribeClientToSession(ws, sessionId);

  const streamCallback = (event: StreamEvent): void => {
    const sessionClients = getSubscribedClients(event.sessionId);
    for (const client of sessionClients) {
      sendWs(client, event as WsServerMessage);
    }
  };

  sendWs(ws, {
    type: 'status',
    sessionId,
    status: 'generating',
  });

  await sendChatMessage(
    sessionId,
    userMessage,
    attachments,
    streamCallback,
    config.claudeHahaPath,
  );

  sendWs(ws, {
    type: 'status',
    sessionId,
    status: 'idle',
  });
}

// ---------------------------------------------------------------------------
// Handle permission response
// ---------------------------------------------------------------------------

function handlePermissionMessage(message: {
  sessionId: string;
  requestId: string;
  decision: 'allow' | 'deny' | 'always';
}): void {
  const { requestId, decision } = message;

  const pending = permissionRequests.get(requestId);
  if (!pending) {
    console.warn(
      '[websocket] No pending permission request for ID: ' + requestId,
    );
    return;
  }

  console.log(
    '[websocket] Permission decision for ' + requestId + ': ' + decision,
  );

  clearTimeout(pending.timer);
  pending.resolve(decision);
  permissionRequests.delete(requestId);
}

// ---------------------------------------------------------------------------
// Handle stop generation
// ---------------------------------------------------------------------------

function handleStopMessage(message: { sessionId: string }): void {
  const { sessionId } = message;
  console.log('[websocket] Stop requested for session ' + sessionId);

  stopGeneration(sessionId);
  updateSessionStatus(sessionId, 'idle');
}

// ---------------------------------------------------------------------------
// Handle resume session
// ---------------------------------------------------------------------------

function handleResumeMessage(
  ws: WebSocket,
  message: { sessionId: string },
  _config: Config,
): void {
  const { sessionId } = message;

  const session = getSession(sessionId);
  if (!session) {
    sendWs(ws, {
      type: 'error',
      sessionId,
      code: 'session_not_found',
      message: 'Session ' + sessionId + ' not found',
    });
    return;
  }

  subscribeClientToSession(ws, sessionId);

  sendWs(ws, {
    type: 'connected',
    sessionId,
  });

  sendWs(ws, {
    type: 'status',
    sessionId,
    status: session.status,
  });

  console.log('[websocket] Client resumed session ' + sessionId);
}

// ---------------------------------------------------------------------------
// Subscribe a WebSocket client to a session
// ---------------------------------------------------------------------------

function subscribeClientToSession(ws: WebSocket, sessionId: string): void {
  const info = clients.get(ws);
  if (!info) return;

  info.subscribedSessionIds.add(sessionId);

  let sessionSet = sessionClients.get(sessionId);
  if (!sessionSet) {
    sessionSet = new Set();
    sessionClients.set(sessionId, sessionSet);
  }
  sessionSet.add(ws);
}

// ---------------------------------------------------------------------------
// Get all subscribed clients for a session
// ---------------------------------------------------------------------------

function getSubscribedClients(sessionId: string): WebSocket[] {
  const sessionSet = sessionClients.get(sessionId);
  if (!sessionSet) return [];

  const active: WebSocket[] = [];
  for (const ws of sessionSet) {
    if (ws.readyState === WebSocket.OPEN) {
      active.push(ws);
    } else {
      sessionSet.delete(ws);
    }
  }

  return active;
}

// ---------------------------------------------------------------------------
// Permission request - send to mobile and wait for response
// ---------------------------------------------------------------------------

export function requestPermissionFromMobile(
  sessionId: string,
  tool: { name: string; input: Record<string, unknown>; description?: string },
  timeoutMs: number = 60_000,
): Promise<'allow' | 'deny' | 'always'> {
  return new Promise((resolve) => {
    const requestId = sessionId + '-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);

    const timer = setTimeout(() => {
      console.warn('[websocket] Permission request ' + requestId + ' timed out');
      permissionRequests.delete(requestId);
      resolve('deny');
    }, timeoutMs);

    permissionRequests.set(requestId, { resolve, timer, sessionId });

    const event: PermissionRequestEvent = {
      type: 'permission_request',
      sessionId,
      requestId,
      tool: {
        name: tool.name,
        input: tool.input,
        status: 'pending',
        description: tool.description,
      },
    };

    const subscribedClients = getSubscribedClients(sessionId);
    for (const client of subscribedClients) {
      sendWs(client, event);
    }

    console.log(
      '[websocket] Permission request sent: ' + requestId + ' for tool "' + tool.name + '"',
    );
  });
}

// ---------------------------------------------------------------------------
// Send a WebSocket message (safe wrapper)
// ---------------------------------------------------------------------------

function sendWs(ws: WebSocket, message: WsServerMessage): void {
  if (ws.readyState !== WebSocket.OPEN) {
    return;
  }

  try {
    const data = JSON.stringify(message);
    ws.send(data);
  } catch (err) {
    console.error(
      '[websocket] Failed to send message:',
      (err as Error).message,
    );
  }
}

// ---------------------------------------------------------------------------
// Broadcast to all clients subscribed to a session
// ---------------------------------------------------------------------------

export function broadcastToSession(
  sessionId: string,
  message: WsServerMessage,
): void {
  const subscribedClients = getSubscribedClients(sessionId);
  for (const client of subscribedClients) {
    sendWs(client, message);
  }
}

// ---------------------------------------------------------------------------
// Stop WebSocket server
// ---------------------------------------------------------------------------

export function stopWebSocketServer(): void {
  console.log('[websocket] Stopping WebSocket server...');

  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
    console.log('[websocket] Heartbeat stopped');
  }

  if (wss) {
    for (const client of wss.clients) {
      try {
        client.close(1001, 'Server shutting down');
      } catch {
        // Client may already be disconnected
      }
    }

    try {
      wss.close();
      console.log('[websocket] WebSocket server closed');
    } catch (err) {
      console.error('[websocket] Error closing WebSocket server:', err);
    }
    wss = null;
  }

  clients.clear();
  sessionClients.clear();
  permissionRequests.clear();

  console.log('[websocket] WebSocket server stopped');
}

// ---------------------------------------------------------------------------
// Set up permission callback for the claude bridge
// ---------------------------------------------------------------------------

export function initPermissionHandler(): void {
  setPermissionCallback(
    (sessionId, requestId, tool, resolve) => {
      console.log(
        '[websocket] Handling permission request: ' + requestId + ' for tool "' + tool.name + '"',
      );

      const subscribedClients = getSubscribedClients(sessionId);

      if (subscribedClients.length === 0) {
        console.log(
          '[websocket] No mobile clients for session ' + sessionId + ', auto-allowing',
        );
        resolve('allow');
        return;
      }

      requestPermissionFromMobile(sessionId, tool, 60_000).then(resolve);
    },
  );

  console.log('[websocket] Permission handler initialized');
}
