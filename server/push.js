/**
 * Push-уведомления через Firebase Cloud Messaging.
 * Требуется: FIREBASE_SERVICE_ACCOUNT — путь к JSON сервисного аккаунта Firebase.
 * Если не задан — push отключены.
 */
import { readFileSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { initializeApp, cert } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';

const __dirname = dirname(fileURLToPath(import.meta.url));

let messaging = null;
const fcmTokens = new Map(); // userId -> Set<token>

function init() {
  const path = process.env.FIREBASE_SERVICE_ACCOUNT || join(__dirname, 'firebase-service-account.json');
  if (!existsSync(path)) {
    console.log(`[push] FIREBASE_SERVICE_ACCOUNT not found at ${path}, push disabled`);
    return;
  }
  try {
    const serviceAccount = JSON.parse(readFileSync(path, 'utf8'));
    initializeApp({ credential: cert(serviceAccount) });
    messaging = getMessaging();
    console.log('[push] Firebase initialized');
  } catch (e) {
    console.error('[push] Firebase init failed:', e.message);
  }
}

export function registerToken(userId, token) {
  if (!token || typeof token !== 'string') return;
  let set = fcmTokens.get(userId);
  if (!set) {
    set = new Set();
    fcmTokens.set(userId, set);
  }
  set.add(token);
  // Ограничение: макс 10 токенов на пользователя
  if (set.size > 10) {
    const arr = [...set];
    set.clear();
    arr.slice(-10).forEach(t => set.add(t));
  }
}

export function unregisterToken(userId, token) {
  const set = fcmTokens.get(userId);
  if (set) {
    set.delete(token);
    if (set.size === 0) fcmTokens.delete(userId);
  }
}

async function sendToUser(userId, message) {
  if (!messaging) return;
  const tokens = fcmTokens.get(userId);
  if (!tokens || tokens.size === 0) {
    console.log(`[push] No FCM token for user ${userId} — recipient must open app once to register`);
    return;
  }
  const tokenList = [...tokens];
  const payload = {
    tokens: tokenList,
    data: message.data,
    android: { priority: 'high' },
  };
  if (!message.dataOnly && message.notification) {
    payload.notification = message.notification;
    payload.android.notification = { channelId: 'black_square_messages', sound: 'default' };
  }
  try {
    const res = await messaging.sendEachForMulticast(payload);
    if (res.failureCount > 0) {
      res.responses.forEach((r, i) => {
        if (!r.success) {
          console.error(`[push] FCM error for ${userId}:`, r.error?.code, r.error?.message);
          if (r.error?.code === 'messaging/invalid-registration-token') {
            tokens.delete(tokenList[i]);
          }
        }
      });
      console.error(`[push] Send to ${userId}: ${res.successCount} ok, ${res.failureCount} failed`);
    } else {
      console.log(`[push] Sent to ${userId} (${res.successCount} device(s))`);
    }
  } catch (e) {
    console.error(`[push] Send failed for ${userId}:`, e.message);
  }
}

export async function sendMessagePush(recipientId, fromId, chatId, fromName) {
  const title = fromName ? `${fromName}` : 'Новое сообщение';
  const body = fromName ? 'Новое сообщение' : 'У вас новое сообщение';
  await sendToUser(recipientId, {
    notification: {
      title,
      body,
    },
    data: {
      type: 'message',
      sender: fromId || '',
      fromName: fromName || '',
      chatId: chatId || '',
    },
  });
}

/// Data-only push для звонков — приложение показывает экран и мелодию (full-screen intent в фоне)
export async function sendCallPush(recipientId, fromId, fromName, callId) {
  const name = (fromName && String(fromName).trim()) || 'Кто-то звонит';
  await sendToUser(recipientId, {
    dataOnly: true,
    data: {
      type: 'call',
      sender: fromId || '',
      fromName: name,
      callId: callId || '',
    },
  });
}

init();
