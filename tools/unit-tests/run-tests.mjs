#!/usr/bin/env node
// 用 TypeScript 编译器把纯逻辑 .ets 转成 CommonJS，在 Node 中跑断言。
// 只覆盖不依赖 ArkUI 的 ChatHistoryUtils，真机行为仍由 uitest 覆盖。

import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import ts from 'typescript';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const etsRoot = join(repo, 'harmony-app', 'entry', 'src', 'main', 'ets');

function transpile(sourcePath, outPath, importRewrite = []) {
  let source = readFileSync(sourcePath, 'utf8');
  for (const [from, to] of importRewrite) {
    source = source.replace(from, to);
  }
  const result = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
      esModuleInterop: true
    },
    fileName: sourcePath
  });
  writeFileSync(outPath, result.outputText, 'utf8');
}

const dir = mkdtempSync(join(tmpdir(), 'cc-haha-unit-'));
try {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'package.json'), '{"type":"commonjs"}', 'utf8');
  transpile(join(etsRoot, 'models', 'Message.ets'), join(dir, 'Message.js'));
  transpile(join(etsRoot, 'services', 'chat', 'ChatHistoryUtils.ets'),
    join(dir, 'ChatHistoryUtils.js'),
    [["'../../models/Message'", "'./Message'"]]);

  const {
    messageKey, mergeMessages, parseServerMessages, userDisplayText,
    lastAssistantSnippet
  } = await import(pathToFileURL(join(dir, 'ChatHistoryUtils.js')).href);
  const { MessageModel, MessageRole } = await import(pathToFileURL(join(dir, 'Message.js')).href);

  const results = [];
  const test = (name, fn) => {
    try {
      fn();
      results.push([name, true, '']);
    } catch (error) {
      results.push([name, false, error.message]);
    }
  };

  test('messageKey: 同角色同文本相同，工具 ID 不同则不同', () => {
    const a = new MessageModel(MessageRole.USER, 'u1');
    a.appendText('hello');
    const b = new MessageModel(MessageRole.USER, 'u2');
    b.appendText('hello');
    assert.equal(messageKey(a), messageKey(b));

    const t1 = new MessageModel(MessageRole.ASSISTANT, 'a1');
    t1.addToolUse('tool-1', 'Read', {});
    const t2 = new MessageModel(MessageRole.ASSISTANT, 'a2');
    t2.addToolUse('tool-2', 'Read', {});
    assert.notEqual(messageKey(t1), messageKey(t2));
  });

  test('userDisplayText: 去掉图片/文件标记行', () => {
    const m = new MessageModel(MessageRole.USER, 'u1');
    m.appendText('看这个\n[图片] a.png\n[文件] b.txt\n正文');
    assert.equal(userDisplayText(m), '看这个\n正文');
  });

  test('parseServerMessages: 两条 user 之间合并为一条 assistant', () => {
    const raw = [
      { type: 'user', id: 'u1', timestamp: '2026-11-14T10:00:00Z', content: [{ type: 'text', text: 'hi' }] },
      { type: 'assistant', id: 'a1', timestamp: '2026-11-14T10:00:01Z', model: 'm1', content: [{ type: 'thinking', thinking: 'think' }] },
      { type: 'assistant', id: 'a1', timestamp: '2026-11-14T10:00:02Z', content: [{ type: 'text', text: 'hello' }] },
      { type: 'tool_use', id: 'tu1', timestamp: '2026-11-14T10:00:03Z', content: [{ type: 'tool_use', id: 'tool-1', name: 'Read', input: { path: 'a' } }] },
      { type: 'tool_result', id: 'tr1', timestamp: '2026-11-14T10:00:04Z', content: [{ type: 'tool_result', tool_use_id: 'tool-1', content: 'ok', is_error: false }] },
      { type: 'user', id: 'u2', timestamp: '2026-11-14T10:01:00Z', content: 'next' }
    ];
    const parsed = parseServerMessages(raw);
    assert.equal(parsed.length, 3);
    assert.equal(parsed[0].role, MessageRole.USER);
    assert.equal(parsed[1].role, MessageRole.ASSISTANT);
    assert.equal(parsed[1].contents.some(c => c.type === 'text' && c.text === 'hello'), true);
    assert.equal(parsed[1].contents.some(c => c.type === 'thinking' && c.text === 'think'), true);
    assert.equal(parsed[1].contents.some(c => c.type === 'tool_use' && c.status === 'completed'), true);
    assert.equal(parsed[2].role, MessageRole.USER);
  });

  test('mergeMessages: 相同内容不重复，保留更完整的 assistant', () => {
    const local = [];
    const u = new MessageModel(MessageRole.USER, 'u1');
    u.timestamp = Date.parse('2026-11-14T10:00:00Z');
    u.appendText('hi');
    local.push(u);
    const short = new MessageModel(MessageRole.ASSISTANT, 'a-local');
    short.timestamp = Date.parse('2026-11-14T10:00:02Z');
    short.appendText('hello world!');
    local.push(short);

    const remoteU = new MessageModel(MessageRole.USER, 'u1');
    remoteU.timestamp = u.timestamp;
    remoteU.appendText('hi');
    const full = new MessageModel(MessageRole.ASSISTANT, 'a-remote');
    full.timestamp = Date.parse('2026-11-14T10:00:02Z');
    full.appendText('hello world! this is the full answer');
    const merged = mergeMessages(local, [remoteU, full]);

    assert.equal(merged.length, 2);
    assert.equal(merged[0].role, MessageRole.USER);
    assert.equal(merged[1].contents.filter(c => c.type === 'text')[0].text,
      'hello world! this is the full answer');
  });

  test('lastAssistantSnippet: 去掉 Markdown 并限长', () => {
    const m = new MessageModel(MessageRole.ASSISTANT, 'a1');
    m.appendText('## 标题\n**加粗** 和 `代码`\n第二行');
    const snippet = lastAssistantSnippet([m]);
    assert.equal(snippet.includes('#'), false);
    assert.equal(snippet.includes('`'), false);
    assert.equal(snippet.includes('\n'), false);
    assert.equal(snippet.length <= 121, true);
  });

  let failed = 0;
  for (const [name, ok, detail] of results) {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`);
    if (!ok) failed++;
  }
  if (failed > 0) {
    console.error(`${failed} test(s) failed`);
    process.exit(1);
  }
  console.log(`all ${results.length} tests passed`);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
