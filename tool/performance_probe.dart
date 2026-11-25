// Run only as an explicit profiling target:
// flutter build apk --profile --target tool/performance_probe.dart
// Optional bounded memory soak: --dart-define=PROBE_SOAK_ROUNDS=10
// Continuous scrolling sample: --dart-define=PROBE_EXCLUDE_JUMPS=true
// Synthetic in-memory data only; never initializes the application's database.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

class _ProbeStore extends InventoryStore {
  _ProbeStore(int count)
    : rows = List.generate(count, (index) {
        const names = [
          '두부',
          '우유',
          '대파',
          '달걀',
          '당근',
          '김치',
          '직접 만든 반찬',
          '처음 보는 재료',
        ];
        return InventoryBatch(
          id: 'probe-${index.toString().padLeft(4, '0')}',
          name: names[index % names.length],
          quantity: 1,
          unit: '개',
          shelfId: 'shelf-${index % 3 + 1}',
          category: index % 8 == 6 ? '반찬' : '기타',
          expiryStatus: index % 5 == 0
              ? ExpiryStatus.unknown
              : ExpiryStatus.actual,
          expiryDate: index % 5 == 0
              ? null
              : DateTime(2026, 11, 9).add(Duration(days: index % 15)),
          createdAt: DateTime(2026, 11, 9),
        );
      });
  final List<InventoryBatch> rows;
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
  @override
  bool get isInitialized => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> update(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    throw StateError(
      'The performance probe does not permit inventory mutations.',
    );
  }
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();
  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final _browser = GlobalKey();
  _ProbeStore _store = _ProbeStore(100);
  final _frames = <FrameTiming>[];
  bool _recording = false;
  String _status = 'Synthetic benchmark · warming up';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onFrames(List<FrameTiming> frames) {
    if (_recording) _frames.addAll(frames);
  }

