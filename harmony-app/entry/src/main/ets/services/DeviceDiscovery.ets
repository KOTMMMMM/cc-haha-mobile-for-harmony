import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { DiscoveredDevice } from '../models/ConnectionConfig';
import { Constants } from '../utils/Constants';
import { Logger } from '../utils/Logger';

// 与 pc-bridge 服务端 discovery.ts 协议一致
const MULTICAST_ADDR: string = '224.0.0.114';
const QUERY_MSG: string = 'cc-haha-bridge-query';

export class DeviceDiscovery {
  private udp: socket.UDPSocket | null = null;
  private scanning: boolean = false;
  private scanTimer: number = -1;

  startDiscovery(callback: (device: DiscoveredDevice) => void): void {
    if (this.scanning) { return; }
    this.scanning = true;
    this.udp = socket.constructUDPSocketInstance();

    this.udp.bind({ address: '0.0.0.0', port: Constants.DISCOVERY_PORT, family: 1 }).then(() => {
      this.udp!.on('message', (data: socket.SocketMessageInfo) => {
        try {
          const decoder = new util.TextDecoder('utf-8');
          const txt = decoder.decodeWithStream(new Uint8Array(data.message), { stream: false });
          const parsed: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
          if (parsed['type'] === 'cc-haha-bridge') {
            callback({
              hostname: (parsed['hostname'] as string) || '',
              address: data.remoteInfo.address,
              port: (parsed['port'] as number) || 0,
              version: (parsed['version'] as string) || '1.0.0',
              serverName: (parsed['serverName'] as string) || (parsed['hostname'] as string) || ''
            });
          }
        } catch (e) {
          Logger.debug('discovery: ignore non-JSON broadcast');
        }
      });
      this.sendQuery();
      this.scanTimer = setInterval(() => { if (this.scanning) { this.sendQuery(); } }, 3000);
    }).catch((err: Error) => {
      Logger.error('Discovery bind failed: ' + err.message);
      this.scanning = false;
    });

    setTimeout(() => { this.stopDiscovery(); }, Constants.DISCOVERY_TIMEOUT_MS);
  }

  private sendQuery(): void {
    if (!this.udp) { return; }
    try {
      this.udp.send({
        data: QUERY_MSG,
        address: { address: MULTICAST_ADDR, port: Constants.DISCOVERY_PORT, family: 1 }
      });
    } catch (e) {
      Logger.warn('discovery query send failed: ' + (e as Error).message);
    }
  }

  stopDiscovery(): void {
    this.scanning = false;
    if (this.scanTimer !== -1) { clearInterval(this.scanTimer); this.scanTimer = -1; }
    if (this.udp) {
      try {
        this.udp.off('message');
        this.udp.close();
      } catch (e) {
        Logger.debug('discovery close ignored: ' + (e as Error).message);
      }
      this.udp = null;
    }
  }

  getIsScanning(): boolean { return this.scanning; }
}
