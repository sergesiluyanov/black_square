import 'dart:async';
import 'dart:io';

import 'package:black_square/screens/chat_list_screen.dart';
import 'package:black_square/screens/chat_screen.dart';
import 'package:black_square/screens/call_screen.dart';
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
      systemNavigationBarColor: Color(0xFF0A0A0A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

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

  runApp(
    MultiProvider(
      providers: [
        Provider<ChatService>.value(value: chatService),
        ChangeNotifierProvider<CallService>.value(value: callService),
      ],
      child: _NotificationHandler(
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

  const _NotificationHandler({
    required this.navigatorKey,
    required this.child,
  });

  @override
  State<_NotificationHandler> createState() => _NotificationHandlerState();
}

class _NotificationHandlerState extends State<_NotificationHandler> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      NotificationService().onNotificationTap = _handleNotificationTap;
    }
  }

  void _handleNotificationTap(String? type, Map<String, String> data) {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    final chatService = Provider.of<ChatService>(ctx, listen: false);
    if (type == 'message') {
      final chatId = data['chatId'];
      final from = data['from'];
      chatService.getChats().then((chats) {
        final chat = chats.where((c) =>
            (chatId != null && c.id == chatId) ||
            (from != null && c.recipientId == from)).firstOrNull;
        if (chat != null && ctx.mounted) {
          Navigator.of(ctx).push(
            MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
          );
        }
      });
    }
    // type == 'call' — экран звонка уже поверх, просто открываем приложение
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
          surface: const Color(0xFF0A0A0A),
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0A0A),
          elevation: 0,
        ),
      ),
      home: const ChatListScreen(),
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const Positioned.fill(child: CallScreen()),
        ],
      ),
    );
  }
}
