export interface TailscaleRequest {
  action: string;
  controlUrl: string;
  createdAtMs: number;
  /** 可选：一次性 Auth Key，扩展读取后会从 request.json 清除 */
  authKey?: string;
}

export interface TailscaleStatus {
  state: string;
  detail: string;
  authUrl: string;
  selfIpv4: string;
  selfIpv6: string;
  routes: string;
  errorCode: number;
  engineVersion: string;
  heartbeatAt: number;
  updatedAtMs: number;
}

export function emptyTailscaleStatus(): TailscaleStatus {
  return {
    state: 'idle',
    detail: '',
    authUrl: '',
    selfIpv4: '',
    selfIpv6: '',
    routes: '',
    errorCode: 0,
    engineVersion: '',
    heartbeatAt: 0,
    updatedAtMs: 0
  };
}
