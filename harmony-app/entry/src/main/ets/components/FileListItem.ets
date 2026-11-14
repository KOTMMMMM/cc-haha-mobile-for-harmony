import { FileInfo, formatFileSize, formatModifiedTime } from '../models/FileInfo';

@Component
export struct FileListItem {
  @Prop file: FileInfo = { name: '', path: '', type: 'file', isDirectory: false };
  onTap: (file: FileInfo) => void = (f: FileInfo) => {};

  build() {
    Row() {
      Column() {
        Text(this.file.isDirectory ? 'Dir' : 'File')
          .fontSize(12).fontColor(this.file.isDirectory ? '#FFB74D' : '#90A4AE')
      }
      .width(44).height(44).borderRadius(10)
      .backgroundColor(this.file.isDirectory ? 'rgba(255,183,77,0.15)' : 'rgba(144,164,174,0.1)')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

      Column() {
        Text(this.file.name)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#333')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Row() {
          if (!this.file.isDirectory) {
            Text(formatFileSize(this.file.size)).fontSize(12).fontColor('#999')
          }
          Text(formatModifiedTime(this.file.modifiedAt)).fontSize(12).fontColor('#999')
            .margin({ left: this.file.isDirectory ? 0 : 8 })
          if (this.file.extension) {
            Text(this.file.extension).fontSize(12).fontColor('#999').margin({ left: 8 })
          }
        }.margin({ top: 2 })
      }
      .layoutWeight(1).margin({ left: 12 })

      if (this.file.isDirectory) {
        Text('>').fontSize(16).fontColor('#CCC')
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
    .onClick(() => { this.onTap(this.file); })
  }
}
