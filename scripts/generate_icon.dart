// Run: dart run scripts/generate_icon.dart
// Creates a crisp 1024x1024 PNG icon: black square with white outline on black background
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  const size = 1024;
  final image = img.Image(width: size, height: size);

  // Black background
  img.fill(image, color: img.ColorRgb8(0, 0, 0));

  // Square: margin 10%, outline 2.5%
  final margin = (1024 * 0.10).round();
  final strokeWidth = (1024 * 0.025).round();
  final innerStart = margin + strokeWidth;
  final innerEnd = size - margin - strokeWidth;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final inOuter = x >= margin && x < size - margin && y >= margin && y < size - margin;
      final inInner = x >= innerStart && x < innerEnd && y >= innerStart && y < innerEnd;
      if (inOuter && !inInner) {
        image.setPixelRgba(x, y, 255, 255, 255, 255);
      }
    }
  }

  final file = File('assets/icon/icon.png');
  file.writeAsBytesSync(img.encodePng(image)!);
  print('Created ${file.path} (${size}x$size)');
}
