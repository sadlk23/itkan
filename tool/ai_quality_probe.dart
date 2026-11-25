import 'dart:convert';
import 'dart:io';

import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ai_service.dart';

/// Opt-in live checks using synthetic inventory only. Never writes app storage.
/// dart run tool/ai_quality_probe.dart --run --config=config/ai.local.json
Future<void> main(List<String> arguments) async {
  if (!arguments.contains('--run')) {
    stdout.writeln(
      '실제 호출은 실행하지 않았습니다. --run --config=<설정 파일>로 실행하세요. API 사용량이 발생하며 가상 재고만 전송합니다.',
    );
    return;
  }
  final configArgument = arguments
      .where((a) => a.startsWith('--config='))
      .firstOrNull;
  if (configArgument == null) {
    stderr.writeln('제공받은 API 설정 파일을 --config= 경로로 지정해주세요.');
    exitCode = 2;
    return;
  }
  Map<String, dynamic> config;
  try {
    config = Map<String, dynamic>.from(
      jsonDecode(await File(configArgument.substring(9)).readAsString()) as Map,
    );
    if ((config['AI_BASE_URL'] as String? ?? '').trim().isEmpty) {
      throw const FormatException('missing endpoint');
    }
  } catch (_) {
    stderr.writeln('유효한 API 설정이 없습니다. 설정 내용과 비밀값은 출력하지 않습니다.');
    exitCode = 2;
    return;
  }
  final repeatArgument = arguments
      .where((a) => a.startsWith('--repeat='))
      .firstOrNull;
  final repeats = repeatArgument == null
      ? 1
      : int.tryParse(repeatArgument.substring(9));
  if (repeats == null || repeats < 1 || repeats > 10) {
    stderr.writeln('--repeat은 1~10 범위여야 합니다.');
    exitCode = 2;
    return;
  }
  final ai = AiService(
    baseUrl: config['AI_BASE_URL'] as String?,
    apiKey: config['AI_API_KEY'] as String?,
    model: config['AI_MODEL'] as String?,
    format: config['AI_API_FORMAT'] as String?,
  );
  final batches = [
    InventoryBatch(id: 'fixture-tofu', name: '두부', quantity: 300, unit: 'g'),
    InventoryBatch(id: 'fixture-egg', name: '달걀', quantity: 4, unit: '개'),
  ];
  final results = <Map<String, Object?>>[];
  try {
    for (var repeat = 1; repeat <= repeats; repeat++) {
      for (final scenario in [
        (
          name: '선택 재료·15분',
          servings: 1,
          minutes: 15,
          preference: '',
          equipment: '',
        ),
        (
          name: '복합 조건',
          servings: 1,
          minutes: 15,
          preference: '맵지 않게, 국물 없이',
          equipment: '전자레인지',
        ),
        (
          name: '조건 변경',
          servings: 2,
          minutes: 20,
          preference: '맵지 않게, 국물 없이',
          equipment: '전자레인지',
        ),
      ]) {
        final watch = Stopwatch()..start();
        try {
          final recipes = await ai.recommend(
            batches,
            selectedBatchIds: {'fixture-tofu', 'fixture-egg'},
            servings: scenario.servings,
            maxMinutes: scenario.minutes,
            preferences: scenario.preference,
            equipment: scenario.equipment,
          );
          results.add({
            'case': scenario.name,
            'repeat': repeat,
            'elapsedMs': watch.elapsedMilliseconds,
            'structuredValidation': recipes.isEmpty ? 'empty' : 'passed',
            'humanQualityReview': 'pending',
            'request': {
              'servings': scenario.servings,
              'maxMinutes': scenario.minutes,
              'preferences': scenario.preference,
              'equipment': scenario.equipment,
            },
            'recipes': recipes.map((r) => r.toJson()).toList(),
          });
          stdout.writeln(
            '${scenario.name}: ${recipes.length}개, ${watch.elapsedMilliseconds}ms (요리 품질 수동 평가 필요)',
          );
          if (recipes.isEmpty) exitCode = 1;
        } catch (error) {
          results.add({
            'case': scenario.name,
            'repeat': repeat,
            'elapsedMs': watch.elapsedMilliseconds,
            'structuredValidation': 'failed',
            'errorType': error.runtimeType.toString(),
          });
          stderr.writeln(
            '${scenario.name}: 실패 (${error.runtimeType}). 비밀값과 원문 오류는 기록하지 않았습니다.',
          );
          exitCode = 1;
        }
      }
    }
    final report = File('build/ai_quality_probe.json');
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'syntheticInventoryOnly': true,
        'results': results,
      }),
    );
    stdout.writeln(
      '결과: build/ai_quality_probe.json. 이 결과만으로 대화·음성·UI 사용성 검증을 대체하지 않습니다.',
    );
  } finally {
    ai.dispose();
  }
}
