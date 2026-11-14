// ============================================================================
// Session Manager - manages cc-haha CLI child processes and session state
// ============================================================================

import type { Session, SessionStatus, ChatMessage, ContentBlock } from './types.js';
import { v4 as uuidv4 } from 'uuid';
import { spawn, type Subprocess } from 'bun';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { existsSync, mkdirSync } from 'node:fs';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const sessions = new Map<string, Session>();
let maxSessions = 5;

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

export function setMaxSessions(max: number): void {
  maxSessions = max;
  console.log('[session-manager] Max sessions set to ' + max);
}

export function createSession(
  workDir?: string,
  model?: string,
  claudeHahaPath?: string,
): Session | { error: string } {
  if (sessions.size >= maxSessions) {
    const error = 'Maximum number of sessions reached (' + maxSessions + '). Close an existing session first.';
    console.warn('[session-manager] ' + error);
    return { error };
  }

  const id = uuidv4();
  const resolvedWorkDir = workDir
    ? resolve(workDir)
    : join(homedir(), 'cc-haha-workspace');

  if (!existsSync(resolvedWorkDir)) {
    try {
      mkdirSync(resolvedWorkDir, { recursive: true });
      console.log('[session-manager] Created workspace directory: ' + resolvedWorkDir);
    } catch (err) {
      return {
        error: 'Failed to create workspace directory: ' + (err as Error).message,
      };
    }
  }

  const session: Session = {
    id,
    workDir: resolvedWorkDir,
    status: 'idle',
    model: model || 'claude-sonnet-4-20250514',
    createdAt: Date.now(),
    process: null,
    messages: [],
    currentMessageId: null,
  };

  sessions.set(id, session);
  console.log(
    '[session-manager] Created session ' + id + ' (workspace: ' + resolvedWorkDir + ', model: ' + session.model + ')',
  );
  console.log(
    '[session-manager] Active sessions: ' + sessions.size + '/' + maxSessions,
  );

  return session;
}

export function getSession(id: string): Session | undefined {
  return sessions.get(id);
}

export function listSessions(): Session[] {
  return Array.from(sessions.values()).map((s) => ({
    ...s,
    process: s.process ? { pid: s.process.pid } : null,
    messages: s.messages.slice(-5),
  }));
}

export function updateSessionStatus(
  sessionId: string,
  status: SessionStatus,
): void {
  const session = sessions.get(sessionId);
  if (session) {
    session.status = status;
    console.log(
      '[session-manager] Session ' + sessionId + ' status -> ' + status,
    );
  }
}

export function setSessionProcess(
  sessionId: string,
  proc: { pid: number },
): void {
  const session = sessions.get(sessionId);
  if (session) {
    session.process = proc;
  }
}

export function setCurrentMessageId(
  sessionId: string,
  messageId: string | null,
): void {
  const session = sessions.get(sessionId);
  if (session) {
    session.currentMessageId = messageId;
  }
}

export function addMessage(sessionId: string, message: ChatMessage): void {
  const session = sessions.get(sessionId);
  if (session) {
    session.messages.push(message);
    if (session.messages.length > 100) {
      session.messages = session.messages.slice(-100);
    }
  }
}

export function getMessages(sessionId: string): ChatMessage[] {
  const session = sessions.get(sessionId);
  return session ? [...session.messages] : [];
}

export function killSession(sessionId: string): boolean {
  const session = sessions.get(sessionId);
  if (!session) {
    console.warn('[session-manager] Cannot kill unknown session: ' + sessionId);
    return false;
  }

  console.log(
    '[session-manager] Killing session ' + sessionId + ' (status: ' + session.status + ')',
  );

  if (session.process) {
    try {
      process.kill(session.process.pid, 'SIGTERM');
      console.log(
        '[session-manager] Sent SIGTERM to process ' + session.process.pid,
      );
    } catch (err) {
      console.warn(
        '[session-manager] Failed to kill process ' + session.process.pid + ': ' + (err as Error).message,
      );
      try {
        process.kill(session.process.pid, 'SIGKILL');
        console.log(
          '[session-manager] Sent SIGKILL to process ' + session.process.pid,
        );
      } catch {
        // Process may already be dead
      }
    }
  }

  session.status = 'error';
  session.process = null;
  session.currentMessageId = null;
  sessions.delete(sessionId);

  console.log(
    '[session-manager] Session ' + sessionId + ' removed. Active sessions: ' + sessions.size + '/' + maxSessions,
  );

  return true;
}

export function cleanupAll(): void {
  console.log(
    '[session-manager] Cleaning up ' + sessions.size + ' active sessions...',
  );

  for (const [id, session] of sessions) {
    console.log('[session-manager] Terminating session: ' + id);
    if (session.process) {
      try {
        process.kill(session.process.pid, 'SIGTERM');
      } catch {
        // Process may already be dead
      }
    }
  }

  sessions.clear();
  console.log('[session-manager] All sessions cleaned up.');
}

export function getSessionCount(): number {
  return sessions.size;
}
