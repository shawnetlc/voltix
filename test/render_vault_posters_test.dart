import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Render all 22 Vault Posters', (tester) async {
    const width = 1000.0;
    const height = 1500.0;

    final boltBytes = File('assets/images/voltix_bolt.png').readAsBytesSync();
    final codec = await ui.instantiateImageCodec(boltBytes);
    final frame = await codec.getNextFrame();
    final boltImage = frame.image;

    final posters = [
      _PosterConfig(
        filename: '1_trending_movies.png',
        titleTop: 'TRENDING',
        titleBottom: 'MOVIES',
        categoryType: _CategoryType.stars,
        starsGradient: [const Color(0xFFFDE047), const Color(0xFF84CC16), const Color(0xFF10B981)],
        primaryColor: const Color(0xFF84CC16),
        secondaryColor: const Color(0xFFFDE047),
        borderGradient: [const Color(0xFF84CC16), const Color(0xFFFDE047)],
      ),
      _PosterConfig(
        filename: '2_trending_shows.png',
        titleTop: 'TRENDING',
        titleBottom: 'SHOWS',
        categoryType: _CategoryType.stars,
        starsGradient: [const Color(0xFFFDE047), const Color(0xFF84CC16), const Color(0xFF10B981)],
        primaryColor: const Color(0xFF84CC16),
        secondaryColor: const Color(0xFFFDE047),
        borderGradient: [const Color(0xFF84CC16), const Color(0xFFFDE047)],
      ),
      _PosterConfig(
        filename: '3_newest_movies.png',
        titleTop: 'NEWEST',
        titleBottom: 'MOVIES',
        categoryType: _CategoryType.stars,
        starsGradient: [const Color(0xFF00E5FF), const Color(0xFF818CF8), const Color(0xFFE879F9)],
        primaryColor: const Color(0xFF00E5FF),
        secondaryColor: const Color(0xFFE879F9),
        borderGradient: [const Color(0xFF00E5FF), const Color(0xFFE879F9)],
      ),
      _PosterConfig(
        filename: '4_newest_shows.png',
        titleTop: 'NEWEST',
        titleBottom: 'SHOWS',
        categoryType: _CategoryType.stars,
        starsGradient: [const Color(0xFF00E5FF), const Color(0xFF818CF8), const Color(0xFFE879F9)],
        primaryColor: const Color(0xFF00E5FF),
        secondaryColor: const Color(0xFFE879F9),
        borderGradient: [const Color(0xFF00E5FF), const Color(0xFFE879F9)],
      ),
      _PosterConfig(
        filename: '5_popular_netflix_movies.png',
        titleTop: 'NETFLIX',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.netflix,
        primaryColor: const Color(0xFFE50914),
        secondaryColor: const Color(0xFFB81D24),
        borderGradient: [const Color(0xFFE50914), const Color(0xFF831010)],
      ),
      _PosterConfig(
        filename: '6_popular_netflix_shows.png',
        titleTop: 'NETFLIX',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.netflix,
        primaryColor: const Color(0xFFE50914),
        secondaryColor: const Color(0xFFB81D24),
        borderGradient: [const Color(0xFFE50914), const Color(0xFF831010)],
      ),
      _PosterConfig(
        filename: '7_popular_prime_video_movies.png',
        titleTop: 'prime video',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.prime,
        primaryColor: const Color(0xFF00A8E1),
        secondaryColor: const Color(0xFF0073BB),
        borderGradient: [const Color(0xFF00A8E1), const Color(0xFF005A9C)],
      ),
      _PosterConfig(
        filename: '8_popular_prime_video_shows.png',
        titleTop: 'prime video',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.prime,
        primaryColor: const Color(0xFF00A8E1),
        secondaryColor: const Color(0xFF0073BB),
        borderGradient: [const Color(0xFF00A8E1), const Color(0xFF005A9C)],
      ),
      _PosterConfig(
        filename: '9_popular_hulu_movies.png',
        titleTop: 'hulu',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.hulu,
        primaryColor: const Color(0xFF1CE783),
        secondaryColor: const Color(0xFF00ED82),
        borderGradient: [const Color(0xFF1CE783), const Color(0xFF0E7A44)],
      ),
      _PosterConfig(
        filename: '10_popular_hulu_shows.png',
        titleTop: 'hulu',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.hulu,
        primaryColor: const Color(0xFF1CE783),
        secondaryColor: const Color(0xFF00ED82),
        borderGradient: [const Color(0xFF1CE783), const Color(0xFF0E7A44)],
      ),
      _PosterConfig(
        filename: '11_popular_paramount_movies.png',
        titleTop: 'Paramount+',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.paramount,
        primaryColor: const Color(0xFF0064FF),
        secondaryColor: const Color(0xFF0038A8),
        borderGradient: [const Color(0xFF0064FF), const Color(0xFF0038A8)],
      ),
      _PosterConfig(
        filename: '12_popular_paramount_shows.png',
        titleTop: 'Paramount+',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.paramount,
        primaryColor: const Color(0xFF0064FF),
        secondaryColor: const Color(0xFF0038A8),
        borderGradient: [const Color(0xFF0064FF), const Color(0xFF0038A8)],
      ),
      _PosterConfig(
        filename: '13_popular_hbo_max_movies.png',
        titleTop: 'max',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.max,
        primaryColor: const Color(0xFF9933FF),
        secondaryColor: const Color(0xFF5E17EB),
        borderGradient: [const Color(0xFF9933FF), const Color(0xFFE5097F)],
      ),
      _PosterConfig(
        filename: '14_popular_hbo_max_shows.png',
        titleTop: 'max',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.max,
        primaryColor: const Color(0xFF9933FF),
        secondaryColor: const Color(0xFF5E17EB),
        borderGradient: [const Color(0xFF9933FF), const Color(0xFFE5097F)],
      ),
      _PosterConfig(
        filename: '15_popular_disney_movies.png',
        titleTop: 'Disney+',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.disney,
        primaryColor: const Color(0xFF113CCF),
        secondaryColor: const Color(0xFF00D6FE),
        borderGradient: [const Color(0xFF00D6FE), const Color(0xFF113CCF)],
      ),
      _PosterConfig(
        filename: '16_popular_disney_shows.png',
        titleTop: 'Disney+',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.disney,
        primaryColor: const Color(0xFF113CCF),
        secondaryColor: const Color(0xFF00D6FE),
        borderGradient: [const Color(0xFF00D6FE), const Color(0xFF113CCF)],
      ),
      _PosterConfig(
        filename: '17_popular_peacock_movies.png',
        titleTop: 'Peacock',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.peacock,
        primaryColor: const Color(0xFFF59E0B),
        secondaryColor: const Color(0xFFD97706),
        borderGradient: [const Color(0xFFF59E0B), const Color(0xFFB45309)],
      ),
      _PosterConfig(
        filename: '18_popular_peacock_shows.png',
        titleTop: 'Peacock',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.peacock,
        primaryColor: const Color(0xFFF59E0B),
        secondaryColor: const Color(0xFFD97706),
        borderGradient: [const Color(0xFFF59E0B), const Color(0xFFB45309)],
      ),
      _PosterConfig(
        filename: '19_popular_apple_tv_movies.png',
        titleTop: 'tv+',
        titleBottom: 'POPULAR\nMOVIES',
        categoryType: _CategoryType.appletv,
        primaryColor: const Color(0xFFE5E7EB),
        secondaryColor: const Color(0xFF9CA3AF),
        borderGradient: [const Color(0xFFE5E7EB), const Color(0xFF6B7280)],
      ),
      _PosterConfig(
        filename: '20_popular_apple_tv_shows.png',
        titleTop: 'tv+',
        titleBottom: 'POPULAR\nSHOWS',
        categoryType: _CategoryType.appletv,
        primaryColor: const Color(0xFFE5E7EB),
        secondaryColor: const Color(0xFF9CA3AF),
        borderGradient: [const Color(0xFFE5E7EB), const Color(0xFF6B7280)],
      ),
      _PosterConfig(
        filename: '21_best_movies_of_all_time.png',
        titleTop: 'BEST',
        titleBottom: 'MOVIES',
        categoryType: _CategoryType.stars,
        starsGradient: [const Color(0xFFF59E0B), const Color(0xFFF43F5E), const Color(0xFFEC4899)],
        primaryColor: const Color(0xFFF59E0B),
        secondaryColor: const Color(0xFFEC4899),
        borderGradient: [const Color(0xFFF59E0B), const Color(0xFFEC4899)],
      ),
      _PosterConfig(
        filename: '22_best_shows_of_all_time.png',
        titleTop: 'BEST',
        titleBottom: 'SHOWS',
        categoryType: _CategoryType.stars,
        starsGradient: [const Color(0xFFF59E0B), const Color(0xFFF43F5E), const Color(0xFFEC4899)],
        primaryColor: const Color(0xFFF59E0B),
        secondaryColor: const Color(0xFFEC4899),
        borderGradient: [const Color(0xFFF59E0B), const Color(0xFFEC4899)],
      ),
    ];

    final exportDir = Directory('exported_vault_posters');
    final assetsDir = Directory('assets/vault_posters');
    if (!exportDir.existsSync()) exportDir.createSync(recursive: true);
    if (!assetsDir.existsSync()) assetsDir.createSync(recursive: true);

    for (final p in posters) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

      _drawVaultPoster(canvas, width, height, p, boltImage);

      final picture = recorder.endRecording();
      final img = await picture.toImage(width.toInt(), height.toInt());
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      File('${exportDir.path}/${p.filename}').writeAsBytesSync(bytes);
      File('${assetsDir.path}/${p.filename}').writeAsBytesSync(bytes);
      // ignore: avoid_print
      print('Rendered: ${p.filename} (${bytes.length} bytes)');
    }
  });
}

