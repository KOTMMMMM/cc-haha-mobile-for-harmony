import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';

/**
 * 连续任务：生成回复期间退到后台时保持进程/网络存活，
 * 以便收到 message_complete 并发出「回复完成」通知（系统会显示一条常驻提示）。
 */
export class BackgroundTaskService {
  private context: common.UIAbilityContext | null = null;
  private running: boolean = false;

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async start(): Promise<void> {
    if (!this.context || this.running) { return; }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'com.claudehaha.mobile', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        this.context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.running = true;
      Logger.info('background continuous task started');
    } catch (err) {
      Logger.warn('startBackgroundRunning failed: ' + (err as BusinessError).message);
    }
  }

  async stop(): Promise<void> {
    if (!this.context || !this.running) { return; }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      Logger.info('background continuous task stopped');
    } catch (err) {
      Logger.warn('stopBackgroundRunning failed: ' + (err as BusinessError).message);
    }
    this.running = false;
  }

  isRunning(): boolean { return this.running; }
}
