import { DeliveryState, MessageModel, MessageRole } from '../../models/Message';
import { userDisplayText } from './ChatHistoryUtils';

/**
 * 发送可靠性纯逻辑（不依赖 ArkUI / 网络，可在 Node 单测中运行）。
 *
 * cc-haha 服务端对 user_message 没有显式 ACK（2026-11 版本）：
 * 送达判定只能依赖本轮第一个事件，或用历史消息做一次性对账。
 * 原则：不确定送达时不自动重发，只把状态显示给用户，由用户决定是否重试。
 */

const MATCH_WINDOW_MS: number = 15 * 60 * 1000;

/** 视为“本轮已开始”的事件：收到任一即代表前面的 user_message 已被服务端接受 */
export function eventConfirmsDelivery(eventType: string, event: Record<string, Object>): boolean {
  if (eventType === 'content_start' || eventType === 'content_delta' ||
      eventType === 'thinking' || eventType === 'tool_use_complete' ||
      eventType === 'tool_result' || eventType === 'message_complete' ||
      eventType === 'user_message_replay') {
    return true;
  }
  if (eventType === 'status') {
    const state = event.state as string;
    return !!state && state !== 'idle';
  }
  if (eventType === 'session_state') {
    return (event.turnState as string) === 'running';
  }
  return false;
}

/** 远端用户消息正文索引：正文 -> 时间戳列表（同文多条时逐一消费） */
export function buildUserTextIndex(messages: MessageModel[]): Map<string, number[]> {
  const index: Map<string, number[]> = new Map();
  for (const m of messages) {
    if (m.role !== MessageRole.USER) { continue; }
    const text = userDisplayText(m);
    if (text.length === 0) { continue; }
    const list = index.get(text) ?? [];
    list.push(m.timestamp);
    index.set(text, list);
  }
  return index;
}

/** 在允许的时间窗内消费一条最近的同文远端消息；成功返回 true */
function consumeClosest(index: Map<string, number[]>, text: string, timestamp: number): boolean {
  const list = index.get(text);
  if (!list || list.length === 0) { return false; }
  let best = -1;
  let bestDiff = MATCH_WINDOW_MS + 1;
  for (let i = 0; i < list.length; i++) {
    const diff = Math.abs(list[i] - timestamp);
    if (diff < bestDiff) { bestDiff = diff; best = i; }
  }
  if (best < 0 || bestDiff > MATCH_WINDOW_MS) { return false; }
  list.splice(best, 1);
  if (list.length === 0) { index.delete(text); }
  return true;
}

export interface DeliveryResolution {
  id: string;
  state: DeliveryState;
}

/**
 * 重连/补拉后对账本地处于 sending 的消息。
 * - 远端已有同文消息（时间窗内一对一匹配）→ sent；
 * - 远端没有且当前不在生成 → failed（不自动重发，UI 显示可点按重试）；
 * - 远端没有但仍在生成 → 保持 sending，等回合结束再对账。
 * queued 不参与对账（尚未发送）。
 */
export function resolvePendingDelivery(local: MessageModel[], remote: MessageModel[],
                                      isGenerating: boolean): DeliveryResolution[] {
  const index = buildUserTextIndex(remote);
  const results: DeliveryResolution[] = [];
  for (const m of local) {
    if (m.role !== MessageRole.USER || m.delivery !== DeliveryState.SENDING) { continue; }
    const text = userDisplayText(m);
    if (text.length === 0) {
      // 纯附件消息没有可匹配的正文：标记失败会导致误判并可能重复发送附件，
      // 这里保持待确认，交给本轮事件确认或用户自行判断。
      results.push({ id: m.id, state: DeliveryState.SENDING });
      continue;
    }
    const matched = consumeClosest(index, text, m.timestamp);
    if (matched) {
      results.push({ id: m.id, state: DeliveryState.SENT });
    } else {
      results.push({
        id: m.id,
        state: isGenerating ? DeliveryState.SENDING : DeliveryState.FAILED
      });
    }
  }
  return results;
}

/** 本地缓存加载时修正不可恢复的排队状态；sending 保留到首次历史对账 */
export function normalizeLoadedDelivery(messages: MessageModel[]): number {
  let changed = 0;
  for (const m of messages) {
    if (m.delivery === DeliveryState.QUEUED) {
      m.delivery = DeliveryState.FAILED;
      m.revision++;
      changed++;
    }
  }
  return changed;
}

export function countQueued(messages: MessageModel[]): number {
  let count = 0;
  for (const m of messages) {
    if (m.delivery === DeliveryState.QUEUED) { count++; }
  }
  return count;
}