enum _CategoryType {
  stars,
  netflix,
  prime,
  hulu,
  paramount,
  max,
  disney,
  peacock,
  appletv,
}

class _PosterConfig {
  final String filename;
  final String titleTop;
  final String titleBottom;
  final _CategoryType categoryType;
  final List<Color>? starsGradient;
  final Color primaryColor;
  final Color secondaryColor;
  final List<Color> borderGradient;

  _PosterConfig({
    required this.filename,
    required this.titleTop,
    required this.titleBottom,
    required this.categoryType,
    this.starsGradient,
    required this.primaryColor,
    required this.secondaryColor,
    required this.borderGradient,
  });
}

void _drawVaultPoster(Canvas canvas, double w, double h, _PosterConfig config, ui.Image boltImage) {
  // 1. Background (deep obsidian slate)
  final bgPaint = Paint()
    ..shader = ui.Gradient.radial(
      Offset(w / 2, h * 0.4),
      w * 0.9,
      [const Color(0xFF151922), const Color(0xFF080B10)],
    );
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

  // Crosshatch / subtle grid texture
  final gridPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.02)
    ..strokeWidth = 1.0;
  for (double i = -h; i < w + h; i += 32) {
    canvas.drawLine(Offset(i, 0), Offset(i + h, h), gridPaint);
    canvas.drawLine(Offset(i + h, 0), Offset(i, h), gridPaint);
  }

  // 2. Glowing rounded neon border
  final borderRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(36, 36, w - 72, h - 72),
    const Radius.circular(36),
  );

  // Outer glow
  final glowPaint = Paint()
    ..shader = ui.Gradient.linear(
      Offset(36, 36),
      Offset(w - 36, h - 36),
      config.borderGradient.map((c) => c.withValues(alpha: 0.4)).toList(),
    )
    ..style = PaintingStyle.stroke
    ..strokeWidth = 18
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
  canvas.drawRRect(borderRect, glowPaint);

  // Sharp inner neon border
  final strokePaint = Paint()
    ..shader = ui.Gradient.linear(
      Offset(36, 36),
      Offset(w - 36, h - 36),
      config.borderGradient,
    )
    ..style = PaintingStyle.stroke
    ..strokeWidth = 8;
  canvas.drawRRect(borderRect, strokePaint);

  // 3. Small discrete Voltix Bolt watermark in the center
  final boltW = 160.0;
  final boltH = (boltW / boltImage.width) * boltImage.height;
  final boltRect = Rect.fromCenter(
    center: Offset(w / 2, h * 0.54),
    width: boltW,
    height: boltH,
  );
  final boltPaint = Paint()
    ..colorFilter = const ColorFilter.mode(Colors.white, BlendMode.srcIn)
    ..color = Colors.white.withValues(alpha: 0.25);
  canvas.drawImageRect(
    boltImage,
    Rect.fromLTWH(0, 0, boltImage.width.toDouble(), boltImage.height.toDouble()),
    boltRect,
    boltPaint,
  );

  // 4. Draw Header / Logo Area (Upper half)
  _drawHeaderGraphic(canvas, w, h, config);

  // 5. Draw Glowing Underline Divider
  final dividerY = h * 0.43;
  final linePaint = Paint()
    ..shader = ui.Gradient.linear(
      Offset(w * 0.2, dividerY),
      Offset(w * 0.8, dividerY),
      [
        config.primaryColor.withValues(alpha: 0.0),
        config.primaryColor,
        config.secondaryColor,
        config.secondaryColor.withValues(alpha: 0.0),
      ],
    )
    ..strokeWidth = 4
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(Offset(w * 0.18, dividerY), Offset(w * 0.82, dividerY), linePaint);

  // Glow on divider
  final lineGlowPaint = Paint()
    ..shader = linePaint.shader
    ..strokeWidth = 12
    ..strokeCap = StrokeCap.round
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
  canvas.drawLine(Offset(w * 0.18, dividerY), Offset(w * 0.82, dividerY), lineGlowPaint);

  // 6. Draw Bottom Title Area
  _drawBottomTitle(canvas, w, h, config);
}

