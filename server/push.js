/**
 * Push-уведомления через Firebase Cloud Messaging.
 * Требуется: FIREBASE_SERVICE_ACCOUNT — путь к JSON сервисного аккаунта Firebase.
 * Если не задан — push отключены.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { initializeApp, cert } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FCM_TOKENS_FILE = join(__dirname, 'data', 'fcm_tokens.json');

let messaging = null;
const fcmTokens = new Map(); // userId -> Set<token>

function loadFcmTokens() {
  try {
    if (existsSync(FCM_TOKENS_FILE)) {
      const data = JSON.parse(readFileSync(FCM_TOKENS_FILE, 'utf8'));
      for (const [userId, tokens] of Object.entries(data)) {
        if (Array.isArray(tokens) && tokens.length > 0) {
          fcmTokens.set(userId, new Set(tokens));
        }
      }
      console.log(`[push] Loaded FCM tokens for ${fcmTokens.size} users`);
    }
  } catch (e) {
    console.error('[push] Failed to load FCM tokens:', e.message);
  }
}

let _saveTokensTimer = null;
export function saveFcmTokens() {
  if (_saveTokensTimer) return;
  _saveTokensTimer = setTimeout(() => {
    _saveTokensTimer = null;
    try {
      const dir = dirname(FCM_TOKENS_FILE);
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      const data = {};
      for (const [userId, set] of fcmTokens) {
        if (set.size > 0) data[userId] = [...set];
      }
      writeFileSync(FCM_TOKENS_FILE, JSON.stringify(data), 'utf8');
    } catch (e) {
      console.error('[push] Failed to save FCM tokens:', e.message);
    }
  }, 3000);
}

function init() {
  loadFcmTokens();
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
  saveFcmTokens();
}

export function unregisterToken(userId, token) {
  const set = fcmTokens.get(userId);
  if (set) {
    set.delete(token);
    if (set.size === 0) fcmTokens.delete(userId);
    saveFcmTokens();
  }
}

async function sendToUser(userId, message) {
  if (!messaging) {
    console.log(`[push] Skip: Firebase not initialized`);
    return;
  }
  const tokens = fcmTokens.get(userId);
  if (!tokens || tokens.size === 0) {
    console.log(`[push] No FCM token for user ${userId} — recipient must open app once to register`);
    return;
  }
  const tokenList = [...tokens];
  // data-only: onBackgroundMessage вызывается всегда (foreground/background/killed).
  // notification+data на Android в фоне НЕ вызывает onBackgroundMessage — пуши не показываются.
  const payload = {
    tokens: tokenList,
    data: message.data,
    android: { priority: 'high' },
  };
  try {
    const res = await messaging.sendEachForMulticast(payload);
    if (res.failureCount > 0) {
      res.responses.forEach((r, i) => {
        if (!r.success) {
          console.error(`[push] FCM error for ${userId}:`, r.error?.code, r.error?.message);
          if (r.error?.code === 'messaging/invalid-registration-token' ||
              r.error?.code === 'messaging/registration-token-not-registered') {
            tokens.delete(tokenList[i]);
            saveFcmTokens();
          }
        }
      });
      console.error(`[push] Send to ${userId}: ${res.successCount} ok, ${res.failureCount} failed`);
    } else {
      console.log(`[push] Sent to ${userId} (${res.successCount} device(s)) OK`);
    }
  } catch (e) {
    console.error(`[push] Send failed for ${userId}:`, e.message);
  }
}

export async function sendMessagePush(recipientId, fromId, chatId, fromName) {
  const title = fromName ? `${fromName}` : 'Новое сообщение';
  const body = fromName ? 'Новое сообщение' : 'У вас новое сообщение';
  await sendToUser(recipientId, {
    data: {
      type: 'message',
      sender: fromId || '',
      fromName: fromName || '',
      chatId: chatId || '',
      title,
      body,
    },
  });
}

/// Push для отмены звонка: убирает CallKit нотификацию у офлайн-получателя.
export async function sendCancelPush(recipientId, callId) {
  await sendToUser(recipientId, {
    data: {
      type: 'call-cancelled',
      callId: callId || '',
    },
  });
}

/// Push для звонков: data-only. Background handler показывает CallKit.
export async function sendCallPush(recipientId, fromId, fromName, callId) {
  const name = (fromName && String(fromName).trim()) || 'Кто-то звонит';
  await sendToUser(recipientId, {
    data: {
      type: 'call',
      sender: fromId || '',
      fromName: name,
      callId: callId || '',
    },
  });
}

init();

export function isPushEnabled() {
  return !!messaging;
}
