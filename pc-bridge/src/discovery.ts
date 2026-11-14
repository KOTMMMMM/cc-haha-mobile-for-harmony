// ============================================================================
// Discovery Service - UDP broadcast for phone to find the PC bridge
// ============================================================================

import dgram from 'node:dgram';
import { networkInterfaces, hostname } from 'node:os';
import type { DiscoveryBroadcast } from './types.js';

const MULTICAST_ADDR = '224.0.0.114';
const DISCOVERY_PORT = 3458;

let broadcastSocket: dgram.Socket | null = null;
let listenSocket: dgram.Socket | null = null;
let broadcastTimer: ReturnType<typeof setInterval> | null = null;
let isRunning = false;

function getLocalAddresses(): string[] {
  const interfaces = networkInterfaces();
  const addresses: string[] = [];

  for (const [, netInfo] of Object.entries(interfaces)) {
    if (!netInfo) continue;
    for (const info of netInfo) {
      if (info.family === 'IPv4' && !info.internal) {
        addresses.push(info.address);
      }
    }
  }

  return addresses;
}

export function startDiscovery(
  port: number,
  discoveryPort: number = DISCOVERY_PORT,
  intervalMs: number = 10_000,
): void {
  if (isRunning) {
    console.warn('[discovery] Service already running, ignoring start()');
    return;
  }

  console.log('[discovery] Starting discovery service on port ' + discoveryPort + '...');

  const localHostname = hostname();
  const localAddresses = getLocalAddresses();

  console.log(
    '[discovery] Local hostname: ' + localHostname + ', addresses: ' + localAddresses.join(', '),
  );

  broadcastSocket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  broadcastSocket.on('error', (err) => {
    console.error('[discovery] Broadcast socket error:', err);
  });

  broadcastSocket.on('listening', () => {
    console.log('[discovery] Broadcast socket listening');
    if (broadcastSocket) {
      broadcastSocket.setBroadcast(true);
      broadcastSocket.setMulticastTTL(128);
      broadcastSocket.setMulticastLoopback(false);
    }
  });

  broadcastSocket.bind(0, () => {
    console.log('[discovery] Broadcast socket bound');
  });

  const broadcastMessage = (): void => {
    if (!broadcastSocket) return;

    const announcement: DiscoveryBroadcast = {
      type: 'cc-haha-bridge',
      port,
      hostname: localHostname,
      version: '1.0.0',
      serverName: localHostname,
      timestamp: Date.now(),
    };

    const data = Buffer.from(JSON.stringify(announcement), 'utf8');
    const sent = new Set<string>();

    const sendTo = (addr: string, p: number): void => {
      const key = addr + ':' + p;
      if (sent.has(key)) return;
      sent.add(key);

      broadcastSocket!.send(data, 0, data.length, p, addr, (err) => {
        if (err) {
          console.warn(
            '[discovery] Failed to broadcast to ' + addr + ':' + p + ': ' + err.message,
          );
        }
      });
    };

    sendTo(MULTICAST_ADDR, discoveryPort);

    for (const addr of localAddresses) {
      const parts = addr.split('.');
      if (parts.length === 4) {
        const broadcastAddr = parts[0] + '.' + parts[1] + '.' + parts[2] + '.255';
        sendTo(broadcastAddr, discoveryPort);
      }
    }

    sendTo('127.0.0.1', discoveryPort);

    console.log(
      '[discovery] Broadcast sent to ' + sent.size + ' destination(s)',
    );
  };

  broadcastMessage();
  broadcastTimer = setInterval(broadcastMessage, intervalMs);

  listenSocket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  listenSocket.on('error', (err) => {
    console.error('[discovery] Listen socket error:', err);
  });

  listenSocket.on('message', (msg: Buffer, rinfo: dgram.RemoteInfo) => {
    const msgStr = msg.toString('utf8').trim();

    let parsed: Record<string, unknown> | null = null;
    try {
      parsed = JSON.parse(msgStr);
    } catch {
      // Not JSON
    }

    const isQuery =
      (parsed && parsed['type'] === 'cc-haha-bridge-query') ||
      msgStr === 'cc-haha-bridge-query' ||
      msgStr === 'DISCOVER_CC_HAHA' ||
      (parsed && parsed['action'] === 'discover');

    if (isQuery) {
      console.log(
        '[discovery] Received query from ' + rinfo.address + ':' + rinfo.port,
      );

      const response: DiscoveryBroadcast = {
        type: 'cc-haha-bridge',
        port,
        hostname: localHostname,
        version: '1.0.0',
        serverName: localHostname,
        timestamp: Date.now(),
      };

      const responseData = Buffer.from(JSON.stringify(response), 'utf8');
      listenSocket!.send(
        responseData,
        0,
        responseData.length,
        rinfo.port,
        rinfo.address,
        (err) => {
          if (err) {
            console.warn(
              '[discovery] Failed to respond to ' + rinfo.address + ':' + rinfo.port + ': ' + err.message,
            );
          } else {
            console.log(
              '[discovery] Response sent to ' + rinfo.address + ':' + rinfo.port,
            );
          }
        },
      );
    }
  });

  listenSocket.on('listening', () => {
    const address = listenSocket!.address();
    console.log(
      '[discovery] Listen socket bound to ' + address.address + ':' + address.port,
    );
  });

  listenSocket.bind(discoveryPort, '0.0.0.0', () => {
    console.log(
      '[discovery] Listen socket ready on port ' + discoveryPort,
    );

    for (const addr of localAddresses) {
      try {
        listenSocket!.addMembership(MULTICAST_ADDR, addr);
        console.log(
          '[discovery] Joined multicast group ' + MULTICAST_ADDR + ' on ' + addr,
        );
      } catch (err) {
        console.warn(
          '[discovery] Failed to join multicast on ' + addr + ': ' + (err as Error).message,
        );
      }
    }

    try {
      listenSocket!.addMembership(MULTICAST_ADDR, '127.0.0.1');
    } catch {
      // Loopback multicast may not be supported
    }
  });

  isRunning = true;
  console.log('[discovery] Discovery service started successfully');
}

export function stopDiscovery(): void {
  console.log('[discovery] Stopping discovery service...');

  if (broadcastTimer) {
    clearInterval(broadcastTimer);
    broadcastTimer = null;
    console.log('[discovery] Broadcast timer stopped');
  }

  if (broadcastSocket) {
    try {
      broadcastSocket.close();
      console.log('[discovery] Broadcast socket closed');
    } catch (err) {
      console.warn('[discovery] Error closing broadcast socket:', err);
    }
    broadcastSocket = null;
  }

  if (listenSocket) {
    try {
      listenSocket.close();
      console.log('[discovery] Listen socket closed');
    } catch (err) {
      console.warn('[discovery] Error closing listen socket:', err);
    }
    listenSocket = null;
  }

  isRunning = false;
  console.log('[discovery] Discovery service stopped');
}

export function isDiscoveryRunning(): boolean {
  return isRunning;
}
