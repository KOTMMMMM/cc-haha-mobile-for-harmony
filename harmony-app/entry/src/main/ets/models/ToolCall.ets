export interface ToolCallInfo {
  toolId: string;
  toolName: string;
  toolIcon: string;
  status: 'pending' | 'running' | 'completed' | 'error';
  input: Record<string, Object>;
  output?: string;
  expanded: boolean;
}

export function getToolColor(status: string): string {
  switch (status) {
    case 'running': return '#1677FF';
    case 'completed':
    case 'success': return '#52C41A';
    case 'error': return '#FF4D4F';
    default: return '#8C8C8C';
  }
}

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

export class ToolIconHelper {
  static getIcon(toolName: string): string {
    const name = toolName.toLowerCase();
    if (name.includes('bash')) return '\uE90F';
    if (name.includes('read')) return '\uE910';
    if (name.includes('edit') || name.includes('write')) return '\uE911';
    if (name.includes('grep') || name.includes('glob')) return '\uE912';
    if (name.includes('web') || name.includes('fetch')) return '\uE913';
    if (name.includes('task') || name.includes('agent')) return '\uE914';
    if (name.includes('todo')) return '\uE915';
    return '\uE916';
  }

  static getColor(status: string): string {
    switch (status) {
      case 'running': return '#1677FF';
      case 'completed': return '#52C41A';
      case 'error': return '#FF4D4F';
      default: return '#8C8C8C';
    }
  }
}
