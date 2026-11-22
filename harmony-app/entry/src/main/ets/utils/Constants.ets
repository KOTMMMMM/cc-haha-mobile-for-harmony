/**
 * Application constants and configuration keys
 */
export class Constants {
  // Network defaults (新版 cc-haha 内置服务端)
  static readonly DEFAULT_PORT: number = 65499;
  static readonly DEFAULT_WS_PORT: number = 65499;
  static readonly WS_PATH: string = '/ws/';

  // Reconnection（不再限次数：Tailscale 断线/切网/后台冻结后都能自动恢复）
  static readonly WS_RECONNECT_BASE_MS: number = 1000;
  static readonly WS_RECONNECT_MAX_MS: number = 10000;
  static readonly HEARTBEAT_INTERVAL_MS: number = 30000;
  static readonly WS_PONG_TIMEOUT_MS: number = 20000;

  // Preferences
  static readonly PREFERENCES_NAME: string = 'cc_haha_prefs';
  /** 旧版明文 token 键；新版本迁移到 Asset Store 后删除 */
  static readonly KEY_TOKEN: string = 'auth_token';
  /** Asset Store 中保存 H5 token 的别名 */
  static readonly ASSET_ALIAS_TOKEN: string = 'cc_haha_h5_token';
  static readonly KEY_HOST: string = 'connection_host';
  static readonly KEY_PORT: string = 'connection_port';
  static readonly KEY_SCHEME: string = 'connection_scheme';
  static readonly KEY_HOSTNAME: string = 'connection_hostname';
  static readonly KEY_ORIGIN: string = 'connection_origin';
  static readonly KEY_HOST_ALTS: string = 'connection_host_alts';
  static readonly KEY_THEME: string = 'app_theme';
  static readonly KEY_FONT_SIZE: string = 'font_size';
  static readonly KEY_SELECTED_MODEL: string = 'selected_model';
  static readonly KEY_DEVICE_ID: string = 'device_id';
  static readonly KEY_DEVICE_NAME: string = 'device_name';
  static readonly KEY_NOTIFY_ON_COMPLETE: string = 'notify_on_complete';
  static readonly KEY_CURRENT_SESSION_ID: string = 'current_session_id';

  // App info
  static readonly APP_VERSION: string = '1.1.0';
}