  Element? _find(bool Function(Element) test) {
    Element? found;
    void walk(Element node) {
      if (found != null) return;
      if (test(node)) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    final context = _browser.currentContext;
    if (context != null) walk(context as Element);
    return found;
  }

  ScrollPosition get _position {
    final element = _find(
      (node) => node is StatefulElement && node.state is ScrollableState,
    );
    if (element is! StatefulElement) {
      throw StateError('Inventory scrollable not found');
    }
    return (element.state as ScrollableState).position;
  }

  Future<void> _pause([int milliseconds = 500]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  Future<void> _run() async {
    try {
      await _pause(1500);
      for (final count in [100, 500]) {
        final previous = _store;
        setState(() {
          _store = _ProbeStore(count);
          _generation++;
          _status = '$count synthetic items · warmup';
        });
        await _pause(1000);
        previous.dispose();
        for (final organizing in [false, true]) {
          _position.jumpTo(0);
          await _pause();
          if (organizing) {
            final button = _find(
              (e) =>
                  e.widget.key == const ValueKey('inventory-organize-toggle'),
            )?.widget;
            if (button is! IconButton || button.onPressed == null) {
              throw StateError('Organize action unavailable');
            }
            button.onPressed!();
            await _pause(1000);
          }
          // Warm both ends before recording. This is a warm scrolling test,
          // not an app startup test and not a photograph import benchmark.
          _position.jumpTo(_position.maxScrollExtent);
          await _pause(500);
          _position.jumpTo(0);
          await _pause(800);
          setState(
            () => _status =
                '$count items · ${organizing ? 'organize' : 'browse'} · measuring',
          );
          await _pause(300);
          _memory(count, organizing, 'before');
          await _measure(count, organizing);
          _memory(count, organizing, 'after');
          await _pause(500);
        }
      }
      const soakRounds = int.fromEnvironment('PROBE_SOAK_ROUNDS');
      // Reuse the final 500-item organizing screen and its image cache. Do not
      // rebuild the store or force GC: repeated checkpoints expose retention.
      for (var round = 1; round <= soakRounds; round++) {
        setState(
          () => _status = '500 items · organize soak $round/$soakRounds',
        );
        _position.jumpTo(0);
        await _pause(500);
        _memory(500, true, 'soak-$round-before');
        await _measure(500, true, soakRound: round);
        _memory(500, true, 'soak-$round-after');
        await _pause(500);
      }
      setState(() => _status = 'Probe complete · inspect PERF_PROBE logs');
      debugPrint(
        'PERF_PROBE ${jsonEncode({'event': 'complete', 'scenarios': 4, 'soakRounds': soakRounds, 'mutatedUserData': false, 'limitation': 'bounded synthetic run; not proof of lifetime leak freedom'})}',
      );
    } catch (error, stack) {
      _recording = false;
      debugPrint(
        'PERF_PROBE ${jsonEncode({'event': 'error', 'error': error.toString(), 'stack': stack.toString()})}',
      );
      if (mounted) setState(() => _status = 'Probe failed · inspect log');
    }
  }

  Future<void> _measure(int count, bool organizing, {int? soakRound}) async {
    const excludeJumps = bool.fromEnvironment('PROBE_EXCLUDE_JUMPS');
    _frames.clear();
    _recording = true;
    final elapsed = Stopwatch()..start();
    for (var leg = 0; leg < 60; leg++) {
      final position = _position;
      if (leg == 30) {
        if (excludeJumps) {
          // Preserve prior scrolling frames, drain delayed timing batches, then
          // exclude the artificial far-end jump and its settling frames.
          await _pause(1200);
          _recording = false;
          position.jumpTo(position.maxScrollExtent);
          await _pause(1200);
          _recording = true;
        } else {
          position.jumpTo(position.maxScrollExtent);
        }
      }
      final delta = position.viewportDimension * .85 * (leg < 30 ? 1 : -1);
      final target = (position.pixels + delta).clamp(
        0.0,
        position.maxScrollExtent,
      );
      await position.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.linear,
      );
      await _pause(20);
    }
    // Timings arrive in batches in profile mode.
    await _pause(1200);
    elapsed.stop();
    _recording = false;
    _emit(count, organizing, elapsed.elapsedMilliseconds, soakRound: soakRound);
  }

  Map<String, num> _distribution(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return {'count': 0};
    double p(double fraction) =>
        sorted[((sorted.length - 1) * fraction).ceil()];
    return {
      'count': sorted.length,
      'p50Ms': p(.5),
      'p95Ms': p(.95),
      'maxMs': sorted.last,
    };
  }

  void _memory(int count, bool organizing, String phase) {
    final cache = PaintingBinding.instance.imageCache;
    debugPrint(
      'PERF_PROBE ${jsonEncode({'event': 'memory', 'items': count, 'mode': organizing ? 'organize' : 'browse', 'phase': phase, 'processRssBytes': ProcessInfo.currentRss, 'imageCacheBytes': cache.currentSizeBytes, 'imageCacheEntries': cache.currentSize, 'liveImageCount': cache.liveImageCount, 'pendingImageCount': cache.pendingImageCount})}',
    );
  }

  void _emit(int count, bool organizing, int elapsedMs, {int? soakRound}) {
    const excludeJumps = bool.fromEnvironment('PROBE_EXCLUDE_JUMPS');
    debugPrint(
      'PERF_PROBE ${jsonEncode({'event': soakRound == null ? 'scenario' : 'soak', 'soakRound': soakRound, 'items': count, 'mode': organizing ? 'organize' : 'browse', 'scrollLegs': 60, 'excludeJumps': excludeJumps, 'elapsedIncludesTimingDrainPauses': true, 'elapsedMs': elapsedMs, 'frames': _frames.length, 'build': _distribution(_frames.map((f) => f.buildDuration.inMicroseconds / 1000)), 'raster': _distribution(_frames.map((f) => f.rasterDuration.inMicroseconds / 1000)), 'totalSpan': _distribution(_frames.map((f) => f.totalSpan.inMicroseconds / 1000)), 'buildOver16_67Ms': _frames.where((f) => f.buildDuration.inMicroseconds > 16667).length, 'rasterOver16_67Ms': _frames.where((f) => f.rasterDuration.inMicroseconds > 16667).length, 'scope': 'synthetic inventory; warm scroll; no real photos or DB; device refresh rate not inferred'})}',
    );
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: FridgeTheme.light,
    home: Scaffold(
      appBar: AppBar(
        title: Text(_status, style: const TextStyle(fontSize: 13)),
      ),
      body: KeyedSubtree(
        key: ValueKey(_generation),
        child: SizedBox.expand(
          key: _browser,
          child: InventoryBrowser(store: _store, onOpen: (_) {}, onAdd: () {}),
        ),
      ),
    ),
  );
}
