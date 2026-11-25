import 'dart:io';

import 'package:flutter/material.dart';

import 'ingredient_art_catalog.dart';
import '../services/ingredient_photo_service.dart';

/// Displays a saved photo, a representative illustration, or a category icon.
class FoodIllustration extends StatelessWidget {
  const FoodIllustration({
    super.key,
    required this.name,
    this.size = 64,
    this.category = '기타',
    this.artKey = 'generic',
    this.photoFile,
    this.shelfPresentation = false,
  });
  final String name;
  final double size;
  final String category, artKey;
  final String? photoFile;
  final bool shelfPresentation;

  Widget _present(BuildContext context, Widget child, String? source) {
    if (!shelfPresentation) return child;
    final labelHeight = MediaQuery.textScalerOf(context).scale(10) * 1.5 + 2;
    return Semantics(
      image: true,
      label: switch (source) {
        '사진' => '사용자 사진',
        '대표' => '대표 이미지',
        _ => '분류 아이콘',
      },
      excludeSemantics: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: EdgeInsets.only(top: labelHeight),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF1F3ED),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE3E8DE)),
              ),
              child: Padding(padding: const EdgeInsets.all(3), child: child),
            ),
          ),
          if (source != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Text(
                source,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xFF756E65)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final art = IngredientArtCatalog.resolve(
      name,
      category: category,
      artKey: artKey,
    );
    final drawing = art.isRepresentative
        ? FittedBox(
            alignment: Alignment.bottomCenter,
            child: CustomPaint(
              size: Size.square(size),
              painter: _FoodPainter(art.representativeName!),
            ),
          )
        : _CategoryArt(
            category: art.category,
            name: name,
            size: size,
            shelfPresentation: shelfPresentation,
          );
    final fallback = _present(
      context,
      drawing,
      art.isRepresentative ? '대표' : null,
    );
    final media = SizedBox.square(
      dimension: size,
      child: photoFile == null
          ? fallback
          : _LocalPhoto(
              basename: photoFile!,
              size: size,
              fallback: fallback,
              present: (child) => _present(
                context,
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    shelfPresentation ? 12 : 8,
                  ),
                  child: child,
                ),
                '사진',
              ),
            ),
    );
    return shelfPresentation ? media : ExcludeSemantics(child: media);
  }
}

/// Resolve disk paths once per photo identity, rather than on selection or
/// inventory rebuilds. A changed photo gets a fresh FutureBuilder so its old
/// snapshot can never show the previous batch's picture while loading.
class _LocalPhoto extends StatefulWidget {
  const _LocalPhoto({
    required this.basename,
    required this.size,
    required this.fallback,
    required this.present,
  });
  final String basename;
  final double size;
  final Widget fallback;
  final Widget Function(Widget) present;

  @override
  State<_LocalPhoto> createState() => _LocalPhotoState();
}

class _LocalPhotoState extends State<_LocalPhoto> {
  late Future<String?> _path;

  @override
  void initState() {
    super.initState();
    _path = IngredientPhotoService().resolvePath(widget.basename);
  }

