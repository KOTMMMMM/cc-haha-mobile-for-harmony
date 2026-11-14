// ============================================================================
// Authentication module - pairing codes and JWT tokens
// ============================================================================

import type {
  PairingCode,
  PairingRequest,
  PairingVerifyRequest,
  JwtPayload,
} from './types.js';
import type { IncomingMessage, ServerResponse } from 'node:http';
import crypto from 'node:crypto';

// ---------------------------------------------------------------------------
// Pairing code store
// ---------------------------------------------------------------------------

const pairingStore = new Map<string, PairingCode>();

const cleanupInterval = setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of pairingStore) {
    if (entry.expiresAt <= now) {
      pairingStore.delete(key);
      console.log('[auth] Expired pairing code removed for device: ' + key);
    }
  }
}, 60_000);

if (cleanupInterval.unref) {
  cleanupInterval.unref();
}

// ---------------------------------------------------------------------------
// Pairing code generation
// ---------------------------------------------------------------------------

export function generatePairingCode(
  request: PairingRequest,
  expiryMs: number,
): PairingCode {
  if (pairingStore.has(request.deviceId)) {
    pairingStore.delete(request.deviceId);
    console.log(
      '[auth] Replaced existing pairing code for device: ' + request.deviceId,
    );
  }

  const code = crypto.randomInt(100000, 999999).toString();

  const pairingCode: PairingCode = {
    code,
    deviceId: request.deviceId,
    deviceName: request.deviceName,
    expiresAt: Date.now() + expiryMs,
    verified: false,
  };

  pairingStore.set(request.deviceId, pairingCode);

  console.log(
    '[auth] Generated pairing code ' + code + ' for device "' + request.deviceName + '" (' + request.deviceId + '), expires in ' + (expiryMs / 1000) + 's',
  );

  return pairingCode;
}

// ---------------------------------------------------------------------------
// Pairing code validation
// ---------------------------------------------------------------------------

export function verifyPairingCode(
  request: PairingVerifyRequest,
): { valid: boolean; deviceName?: string; error?: string } {
  const entry = pairingStore.get(request.deviceId);

  if (!entry) {
    console.log('[auth] No pairing code found for device: ' + request.deviceId);
    return { valid: false, error: 'no_pending_code' };
  }

  if (entry.expiresAt <= Date.now()) {
    pairingStore.delete(request.deviceId);
    console.log('[auth] Pairing code expired for device: ' + request.deviceId);
    return { valid: false, error: 'code_expired' };
  }

  if (entry.code !== request.code) {
    console.log(
      '[auth] Invalid pairing code for device: ' + request.deviceId + ' (expected: ' + entry.code + ', got: ' + request.code + ')',
    );
    return { valid: false, error: 'invalid_code' };
  }

  entry.verified = true;
  console.log(
    '[auth] Pairing code verified for device "' + entry.deviceName + '" (' + request.deviceId + ')',
  );

  return { valid: true, deviceName: entry.deviceName };
}

// ---------------------------------------------------------------------------
// Cleanup pairing code after successful auth
// ---------------------------------------------------------------------------

export function consumePairingCode(deviceId: string): boolean {
  return pairingStore.delete(deviceId);
}

// ---------------------------------------------------------------------------
// JWT token generation (HMAC-SHA256)
// ---------------------------------------------------------------------------

export function generateJwt(
  deviceId: string,
  deviceName: string,
  secret: string,
  expiryMs: number = 30 * 24 * 60 * 60 * 1000,
): string {
  const header = {
    alg: 'HS256',
    typ: 'JWT',
  };

  const now = Math.floor(Date.now() / 1000);
  const payload: JwtPayload = {
    deviceId,
    deviceName,
    iat: now,
    exp: now + Math.floor(expiryMs / 1000),
  };

  const base64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const base64Payload = Buffer.from(JSON.stringify(payload)).toString(
    'base64url',
  );

  const signingInput = [base64Header, base64Payload].join('.');
  const signature = crypto
    .createHmac('sha256', secret)
    .update(signingInput)
    .digest('base64url');

  const token = [signingInput, signature].join('.');
  console.log(
    '[auth] Generated JWT for device "' + deviceName + '" (' + deviceId + '), expires in ' + (expiryMs / 1000) + 's',
  );

  return token;
}

// ---------------------------------------------------------------------------
// JWT verification
// ---------------------------------------------------------------------------

export function verifyJwt(
  token: string,
  secret: string,
): { valid: boolean; payload?: JwtPayload; error?: string } {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) {
      return { valid: false, error: 'invalid_token_format' };
    }

    const [base64Header, base64Payload, signature] = parts;
    const signingInput = [base64Header, base64Payload].join('.');

    const expectedSig = crypto
      .createHmac('sha256', secret)
      .update(signingInput)
      .digest('base64url');

    if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expectedSig))) {
      return { valid: false, error: 'invalid_signature' };
    }

    const payload: JwtPayload = JSON.parse(
      Buffer.from(base64Payload, 'base64url').toString('utf8'),
    );

    const now = Math.floor(Date.now() / 1000);
    if (payload.exp <= now) {
      return { valid: false, error: 'token_expired' };
    }

    return { valid: true, payload };
  } catch (err) {
    console.error('[auth] JWT verification error:', err);
    return { valid: false, error: 'invalid_token' };
  }
}

// ---------------------------------------------------------------------------
// JWT extraction from request
// ---------------------------------------------------------------------------

export function extractJwt(req: IncomingMessage): string | null {
  const authHeader = req.headers['authorization'];
  if (authHeader) {
    const bearerRegex = /^Bearer[ \t]+(.+)/i;
    const match = authHeader.match(bearerRegex);
    if (match && match[1]) {
      return match[1];
    }
  }

  try {
    const url = new URL(
      req.url || '/',
      'http://' + (req.headers.host || 'localhost'),
    );
    const token = url.searchParams.get('token');
    if (token) {
      return token;
    }
  } catch {
    // URL parsing failed
  }

  return null;
}

// ---------------------------------------------------------------------------
// JWT auth middleware helper
// ---------------------------------------------------------------------------

export function authenticateRequest(
  req: IncomingMessage,
  res: ServerResponse,
  secret: string,
): { authenticated: boolean; payload?: JwtPayload } {
  const token = extractJwt(req);

  if (!token) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        success: false,
        error: 'Authentication required. Provide Bearer token or ?token= query parameter.',
        code: 'unauthorized',
      }),
    );
    return { authenticated: false };
  }

  const result = verifyJwt(token, secret);
  if (!result.valid) {
    const statusCode = result.error === 'token_expired' ? 401 : 403;
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        success: false,
        error: 'Authentication failed: ' + result.error,
        code: result.error,
      }),
    );
    return { authenticated: false };
  }

  return { authenticated: true, payload: result.payload };
}
