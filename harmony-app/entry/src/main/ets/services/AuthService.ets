import preferences from '@ohos.data.preferences';
import { ConnectionConfig } from '../models/ConnectionConfig';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';

export class AuthService {
  private prefs: preferences.Preferences | null = null;

  private logFailure(operation: string, error: Object): void {
    let detail: string = '';
    try {
      detail = (error as Error).message ?? '';
    } catch (e) {
      detail = '';
    }
    Logger.warn('AuthService.' + operation + ' failed: ' + detail);
  }

  async initialize(context: Context): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, Constants.PREFERENCES_NAME);
    } catch (err) {
      Logger.error('AuthService init failed: ' + JSON.stringify(err));
    }
  }

  async getToken(): Promise<string | null> {
    if (!this.prefs) { return null; }
    try {
      const token = await this.prefs.get(Constants.KEY_TOKEN, '') as string;
      return token || null;
    } catch (err) {
      this.logFailure('getToken', err);
      return null;
    }
  }

  async setToken(token: string): Promise<void> {
    if (!this.prefs) { return; }
    try { await this.prefs.put(Constants.KEY_TOKEN, token); await this.prefs.flush(); }
    catch (err) { this.logFailure('setToken', err); }
  }

  private parseAltHosts(json: string): string[] {
    if (!json) { return []; }
    try {
      const arr = JSON.parse(json) as string[];
      const out: string[] = [];
      if (Array.isArray(arr)) {
        for (const h of arr) {
          if (typeof h === 'string' && h.length > 0) { out.push(h); }
        }
      }
      return out;
    } catch (err) {
      Logger.warn('AuthService.parseAltHosts failed: invalid JSON');
      return [];
    }
  }

  async getConnectionConfig(): Promise<ConnectionConfig | null> {
    if (!this.prefs) { return null; }
    try {
      const host = await this.prefs.get(Constants.KEY_HOST, '') as string;
      const port = await this.prefs.get(Constants.KEY_PORT, Constants.DEFAULT_PORT) as number;
      const token = await this.prefs.get(Constants.KEY_TOKEN, '') as string;
      const hostname = await this.prefs.get(Constants.KEY_HOSTNAME, '') as string;
      const origin = await this.prefs.get(Constants.KEY_ORIGIN, '') as string;
      const altsJson = await this.prefs.get(Constants.KEY_HOST_ALTS, '') as string;
      if (!host || !token) { return null; }
      const alternates = this.parseAltHosts(altsJson);
      return {
        host, port, token,
        hostname: hostname || undefined,
        origin: origin || undefined,
        alternates: alternates.length > 0 ? alternates : undefined
      };
    } catch (err) {
      this.logFailure('getConnectionConfig', err);
      return null;
    }
  }

  async setConnectionConfig(config: ConnectionConfig): Promise<void> {
    if (!this.prefs) { return; }
    try {
      // 自动把旧地址保留为备用地址：在家用局域网、外出用 Tailscale，无需手动切换
      const oldHost = await this.prefs.get(Constants.KEY_HOST, '') as string;
      const oldAltsJson = await this.prefs.get(Constants.KEY_HOST_ALTS, '') as string;
      const alts: string[] = [];
      const pushAlt = (h: string): void => {
        if (h && h !== config.host && alts.indexOf(h) < 0) { alts.push(h); }
      };
      pushAlt(oldHost);
      for (const h of this.parseAltHosts(oldAltsJson)) { pushAlt(h); }
      if (config.alternates) {
        for (const h of config.alternates) { pushAlt(h); }
      }
      while (alts.length > 4) { alts.pop(); }

      await this.prefs.put(Constants.KEY_HOST, config.host);
      await this.prefs.put(Constants.KEY_PORT, config.port);
      await this.prefs.put(Constants.KEY_TOKEN, config.token);
      if (config.hostname) { await this.prefs.put(Constants.KEY_HOSTNAME, config.hostname); }
      if (config.origin) { await this.prefs.put(Constants.KEY_ORIGIN, config.origin); }
      await this.prefs.put(Constants.KEY_HOST_ALTS, JSON.stringify(alts));
      await this.prefs.flush();
    } catch (err) { this.logFailure('setConnectionConfig', err); }
  }

  async getNotifyOnComplete(): Promise<boolean> {
    if (!this.prefs) { return true; }
    try { return await this.prefs.get(Constants.KEY_NOTIFY_ON_COMPLETE, true) as boolean; }
    catch (err) {
      this.logFailure('getNotifyOnComplete', err);
      return true;
    }
  }

  async setNotifyOnComplete(enabled: boolean): Promise<void> {
    if (!this.prefs) { return; }
    try { await this.prefs.put(Constants.KEY_NOTIFY_ON_COMPLETE, enabled); await this.prefs.flush(); }
    catch (err) { this.logFailure('setNotifyOnComplete', err); }
  }

  async isAuthenticated(): Promise<boolean> {
    const token = await this.getToken();
    return token !== null && token.length > 0;
  }

  async logout(): Promise<void> {
    if (!this.prefs) { return; }
    try {
      await this.prefs.delete(Constants.KEY_TOKEN);
      await this.prefs.delete(Constants.KEY_HOST);
      await this.prefs.delete(Constants.KEY_PORT);
      await this.prefs.delete(Constants.KEY_HOSTNAME);
      await this.prefs.flush();
    } catch (err) { this.logFailure('logout', err); }
  }

  async getTheme(): Promise<string> {
    if (!this.prefs) { return 'light'; }
    try { return await this.prefs.get(Constants.KEY_THEME, 'light') as string; }
    catch (err) {
      this.logFailure('getTheme', err);
      return 'light';
    }
  }

  async setTheme(theme: string): Promise<void> {
    if (!this.prefs) { return; }
    try { await this.prefs.put(Constants.KEY_THEME, theme); await this.prefs.flush(); }
    catch (err) { this.logFailure('setTheme', err); }
  }

  async getFontSize(): Promise<number> {
    if (!this.prefs) { return 16; }
    try { return await this.prefs.get(Constants.KEY_FONT_SIZE, 16) as number; }
    catch (err) {
      this.logFailure('getFontSize', err);
      return 16;
    }
  }

  async setFontSize(fontSize: number): Promise<void> {
    if (!this.prefs) { return; }
    try { await this.prefs.put(Constants.KEY_FONT_SIZE, fontSize); await this.prefs.flush(); }
    catch (err) { this.logFailure('setFontSize', err); }
  }

  async getSelectedModel(): Promise<string | null> {
    if (!this.prefs) { return null; }
    try {
      const model = await this.prefs.get(Constants.KEY_SELECTED_MODEL, '') as string;
      return model || null;
    } catch (err) {
      this.logFailure('getSelectedModel', err);
      return null;
    }
  }

  async setSelectedModel(model: string): Promise<void> {
    if (!this.prefs) { return; }
    try { await this.prefs.put(Constants.KEY_SELECTED_MODEL, model); await this.prefs.flush(); }
    catch (err) { this.logFailure('setSelectedModel', err); }
  }

  async getOrCreateDeviceId(): Promise<string> {
    if (!this.prefs) { return 'dev-' + Date.now(); }
    try {
      let id = await this.prefs.get(Constants.KEY_DEVICE_ID, '') as string;
      if (!id) {
        id = 'dev-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8);
        await this.prefs.put(Constants.KEY_DEVICE_ID, id);
        await this.prefs.flush();
      }
      return id;
    } catch (err) {
      this.logFailure('getOrCreateDeviceId', err);
      return 'dev-' + Date.now();
    }
  }

  async getOrCreateDeviceName(): Promise<string> {
    if (!this.prefs) { return 'HarmonyOS'; }
    try {
      let name = await this.prefs.get(Constants.KEY_DEVICE_NAME, '') as string;
      if (!name) {
        name = 'HarmonyOS';
        await this.prefs.put(Constants.KEY_DEVICE_NAME, name);
        await this.prefs.flush();
      }
      return name;
    } catch (err) {
      this.logFailure('getOrCreateDeviceName', err);
      return 'HarmonyOS';
    }
  }

  async getCurrentSessionId(): Promise<string> {
    if (!this.prefs) { return ''; }
    try { return await this.prefs.get(Constants.KEY_CURRENT_SESSION_ID, '') as string; }
    catch (err) {
      this.logFailure('getCurrentSessionId', err);
      return '';
    }
  }

  async setCurrentSessionId(sessionId: string): Promise<void> {
    if (!this.prefs) { return; }
    try { await this.prefs.put(Constants.KEY_CURRENT_SESSION_ID, sessionId); await this.prefs.flush(); }
    catch (err) { this.logFailure('setCurrentSessionId', err); }
  }
}
