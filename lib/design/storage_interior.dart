import 'package:flutter/material.dart';

import '../models/inventory.dart';

/// Thin cabinet walls reserve the centre for real inventory, not decoration.
class StorageInterior extends StatelessWidget {
  const StorageInterior({
    super.key,
    required this.storage,
    required this.children,
    this.firstSegment = true,
    this.lastSegment = true,
  });
  final StorageType storage;
  final List<Widget> children;
  final bool firstSegment, lastSegment;
  @override
  Widget build(BuildContext context) {
    final pantry = storage == StorageType.pantry;
    final cold = storage == StorageType.freezer;
    final wall = pantry ? const Color(0xFFDED5C5) : const Color(0xFFDDDCD3);
    final back = pantry
        ? const Color(0xFFF3EADB)
        : cold
        ? const Color(0xFFF0F7FA)
        : const Color(0xFFFAF8F3);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.vertical(
          top: firstSegment ? const Radius.circular(20) : Radius.zero,
          bottom: lastSegment ? const Radius.circular(20) : Radius.zero,
        ),
        gradient: LinearGradient(
          colors: [wall, back, back, wall],
          stops: const [0, .035, .965, 1],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          10,
          firstSegment ? 12 : 0,
          10,
          lastSegment ? 8 : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// Straight translucent front edge shared by all shelf rows.
class GlassShelfLip extends StatelessWidget {
  const GlassShelfLip({
    super.key,
    this.pantry = false,
    this.highlighted = false,
  });
  final bool pantry, highlighted;
  @override
  Widget build(BuildContext context) => Container(
    height: 5,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: pantry
            ? const [Color(0xFFE7D7BC), Color(0xFFBCA481)]
            : const [Color(0xFFFFFEFA), Color(0xFFC9CDC3)],
      ),
      border: Border(
        bottom: BorderSide(
          color: highlighted
              ? const Color(0xFF173E36)
              : pantry
              ? const Color(0xFFA89172)
              : const Color(0xFFD8DAD1),
        ),
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x16324840),
          blurRadius: 3,
          offset: Offset(0, 3),
        ),
      ],
    ),
  );
}
