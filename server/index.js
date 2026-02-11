import { WebSocketServer } from 'ws';
import { createServer } from 'http';

const PORT = process.env.PORT || 8080;

// userId -> WebSocket
const clients = new Map();
const pendingMessages = new Map();

const server = createServer((req, res) => {
  // Health check для Railway/Render
  if (req.url === '/health' || req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'black-square-server' }));
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
  let userId = null;

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString());

      switch (msg.type) {
        case 'auth':
          userId = msg.userId;
          if (userId) {
            clients.set(userId, ws);
            console.log(`[${new Date().toISOString()}] User connected: ${userId}`);

            const pending = pendingMessages.get(userId) || [];
            for (const m of pending) {
              ws.send(JSON.stringify(m));
            }
            pendingMessages.delete(userId);
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

          const recipient = clients.get(to);
          if (recipient && recipient.readyState === 1) {
            recipient.send(JSON.stringify(envelope));
          } else {
            const queue = pendingMessages.get(to) || [];
            queue.push(envelope);
            pendingMessages.set(to, queue);
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
    if (userId) {
      clients.delete(userId);
      console.log(`[${new Date().toISOString()}] User disconnected: ${userId}`);
    }
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err.message);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Black Square server running on port ${PORT}`);
  console.log(`WebSocket: ws://0.0.0.0:${PORT}`);
});
