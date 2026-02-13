# Настройка push-уведомлений (Firebase)

Для работы push-уведомлений о сообщениях и входящих звонках нужна настройка Firebase.

## 1. Firebase Console

1. Создайте проект в [Firebase Console](https://console.firebase.google.com/)
2. Добавьте Android-приложение с package name: `com.blacksquare.black_square`
3. Скачайте `google-services.json` и поместите в `android/app/`
4. В разделе Project Settings → Service Accounts нажмите "Generate new private key"
5. Сохраните JSON как `server/firebase-service-account.json`

## 2. Сервер

На сервере задайте переменную окружения (или положите файл в `server/`):

```bash
export FIREBASE_SERVICE_ACCOUNT="/path/to/firebase-service-account.json"
```

Перезапустите сервер: `pm2 restart black-square`

## 3. Сборка приложения

```bash
flutter pub get
flutter build apk
```

Без `google-services.json` сборка Android не пройдёт — добавьте файл перед `flutter build`.
