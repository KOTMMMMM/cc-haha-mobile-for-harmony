import { FileInfo } from '../models/FileInfo';
import { FileListItem } from '../components/FileListItem';
import { ApiService } from '../services/ApiService';
import { SessionService } from '../services/SessionService';
import { Logger } from '../utils/Logger';

@Component
export struct FilesPage {
  @StorageLink('apiService') apiService: ApiService = new ApiService();
  @StorageLink('sessionService') sessionService: SessionService = new SessionService();
  @State currentPath: string = '';
  @State files: FileInfo[] = [];
  @State isLoading: boolean = false;
  @State pathHistory: string[] = [];

  aboutToAppear(): void {
    const session = this.sessionService.getCurrentSession();
    if (session && session.workDir) {
      this.currentPath = session.workDir;
      this.pathHistory = [session.workDir];
    }
    this.loadFiles();
  }

  async loadFiles(): Promise<void> {
    this.isLoading = true;
    try {
      const result = await this.apiService.browseFiles(this.currentPath);
      if (result) {
        this.files = result.entries;
        this.currentPath = result.currentPath;
        if (this.pathHistory.length === 0) { this.pathHistory = [result.currentPath]; }
      } else {
        this.files = [];
        Logger.warn('browseFiles returned null for ' + this.currentPath);
      }
    } catch (err) {
      Logger.error('Failed to load files: ' + (err as Error).message);
      this.files = [];
    } finally { this.isLoading = false; }
  }

  onFileTap(file: FileInfo): void {
    if (file.isDirectory) {
      this.pathHistory.push(file.path);
      this.currentPath = file.path;
      this.files = [];
      this.loadFiles();
    }
  }

  goBack(): void {
    if (this.pathHistory.length > 1) {
      this.pathHistory.pop();
      this.currentPath = this.pathHistory[this.pathHistory.length - 1];
      this.files = [];
      this.loadFiles();
    }
  }

  build() {
    Column() {
      if (this.pathHistory.length > 1) {
        Row() {
          Button('<').type(ButtonType.Circle).backgroundColor(Color.Transparent)
            .width(28).height(28).fontColor('#999')
            .onClick(() => { this.goBack(); })
          Text(this.currentPath).fontSize(13).fontColor('#666')
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').padding({ left: 8, right: 16, top: 8, bottom: 4 })
          .backgroundColor('#FFFFFF').border({ width: { bottom: 0.5 }, color: '#E5E5E5' })
      }

      Row() {
        Text(this.currentPath || '浏览中...').fontSize(11).fontColor('#BBB').layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.isLoading) {
          LoadingProgress().width(14).height(14).color('#1677FF')
        } else {
          Text(this.files.length + ' 项').fontSize(11).fontColor('#BBB')
        }
      }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 }).backgroundColor('#FAFAFA')

      if (this.files.length === 0 && !this.isLoading) {
        Column() {
          Text('此目录为空').fontSize(16).fontColor('#999')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.files, (file: FileInfo) => {
            ListItem() {
              FileListItem({
                file: file,
                onTap: (f: FileInfo): void => { this.onFileTap(f); }
              })
            }
          }, (f: FileInfo) => f.path)
        }
        .scrollBar(BarState.Off).layoutWeight(1).width('100%').backgroundColor('#FFFFFF')
      }
    }.width('100%').height('100%').backgroundColor('#F8F8F8')
  }
}
