#!/usr/bin/env node
// 协议 smoke test：只验证 PC 端 cc-haha 的 REST 契约，不连接 WebSocket。
// 用法：
//   CC_HAHA_HOST=127.0.0.1 CC_HAHA_PORT=65499 CC_HAHA_TOKEN=... node tools/smoke-test.mjs
// token 未提供时尝试读取 ~/.claude/cc-haha/settings.json 的 h5Access.token。

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const host = process.env.CC_HAHA_HOST || '127.0.0.1';
const port = process.env.CC_HAHA_PORT || '65499';
let token = process.env.CC_HAHA_TOKEN || '';

if (!token) {
  try {
    const settingsPath = join(homedir(), '.claude', 'cc-haha', 'settings.json');
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    token = settings?.h5Access?.token || '';
  } catch {
    // 下面统一报错
  }
}

if (!token) {
  console.error('缺少 token：设置 CC_HAHA_TOKEN 或确认 ~/.claude/cc-haha/settings.json 存在');
  process.exit(2);
}

const base = `http://${host}:${port}`;
const headers = { Authorization: `Bearer ${token}`, 'User-Agent': 'cc-haha-smoke/1.0.1' };

async function request(path) {
  const res = await fetch(base + path, { headers });
  if (!res.ok) {
    throw new Error(`${path} -> HTTP ${res.status}`);
  }
  return res.json();
}

function check(name, ok, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`);
  if (!ok) process.exitCode = 1;
}

try {
  const health = await request('/health');
  check('GET /health', health?.status === 'ok', `status=${health?.status}`);

  const sessions = await request('/api/sessions');
  const list = Array.isArray(sessions?.sessions) ? sessions.sessions : [];
  check('GET /api/sessions', Array.isArray(sessions?.sessions), `count=${list.length}`);

  if (list.length > 0) {
    const id = list[0].id;
    const page = await request(`/api/sessions/${encodeURIComponent(id)}/messages`);
    const messages = Array.isArray(page?.messages) ? page.messages : [];
    check('GET /api/sessions/:id/messages', Array.isArray(page?.messages),
      `count=${messages.length} hasMore=${page?.page?.hasMore ?? 'unknown'}`);

    const inspection = await request(
      `/api/sessions/${encodeURIComponent(id)}/inspection?includeContext=1&contextOnly=1`);
    check('GET /api/sessions/:id/inspection', !!inspection?.status,
      `context=${inspection?.context?.percentage ?? 'n/a'}%`);
  }

  const providers = await request('/api/providers');
  check('GET /api/providers', Array.isArray(providers?.providers),
    `count=${Array.isArray(providers?.providers) ? providers.providers.length : 0}`);
} catch (error) {
  console.error('smoke test failed:', error.message);
  process.exit(1);
}