void _drawHeaderGraphic(Canvas canvas, double w, double h, _PosterConfig config) {
  final centerX = w / 2;

  switch (config.categoryType) {
    case _CategoryType.stars:
      // Draw 6 stars with gradient colors
      final startX = centerX - 190;
      final starY = h * 0.19;
      for (int i = 0; i < 6; i++) {
        final t = i / 5.0;
        final starColor = Color.lerp(config.starsGradient![0], config.starsGradient!.last, t)!;
        _drawStar(canvas, Offset(startX + (i * 76), starY), 22, starColor);
      }

      // Draw Top Word (e.g. TRENDING / NEWEST / BEST)
      final tp = TextPainter(
        text: TextSpan(
          text: config.titleTop,
          style: TextStyle(
            fontSize: 92,
            fontWeight: FontWeight.w900,
            letterSpacing: 8,
            foreground: Paint()
              ..shader = ui.Gradient.linear(
                Offset(centerX - 200, h * 0.26),
                Offset(centerX + 200, h * 0.36),
                [config.primaryColor, config.secondaryColor],
              ),
            shadows: [
              Shadow(color: config.primaryColor.withValues(alpha: 0.8), blurRadius: 32),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.26));
      break;

    case _CategoryType.netflix:
      // Red Netflix Wordmark
      final tp = TextPainter(
        text: TextSpan(
          text: 'NETFLIX',
          style: TextStyle(
            fontSize: 108,
            fontWeight: FontWeight.w900,
            letterSpacing: 10,
            color: const Color(0xFFE50914),
            shadows: [
              const Shadow(color: Color(0xFFE50914), blurRadius: 40),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.23));
      break;

    case _CategoryType.prime:
      // Prime Video wordmark & smile arrow
      final tp = TextPainter(
        text: TextSpan(
          text: 'prime video',
          style: TextStyle(
            fontSize: 88,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            color: const Color(0xFF00A8E1),
            shadows: [
              const Shadow(color: Color(0xFF00A8E1), blurRadius: 36),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.20));

      // Smile arrow arc
      final smilePath = Path()
        ..moveTo(centerX - 130, h * 0.32)
        ..quadraticBezierTo(centerX, h * 0.37, centerX + 120, h * 0.32);
      final smilePaint = Paint()
        ..color = const Color(0xFF00A8E1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(smilePath, smilePaint);
      break;

    case _CategoryType.hulu:
      // Hulu wordmark
      final tp = TextPainter(
        text: TextSpan(
          text: 'hulu',
          style: TextStyle(
            fontSize: 136,
            fontWeight: FontWeight.w900,
            letterSpacing: -2,
            color: const Color(0xFF1CE783),
            shadows: [
              const Shadow(color: Color(0xFF1CE783), blurRadius: 40),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.20));
      break;

    case _CategoryType.paramount:
      // Paramount Mountain & Star Arch
      final mountainPath = Path()
        ..moveTo(centerX - 90, h * 0.28)
        ..lineTo(centerX, h * 0.17)
        ..lineTo(centerX + 90, h * 0.28)
        ..close();
      canvas.drawPath(
        mountainPath,
        Paint()..color = const Color(0xFF0064FF).withValues(alpha: 0.8),
      );

      // Star arch above mountain
      for (int i = 0; i < 9; i++) {
        final angle = math.pi * (0.85 + (i * 0.16));
        final sx = centerX + 115 * math.cos(angle);
        final sy = h * 0.23 + 95 * math.sin(angle);
        _drawStar(canvas, Offset(sx, sy), 8, const Color(0xFF0064FF));
      }

      final tp = TextPainter(
        text: const TextSpan(
          text: 'Paramount+',
          style: TextStyle(
            fontSize: 76,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: Color(0xFF0064FF),
            shadows: [
              Shadow(color: Color(0xFF0064FF), blurRadius: 36),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.30));
      break;

    case _CategoryType.max:
      // Max wordmark
      final tp = TextPainter(
        text: TextSpan(
          text: 'max',
          style: TextStyle(
            fontSize: 148,
            fontWeight: FontWeight.w900,
            letterSpacing: -2,
            foreground: Paint()
              ..shader = ui.Gradient.linear(
                const Offset(0, 0),
                const Offset(300, 300),
                [const Color(0xFF9933FF), const Color(0xFFE5097F)],
              ),
            shadows: const [
              Shadow(color: Color(0xFF9933FF), blurRadius: 40),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.18));
      break;

    case _CategoryType.disney:
      // Disney+ arch
      final arcPath = Path()
        ..moveTo(centerX - 180, h * 0.32)
        ..quadraticBezierTo(centerX, h * 0.14, centerX + 170, h * 0.28);
      canvas.drawPath(
        arcPath,
        Paint()
          ..color = const Color(0xFF00D6FE)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );

      final tp = TextPainter(
        text: const TextSpan(
          text: 'Disney+',
          style: TextStyle(
            fontSize: 98,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: Color(0xFFE2E8F0),
            shadows: [
              Shadow(color: Color(0xFF00D6FE), blurRadius: 36),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.21));
      break;

    case _CategoryType.peacock:
      // Peacock 6-color fan feathers
      final featherColors = [
        const Color(0xFFE50914),
        const Color(0xFFF59E0B),
        const Color(0xFF10B981),
        const Color(0xFF00A8E1),
        const Color(0xFF3B82F6),
        const Color(0xFF8B5CF6),
      ];
      final fanCenter = Offset(centerX, h * 0.32);
      for (int i = 0; i < 6; i++) {
        final angle = -math.pi * 0.85 + (i * (math.pi * 0.7 / 5));
        final fx = fanCenter.dx + 90 * math.cos(angle);
        final fy = fanCenter.dy + 80 * math.sin(angle);
        canvas.drawCircle(
          Offset(fx, fy),
          26,
          Paint()..color = featherColors[i],
        );
      }

      // Small peacock beak
      canvas.drawCircle(
        Offset(centerX, h * 0.31),
        16,
        Paint()..color = Colors.white,
      );
      break;

    case _CategoryType.appletv:
      // Apple TV+ Logo
      final tp = TextPainter(
        text: const TextSpan(
          text: 'tv+',
          style: TextStyle(
            fontSize: 120,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: Color(0xFFF8FAFC),
            shadows: [
              Shadow(color: Colors.white70, blurRadius: 32),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(centerX - (tp.width / 2), h * 0.20));
      break;
  }
}

void _drawBottomTitle(Canvas canvas, double w, double h, _PosterConfig config) {
  final centerX = w / 2;
  final lines = config.titleBottom.split('\n');

  final startY = lines.length > 1 ? h * 0.68 : h * 0.72;
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final tp = TextPainter(
      text: TextSpan(
        text: line,
        style: const TextStyle(
          fontSize: 94,
          fontWeight: FontWeight.w900,
          letterSpacing: 8,
          color: Colors.white,
          shadows: [
            Shadow(color: Colors.black, blurRadius: 16),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(centerX - (tp.width / 2), startY + (i * 115)));
  }
}

void _drawStar(Canvas canvas, Offset center, double radius, Color color) {
  final path = Path();
  for (int i = 0; i < 8; i++) {
    final r = i.isEven ? radius : radius * 0.45;
    final angle = i * math.pi / 4;
    final x = center.dx + r * math.cos(angle);
    final y = center.dy + r * math.sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();

  // Glow
  final glowPaint = Paint()
    ..color = color.withValues(alpha: 0.8)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
  canvas.drawPath(path, glowPaint);

  // Sharp Star
  final fillPaint = Paint()..color = color;
  canvas.drawPath(path, fillPaint);
}
