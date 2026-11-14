// ============================================================================
// REST API Routes - HTTP request routing using Node.js built-in http module
// ============================================================================

import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Config } from '../config.js';
import type { ApiResponse, CreateSessionRequest, FileInfo, ModelProvider } from '../types.js';
import {
  generatePairingCode,
  verifyPairingCode,
  generateJwt,
  consumePairingCode,
  authenticateRequest,
} from '../auth.js';
import {
  createSession,
  listSessions,
  getSession,
  killSession,
  getMessages,
} from '../session-manager.js';
import { stopGeneration } from '../claude-bridge.js';
import { readdirSync, statSync, existsSync } from 'node:fs';
import { join, resolve, normalize } from 'node:path';

// ---------------------------------------------------------------------------
// Route handler type
// ---------------------------------------------------------------------------

type RouteHandler = (
  req: IncomingMessage,
  res: ServerResponse,
  config: Config,
  url: URL,
  pathParts: string[],
) => void | Promise<void>;

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

const routes = new Map<string, RouteHandler>();

function registerRoute(method: string, pattern: string, handler: RouteHandler): void {
  const key = method + ':' + pattern;
  routes.set(key, handler);
  console.log('[routes] Registered ' + key);
}

// ---------------------------------------------------------------------------
// CORS and JSON helpers
// ---------------------------------------------------------------------------

function corsHeaders(res: ServerResponse): void {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Max-Age', '86400');
}

function jsonResponse(
  res: ServerResponse,
  statusCode: number,
  body: ApiResponse,
): void {
  corsHeaders(res);
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function parseBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw.trim()) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(new Error('Invalid JSON: ' + (err as Error).message));
      }
    });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Register all routes
// ---------------------------------------------------------------------------

