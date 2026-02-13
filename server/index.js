import { WebSocketServer } from 'ws';
import { createServer } from 'http';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 8080;
const PENDING_FILE = join(__dirname, 'data', 'pending.json');

// userId -> Set<WebSocket> (разные устройства одного юзера НЕ отключают друг друга)
const clients = new Map();
const pendingMessages = new Map();

function loadPending() {
  try {
    if (existsSync(PENDING_FILE)) {
      const data = JSON.parse(readFileSync(PENDING_FILE, 'utf8'));
      for (const [userId, arr] of Object.entries(data)) {
        if (Array.isArray(arr) && arr.length > 0) {
          pendingMessages.set(userId, arr);
        }
      }
      const total = [...pendingMessages.values()].reduce((s, arr) => s + arr.length, 0);
      console.log(`[${new Date().toISOString()}] Loaded ${total} pending messages for ${pendingMessages.size} users`);
    }
  } catch (e) {
    console.error('Failed to load pending messages:', e.message);
  }
}

function savePending() {
  try {
    const dir = dirname(PENDING_FILE);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data = {};
    for (const [userId, arr] of pendingMessages) {
      if (arr.length > 0) data[userId] = arr;
    }
    writeFileSync(PENDING_FILE, JSON.stringify(data), 'utf8');
  } catch (e) {
    console.error('Failed to save pending messages:', e.message);
  }
}

loadPending();

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

      // Лог входящих call-сигналов для отладки
      if (msg.type && String(msg.type).startsWith('call-')) {
        console.log(`[${new Date().toISOString()}] IN call: type=${msg.type} userId=${userId ?? 'null'} to=${msg.to ?? 'null'}`);
      }

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
            savePending();

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
            savePending();
            console.log(`[${new Date().toISOString()}] Message ${userId} -> ${to} (offline, queued)`);
          }
          break;

        case 'ping':
          ws.send(JSON.stringify({ type: 'pong' }));
          break;

        case 'call-offer':
        case 'call-answer':
        case 'call-ice':
        case 'call-hangup':
        case 'call-reject':
          if (!userId) {
            console.warn(`[${new Date().toISOString()}] Call signal ignored: sender not authenticated`);
            break;
          }
          const callTo = msg.to;
          if (!callTo) {
            console.warn(`[${new Date().toISOString()}] Call signal ignored: missing 'to' field`);
            break;
          }
          const callEnvelope = { ...msg, from: userId };
          const callRecipientSet = clients.get(callTo);
          const callConnected = callRecipientSet ? [...callRecipientSet].filter(w => w.readyState === 1) : [];

          // Подтверждение для call-offer: отправитель узнает, дошёл ли сигнал до сервера
          if (msg.type === 'call-offer') {
            try {
              ws.send(JSON.stringify({
                type: 'call-offer-ack',
                callId: msg.callId,
                recipientOnline: callConnected.length > 0,
                usersOnline: clients.size,
              }));
            } catch (e) {
              console.error(`[${new Date().toISOString()}] Failed to send call-offer-ack:`, e.message);
            }
          }

          for (const w of callConnected) {
            try {
              w.send(JSON.stringify(callEnvelope));
            } catch (e) {
              console.error(`[${new Date().toISOString()}] Call signal failed to ${callTo}:`, e.message);
            }
          }
          if (callConnected.length === 0) {
            if (msg.type === 'call-offer' || msg.type === 'call-ice') {
              ws.send(JSON.stringify({ type: 'call-hangup', callId: msg.callId, reason: 'offline' }));
            }
            console.log(`[${new Date().toISOString()}] Call ${msg.type} ${userId} -> ${callTo} (recipient offline, ${clients.size} users online)`);
          } else {
            console.log(`[${new Date().toISOString()}] Call ${msg.type} ${userId} -> ${callTo} (${callConnected.length} device(s))`);
          }
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
