import 'package:flutter/material.dart';

/// Глобальный notifier жизненного цикла приложения.
/// CallScreen использует его для отображения только в foreground.
final appLifecycleNotifier = ValueNotifier<AppLifecycleState>(AppLifecycleState.resumed);