  @override
  void didUpdateWidget(_LocalPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.basename != widget.basename) {
      _path = IngredientPhotoService().resolvePath(widget.basename);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pixels = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(128, 512);
    return FutureBuilder<String?>(
      key: ValueKey(widget.basename),
      future: _path,
      builder: (context, snapshot) => snapshot.data == null
          ? widget.fallback
          : Image(
              image: ResizeImage(
                FileImage(File(snapshot.data!)),
                width: pixels,
                height: pixels,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              width: widget.size,
              height: widget.size,
              frameBuilder: (context, child, frame, synchronous) =>
                  frame == null && !synchronous
                  ? widget.fallback
                  : widget.present(child),
              errorBuilder: (_, error, stack) => widget.fallback,
            ),
    );
  }
}

/// A category symbol deliberately avoids pretending an unknown item is a jar.
class _CategoryArt extends StatelessWidget {
  const _CategoryArt({
    required this.category,
    required this.name,
    required this.size,
    this.shelfPresentation = false,
  });
  final String category, name;
  final double size;
  final bool shelfPresentation;
  @override
  Widget build(BuildContext context) {
    final icon = switch (category) {
      '채소' => Icons.eco_outlined,
      '과일' => Icons.spa_outlined,
      '육류' => Icons.restaurant_outlined,
      '해산물' => Icons.water_outlined,
      '달걀' => Icons.egg_outlined,
      '유제품' => Icons.local_drink_outlined,
      '반찬' => Icons.rice_bowl_outlined,
      '가공식품' => Icons.inventory_2_outlined,
      '냉동식품' => Icons.ac_unit,
      '조미료' || '소스' => Icons.takeout_dining_outlined,
      _ => Icons.kitchen_outlined,
    };
    return Container(
      padding: EdgeInsets.all(size < 55 ? 2 : 6),
      decoration: BoxDecoration(
        color: shelfPresentation ? Colors.transparent : const Color(0xFFE8EEEA),
        borderRadius: BorderRadius.circular(shelfPresentation ? 18 : 8),
      ),
      child: shelfPresentation
          ? Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Icon(
                  icon,
                  size: size * .36,
                  color: const Color(0xFF526F62),
                ),
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: size * .42, color: const Color(0xFF526F62)),
                if (size >= 55 && !shelfPresentation)
                  Flexible(
                    child: Text(
                      category == '기타'
                          ? (name.isEmpty ? '재료' : name)
                          : category,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: size < 80 ? 9 : 11,
                        color: const Color(0xFF173E36),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _FoodPainter extends CustomPainter {
  const _FoodPainter(this.name);
  final String name;
  @override
  void paint(Canvas c, Size size) {
    c.save();
    c.scale(size.width / 120, size.height / 120);
    Paint solid(int value) => Paint()
      ..color = Color(value)
      ..isAntiAlias = true;
    void oval(Rect r, int color) => c.drawOval(r, solid(color));
    void rect(Rect r, double radius, List<Color> colors) => c.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(radius)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(r),
    );
    void path(Path p, List<Color> colors) => c.drawPath(
      p,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(p.getBounds()),
    );
    void line(List<Offset> pts, int color, double width) {
      final p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final v in pts.skip(1)) {
        p.lineTo(v.dx, v.dy);
      }
      c.drawPath(
        p,
        solid(color)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    c.drawOval(
      const Rect.fromLTWH(18, 101, 87, 8),
      solid(0x23405149)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    final n = name.toLowerCase();
    if (n.contains('두부') || n.contains('tofu')) {
      rect(const Rect.fromLTWH(10, 43, 100, 58), 11, const [
        Color(0xFFD6E4E7),
        Color(0xFFA4BDC1),
      ]);
      rect(const Rect.fromLTWH(14, 47, 92, 48), 8, const [
        Color(0xFFFCFDF7),
        Color(0xFFDDE3D0),
      ]);
      final top = Path()
        ..moveTo(20, 48)
        ..lineTo(71, 25)
        ..quadraticBezierTo(75, 23, 80, 26)
        ..lineTo(103, 43)
        ..lineTo(55, 67)
        ..close();
      path(top, const [Color(0xFFFFFFEF), Color(0xFFECE9CD)]);
      path(
        Path()
          ..moveTo(20, 48)
          ..lineTo(55, 67)
          ..lineTo(55, 91)
          ..lineTo(21, 72)
          ..close(),
        const [Color(0xFFE2DFC3), Color(0xFFC8C6A8)],
      );
      path(
        Path()
          ..moveTo(55, 67)
          ..lineTo(103, 43)
          ..lineTo(102, 69)
          ..lineTo(55, 91)
          ..close(),
        const [Color(0xFFF6F2D9), Color(0xFFDAD6B7)],
      );
      for (final o in const [
        Offset(45, 44),
        Offset(62, 40),
        Offset(74, 48),
        Offset(54, 53),
        Offset(86, 39),
        Offset(40, 64),
        Offset(68, 73),
      ]) {
        oval(Rect.fromCenter(center: o, width: 2.2, height: 1.3), 0x45BDB996);
      }
      line(
        const [Offset(17, 84), Offset(18, 94), Offset(98, 94)],
        0xCFFFFFFF,
        1.5,
      );
    } else if (n.contains('우유') || n.contains('milk')) {
      path(
        Path()
          ..moveTo(31, 28)
          ..lineTo(44, 10)
          ..lineTo(78, 10)
          ..lineTo(91, 28)
          ..lineTo(91, 101)
          ..lineTo(31, 101)
          ..close(),
        const [Color(0xFFFFFFFF), Color(0xFFD5E1E4)],
      );
      path(
        Path()
          ..moveTo(78, 10)
          ..lineTo(91, 28)
          ..lineTo(91, 101)
          ..lineTo(77, 96)
          ..close(),
        const [Color(0xFFB9CDD0), Color(0xFF90AFAF)],
      );
      rect(const Rect.fromLTWH(32, 42, 45, 43), 0, const [
        Color(0xFF286654),
        Color(0xFF123E34),
      ]);
      line(
        const [Offset(44, 11), Offset(44, 27), Offset(77, 27)],
        0xFFAABDBD,
        1,
      );
      line(const [Offset(35, 31), Offset(73, 31)], 0xFFFFFFFF, 2);
      final tp = TextPainter(
        text: const TextSpan(
          text: 'MILK',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, const Offset(36, 52));
      oval(const Rect.fromLTWH(62, 16, 10, 8), 0xFFFDFEFE);
      line(const [Offset(39, 73), Offset(69, 73)], 0x88FFFFFF, 1);
    } else if (n.contains('양파') || n.contains('onion')) {
      final p = Path()
        ..moveTo(54, 22)
        ..lineTo(51, 9)
        ..lineTo(65, 13)
        ..lineTo(64, 24)
        ..cubicTo(111, 44, 108, 91, 72, 102)
        ..cubicTo(20, 119, 4, 63, 54, 22)
        ..close();
      path(p, const [Color(0xFFF4DCAD), Color(0xFFCD944F), Color(0xFF956032)]);
      for (final x in [40.0, 52.0, 65.0, 77.0]) {
        c.drawPath(
          Path()
            ..moveTo(59, 25)
            ..quadraticBezierTo(x - 15, 67, x, 95),
          solid(0x88FFEBC6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
      line(
        const [
          Offset(58, 101),
          Offset(54, 108),
          Offset(64, 104),
          Offset(70, 109),
        ],
        0xFF9F7146,
        1.5,
      );
    } else if (n.contains('대파') ||
        n.contains('쪽파') ||
        n == '파' ||
        n.contains('leek')) {
      for (final d in [-9.0, 4.0, 15.0]) {
        path(
          Path()
            ..moveTo(31 + d, 101)
            ..quadraticBezierTo(53 + d, 61, 55 + d, 39)
            ..lineTo(64 + d, 40)
            ..quadraticBezierTo(61 + d, 78, 43 + d, 105)
            ..close(),
          const [Color(0xFFFFFFFF), Color(0xFFDAE5BF)],
        );
        path(
          Path()
            ..moveTo(55 + d, 45)
            ..quadraticBezierTo(49 + d, 22, 43 + d, 7)
            ..lineTo(53 + d, 6)
            ..quadraticBezierTo(66 + d, 22, 64 + d, 44)
            ..close(),
          const [Color(0xFF82B15C), Color(0xFF23573C)],
        );
        path(
          Path()
            ..moveTo(57 + d, 45)
            ..quadraticBezierTo(68 + d, 18, 83 + d, 8)
            ..lineTo(91 + d, 14)
            ..lineTo(66 + d, 50)
            ..close(),
          const [Color(0xFF6FA14D), Color(0xFF1F573C)],
        );
      }
      line(const [Offset(39, 105), Offset(32, 111)], 0xFFBCA987, 1);
    } else if (n.contains('김치') || n.contains('kimchi')) {
      rect(const Rect.fromLTWH(15, 32, 91, 68), 12, const [
        Color(0xFFE3ECEC),
        Color(0xFFB5C8C8),
      ]);
      rect(const Rect.fromLTWH(21, 40, 79, 53), 8, const [
        Color(0xFFEA8950),
        Color(0xFF9E3223),
      ]);
      for (final o in const [
        Offset(25, 48),
        Offset(49, 44),
        Offset(69, 54),
        Offset(37, 69),
        Offset(66, 76),
      ]) {
        path(
          Path()
            ..moveTo(o.dx, o.dy)
            ..quadraticBezierTo(o.dx + 7, o.dy - 4, o.dx + 20, o.dy + 5)
            ..lineTo(o.dx + 11, o.dy + 17)
            ..quadraticBezierTo(o.dx + 4, o.dy + 12, o.dx, o.dy)
            ..close(),
          const [Color(0xFFFFD593), Color(0xFFD76738)],
        );
        line(
          [Offset(o.dx + 4, o.dy + 3), Offset(o.dx + 12, o.dy + 11)],
          0xFFB7472B,
          1.2,
        );
      }
      rect(const Rect.fromLTWH(11, 26, 99, 15), 6, const [
        Color(0xFF49685C),
        Color(0xFF183E34),
      ]);
      line(const [Offset(20, 29), Offset(98, 29)], 0xFF8BA89B, 2);
      line(const [Offset(18, 48), Offset(18, 82)], 0xBBFFFFFF, 2);
      rect(const Rect.fromLTWH(39, 67, 43, 17), 2, const [
        Color(0xFFF7F4E6),
        Color(0xFFE4DDC8),
      ]);
    } else if (n.contains('달걀') || n.contains('계란') || n.contains('egg')) {
      rect(const Rect.fromLTWH(10, 77, 100, 26), 7, const [
        Color(0xFFCCBCA4),
        Color(0xFF9D8B70),
      ]);
      for (final o in const [Offset(29, 36), Offset(64, 30)]) {
        final p = Path()
          ..moveTo(o.dx + 15, o.dy)
          ..cubicTo(o.dx + 1, o.dy - 1, o.dx - 10, o.dy + 39, o.dx, o.dy + 51)
          ..cubicTo(
            o.dx + 20,
            o.dy + 70,
            o.dx + 43,
            o.dy + 43,
            o.dx + 30,
            o.dy + 17,
          )
          ..quadraticBezierTo(o.dx + 23, o.dy, o.dx + 15, o.dy)
          ..close();
        path(p, const [
          Color(0xFFFFEDCF),
          Color(0xFFDDAA72),
          Color(0xFFB98150),
        ]);
        oval(Rect.fromLTWH(o.dx + 6, o.dy + 13, 7, 14), 0x55FFFFFF);
      }
    } else if (n.contains('당근') || n.contains('carrot')) {
      final p = Path()
        ..moveTo(48, 34)
        ..quadraticBezierTo(68, 25, 80, 44)
        ..quadraticBezierTo(59, 87, 35, 108)
        ..quadraticBezierTo(36, 77, 48, 34)
        ..close();
      path(p, const [Color(0xFFFFB852), Color(0xFFEF7B22), Color(0xFFBE4E13)]);
      for (final y in [51.0, 65.0, 79.0]) {
        line([Offset(48, y), Offset(58, y + 3)], 0xAAAD571B, 1.5);
      }
      for (final x in [40.0, 59.0, 80.0]) {
        path(
          Path()
            ..moveTo(60, 36)
            ..quadraticBezierTo(x - 9, 20, x, 5)
            ..quadraticBezierTo(x + 13, 14, 64, 38)
            ..close(),
          const [Color(0xFF83B25B), Color(0xFF27613D)],
        );
      }
    } else if (n.contains('만두') || n.contains('dumpling')) {
      for (final o in const [Offset(9, 49), Offset(53, 53), Offset(32, 18)]) {
        final p = Path()
          ..moveTo(o.dx, o.dy + 38)
          ..quadraticBezierTo(o.dx + 1, o.dy, o.dx + 27, o.dy)
          ..quadraticBezierTo(o.dx + 53, o.dy + 2, o.dx + 54, o.dy + 38)
          ..quadraticBezierTo(o.dx + 27, o.dy + 52, o.dx, o.dy + 38)
          ..close();
        path(p, const [
          Color(0xFFFFFFE8),
          Color(0xFFE9D9B6),
          Color(0xFFC5AF87),
        ]);
        for (final x in [10.0, 20.0, 30.0, 40.0]) {
          c.drawPath(
            Path()
              ..moveTo(o.dx + x, o.dy + 9)
              ..quadraticBezierTo(
                o.dx + x - 5,
                o.dy + 24,
                o.dx + x + 3,
                o.dy + 34,
              ),
            solid(0x99BDA682)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.3,
          );
        }
      }
    } else if (n.contains('토마토') || n.contains('tomato')) {
      final p = Path()
        ..moveTo(60, 30)
        ..cubicTo(20, 12, 6, 55, 20, 86)
        ..cubicTo(36, 117, 104, 107, 105, 67)
        ..cubicTo(106, 35, 85, 21, 60, 30)
        ..close();
      path(p, const [Color(0xFFFF8A61), Color(0xFFE6412E), Color(0xFFA92121)]);
      oval(const Rect.fromLTWH(28, 39, 14, 23), 0x55FFFFFF);
      path(
        Path()
          ..moveTo(59, 35)
          ..lineTo(41, 20)
          ..lineTo(58, 26)
          ..lineTo(68, 12)
          ..lineTo(68, 29)
          ..lineTo(89, 28)
          ..lineTo(75, 40)
          ..lineTo(63, 34)
          ..lineTo(47, 45)
          ..close(),
        const [Color(0xFF709F4D), Color(0xFF235039)],
      );
    } else if (n.contains('기름') ||
        n.contains('소스') ||
        n.contains('간장') ||
        n.contains('oil')) {
      rect(const Rect.fromLTWH(45, 9, 30, 19), 3, const [
        Color(0xFF3E5946),
        Color(0xFF142E24),
      ]);
      final p = Path()
        ..moveTo(45, 27)
        ..lineTo(75, 27)
        ..lineTo(77, 39)
        ..quadraticBezierTo(88, 43, 88, 55)
        ..lineTo(88, 98)
        ..quadraticBezierTo(60, 110, 32, 98)
        ..lineTo(32, 55)
        ..quadraticBezierTo(32, 44, 43, 39)
        ..close();
      path(p, const [Color(0xFFEBD184), Color(0xFF9D7C28), Color(0xFF5A591D)]);
      rect(const Rect.fromLTWH(36, 58, 48, 28), 1, const [
        Color(0xFFF9F4DE),
        Color(0xFFE7DDBD),
      ]);
      line(
        const [Offset(42, 37), Offset(38, 51), Offset(38, 94)],
        0x88FFFFFF,
        3,
      );
      line(const [Offset(53, 77), Offset(68, 65)], 0xFF4E723D, 3);
    } else if (n.contains('고기') ||
        n.contains('돼지') ||
        n.contains('소고') ||
        n.contains('닭')) {
      rect(const Rect.fromLTWH(9, 30, 103, 74), 12, const [
        Color(0xFFF1F3F0),
        Color(0xFFCAD3D3),
      ]);
      final p = Path()
        ..moveTo(22, 54)
        ..cubicTo(43, 23, 88, 35, 100, 62)
        ..cubicTo(112, 91, 60, 101, 32, 88)
        ..quadraticBezierTo(13, 78, 22, 54)
        ..close();
      path(p, const [Color(0xFFEC9C90), Color(0xFFC75D5A), Color(0xFF963F43)]);
      c.drawPath(
        Path()
          ..moveTo(27, 63)
          ..cubicTo(46, 43, 61, 65, 88, 70),
        solid(0xFFF2C8B8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );
      line(
        const [Offset(37, 81), Offset(58, 73), Offset(77, 86)],
        0xFFE6ADA0,
        2,
      );
    } else {
      // Unknown foods remain an honestly generic, carefully rendered storage jar.
      rect(const Rect.fromLTWH(25, 28, 72, 77), 13, const [
        Color(0xFFE9F0EA),
        Color(0xFFACC3B5),
      ]);
      rect(const Rect.fromLTWH(22, 20, 78, 16), 5, const [
        Color(0xFF456D5C),
        Color(0xFF173E36),
      ]);
      rect(const Rect.fromLTWH(33, 51, 56, 31), 2, const [
        Color(0xFFFEFEF8),
        Color(0xFFE3E8DB),
      ]);
      path(
        Path()
          ..moveTo(54, 73)
          ..quadraticBezierTo(47, 50, 73, 57)
          ..quadraticBezierTo(72, 76, 54, 73)
          ..close(),
        const [Color(0xFF79A55C), Color(0xFF365C3B)],
      );
      line(const [Offset(31, 42), Offset(31, 89)], 0xBBFFFFFF, 2);
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _FoodPainter oldDelegate) =>
      oldDelegate.name != name;
}
