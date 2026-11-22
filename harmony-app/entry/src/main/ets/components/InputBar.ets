import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AttachmentItem } from '../models/Attachment';
import { Logger } from '../utils/Logger';
import { ThemeColors } from '../utils/ThemeUtil';

@Component
export struct InputBar {
  @StorageLink('theme') theme: string = 'light';
  @Prop isGenerating: boolean = false;
  @Prop queuedCount: number = 0;
  onSendMessage: (message: string, attachments: AttachmentItem[]) => void = () => {};
  onStopGeneration: () => void = () => {};
  onCancelQueued: () => void = () => {};
  @StorageLink('composerPrefill') @Watch('onPrefillChanged') composerPrefill: string = '';
  @State inputText: string = '';
  @State attachments: AttachmentItem[] = [];

  aboutToAppear(): void {
    // 页面重建时 AppStorage 里可能已有待回填的排队消息（@Watch 不会在首次创建时触发）
    this.onPrefillChanged();
  }

  /** 停止/离开会话时 ChatPage 把排队消息退回输入框 */
  private onPrefillChanged(): void {
    if (this.composerPrefill.length === 0) { return; }
    this.inputText = this.inputText.length > 0
      ? this.inputText + '\n\n' + this.composerPrefill
      : this.composerPrefill;
    AppStorage.setOrCreate('composerPrefill', '');
  }

  private chooseAttachment(): void {
    AlertDialog.show({
      title: '添加附件',
      message: '',
      primaryButton: {
        value: '图片',
        action: () => { this.pickImages(); }
      },
      secondaryButton: {
        value: '文件',
        action: () => { this.pickDocuments(); }
      },
      cancel: () => {}
    });
  }

