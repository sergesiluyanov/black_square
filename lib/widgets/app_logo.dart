import 'package:flutter/material.dart';

/// Иконка приложения: чёрный квадрат в круге с белой обводкой.
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/icon.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}
