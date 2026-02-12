# Развёртывание Black Square Server

## Cloud.ru / VPS (PM2)

Для сервера на cloud.ru или любом VPS с Linux:

```bash
# 1. Установить PM2 глобально (если ещё нет)
npm i -g pm2

# 2. Запустить сервер
cd server
pm2 start ecosystem.config.cjs

# 3. Сохранить список процессов
pm2 save

# 4. Настроить автозапуск при перезагрузке сервера
pm2 startup
# Выполнить команду, которую выведет PM2 (обычно с sudo)
```

После этого сервер будет:
- **Автоматически перезапускаться** при падении (краш, нехватка памяти)
- **Запускаться при перезагрузке** облачной машины

Полезные команды:
- `pm2 logs black-square` — логи
- `pm2 status` — статус процессов
- `pm2 restart black-square` — перезапуск

---

## Railway (рекомендуется)

**Бесплатно** до $5/месяц кредитов. WebSocket поддерживается из коробки.

### Через веб-интерфейс

1. Зайти на [railway.app](https://railway.app)
2. **New Project** → **Deploy from GitHub repo**
3. Выбрать репозиторий `black_square`
4. В настройках: **Root Directory** → `server`
5. Railway сам определит Node.js и запустит `npm start`
6. **Settings** → **Generate Domain** → получить URL

WebSocket: `wss://ваш-проект.up.railway.app`

### Через CLI

```bash
npm i -g @railway/cli
railway login
cd server
railway init
railway up
railway domain
```

---

## Render

1. [render.com](https://render.com) → **New → Web Service**
2. Подключить GitHub, выбрать репозиторий
3. **Root Directory:** `server`
4. **Build:** `npm install`
5. **Start:** `npm start`
6. Создать сервис

> На бесплатном тарифе Render «засыпает» после 15 мин без активности. Первое подключение может занять 30–60 сек.

---

## Fly.io

```bash
cd server
fly launch
fly deploy
```

---

## Подключение из Flutter

После деплоя получите URL (например `wss://your-app.up.railway.app`).  
В приложении используйте этот URL вместо `ws://localhost:8080`.  
Протокол — **wss://** (не ws://), т.к. в production используется HTTPS.