  private async pickImages(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 4;
      const result = await photoPicker.select(options);
      for (const uri of result.photoUris) {
        await this.addUri(uri);
      }
    } catch (e) {
      Logger.warn('pickImages failed: ' + (e as Error).message);
    }
  }

  private async pickDocuments(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 4;
      const uris = await docPicker.select(options);
      for (const uri of uris) {
        await this.addUri(uri);
      }
    } catch (e) {
      Logger.warn('pickDocuments failed: ' + (e as Error).message);
    }
  }

  private async addUri(uri: string): Promise<void> {
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      if (stat.size > 15 * 1024 * 1024) {
        promptAction.showToast({ message: '文件超过 15MB，未添加' });
        fileIo.closeSync(file);
        return;
      }
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const helper = new util.Base64Helper();
      const data = helper.encodeToStringSync(new Uint8Array(buffer));
      const name = this.fileNameFromUri(uri);
      const mime = this.mimeFromName(name);
      const type = mime.startsWith('image/') ? 'image' : 'file';
      this.attachments = [...this.attachments, {
        type: type, name: name, mimeType: mime, data: data, size: stat.size
      }];
    } catch (e) {
      Logger.warn('read attachment failed: ' + (e as Error).message);
      promptAction.showToast({ message: '读取文件失败' });
    }
  }

  private fileNameFromUri(uri: string): string {
    const idx = uri.lastIndexOf('/');
    if (idx >= 0) {
      return decodeURIComponent(uri.substring(idx + 1));
    }
    return 'file';
  }

  private mimeFromName(name: string): string {
    const idx = name.lastIndexOf('.');
    const ext = idx >= 0 ? name.substring(idx + 1).toLowerCase() : '';
    switch (ext) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'bmp': return 'image/bmp';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'md': return 'text/markdown';
      case 'json': return 'application/json';
      case 'csv': return 'text/csv';
      case 'doc': return 'application/msword';
      case 'docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls': return 'application/vnd.ms-excel';
      case 'xlsx': return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt': return 'application/vnd.ms-powerpoint';
      case 'pptx': return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'zip': return 'application/zip';
      default: return 'application/octet-stream';
    }
  }

  private removeAttachment(index: number): void {
    this.attachments = this.attachments.filter((a, i) => i !== index);
  }

  private handleSend(): void {
    const text = this.inputText.trim();
    if (text.length === 0 && this.attachments.length === 0) { return; }
    // 生成中也允许发送：ChatPage 会排队，当前回合结束后自动发出
    this.onSendMessage(text, this.attachments);
    this.inputText = '';
    this.attachments = [];
  }

  build() {
    Column() {
      if (this.queuedCount > 0) {
        Row() {
          Text('已排队 ' + this.queuedCount)
            .fontSize(11).fontColor(ThemeColors.textSecondary(this.theme)).layoutWeight(1)
          Text('取消')
            .fontSize(11).fontColor(ThemeColors.primary)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .accessibilityLevel('yes').accessibilityText('取消排队').id('composer-cancel-queue')
            .onClick(() => { this.onCancelQueued(); })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 4, bottom: 2 })
      }

      if (this.attachments.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.attachments, (a: AttachmentItem, i: number) => {
            Row() {
              Text(a.name).fontSize(12).fontColor(ThemeColors.text(this.theme)).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 160 })
              Text('×').fontSize(14).fontColor(ThemeColors.textSecondary(this.theme)).margin({ left: 6 })
                .padding({ left: 4, right: 4 })
                .accessibilityLevel('yes').accessibilityText('移除附件 ' + a.name)
                .onClick(() => { this.removeAttachment(i); })
            }
            .padding({ left: 10, right: 8, top: 4, bottom: 4 })
            .backgroundColor(ThemeColors.chipBg(this.theme)).borderRadius(12)
            .margin({ right: 6, bottom: 4 })
          }, (a: AttachmentItem, i: number): string => 'att_' + i + '_' + a.name)
        }
        .width('100%').padding({ left: 12, right: 12, top: 6 })
      }

      Row() {
        Text('+')
          .fontSize(24).fontColor(ThemeColors.textSecondary(this.theme))
          .width(40).height(40).textAlign(TextAlign.Center)
          .accessibilityLevel('yes').accessibilityText('添加附件').id('composer-attach')
          .onClick(() => { this.chooseAttachment(); })

        TextArea({ placeholder: '消息', text: this.inputText })
          .placeholderColor(ThemeColors.placeholder(this.theme))
          .placeholderFont({ size: 14, weight: FontWeight.Normal })
          .fontSize(15).fontColor(ThemeColors.text(this.theme))
          .backgroundColor(ThemeColors.inputBg(this.theme)).borderRadius(20)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .constraintSize({ maxHeight: 120, minHeight: 40 })
          .layoutWeight(1).maxLines(5)
          .onChange((value: string) => { this.inputText = value; })

        if (this.isGenerating) {
          Text('■')
            .fontSize(16).fontColor(ThemeColors.onPrimary(this.theme))
            .width(40).height(40).textAlign(TextAlign.Center)
            .backgroundColor(ThemeColors.dangerDot(this.theme)).borderRadius(20)
            .margin({ left: 8 })
            .accessibilityLevel('yes').accessibilityText('停止').id('composer-stop')
            .onClick(() => { this.onStopGeneration(); })
          if (this.inputText.trim().length > 0 || this.attachments.length > 0) {
            Text('↑')
              .fontSize(20).fontColor(ThemeColors.primary)
              .width(40).height(40).textAlign(TextAlign.Center)
              .backgroundColor(ThemeColors.primarySoft(this.theme)).borderRadius(20)
              .margin({ left: 6 })
              .accessibilityLevel('yes').accessibilityText('排队发送').id('composer-queue')
              .onClick(() => { this.handleSend(); })
          }
        } else if (this.inputText.trim().length > 0 || this.attachments.length > 0) {
          Text('↑')
            .fontSize(20).fontColor(ThemeColors.onPrimary(this.theme))
            .width(40).height(40).textAlign(TextAlign.Center)
            .backgroundColor(ThemeColors.primary).borderRadius(20)
            .margin({ left: 8 })
            .accessibilityLevel('yes').accessibilityText('发送').id('composer-send')
            .onClick(() => { this.handleSend(); })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(ThemeColors.card(this.theme))
      .border({ width: { top: 0.5 }, color: ThemeColors.border(this.theme) })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(ThemeColors.card(this.theme))
  }
}
