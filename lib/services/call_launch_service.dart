import 'dart:io';

import 'package:flutter/services.dart';

/// Данные о звонке, принятом при запуске из killed state.
class CallLaunchData {
  final String callId;
  final String from;
  final String? fromName;

  CallLaunchData({required this.callId, required this.from, this.fromName});
}

/// Получает данные о принятом звонке из launch intent (Android).
/// Когда приложение запущено нажатием "Принять" на CallKit при killed state.
Future<CallLaunchData?> getLaunchIntentCallData() async {
  if (!Platform.isAndroid) return null;
  try {
    const channel = MethodChannel('black_square/call_launch');
    final result = await channel.invokeMethod<Map<Object?, Object?>>('getLaunchIntentCallData');
    if (result == null) return null;
    final callId = result['callId']?.toString();
    final from = result['from']?.toString();
    if (callId == null || from == null || from.isEmpty) return null;
    final fromName = result['fromName']?.toString();
    return CallLaunchData(callId: callId, from: from, fromName: fromName);
  } catch (_) {
    return null;
  }
}
