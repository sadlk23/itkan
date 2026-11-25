import 'package:flutter/material.dart';

import 'food_illustration.dart';

/// Actual ingredient silhouettes on a preparation board, not a finished dish.
class RecipeIngredientBanner extends StatelessWidget {
  const RecipeIngredientBanner({
    super.key,
    required this.names,
    this.height = 112,
  });
  final List<String> names;
  final double height;
  @override
  Widget build(BuildContext context) {
    final visible = names
        .where((name) => name.trim().isNotEmpty)
        .toSet()
        .take(3)
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = (box.maxWidth / (visible.length + .6)).clamp(
            24.0,
            height * .72,
          );
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                height: height * .58,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2ECE9),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFC4D4CE)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x123A3D26),
                        blurRadius: 5,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 24,
                bottom: 18,
                child: Container(
                  width: 28,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: visible
                    .map((name) => FoodIllustration(name: name, size: size))
                    .toList(),
              ),
            ],
          );
        },
      ),
    );
  }
}
