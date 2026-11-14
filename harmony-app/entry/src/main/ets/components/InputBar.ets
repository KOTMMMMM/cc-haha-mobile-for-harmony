import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AttachmentItem } from '../models/Attachment';
import { Logger } from '../utils/Logger';

@Component
export struct InputBar {
  @Prop sessionId: string = '';
  @Prop isGenerating: boolean = false;
  onSendMessage: (message: string, attachments: AttachmentItem[]) => void = () => {};
  onStopGeneration: () => void = () => {};
  @State inputText: string = '';
  @State attachments: AttachmentItem[] = [];

  private chooseAttachment(): void {
    AlertDialog.show({
      title: '添加附件',
      message: '选择要发送的内容类型',
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
    if ((text.length === 0 && this.attachments.length === 0) || this.isGenerating) { return; }
    this.onSendMessage(text, this.attachments);
    this.inputText = '';
    this.attachments = [];
  }

  build() {
    Column() {
      if (this.attachments.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.attachments, (a: AttachmentItem, i: number) => {
            Row() {
              Text(a.type === 'image' ? '🖼' : '📄').fontSize(12).margin({ right: 4 })
              Text(a.name).fontSize(12).fontColor('#333').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 160 })
              Text('×').fontSize(14).fontColor('#999').margin({ left: 6 })
                .onClick(() => { this.removeAttachment(i); })
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('#F0F0F0').borderRadius(12)
            .margin({ right: 6, bottom: 4 })
          }, (a: AttachmentItem, i: number): string => 'att_' + i + '_' + a.name)
        }
        .width('100%').padding({ left: 12, right: 12, top: 6 })
      }

      Row() {
        Text('📎')
          .fontSize(20)
          .padding(4)
          .margin({ right: 4 })
          .onClick(() => { this.chooseAttachment(); })

        TextArea({ placeholder: '输入消息...', text: this.inputText })
          .placeholderColor('#BBB')
          .placeholderFont({ size: 14, weight: FontWeight.Normal })
          .fontSize(15).fontColor('#333')
          .backgroundColor('#F5F5F5').borderRadius(20)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .constraintSize({ maxHeight: 120, minHeight: 40 })
          .layoutWeight(1).maxLines(5)
          .onChange((value: string) => { this.inputText = value; })

        if (this.isGenerating) {
          Button('停止')
            .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
            .backgroundColor('#F44336').borderRadius(20)
            .height(40).padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .onClick(() => { this.onStopGeneration(); })
        } else if (this.inputText.trim().length > 0 || this.attachments.length > 0) {
          Button('发送')
            .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
            .backgroundColor('#1677FF').borderRadius(20)
            .height(40).padding({ left: 16, right: 16 })
            .onClick(() => { this.handleSend(); })
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')
      .border({ width: { top: 0.5 }, color: '#E5E5E5' })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
  }
}
