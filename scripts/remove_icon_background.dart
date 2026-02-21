// Run: dart run scripts/remove_icon_background.dart
// Removes grey/dark background from icon.png, making it transparent.
// Use for splash and app bar where background is black.
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final file = File('assets/icon/icon.png');
  if (!file.existsSync()) {
    print('Error: assets/icon/icon.png not found');
    exit(1);
  }
  final bytes = file.readAsBytesSync();
  final image = img.decodeImage(bytes);
  if (image == null) {
    print('Error: could not decode image');
    exit(1);
  }

  // Sample corner pixels to detect background color (grey)
  final corners = [
    [0, 0],
    [image.width - 1, 0],
    [0, image.height - 1],
    [image.width - 1, image.height - 1],
  ];
  int? bgR, bgG, bgB;
  for (final c in corners) {
    final p = image.getPixel(c[0], c[1]);
    final r = p.r.toInt();
    final g = p.g.toInt();
    final b = p.b.toInt();
    if (bgR == null) {
      bgR = r;
      bgG = g;
      bgB = b;
    }
  }

  // Replace background-like pixels (dark grey, similar to corners) with transparent
  const tolerance = 25;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      if (bgR != null &&
          (r - bgR).abs() <= tolerance &&
          (g - bgG!).abs() <= tolerance &&
          (b - bgB!).abs() <= tolerance) {
        image.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }

  file.writeAsBytesSync(img.encodePng(image)!);
  print('Updated ${file.path} - grey background made transparent');
}
