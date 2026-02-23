import { WebSocketServer } from 'ws';
import { createServer } from 'http';
import { networkInterfaces } from 'os';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { registerToken, sendMessagePush, sendCallPush, isPushEnabled } from './push.js';

function getLocalIp() {
  const nets = networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name] || []) {
      if (net.family === 'IPv4' && !net.internal) return net.address;
    }
  }
  return 'localhost';
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 8080;
const PENDING_FILE = join(__dirname, 'data', 'pending.json');

// userId -> Set<WebSocket> (разные устройства одного юзера НЕ отключают друг друга)
const clients = new Map();
const pendingMessages = new Map();

// userId -> Map<contactId, name> — имена собеседников для пушей (имя, которое юзер ввёл при создании чата)
const contactNames = new Map();

// recipientId -> { offer, callerWs, callId, from, timeoutId } — буфер для офлайн получателей
const PENDING_CALL_TIMEOUT_MS = 60000; // 1 мин — caller ждёт
const pendingCalls = new Map();

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
    const raw = data.toString();
    const size = raw.length;
    // Лог больших сообщений (call-offer с SDP обычно 1–5 KB)
    if (size > 500) {
      console.log(`[${new Date().toISOString()}] IN large msg size=${size} preview=${raw.slice(0, 80)}...`);
    }
    try {
      const msg = JSON.parse(raw);
      const msgType = msg.type;

      // Лог всех входящих (кроме message — слишком часто)
      if (msgType && msgType !== 'message') {
        console.log(`[${new Date().toISOString()}] IN type=${msgType} size=${size} userId=${userId ?? 'null'}`);
      }

      switch (msgType) {
        case 'auth':
          userId = msg.userId;
          if (userId) {
            getClientSet(userId).add(ws);
            if (msg.fcmToken) {
              registerToken(userId, msg.fcmToken);
              console.log(`[${new Date().toISOString()}] FCM token registered for ${userId} [push]`);
            }
            if (msg.contactNames && typeof msg.contactNames === 'object') {
              contactNames.set(userId, new Map(Object.entries(msg.contactNames)));
            }
            console.log(`[${new Date().toISOString()}] Connect: ${userId} (conn: ${connId}, total users: ${clients.size})`);

            const pending = pendingMessages.get(userId) || [];
            for (const m of pending) {
              ws.send(JSON.stringify(m));
            }
            pendingMessages.delete(userId);
            savePending();

            // Буферизованный call-offer — доставляем при подключении
            const pendingCall = pendingCalls.get(userId);
            if (pendingCall) {
              clearTimeout(pendingCall.timeoutId);
              pendingCalls.delete(userId);
              try {
                ws.send(JSON.stringify(pendingCall.offer));
                console.log(`[${new Date().toISOString()}] Delivered buffered call-offer to ${userId} from ${pendingCall.from}`);
              } catch (e) {
                console.error(`[${new Date().toISOString()}] Failed to deliver buffered call:`, e.message);
              }
            }

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
          const { to, chatId, payload, fromName } = msg;
          const envelope = {
            type: 'message',
            from: userId,
            chatId,
            payload,
            timestamp: new Date().toISOString(),
            ...(fromName && { fromName }),
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
            console.log(`[${new Date().toISOString()}] Message ${userId} -> ${to} (${connected.length} device(s), no push — recipient online)`);
          } else {
            const queue = pendingMessages.get(to) || [];
            queue.push(envelope);
            pendingMessages.set(to, queue);
            savePending();
            const pushName = contactNames.get(to)?.get(userId) || fromName;
            console.log(`[${new Date().toISOString()}] Message ${userId} -> ${to} (offline, queued, sending push)`);
            sendMessagePush(to, userId, chatId, pushName).catch((e) => console.error(`[push] Message push failed:`, e.message));
            console.log(`[${new Date().toISOString()}] Message ${userId} -> ${to} (offline, queued, push sent)`);
          }
          break;

        case 'set-contact-name':
          if (userId) {
            const contactId = msg.contactId;
            const name = msg.name;
            if (contactId && typeof name === 'string' && name.trim()) {
              let map = contactNames.get(userId);
              if (!map) {
                map = new Map();
                contactNames.set(userId, map);
              }
              map.set(contactId, name.trim());
            }
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
        case 'call-reoffer':
        case 'call-reanswer':
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
          // call-hangup от звонящего: если получатель офлайн — ставим «Звонок пропущен» в очередь
          if (msg.type === 'call-hangup' && callConnected.length === 0) {
            const pc = pendingCalls.get(callTo);
            if (pc?.callId === msg.callId) {
              clearTimeout(pc.timeoutId);
              pendingCalls.delete(callTo);
            }
            const missed = { type: 'call-missed', from: userId, callId: msg.callId };
            const q = pendingMessages.get(callTo) || [];
            q.push(missed);
            pendingMessages.set(callTo, q);
            savePending();
            console.log(`[${new Date().toISOString()}] Call hangup ${userId} -> ${callTo} (offline, call-missed queued)`);
          }
          // Push только когда получатель офлайн — иначе экран звонка показывается сразу через WebSocket
          if (msg.type === 'call-offer' && callConnected.length === 0) {
            const pushName = contactNames.get(callTo)?.get(userId) || msg.callerName || null;
            console.log(`[${new Date().toISOString()}] Call ${userId} -> ${callTo} (offline, sending push)`);
            sendCallPush(callTo, userId, pushName, msg.callId).catch((e) => console.error(`[push] Call push failed:`, e.message));
          }
          if (callConnected.length === 0) {
            if (msg.type === 'call-offer') {
              const timeoutId = setTimeout(() => {
                if (pendingCalls.get(callTo)?.callId === msg.callId) {
                  pendingCalls.delete(callTo);
                  try {
                    ws.send(JSON.stringify({ type: 'call-hangup', callId: msg.callId, reason: 'offline' }));
                  } catch (_) {}
                  // Уведомляем получателя о пропущенном звонке (доставится при подключении)
                  const missed = { type: 'call-missed', from: userId, callId: msg.callId };
                  const q = pendingMessages.get(callTo) || [];
                  q.push(missed);
                  pendingMessages.set(callTo, q);
                  savePending();
                  console.log(`[${new Date().toISOString()}] Call timeout: ${userId} -> ${callTo}, call-missed queued`);
                }
              }, PENDING_CALL_TIMEOUT_MS);
              pendingCalls.set(callTo, {
                offer: callEnvelope,
                callerWs: ws,
                callId: msg.callId,
                from: userId,
                timeoutId,
              });
              console.log(`[${new Date().toISOString()}] Call ${msg.type} ${userId} -> ${callTo} (offline, buffered, push sent)`);
            } else if (msg.type === 'call-ice') {
              ws.send(JSON.stringify({ type: 'call-hangup', callId: msg.callId, reason: 'offline' }));
            }
            if (msg.type !== 'call-offer') {
              console.log(`[${new Date().toISOString()}] Call ${msg.type} ${userId} -> ${callTo} (recipient offline)`);
            }
          } else {
            console.log(`[${new Date().toISOString()}] Call ${msg.type} ${userId} -> ${callTo} (${callConnected.length} device(s), no push — recipient online)`);
          }
          break;
      }
    } catch (e) {
      console.error(`[${new Date().toISOString()}] Parse error: ${e.message}, msg length=${raw?.length ?? 0}, preview=${raw?.slice(0, 100)}`);
    }
  });

  ws.on('close', () => {
    const conn = connections.get(ws);
    if (conn) {
      clearInterval(conn.timer);
      connections.delete(ws);
    }
    for (const [recipientId, pc] of pendingCalls.entries()) {
      if (pc.callerWs === ws) {
        clearTimeout(pc.timeoutId);
        pendingCalls.delete(recipientId);
        const missed = { type: 'call-missed', from: pc.from, callId: pc.callId };
        const q = pendingMessages.get(recipientId) || [];
        q.push(missed);
        pendingMessages.set(recipientId, q);
        savePending();
        console.log(`[${new Date().toISOString()}] Pending call cancelled: caller disconnected, call-missed queued for ${recipientId}`);
      }
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
  const host = process.env.PUBLIC_HOST || getLocalIp();
  const pushStatus = isPushEnabled() ? 'enabled' : 'DISABLED (no firebase-service-account.json)';
  console.log(`Black Square server on port ${PORT}`);
  console.log(`WebSocket: ws://${host}:${PORT}`);
  console.log(`[push] ${pushStatus}`);
});
