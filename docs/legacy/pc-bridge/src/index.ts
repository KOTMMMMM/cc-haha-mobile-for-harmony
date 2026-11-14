// ============================================================================
// PC Bridge Server - Main Entry Point
//
// Starts the HTTP server (REST API + WebSocket) and discovery service,
// bridging the HarmonyOS Next mobile app with the cc-haha CLI.
//
// Usage:
//   bun run src/index.ts
//   bun --watch run src/index.ts  (development with hot reload)
// ============================================================================

import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { loadConfig, validateConfig, type Config } from './config.js';
import { registerRoutes, handleRequest } from './api/routes.js';
import { startWebSocketServer, stopWebSocketServer, initPermissionHandler } from './api/websocket.js';
import { startDiscovery, stopDiscovery } from './discovery.js';
import { cleanupAll, setMaxSessions } from './session-manager.js';

// ---------------------------------------------------------------------------
// Banner
// ---------------------------------------------------------------------------

function printBanner(config: Config): void {
  const banner = [
    '',
    '  ============================================================',
    '        CC-HAHA PC Bridge Server v1.0.0',
    '        Middleware for HarmonyOS Next Mobile App',
    '  ============================================================',
    '',
    '  HTTP Server:  http://' + config.host + ':' + config.port,
    '  Health Check: http://localhost:' + config.port + '/health',
    '  WebSocket:    ws://localhost:' + config.port + '/ws',
    '  Max Sessions: ' + config.maxSessions,
    '  Discovery:    ' + (config.discoveryEnabled ? 'enabled (port ' + config.discoveryPort + ')' : 'disabled'),
    '  CLI Path:     ' + config.claudeHahaPath,
    '',
    '  Pairing: POST /api/pair/request -> POST /api/pair/verify',
    '  Sessions: GET/POST /api/sessions',
    '',
  ].join('\n');
  console.log(banner);
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  try {
    const config = loadConfig();
    validateConfig(config);

    setMaxSessions(config.maxSessions);

    registerRoutes(config);

    const httpServer = createServer((req: IncomingMessage, res: ServerResponse) => {
      handleRequest(req, res, config);
    });

    startWebSocketServer(httpServer, config);

    initPermissionHandler();

    await new Promise<void>((resolve, reject) => {
      httpServer.listen(config.port, config.host, () => {
        console.log('[index] HTTP server listening on ' + config.host + ':' + config.port);
        resolve();
      });

      httpServer.on('error', (err: NodeJS.ErrnoException) => {
        if (err.code === 'EADDRINUSE') {
          console.error(
            '[index] ERROR: Port ' + config.port + ' is already in use. Is another bridge running?',
          );
          reject(err);
        } else {
          console.error('[index] HTTP server error:', err);
          reject(err);
        }
      });
    });

    if (config.discoveryEnabled) {
      try {
        startDiscovery(
          config.port,
          config.discoveryPort,
          config.discoveryIntervalMs,
        );
      } catch (err) {
        console.error('[index] Failed to start discovery service:', err);
        console.log('[index] Continuing without LAN discovery...');
      }
    }

    printBanner(config);

    let shuttingDown = false;

    const shutdown = async (signal: string): Promise<void> => {
      if (shuttingDown) return;
      shuttingDown = true;

      console.log('');
      console.log('[index] Received ' + signal + ', shutting down...');

      stopDiscovery();
      stopWebSocketServer();
      cleanupAll();

      await new Promise<void>((resolve) => {
        httpServer.close(() => {
          console.log('[index] HTTP server closed');
          resolve();
        });

        setTimeout(() => {
          console.warn('[index] HTTP server did not close gracefully, forcing...');
          resolve();
        }, 5000);
      });

      console.log('[index] Shutdown complete. Goodbye!');
      process.exit(0);
    };

    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));

    process.on('uncaughtException', (err: Error) => {
      console.error('[index] Uncaught exception:', err);
      if (!shuttingDown) {
        shutdown('uncaughtException');
      }
    });

    process.on('unhandledRejection', (reason: unknown) => {
      console.error('[index] Unhandled rejection:', reason);
      if (!shuttingDown) {
        shutdown('unhandledRejection');
      }
    });

    console.log('[index] Bridge server is ready. Press Ctrl+C to stop.');
  } catch (err) {
    console.error('[index] Fatal error during startup:', err);
    process.exit(1);
  }
}

main();
