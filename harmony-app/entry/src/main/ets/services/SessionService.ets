import { MessageModel, MessageRole } from '../models/Message';
import { Session } from '../models/Session';
import { Logger } from '../utils/Logger';

export class SessionService {
  private currentSessionId: string = '';
  private messages: MessageModel[] = [];
  private sessions: Session[] = [];
  private currentSession: Session | null = null;

  getCurrentSessionId(): string { return this.currentSessionId; }
  setCurrentSessionId(sessionId: string): void { this.currentSessionId = sessionId; }
  getCurrentSession(): Session | null { return this.currentSession; }

  setCurrentSession(session: Session): void {
    this.currentSession = session;
    this.currentSessionId = session.id;
  }

  getMessages(): MessageModel[] { return this.messages; }

  getMessageById(id: string): MessageModel | null {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === id) { return this.messages[i]; }
    }
    return null;
  }

  getLastAssistantMessage(): MessageModel | null {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === MessageRole.ASSISTANT) { return this.messages[i]; }
    }
    return null;
  }

  addMessage(message: MessageModel): void { this.messages.push(message); }

  addUserMessage(text: string): MessageModel {
    const msg = new MessageModel(MessageRole.USER);
    msg.appendText(text);
    this.messages.push(msg);
    return msg;
  }

  createAssistantMessage(): MessageModel {
    const msg = new MessageModel(MessageRole.ASSISTANT);
    msg.isStreaming = true;
    this.messages.push(msg);
    return msg;
  }

  updateMessage(messageId: string, updates: Partial<MessageModel>): void {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        if (updates.isStreaming !== undefined) { this.messages[i].isStreaming = updates.isStreaming; }
        if (updates.usage !== undefined) { this.messages[i].usage = updates.usage; }
        if (updates.model !== undefined) { this.messages[i].model = updates.model; }
        break;
      }
    }
  }

  appendToLastAssistant(text: string): MessageModel | null {
    const last = this.getLastAssistantMessage();
    if (last) { last.appendText(text); }
    return last;
  }

  setMessages(messages: MessageModel[]): void { this.messages = messages; }

  clearMessages(): void {
    this.messages = [];
    this.currentSessionId = '';
    this.currentSession = null;
  }

  getSessions(): Session[] { return this.sessions; }
  setSessions(sessions: Session[]): void { this.sessions = sessions; }
  addSession(session: Session): void { this.sessions.unshift(session); }

  removeSession(sessionId: string): void {
    const index = this.sessions.findIndex(s => s.id === sessionId);
    if (index >= 0) {
      this.sessions.splice(index, 1);
      if (this.currentSessionId === sessionId) { this.clearMessages(); }
    }
  }

  updateSessionTitle(sessionId: string, title: string): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === sessionId) { this.sessions[i].title = title; break; }
    }
    if (this.currentSession && this.currentSession.id === sessionId) {
      this.currentSession.title = title;
    }
  }

  updateSession(sessionId: string, updates: Partial<Session>): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === sessionId) {
        if (updates.status !== undefined) { this.sessions[i].status = updates.status; }
        if (updates.messageCount !== undefined) { this.sessions[i].messageCount = updates.messageCount; }
        if (updates.model !== undefined) { this.sessions[i].model = updates.model; }
        this.sessions[i].updateActivity();
        break;
      }
    }
  }

  getMessageCount(): number { return this.messages.length; }
}
