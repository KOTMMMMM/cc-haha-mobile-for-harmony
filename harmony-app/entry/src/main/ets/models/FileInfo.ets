export interface FileInfo {
  name: string;
  path: string;
  type: 'file' | 'directory';
  isDirectory: boolean;
  size?: number;
  modifiedAt?: number;
  extension?: string;
}

export function formatFileSize(bytes?: number): string {
  if (!bytes || bytes <= 0) { return '0 B'; }
  if (bytes < 1024) { return bytes + ' B'; }
  if (bytes < 1048576) { return (bytes / 1024).toFixed(1) + ' KB'; }
  return (bytes / 1048576).toFixed(1) + ' MB';
}

export function formatModifiedTime(ts?: number): string {
  if (!ts) { return ''; }
  const diff = Date.now() - ts;
  if (diff < 60000) { return '刚刚'; }
  if (diff < 3600000) { return Math.floor(diff / 60000) + '分钟前'; }
  if (diff < 86400000) { return Math.floor(diff / 3600000) + '小时前'; }
  return Math.floor(diff / 86400000) + '天前';
}
