import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'food_illustration.dart';
import '../models/inventory.dart';

/// A shelf, not an absolute-positioned screenshot: grows with inventory/text.
class FridgeScene extends StatelessWidget {
  const FridgeScene({
    super.key,
    required this.children,
    required this.storageLabel,
  });
  final List<Widget> children;
  final String storageLabel;

  @override
  Widget build(BuildContext context) {
    final pantry = storageLabel.contains('팬트리') || storageLabel.contains('실온');
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = constraints.maxWidth < 300 || textScale > 1.3 ? 2 : 3;
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += columns) {
          rows.add(
            _Shelf(
              pantry: pantry,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(
                  columns,
                  (j) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: i + j < children.length
                          ? children[i + j]
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 19, 12, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(27),
            border: Border.all(color: FridgeTheme.ivory, width: 7),
            gradient: LinearGradient(
              colors: pantry
                  ? const [
                      Color(0xFFDDD2BD),
                      Color(0xFFF3EBDA),
                      Color(0xFFE8DEC9),
                      Color(0xFFD3C7B1),
                    ]
                  : const [
                      Color(0xFFC8D5C6),
                      Color(0xFFEDF1E6),
                      Color(0xFFE7EDDF),
                      Color(0xFFC5D2BF),
                    ],
              stops: const [0, .13, .87, 1],
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14283C34),
                blurRadius: 20,
                offset: Offset(0, 9),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 3, bottom: 16),
                child: Row(
                  children: [
                    Icon(
                      pantry ? Icons.kitchen_outlined : Icons.ac_unit_rounded,
                      size: 13,
                      color: FridgeTheme.sage,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '$storageLabel · 나의 작은 주방',
                        style: const TextStyle(
                          fontSize: 11,
                          color: FridgeTheme.sage,
                          letterSpacing: .3,
                        ),
                      ),
                    ),
                    Container(
                      width: 24,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9F9E9),
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [
                          BoxShadow(color: Color(0xAAFFFFE8), blurRadius: 8),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (children.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 35, horizontal: 18),
                  child: Column(
                    children: [
                      Icon(
                        Icons.eco_outlined,
                        size: 36,
                        color: FridgeTheme.sage,
                      ),
                      SizedBox(height: 14),
                      Text(
                        '첫 재료를 채워볼까요?',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '추가한 재료가 이곳에 놓여요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: FridgeTheme.muted,
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...rows,
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x55D7E3CE),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(15),
                    top: Radius.circular(5),
                  ),
                  border: Border.all(color: const Color(0xFFB9C7AF)),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 65,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFAABC9D),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      pantry ? '필요할 때 꺼내 쓰는 작은 저장소' : '신선함을 담아두는 작은 공간',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF5F7356),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.child, required this.pantry});
  final Widget child;
  final bool pantry;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 18),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: pantry ? const Color(0xFFC4AD87) : const Color(0xFFFCFCF2),
          width: 7,
        ),
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x153B5434),
          blurRadius: 3,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 12),
      child: child,
    ),
  );
}

/// Ivory refrigerator door with a short, skippable-for-reduced-motion reveal.
class FridgeDoor extends StatefulWidget {
  const FridgeDoor({super.key, required this.onOpen, this.onOpenStorage});
  final VoidCallback onOpen;
  final ValueChanged<StorageType>? onOpenStorage;
  @override
  State<FridgeDoor> createState() => _FridgeDoorState();
}

