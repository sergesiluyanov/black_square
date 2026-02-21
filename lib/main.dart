import 'dart:async';
import 'dart:io';

import 'package:black_square/screens/splash_screen.dart';
import 'package:black_square/screens/chat_screen.dart';
import 'package:black_square/screens/call_screen.dart';
import 'package:black_square/services/call_launch_service.dart';
import 'package:black_square/services/call_service.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:black_square/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    try {
      await NotificationService().initialize();
    } catch (_) {
      // Firebase не настроен — приложение работает без push
    }
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Проверяем launch intent до подключения WebSocket — приложение могло быть
  // запущено принятием звонка из killed state
  CallLaunchData? launchCallData;
  if (Platform.isAndroid) {
    launchCallData = await getLaunchIntentCallData();
  }

  final chatService = ChatService();
  try {
    await chatService.initialize().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Connection timeout'),
    );
  } on TimeoutException catch (_) {
    // Сервер недоступен — запускаем приложение, WebSocket переподключится
  } catch (_) {}

  final callService = CallService(chatService);
  callService.init();
  callService.dismissMissedCallFromPush(); // при открытии — главный экран, без экрана пропущенного звонка
  if (launchCallData != null) {
    callService.setPendingAcceptFromLaunch(launchCallData.callId, launchCallData.from);
  }

  final appLifecycle = ValueNotifier<AppLifecycleState>(AppLifecycleState.resumed);
  runApp(
    MultiProvider(
      providers: [
        Provider<ChatService>.value(value: chatService),
        ChangeNotifierProvider<CallService>.value(value: callService),
        Provider<ValueNotifier<AppLifecycleState>>.value(value: appLifecycle),
      ],
        child: _NotificationHandler(
        appLifecycle: appLifecycle,
        navigatorKey: _navigatorKey,
        child: const BlackSquareApp(),
      ),
    ),
  );
}

/// Устанавливает обработчик тапа по push и навигацию к чату/звонку
class _NotificationHandler extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final ValueNotifier<AppLifecycleState> appLifecycle;

  const _NotificationHandler({
    required this.navigatorKey,
    required this.child,
    required this.appLifecycle,
  });

  @override
  State<_NotificationHandler> createState() => _NotificationHandlerState();
}

class _NotificationHandlerState extends State<_NotificationHandler> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      NotificationService().onNotificationTap = _handleNotificationTap;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.appLifecycle.value = state;
    if (state == AppLifecycleState.resumed && mounted) {
      Provider.of<CallService>(context, listen: false).dismissMissedCallFromPush();
    }
  }

  void _handleNotificationTap(String? type, Map<String, String> data) {
    void doNavigate() {
      final ctx = widget.navigatorKey.currentContext;
      if (ctx == null) return;
      final chatService = Provider.of<ChatService>(ctx, listen: false);
      final callService = Provider.of<CallService>(ctx, listen: false);
      if (type == 'message') {
        final chatId = data['chatId'];
        final from = data['sender'] ?? data['from'];
        StreamSubscription? sub;
        void tryNavigate() {
          chatService.getChats().then((chats) {
            final chat = chats.where((c) =>
                (chatId != null && c.id == chatId) ||
                (from != null && c.recipientId == from)).firstOrNull;
            if (chat != null && ctx.mounted) {
              sub?.cancel();
              chatService.markChatAsRead(chat.id);
              Navigator.of(ctx).push(
                MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
              );
            }
          });
        }
        tryNavigate();
        sub = chatService.chatsUpdated.listen((_) => tryNavigate());
        Future.delayed(const Duration(seconds: 5), () => sub?.cancel());
      } else if (type == 'call') {
        // Не показываем «Перезвонить» — приложение откроется, WebSocket подключится,
        // сервер доставит буферизованный call-offer, CallService покажет экран входящего звонка
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => doNavigate());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class BlackSquareApp extends StatelessWidget {
  const BlackSquareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Black Square',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6B8AFF),
          surface: Colors.black,
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
        ),
      ),
      home: const SplashScreen(),
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const Positioned.fill(child: CallScreen()),
        ],
      ),
    );
  }
}
