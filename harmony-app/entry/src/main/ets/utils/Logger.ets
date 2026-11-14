/**
 * Simple logging utility
 */
export enum LogLevel { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 }

export class Logger {
  private static TAG: string = 'ClaudeHaha';
  private static level: LogLevel = LogLevel.DEBUG;

  static setLevel(level: LogLevel): void { Logger.level = level; }

  static debug(msg: string, ...args: Object[]): void {
    if (Logger.level <= LogLevel.DEBUG) console.debug(`[${Logger.TAG}][DEBUG] ${msg}`, ...args);
  }

  static info(msg: string, ...args: Object[]): void {
    if (Logger.level <= LogLevel.INFO) console.info(`[${Logger.TAG}][INFO] ${msg}`, ...args);
  }

  static warn(msg: string, ...args: Object[]): void {
    if (Logger.level <= LogLevel.WARN) console.warn(`[${Logger.TAG}][WARN] ${msg}`, ...args);
  }

  static error(msg: string, ...args: Object[]): void {
    if (Logger.level <= LogLevel.ERROR) console.error(`[${Logger.TAG}][ERROR] ${msg}`, ...args);
  }
}