class _FridgeDoorState extends State<FridgeDoor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  bool _opening = false;
  StorageType _selected = StorageType.fridge;

  Future<void> _open([StorageType storage = StorageType.fridge]) async {
    if (_opening) return;
    _opening = true;
    _selected = storage;
    if (!MediaQuery.disableAnimationsOf(context)) {
      await _controller.forward();
    }
    if (mounted) {
      if (widget.onOpenStorage case final callback?) {
        callback(storage);
      } else {
        widget.onOpen();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '냉장고 문 열기',
    onTap: () => _open(),
    excludeSemantics: widget.onOpenStorage == null,
    explicitChildNodes: widget.onOpenStorage != null,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: AspectRatio(
        aspectRatio: .63,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => _DoorInterior(
                      width: w,
                      opening: Curves.easeOutCubic.transform(_controller.value),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final t = Curves.easeInOutCubic.transform(
                      _controller.value,
                    );
                    if (widget.onOpenStorage != null) {
                      return Stack(
                        children: [
                          for (final storage in [
                            StorageType.freezer,
                            StorageType.fridge,
                          ])
                            Positioned.fill(
                              child: Transform(
                                alignment: Alignment.centerLeft,
                                transform: Matrix4.identity()
                                  ..setEntry(3, 2, .0012)
                                  ..rotateY(
                                    storage == _selected
                                        ? -t * math.pi * .48
                                        : 0,
                                  ),
                                child: ExcludeSemantics(
                                  child: ClipRect(
                                    clipper: _DoorSectionClipper(
                                      storage == StorageType.freezer,
                                    ),
                                    child: child,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    }
                    return Transform(
                      alignment: Alignment.centerLeft,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, .0012)
                        ..rotateY(-t * math.pi * .48),
                      child: ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          Color.lerp(
                            Colors.transparent,
                            const Color(0x553C493B),
                            t,
                          )!,
                          BlendMode.srcATop,
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: SizedBox.expand(
                    child: Material(
                      elevation: 10,
                      shadowColor: const Color(0x33283C34),
                      borderRadius: BorderRadius.circular(28),
                      color: const Color(0xFF173E36),
                      child: InkWell(
                        onTap: _open,
                        borderRadius: BorderRadius.circular(28),
                        excludeFromSemantics: true,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(color: const Color(0xFF0D2922)),
                            gradient: const LinearGradient(
                              colors: [Color(0xFF356255), Color(0xFF102E28)],
                            ),
                          ),
                          child: Stack(
                            children: [
                              Positioned(
                                left: w * .11,
                                top: constraints.maxHeight * .1,
                                width: w * .65,
                                child: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '잇칸 · MY FRIDGE',
                                    style: TextStyle(
                                      fontSize: 10,
                                      letterSpacing: 2,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                top: constraints.maxHeight * .3,
                                child: Container(
                                  height: 3,
                                  color: const Color(0xFF0B241F),
                                ),
                              ),
                              Positioned(
                                right: w * .09,
                                top: constraints.maxHeight * .12,
                                child: _Handle(
                                  height: constraints.maxHeight * .11,
                                ),
                              ),
                              Positioned(
                                right: w * .09,
                                top: constraints.maxHeight * .37,
                                child: _Handle(
                                  height: constraints.maxHeight * .22,
                                ),
                              ),
                              Positioned(
                                left: w * .12,
                                top: constraints.maxHeight * .46,
                                width: w * .49,
                                height: constraints.maxHeight * .12,
                                child: Container(
                                  key: const ValueKey('door-brand-plate'),
                                  padding: EdgeInsets.all(w * .025),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFFDDE8E3),
                                        Color(0xFFAFBEB7),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                    border: Border.all(
                                      color: const Color(0xFF829B90),
                                      width: .7,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x330A211B),
                                        offset: Offset(0, 2),
                                        blurRadius: 3,
                                      ),
                                    ],
                                  ),
                                  child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'EATKAN',
                                          style: TextStyle(
                                            color: Color(0xFF173E36),
                                            fontSize: 17,
                                            letterSpacing: 3,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        Text(
                                          'FRESH EVERY DAY',
                                          style: TextStyle(
                                            color: Color(0xFF38574B),
                                            fontSize: 7,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.onOpenStorage != null) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: constraints.maxHeight * .3,
                    child: Semantics(
                      button: true,
                      label: '냉동실 문 열기',
                      onTap: () => _open(StorageType.freezer),
                      child: GestureDetector(
                        key: const ValueKey('freezer-door-target'),
                        behavior: HitTestBehavior.opaque,
                        excludeFromSemantics: true,
                        onTap: () => _open(StorageType.freezer),
                      ),
                    ),
                  ),
                  Positioned(
                    top: constraints.maxHeight * .3,
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Semantics(
                      button: true,
                      label: '냉장실 문 열기',
                      onTap: () => _open(StorageType.fridge),
                      child: GestureDetector(
                        key: const ValueKey('fridge-door-target'),
                        behavior: HitTestBehavior.opaque,
                        excludeFromSemantics: true,
                        onTap: () => _open(StorageType.fridge),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _DoorSectionClipper extends CustomClipper<Rect> {
  const _DoorSectionClipper(this.upper);
  final bool upper;
  @override
  Rect getClip(Size size) => upper
      ? Rect.fromLTWH(0, 0, size.width, size.height * .3)
      : Rect.fromLTWH(0, size.height * .3, size.width, size.height * .7);
  @override
  bool shouldReclip(_DoorSectionClipper oldClipper) =>
      upper != oldClipper.upper;
}

/// Separate pantry entry; it opens the existing room, never creates inventory.
class PantryDoor extends StatefulWidget {
  const PantryDoor({super.key, required this.onOpen});
  final VoidCallback onOpen;
  @override
  State<PantryDoor> createState() => _PantryDoorState();
}

class _PantryDoorState extends State<PantryDoor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  bool _opening = false;
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    if (!MediaQuery.disableAnimationsOf(context)) await _controller.forward();
    if (mounted) widget.onOpen();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '팬트리 문 열기',
    onTap: _open,
    excludeSemantics: true,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: AspectRatio(
        aspectRatio: .85,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFE2D3B7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFB59B71), width: 5),
              ),
              child: const Center(
                child: FoodIllustration(name: '기름', size: 58),
              ),
            ),
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform(
                alignment: Alignment.centerLeft,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, .0012)
                  ..rotateY(
                    -Curves.easeInOut.transform(_controller.value) *
                        math.pi *
                        .47,
                  ),
                child: child,
              ),
              child: Material(
                color: const Color(0xFFC8B18B),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: _open,
                  borderRadius: BorderRadius.circular(14),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFA88D65)),
                      gradient: const LinearGradient(
                        colors: [Color(0xFFDBCAA9), Color(0xFFB99B70)],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'PANTRY',
                              style: TextStyle(
                                fontSize: 13,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                width: 7,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: FridgeTheme.ink,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                          const FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '실온 보관',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Decorative preview only; inventory remains the source for the next screen.
class _DoorInterior extends StatelessWidget {
  const _DoorInterior({required this.width, required this.opening});
  final double width;
  final double opening;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE9E6D8),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFC6CCBC)),
      ),
      child: Padding(
        padding: EdgeInsets.all(width * .055),
        child: CustomPaint(
          painter: _CabinetDepth(opening),
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                for (final item in [
                  ('두부', .20, .16, .25),
                  ('우유', .60, .35, .24),
                  ('당근', .22, .59, .27),
                ])
                  Positioned(
                    left: box.maxWidth * item.$2,
                    top: box.maxHeight * item.$3,
                    child: FoodIllustration(
                      name: item.$1,
                      size: width * item.$4,
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color.fromRGBO(28, 44, 31, .62 * (1 - opening)),
                            Color.fromRGBO(28, 44, 31, .25 * (1 - opening)),
                            Colors.transparent,
                          ],
                          stops: const [0, .5, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _CabinetDepth extends CustomPainter {
  const _CabinetDepth(this.opening);
  final double opening;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final w = size.width;
    final h = size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(18)),
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFA6B5A1),
            Color(0xFFE6EBDD),
            Color(0xFFDDE5D4),
            Color(0xFFADBEA7),
          ],
          stops: [0, .12, .86, 1],
        ).createShader(bounds),
    );
    final back = Rect.fromLTRB(w * .11, h * .07, w * .89, h * .91);
    canvas.drawRRect(
      RRect.fromRectAndRadius(back, const Radius.circular(10)),
      Paint()..color = const Color(0xFFE7ECDE),
    );
    final lamp = Rect.fromCenter(
      center: Offset(w / 2, h * .045),
      width: w * .27,
      height: h * .012,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        lamp.inflate(w * .035),
        const Radius.circular(12),
      ),
      Paint()
        ..color = Color.fromRGBO(255, 255, 220, .65 * opening)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .06),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(lamp, const Radius.circular(3)),
      Paint()
        ..color = Color.lerp(
          const Color(0xFFB2B8A7),
          const Color(0xFFFFFFDF),
          opening,
        )!,
    );
    for (final y in [.33, .57, .81]) {
      final shelf = Path()
        ..moveTo(w * .11, h * (y - .025))
        ..lineTo(w * .89, h * (y - .025))
        ..lineTo(w * .96, h * y)
        ..lineTo(w * .04, h * y)
        ..close();
      canvas.drawShadow(shelf, const Color(0x77344430), 4, false);
      canvas.drawPath(shelf, Paint()..color = const Color(0xFFF8FAEF));
      canvas.drawLine(
        Offset(w * .04, h * y),
        Offset(w * .96, h * y),
        Paint()
          ..color = const Color(0xFFC5D3BF)
          ..strokeWidth = h * .009,
      );
    }
    final drawer = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * .10, h * .85, w * .90, h * .97),
      const Radius.circular(7),
    );
    canvas.drawRRect(drawer, Paint()..color = const Color(0xFFC4D3B9));
    canvas.drawLine(
      Offset(w * .36, h * .88),
      Offset(w * .64, h * .88),
      Paint()
        ..color = const Color(0xFF8FA686)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CabinetDepth oldDelegate) =>
      opening != oldDelegate.opening;
}

class _Handle extends StatelessWidget {
  const _Handle({required this.height});
  final double height;
  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: height,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      gradient: const LinearGradient(
        colors: [Color(0xFF718F89), Color(0xFFEDF5F3), Color(0xFF365C52)],
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33283C34),
          offset: Offset(2, 3),
          blurRadius: 4,
        ),
      ],
    ),
  );
}
