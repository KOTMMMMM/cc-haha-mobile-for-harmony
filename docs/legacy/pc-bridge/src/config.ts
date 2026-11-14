// ============================================================================
// Configuration - loaded from environment variables with defaults
// ============================================================================

import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

function envInt(key: string, fallback: number): number {
  const val = process.env[key];
  if (val === undefined || val === '') return fallback;
  const parsed = parseInt(val, 10);
  if (isNaN(parsed)) return fallback;
  return parsed;
}

function envBool(key: string, fallback: boolean): boolean {
  const val = process.env[key];
  if (val === undefined || val === '') return fallback;
  return val.toLowerCase() === 'true' || val === '1';
}

function envStr(key: string, fallback: string): string {
  const val = process.env[key];
  if (val === undefined || val === '') return fallback;
  return val;
}

export interface Config {
  port: number;
  host: string;
  claudeHahaPath: string;
  pairingCodeExpiryMs: number;
  jwtSecret: string;
  maxSessions: number;
  discoveryEnabled: boolean;
  discoveryPort: number;
  discoveryIntervalMs: number;
  logLevel: string;
}

export function loadConfig(): Config {
  let jwtSecret = process.env['JWT_SECRET'];
  if (!jwtSecret || jwtSecret === '') {
    const randomBytes = new Uint8Array(32);
    const crypto = require('node:crypto');
    crypto.getRandomValues(randomBytes);
    jwtSecret = Buffer.from(randomBytes).toString('hex');
    console.warn(
      '[config] WARNING: JWT_SECRET not set. Using randomly generated secret.',
    );
    console.warn(
      '[config] All auth tokens will be invalidated on server restart.',
    );
  }

  const pairingExpiryMinutes = envInt('PAIRING_CODE_EXPIRY_MINUTES', 5);
  const discoveryIntervalSec = envInt('DISCOVERY_INTERVAL_SECONDS', 10);

  return {
    port: envInt('PORT', 3457),
    host: envStr('HOST', '0.0.0.0'),
    claudeHahaPath: envStr(
      'CLAUDE_HAHA_PATH',
      resolve('/tmp/cc-haha/src/entrypoints/cli.tsx'),
    ),
    pairingCodeExpiryMs: pairingExpiryMinutes * 60 * 1000,
    jwtSecret,
    maxSessions: envInt('MAX_SESSIONS', 5),
    discoveryEnabled: envBool('DISCOVERY_ENABLED', true),
    discoveryPort: envInt('DISCOVERY_PORT', 3458),
    discoveryIntervalMs: discoveryIntervalSec * 1000,
    logLevel: envStr('LOG_LEVEL', 'info'),
  };
}

export function validateConfig(config: Config): void {
  const errors: string[] = [];

  if (config.port < 1 || config.port > 65535) {
    errors.push('PORT must be between 1 and 65535');
  }

  if (!config.claudeHahaPath || !existsSync(config.claudeHahaPath)) {
    console.warn(
      '[config] WARNING: cc-haha path does not exist: ' + config.claudeHahaPath,
    );
    console.warn(
      '[config] The bridge will start but CLI sessions may fail to launch.',
    );
  }

  if (config.pairingCodeExpiryMs < 30000) {
    errors.push('PAIRING_CODE_EXPIRY_MINUTES must be at least 0.5 minutes');
  }

  if (config.maxSessions < 1) {
    errors.push('MAX_SESSIONS must be at least 1');
  }

  if (errors.length > 0) {
    throw new Error('Configuration errors:\n  - ' + errors.join('\n  - '));
  }
}
