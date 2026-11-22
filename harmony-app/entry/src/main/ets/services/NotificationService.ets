import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';

/**
 * 本地通知：回复完成时提醒（手表的通知镜像由系统完成，无需额外接口）
 */
export class NotificationService {
  private context: common.UIAbilityContext | null = null;
  private appIcon: image.PixelMap | null = null;

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 通知图标：使用 App 自身的 CC 图标（手表镜像通知时显示的是这个图标） */
  private async loadAppIcon(): Promise<image.PixelMap | null> {
    if (this.appIcon) { return this.appIcon; }
    if (!this.context) { return null; }
    try {
      const data = await this.context.resourceManager.getMediaContent($r('app.media.icon').id);
      const source = image.createImageSource(data.buffer as ArrayBuffer);
      // 通知图标限制 192KB 像素数据、建议 128x128
      const pixelMap = await source.createPixelMap({ desiredSize: { width: 128, height: 128 } });
      await source.release();
      this.appIcon = pixelMap;
      return pixelMap;
    } catch (err) {
      Logger.warn('load notification icon failed: ' + (err as BusinessError).message);
      return null;
    }
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
      const icon = await this.loadAppIcon();
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: body }
        },
        wantAgent: agent
      };
      if (icon) {
        request.smallIcon = icon;
        request.largeIcon = icon;
      }
      await notificationManager.publish(request);
    } catch (err) {
      Logger.warn('publish notification failed: ' + (err as BusinessError).message);
    }
  }
}