export function registerRoutes(config: Config): void {
  // -- Health check --
  registerRoute('GET', '/health', (_req, res) => {
    jsonResponse(res, 200, {
      success: true,
      data: {
        status: 'ok',
        uptime: process.uptime(),
        timestamp: Date.now(),
        version: '1.0.0',
      },
    });
  });

  // -- Pairing: request --
  registerRoute('POST', '/api/pair/request', async (req, res, config) => {
    try {
      const body = await parseBody(req);
      const { deviceName, deviceId } = body;

      if (!deviceName || typeof deviceName !== 'string') {
        jsonResponse(res, 400, {
          success: false,
          error: 'deviceName is required',
          code: 'missing_field',
        });
        return;
      }

      if (!deviceId || typeof deviceId !== 'string') {
        jsonResponse(res, 400, {
          success: false,
          error: 'deviceId is required',
          code: 'missing_field',
        });
        return;
      }

      const pairingCode = generatePairingCode(
        { deviceName, deviceId },
        config.pairingCodeExpiryMs,
      );

      jsonResponse(res, 200, {
        success: true,
        data: {
          code: pairingCode.code,
          expiresAt: pairingCode.expiresAt,
          deviceId: pairingCode.deviceId,
        },
      });
    } catch (err) {
      jsonResponse(res, 500, {
        success: false,
        error: 'Failed to create pairing request: ' + (err as Error).message,
        code: 'internal_error',
      });
    }
  });

  // -- Pairing: verify --
  registerRoute('POST', '/api/pair/verify', async (req, res, config) => {
    try {
      const body = await parseBody(req);
      const { deviceId, code } = body;

      if (!deviceId || typeof deviceId !== 'string') {
        jsonResponse(res, 400, {
          success: false,
          error: 'deviceId is required',
          code: 'missing_field',
        });
        return;
      }

      if (!code || typeof code !== 'string') {
        jsonResponse(res, 400, {
          success: false,
          error: 'code (6-digit pairing code) is required',
          code: 'missing_field',
        });
        return;
      }

      if (!/^[0-9]{6}$/.test(code)) {
        jsonResponse(res, 400, {
          success: false,
          error: 'Invalid code format. Must be a 6-digit number.',
          code: 'invalid_code_format',
        });
        return;
      }

      const result = verifyPairingCode({ deviceId, code });

      if (!result.valid) {
        const statusCode =
          result.error === 'code_expired' ? 410 :
          result.error === 'invalid_code' ? 403 :
          400;

        jsonResponse(res, statusCode, {
          success: false,
          error: mapPairingError(result.error || 'unknown_error'),
          code: result.error || 'unknown_error',
        });
        return;
      }

      const token = generateJwt(
        deviceId,
        result.deviceName || 'Unknown Device',
        config.jwtSecret,
      );

      consumePairingCode(deviceId);

      jsonResponse(res, 200, {
        success: true,
        data: {
          token,
          deviceName: result.deviceName,
          deviceId,
        },
      });
    } catch (err) {
      jsonResponse(res, 500, {
        success: false,
        error: 'Failed to verify pairing code: ' + (err as Error).message,
        code: 'internal_error',
      });
    }
  });

  // -- Sessions: list (auth required) --
  registerRoute('GET', '/api/sessions', (req, res, config) => {
    const auth = authenticateRequest(req, res, config.jwtSecret);
    if (!auth.authenticated) return;

    const sessions = listSessions();

    jsonResponse(res, 200, {
      success: true,
      data: sessions,
    });
  });

  // -- Sessions: create (auth required) --
  registerRoute('POST', '/api/sessions', async (req, res, config) => {
    const auth = authenticateRequest(req, res, config.jwtSecret);
    if (!auth.authenticated) return;

    try {
      const body = (await parseBody(req)) as CreateSessionRequest;
      const result = createSession(body.workDir, body.model, config.claudeHahaPath);

      if ('error' in result) {
        jsonResponse(res, 400, {
          success: false,
          error: result.error,
          code: 'session_error',
        });
        return;
      }

      jsonResponse(res, 201, {
        success: true,
        data: {
          id: result.id,
          workDir: result.workDir,
          status: result.status,
          model: result.model,
          createdAt: result.createdAt,
        },
      });
    } catch (err) {
      jsonResponse(res, 500, {
        success: false,
        error: 'Failed to create session: ' + (err as Error).message,
        code: 'internal_error',
      });
    }
  });

  // -- Sessions: delete (auth required) --
  registerRoute('DELETE', '/api/sessions/:id', (req, res, config, _url, pathParts) => {
    const auth = authenticateRequest(req, res, config.jwtSecret);
    if (!auth.authenticated) return;

    const sessionId = pathParts[2];
    if (!sessionId) {
      jsonResponse(res, 400, {
        success: false,
        error: 'Session ID is required',
        code: 'missing_field',
      });
      return;
    }

    const killed = killSession(sessionId);
    if (!killed) {
      jsonResponse(res, 404, {
        success: false,
        error: 'Session ' + sessionId + ' not found',
        code: 'not_found',
      });
      return;
    }

    jsonResponse(res, 200, {
      success: true,
      data: { id: sessionId, killed: true },
    });
  });

  // -- Sessions: get messages (auth required) --
  registerRoute(
    'GET',
    '/api/sessions/:id/messages',
    (req, res, config, _url, pathParts) => {
      const auth = authenticateRequest(req, res, config.jwtSecret);
      if (!auth.authenticated) return;

      const sessionId = pathParts[2];
      if (!sessionId) {
        jsonResponse(res, 400, {
          success: false,
          error: 'Session ID is required',
          code: 'missing_field',
        });
        return;
      }

      const session = getSession(sessionId);
      if (!session) {
        jsonResponse(res, 404, {
          success: false,
          error: 'Session ' + sessionId + ' not found',
          code: 'not_found',
        });
        return;
      }

      jsonResponse(res, 200, {
        success: true,
        data: getMessages(sessionId),
      });
    },
  );

  // -- Sessions: stop generation (auth required) --
  registerRoute(
    'POST',
    '/api/sessions/:id/stop',
    (req, res, config, _url, pathParts) => {
      const auth = authenticateRequest(req, res, config.jwtSecret);
      if (!auth.authenticated) return;

      const sessionId = pathParts[2];
      if (!sessionId) {
        jsonResponse(res, 400, {
          success: false,
          error: 'Session ID is required',
          code: 'missing_field',
        });
        return;
      }

      const session = getSession(sessionId);
      if (!session) {
        jsonResponse(res, 404, {
          success: false,
          error: 'Session ' + sessionId + ' not found',
          code: 'not_found',
        });
        return;
      }

      stopGeneration(sessionId);

      jsonResponse(res, 200, {
        success: true,
        data: { id: sessionId, stopped: true },
      });
    },
  );

  // -- Files: list (auth required) --
  registerRoute('GET', '/api/files', (req, res, config, url) => {
    const auth = authenticateRequest(req, res, config.jwtSecret);
    if (!auth.authenticated) return;

    const requestedPath = url.searchParams.get('path') || '/';
    const sessionId = url.searchParams.get('sessionId');

    let baseDir = process.cwd();
    if (sessionId) {
      const session = getSession(sessionId);
      if (session) {
        baseDir = session.workDir;
      }
    }

    try {
      const safePath = normalize(requestedPath).replace(/^(\.\.[/\])+/, '');
      const fullPath = resolve(baseDir, safePath.startsWith('/') ? safePath.slice(1) : safePath);

      if (!fullPath.startsWith(baseDir) && !fullPath.startsWith('/tmp')) {
        jsonResponse(res, 403, {
          success: false,
          error: 'Access denied: path outside workspace',
          code: 'forbidden',
        });
        return;
      }

      if (!existsSync(fullPath)) {
        jsonResponse(res, 404, {
          success: false,
          error: 'Path not found: ' + requestedPath,
          code: 'not_found',
        });
        return;
      }

      const entries = readdirSync(fullPath);
      const files: FileInfo[] = [];

      for (const name of entries) {
        if (name.startsWith('.') && url.searchParams.get('showHidden') !== 'true') {
          continue;
        }

        try {
          const entryPath = join(fullPath, name);
          const stat = statSync(entryPath);

          files.push({
            name,
            path: join(requestedPath, name).replace(/\/g, '/'),
            type: stat.isDirectory() ? 'directory' : 'file',
            size: stat.isFile() ? stat.size : undefined,
            modifiedAt: stat.mtimeMs,
          });
        } catch {
          // Skip entries we cannot stat
        }
      }

      files.sort((a, b) => {
        if (a.type !== b.type) {
          return a.type === 'directory' ? -1 : 1;
        }
        return a.name.localeCompare(b.name);
      });

      jsonResponse(res, 200, {
        success: true,
        data: {
          path: requestedPath,
          entries: files,
        },
      });
    } catch (err) {
      jsonResponse(res, 500, {
        success: false,
        error: 'Failed to list files: ' + (err as Error).message,
        code: 'internal_error',
      });
    }
  });

  // -- Providers: list (auth required) --
  registerRoute('GET', '/api/providers', (req, res, config) => {
    const auth = authenticateRequest(req, res, config.jwtSecret);
    if (!auth.authenticated) return;

    const providers: ModelProvider[] = [
      {
        id: 'anthropic',
        name: 'Anthropic',
        models: [
          { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4', maxTokens: 200000 },
          { id: 'claude-opus-4-20250514', name: 'Claude Opus 4', maxTokens: 200000 },
          { id: 'claude-3.5-sonnet', name: 'Claude 3.5 Sonnet', maxTokens: 200000 },
          { id: 'claude-3.5-haiku', name: 'Claude 3.5 Haiku', maxTokens: 200000 },
        ],
      },
      {
        id: 'openai',
        name: 'OpenAI',
        models: [
          { id: 'gpt-4o', name: 'GPT-4o', maxTokens: 128000 },
          { id: 'gpt-4o-mini', name: 'GPT-4o Mini', maxTokens: 128000 },
        ],
      },
    ];

    jsonResponse(res, 200, {
      success: true,
      data: providers,
    });
  });

  console.log('[routes] Registered ' + routes.size + ' routes');
}

// ---------------------------------------------------------------------------
// Route matching
// ---------------------------------------------------------------------------

function matchRoute(
  method: string,
  pathname: string,
): { handler: RouteHandler; pathParts: string[] } | null {
  const exactKey = method + ':' + pathname;
  const exactHandler = routes.get(exactKey);
  if (exactHandler) {
    return { handler: exactHandler, pathParts: pathname.split('/') };
  }

  const pathParts = pathname.split('/');

  for (const [key, handler] of routes) {
    const [routeMethod, routePattern] = key.split(':');
    if (routeMethod !== method) continue;

    const patternParts = routePattern.split('/');

    if (patternParts.length !== pathParts.length) continue;

    let match = true;
    for (let i = 0; i < patternParts.length; i++) {
      if (patternParts[i].startsWith(':')) {
        continue;
      }
      if (patternParts[i] !== pathParts[i]) {
        match = false;
        break;
      }
    }

    if (match) {
      return { handler, pathParts };
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Main request handler
// ---------------------------------------------------------------------------

export function handleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  config: Config,
): void {
  const method = req.method || 'GET';

  if (method === 'OPTIONS') {
    corsHeaders(res);
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(
    req.url || '/',
    'http://' + (req.headers.host || 'localhost'),
  );
  const pathname = url.pathname;

  console.log('[routes] ' + method + ' ' + pathname);

  const match = matchRoute(method, pathname);

  if (!match) {
    corsHeaders(res);
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        success: false,
        error: 'Not found: ' + method + ' ' + pathname,
        code: 'not_found',
      }),
    );
    return;
  }

  try {
    const result = match.handler(req, res, config, url, match.pathParts);
    if (result instanceof Promise) {
      result.catch((err) => {
        console.error('[routes] Unhandled error in ' + method + ' ' + pathname + ':', err);
        if (!res.writableEnded) {
          jsonResponse(res, 500, {
            success: false,
            error: 'Internal server error: ' + (err as Error).message,
            code: 'internal_error',
          });
        }
      });
    }
  } catch (err) {
    console.error('[routes] Error handling ' + method + ' ' + pathname + ':', err);
    if (!res.writableEnded) {
      jsonResponse(res, 500, {
        success: false,
        error: 'Internal server error: ' + (err as Error).message,
        code: 'internal_error',
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Error message mapping
// ---------------------------------------------------------------------------

function mapPairingError(error: string): string {
  switch (error) {
    case 'no_pending_code':
      return 'No pending pairing request for this device. Please request a new code on the PC.';
    case 'code_expired':
      return 'Pairing code has expired. Please request a new code.';
    case 'invalid_code':
      return 'Invalid pairing code. Please check the code and try again.';
    default:
      return 'Pairing verification failed.';
  }
}
