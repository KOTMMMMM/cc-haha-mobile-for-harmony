export interface DiscoveredDevice {
  hostname: string;
  address: string;
  port: number;
  version: string;
  serverName: string;
}

export interface ConnectionConfig {
  host: string;
  port: number;
  token: string;
  /** http（局域网/Tailscale 直连）或 https（Cloudflare 公共访问配对） */
  scheme?: string;
  hostname?: string;
  origin?: string;
  /** 备用地址（局域网 IP / Tailscale IP），连接前会探测可达性并自动选择 */
  alternates?: string[];
}

export interface ProviderModel {
  id: string;
  name: string;
  providerId?: string;
  maxTokens?: number;
  description?: string;
}

export interface Provider {
  id: string;
  name: string;
  models: ProviderModel[];
}
