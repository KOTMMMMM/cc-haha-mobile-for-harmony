export interface AttachmentItem {
  type: string;      // 'image' | 'file'
  name: string;
  mimeType: string;
  data: string;      // base64
  size: number;
}
