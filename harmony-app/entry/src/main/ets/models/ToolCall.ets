export function getToolStatusText(status: string): string {
  switch (status) {
    case 'running': return '执行中';
    case 'completed':
    case 'success': return '完成';
    case 'error': return '失败';
    case 'pending': return '等待中';
    default: return status;
  }
}
