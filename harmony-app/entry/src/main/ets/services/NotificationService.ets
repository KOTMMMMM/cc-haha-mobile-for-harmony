import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';

/**
 * 本地通知：回复完成时提醒（手表的通知镜像由系统完成，无需额外接口）
 */
export class NotificationService {
  private context: common.UIAbilityContext | null = null;

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 首次使用前申请通知授权 */
  async ensurePermission(): Promise<boolean> {
    if (!this.context) { return false; }
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (enabled) { return true; }
      await notificationManager.requestEnableNotification(this.context);
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      Logger.warn('Notification permission failed: ' + (err as BusinessError).message);
      return false;
    }
  }

  async isEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      Logger.warn('isNotificationEnabled failed: ' + (err as BusinessError).message);
      return false;
    }
  }

  /** 发送「回复完成」通知，点击回到 App */
  async notifyTurnComplete(title: string, body: string): Promise<void> {
    if (!this.context) { return; }
    try {
      if (!(await notificationManager.isNotificationEnabled())) { return; }
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'com.cchaha.harmony', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: body }
        },
        wantAgent: agent
      };
      await notificationManager.publish(request);
    } catch (err) {
      Logger.warn('publish notification failed: ' + (err as BusinessError).message);
    }
  }
}
