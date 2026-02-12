import { WebSocketServer } from 'ws';
import { createServer } from 'http';

const PORT = process.env.PORT || 8080;

// userId -> Set<WebSocket> (разные устройства одного юзера НЕ отключают друг друга)
const clients = new Map();
const pendingMessages = new Map();

function getClientSet(userId) {
  let set = clients.get(userId);
  if (!set) {
    set = new Set();
    clients.set(userId, set);
  }
  return set;
}

const server = createServer((req, res) => {
  if (req.url === '/health' || req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'black-square-server' }));
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({
  server,
  clientTracking: true,
  maxPayload: 100 * 1024 * 1024, // 100 MB для видео и больших файлов
});

// Ping каждые 30 сек — сохраняет соединения живыми
const PING_INTERVAL = 30000;
const connections = new Map(); // ws -> { userId, pingTimer }

wss.on('connection', (ws, req) => {
  const connId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  let userId = null;

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString());

      switch (msg.type) {
        case 'auth':
          userId = msg.userId;
          if (userId) {
            getClientSet(userId).add(ws);
            console.log(`[${new Date().toISOString()}] Connect: ${userId} (conn: ${connId}, total users: ${clients.size})`);

            const pending = pendingMessages.get(userId) || [];
            for (const m of pending) {
              ws.send(JSON.stringify(m));
            }
            pendingMessages.delete(userId);

            // Ping для поддержания соединения (предотвращает таймаут)
            const timer = setInterval(() => {
              if (ws.readyState === 1) {
                ws.ping();
              }
            }, PING_INTERVAL);
            connections.set(ws, { userId, timer });
          }
          break;

        case 'message':
          const { to, chatId, payload } = msg;
          const envelope = {
            type: 'message',
            from: userId,
            chatId,
            payload,
            timestamp: new Date().toISOString(),
          };

          const recipientSet = clients.get(to);
          const connected = recipientSet ? [...recipientSet].filter(w => w.readyState === 1) : [];
          if (connected.length > 0) {
            for (const w of connected) {
              try {
                w.send(JSON.stringify(envelope));
              } catch (e) {
                console.error(`[${new Date().toISOString()}] Send failed to ${to}:`, e.message);
              }
            }
            console.log(`[${new Date().toISOString()}] Message ${userId} -> ${to} (${connected.length} device(s))`);
          } else {
            const queue = pendingMessages.get(to) || [];
            queue.push(envelope);
            pendingMessages.set(to, queue);
            console.log(`[${new Date().toISOString()}] Message ${userId} -> ${to} (offline, queued)`);
          }
          break;

        case 'ping':
          ws.send(JSON.stringify({ type: 'pong' }));
          break;
      }
    } catch (e) {
      console.error('Parse error:', e.message);
    }
  });

  ws.on('close', () => {
    const conn = connections.get(ws);
    if (conn) {
      clearInterval(conn.timer);
      connections.delete(ws);
    }
    if (userId) {
      const set = clients.get(userId);
      if (set) {
        set.delete(ws);
        if (set.size === 0) clients.delete(userId);
        console.log(`[${new Date().toISOString()}] Disconnect: ${userId} (conn: ${connId}, devices left: ${set.size})`);
      }
    }
  });

  ws.on('error', (err) => {
    console.error(`[${connId}] WebSocket error:`, err.message);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Black Square server running on port ${PORT}`);
  console.log(`WebSocket: ws://0.0.0.0:${PORT}`);
});
