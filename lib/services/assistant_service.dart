import 'dart:convert';

import '../models/assistant_command.dart';
import '../models/inventory.dart';
import '../models/recipe.dart';
import 'ai_service.dart';
import 'inventory_store.dart';
import 'storage_preferences.dart';

class AssistantService {
  AssistantService({
    required this.store,
    AiService? ai,
    AssistantMemory? memory,
  }) : ai = ai ?? AiService(),
       memory = memory ?? AssistantMemory.instance {
    this.memory.syncMode(store.isDemo);
  }
  final InventoryStore store;
  final AiService ai;
  final AssistantMemory memory;
  final Set<String> _executed = {};
  static List<Recipe> get lastRecipes => AssistantMemory.instance.recipes;
  static set lastRecipes(List<Recipe> value) {
    AssistantMemory.instance.recipes = List.unmodifiable(value);
    AssistantMemory.instance.selectedRecipe = null;
  }

  void selectRecipe(Recipe recipe) => memory.selectedRecipe = recipe;
  static int _sequence = 0;
  bool _disposed = false;
  String nextId() =>
      'assistant-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  void dispose() {
    _disposed = true;
    ai.dispose();
  }

  static final _shoppingDestination = RegExp(r'장바구니|장보기(?:\s*목록)?');
  static final _missingIngredients = RegExp(
    r'(?:없는|부족한?|모자라는|모자란|빠진)\s*(?:식재료|재료)|(?:재료\s*)?부족분',
  );

  static bool isMultiItemIntake(String text) =>
      !_shoppingDestination.hasMatch(text) &&
      _recipeShoppingCommand(text) == null &&
      RegExp(r'추가|등록|넣어').hasMatch(text) &&
      (RegExp(r'\d+(?:\.\d+)?\s*(kg|ml|g|L|개|팩)').allMatches(text).length > 1 ||
          RegExp(r',|그리고|하고').hasMatch(text));
  void selectBatch(String id) {
    final b = store.batches.where((b) => b.id == id).firstOrNull;
    if (b != null) {
      memory.lastItem = b.name;
      memory.lastBatchId = b.id;
    }
  }

  Future<void> startCooking(Recipe recipe, {String? replacingSessionId}) async {
    final active = store.cookingSession;
    final currentId = active?['id'] as String?;
    final isActive =
        active != null && !['ended', 'completed'].contains(active['status']);
    if ((replacingSessionId != null && replacingSessionId != currentId) ||
        (isActive && replacingSessionId == null)) {
      throw StateError('진행 중인 요리를 종료할지 먼저 확인해주세요.');
    }
    await store.saveCookingSessionIfCurrent({
      'id': nextId(),
      'recipeId': recipe.id,
      'recipe': recipe.toJson(),
      'step': 0,
      'status': 'cooking',
      'usageApplied': false,
    }, expectedSessionId: currentId);
    selectRecipe(recipe);
  }

  Future<AssistantCommand> interpret(
    String input, {
    required bool useAi,
    Recipe? recipe,
    int? recipeStep,
  }) async {
    memory.syncMode(store.isDemo);
    final initialContext = requestContext;
    if (input.trim().isEmpty || input.length > 2000) {
      throw const FormatException('명령을 1~2000자로 입력해주세요.');
    }
    final pendingReply = _pendingReply(input);
    final recipeShopping = _recipeShoppingCommand(input);
    AssistantCommand command;
    if (recipeShopping != null) {
      command = recipeShopping;
    } else if (pendingReply != null) {
      command = pendingReply;
    } else if (useAi) {
      final local = parseLocal(input, memory: memory);
      final needsHistory = _needsHistory(local, input);
      final context = _promptInventory(input, parsed: local);
      final data = await ai.requestStructured(
        '''주방 앱 사용자 발화를 실행하지 말고 다음 허용 명령 중 하나로 해석하세요.
허용 intent: ${AssistantIntent.values.map((i) => i.name).join(', ')}.
JSON {"command":{"intent":"search","item":"두부"}}만 출력하세요.
당신은 하나의 주방 대화를 이어갑니다. 최근 질문에 대한 짧은 답은 확인 중 명령의 빠진 정보만 채우고, 주제가 바뀌면 이전 실행 의도를 끌고 오지 마세요. 설명·일반 질문·인사·이유 질문은 coach로 처리하고 question에 사용자 질문을 보존하세요. 조리 중이 아니어도 coach를 사용할 수 있습니다.
'그거/그걸'은 최근 선택 대상, '첫 번째/두 번째'는 최근 제시한 목록을 참고하되 여러 의미가 가능하면 clarify로 확인하세요. 단순 '응/좋아'를 재고 변경 승인으로 해석하지 마세요. 승인 버튼은 앱에서 별도 처리합니다.
기존 추천 후 '2인분으로', '15분 안에', '맵지 않게', '전자레인지로만'은 기존 조건을 유지하는 수정입니다. 명시적으로 새로 시작하거나 새 식사 주제를 말하면 새 추천으로 처리하세요.
허용 필드: intent,item,batchId,batchIds,excludedIngredients,quantity,unit,storage,days,servings,maxMinutes,recipeIndex,question,preferences,equipment,refineRecommendation.
필드 타입은 엄격합니다. intent/item/batchId/unit/storage/question/preferences/equipment는 문자열입니다. preferences에 객체를 넣거나 equipment에 배열을 넣지 마세요. batchIds/excludedIngredients만 문자열 배열입니다. quantity는 유한 숫자 또는 생략이며 빈 문자열은 금지입니다. days/servings/maxMinutes/recipeIndex는 양의 정수입니다. refineRecommendation은 boolean입니다. servings와 maxMinutes는 preferences 안이 아닌 command 바로 아래에 둡니다. 알 수 없는 선택 필드는 생략하세요.
정확한 추천 형식 예: {"command":{"intent":"recommend","preferences":"맵지 않게","equipment":"전자레인지만","servings":1,"maxMinutes":15}}. 재료를 지정했다면 이 command에 실제 재고 ID의 batchIds 배열을 추가하세요.
정확한 모호 수량 예: 사용자 "두부 조금 썼어" → {"command":{"intent":"clarify","item":"두부","question":"두부를 얼마나 사용했나요? 수량과 단위를 알려주세요. 예: 100g"}}. "조금/약간/적당히"는 숫자가 아니며 consume나update로 반환하거나 수량을 추측하지 마세요.
사용자가 빼달라거나 알레르기가 있다고 명시한 재료명은 excludedIngredients 배열로 보존합니다. 저장된 개인 설정을 바꾸지 않는 이번 추천용 제외조건입니다. 기존 제외조건 해제 요청은 빈 배열, 추가 요청은 이전과 합친 배열로 반환하세요.
추천은 복수 재료의 실제 ID를 batchIds 배열에 담고 맛·식단 조건은 preferences, 조리 도구는 equipment로 보존하세요. 명시하지 않은 추천 필드는 생략하세요. 기존 추천의 조건 수정이면 refineRecommendation:true와 바뀐 필드만 반환하세요. 재료 전체 선택은 batchIds:[], 조건 해제는 해당 문자열:""로 표시합니다. 이름이 같은 재료도 실제 서로 다른 묶음입니다. 수량·날짜가 미상이면 추측하지 말고 clarify로 질문하세요. createdAt은 앱 등록 시각이며 구매일이 아닙니다.
storage는 fridge/freezer/pantry, unit은 개/팩/g/kg/ml/L입니다. recipeIndex는 1부터. 품목명·수량·단위가 불명확하면 clarify와 question으로 질문하세요. 수량을 추측하지 마세요. 삭제·대량폐기는 지원하지 않으며 clarify를 반환하세요.
create는 새묶음 추가, update는 수량 수정, consume는 사용, discard는 폐기, move는 위치이동, shopping은장보기. 읽기량을 답하지 말고 search나expiring로 해석하세요. 추천과 음식 질문은recommend/coach. 요리 명령은cookingNext/Previous/Pause/Resume/Finish/Read.
선택한 요리의 없는 재료를 장보기·장바구니에 담으라는 요청은 recipeShopping입니다. 번호를 명시하면 recipeIndex, 특정 요리명을 명시하면 item에 해당 제목을 넣으세요. 선택이 없으면 앱에서 요리를 물어봅니다. "없는 재료"를 개별 장보기 품목으로 만들지 마세요. 필요한 재료를 묻기만 하면 coach이고 장보기는 바꾸지 않습니다.
최소 재고 식별목록: ${jsonEncode(context)}
목록에 없는 재고의 유무를 추측하지 마세요. 같은 이름이나 동의어의 묶음 중 어느 것인지 사용자가 지정하지 않으면 batchId를 생략하세요. 검색 결과와 재고 변경 대상은 앱에서 전체 재고로 확인합니다. 새 재료에 보관 위치를 말하지 않으면 storage를 생략하세요.
현재 날짜: ${DateTime.now().toIso8601String()}
대화 맥락: ${jsonEncode(needsHistory ? _interpretationHistory(recipe, recipeStep) : null)}
사용자 입력(명령 해석 대상): ${jsonEncode(input)}''',
      );
      if (data['command'] is! Map) {
        throw const FormatException('AI가 확인 가능한 명령을 반환하지 않았어요.');
      }
      command = AssistantCommand.fromJson(
        Map<String, dynamic>.from(data['command'] as Map),
      );
    } else {
      final followup = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(kg|ml|g|L|개|팩)\s*$')
          .firstMatch(input);
      if (memory.pending != null && followup != null) {
        command = AssistantCommand.fromJson({
          ...memory.pending!.toJson(),
          'quantity': double.parse(followup.group(1)!),
          'unit': followup.group(2),
        });
      } else {
        command = parseLocal(input, memory: memory);
      }
    }
    if (command.intent == AssistantIntent.shopping &&
        _missingIngredients.hasMatch(command.item)) {
      command = const AssistantCommand(
        intent: AssistantIntent.clarify,
        question: '어느 요리의 부족한 재료를 장보기에 담을까요?',
      );
    }
    if (command.intent == AssistantIntent.recommend &&
        !command.suppliedFields.contains('batchIds') &&
        command.batchIds.isEmpty) {
      final grounded = _explicitRecommendationBatches(input, command);
      if (grounded.isNotEmpty) {
        command = AssistantCommand.fromJson({
          for (final entry in command.toJson().entries)
            if (command.suppliedFields.contains(entry.key))
              entry.key: entry.value,
          'intent': command.intent.name,
          'batchIds': grounded,
        });
      }
    }
    final refersToLast =
        RegExp(r'^(그거|그걸|그것|이거|이걸|그 재료)').hasMatch(input.trim()) &&
        memory.lastBatchId != null;
    if (refersToLast &&
        command.changesInventory &&
        command.intent != AssistantIntent.create) {
      command = command.withTarget(memory.lastBatchId!);
    }
    if (command.intent == AssistantIntent.create) {
      final location =
          _mentionedStorage(input) ??
          pendingReply?.storage ??
          await preferredStorage();
      command = AssistantCommand.fromJson({
        ...command.toJson(),
        'storage': location.name,
      });
    } else if (useAi &&
        pendingReply == null &&
        !refersToLast &&
        (command.changesInventory ||
            command.intent == AssistantIntent.search)) {
      command = _groundInventoryTarget(command, input);
    }
    if (_disposed || initialContext != requestContext) {
      throw StateError('재고 또는 조리 상태가 변경되어 이전 요청을 중단했어요.');
    }
    if (command.intent == AssistantIntent.clarify) {
      // Keep the action that elicited a quantity question, not the clarify intent.
      final incomplete = parseLocal(input, memory: memory);
      if (incomplete.changesInventory) memory.pending = incomplete;
    } else if (pendingReply == null && !command.changesInventory) {
      memory.pending = null;
    }
    memory.remember('user', input);
    return command;
  }

  List<String> _explicitRecommendationBatches(
    String input,
    AssistantCommand command,
  ) {
    String normalize(String value) => value.replaceAll('계란', '달걀');
    final text = normalize(input);
    final excluded = command.excludedIngredients.map(normalize).toSet();
    return store.activeBatches
        .where((batch) {
          final name = normalize(batch.name);
          if (excluded.contains(name)) return false;
          final mentions = RegExp(
            '(^|[\\s,])${RegExp.escape(name)}'
            r'(?=[\s,]|은|는|을|를|와|과|로|으로|랑|하고|도|만|$)',
          ).allMatches(text);
          return mentions.any((mention) {
            final rest = text.substring(mention.end);
            return !RegExp(r'^\s*(?:은|는|을|를)?\s*(?:없이|빼|제외|말고|알레르기)')
                .hasMatch(rest);
          });
        })
        .map((batch) => batch.id)
        .toList();
  }

  AssistantCommand? _pendingReply(String raw) {
    final pending = memory.pending;
    if (pending == null || !pending.changesInventory) return null;
    final text = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final amountText = text.replaceFirst(RegExp(r'^아니(?:야)?[,，]?\s*'), '');
    final amount = RegExp(r'^(\d+(?:\.\d+)?)\s*(kg|ml|g|L|개|팩)(?:이야|요|만|으로)?$')
        .firstMatch(amountText);
    if (amount != null) {
      return AssistantCommand.fromJson({
        ...pending.toJson(),
        'quantity': double.parse(amount.group(1)!),
        'unit': amount.group(2),
      });
    }
    final locationReply = RegExp(
      r'^(냉장|냉동|실온)(?:실|고)?(?:에\s*있는\s*(?:거|것)|\s*(?:거|것))$',
    ).firstMatch(text);
    if (locationReply != null && pending.intent != AssistantIntent.create) {
      final targetStorage = switch (locationReply.group(1)) {
        '냉동' => StorageType.freezer,
        '실온' => StorageType.pantry,
        _ => StorageType.fridge,
      };
      final matches = store.activeBatches
          .where(
            (b) =>
                ingredientKey(b.name) == ingredientKey(pending.item) &&
                b.storageType == targetStorage,
          )
          .toList();
      if (matches.length == 1) return pending.withTarget(matches.single.id);
    }
    final ordinal = RegExp(r'^(첫\s*번째|두\s*번째|세\s*번째|[1-9]\s*번)(?:\s*(?:거|것))?$')
        .firstMatch(text);
    if (ordinal != null) {
      final token = ordinal.group(1)!;
      final index = token.startsWith('첫')
          ? 0
          : token.startsWith('두')
          ? 1
          : token.startsWith('세')
          ? 2
          : int.parse(token[0]) - 1;
      final candidates = memory.resultBatchIds
          .where(
            (id) => store.activeBatches.any(
              (b) =>
                  b.id == id &&
                  ingredientKey(b.name) == ingredientKey(pending.item),
            ),
          )
          .toList();
      if (index < candidates.length) {
        return pending.withTarget(candidates[index]);
      }
    }
    final location = switch (text) {
      '냉장' || '냉장고' || '냉장실' || '냉장실로' => StorageType.fridge,
      '냉동' || '냉동고' || '냉동실' || '냉동실로' => StorageType.freezer,
      '실온' || '팬트리' || '실온으로' => StorageType.pantry,
      _ => null,
    };
    if (location != null && pending.intent == AssistantIntent.move) {
      return AssistantCommand.fromJson({
        ...pending.toJson(),
        'storage': location.name,
      });
    }
    return null;
  }

  List<Map<String, dynamic>> inventoryContext() => store.activeBatches
      .map(
        (b) => {
          'id': b.id,
          'revision': b.revision,
          'name': b.name,
          'storage': b.storageType.name,
          'quantity': b.quantityMode == QuantityMode.measured
              ? b.quantity
              : null,
          'unit': b.unit,
          'quantityMode': b.quantityMode.name,
          'stockLevel': b.stockLevel.name,
          'expiryDate': b.expiryDate?.toIso8601String(),
          'expiryStatus': b.expiryStatus.name,
          'daysRemaining': b.daysRemaining(),
          'openedStatus': b.openedStatus.name,
          'createdAt': b.createdAt.toIso8601String(),
        },
      )
      .toList();

  // The full local snapshot detects stale responses. Only scoped rows enter a prompt.
  Map<String, dynamic> _promptInventory(
    String input, {
    Recipe? recipe,
    AssistantCommand? parsed,
    bool forAnswer = false,
  }) {
    final active = store.activeBatches;
    final query = ingredientKey(input);
    final local = parsed ?? parseLocal(input, memory: memory);
    if (!forAnswer && local.intent == AssistantIntent.create) {
      return {'rows': [], 'partial': active.isNotEmpty};
    }
    final item = ingredientKey(local.item);
    final hasItem =
        item.isNotEmpty &&
        (local.changesInventory || local.intent == AssistantIntent.search);
    final recipeNames =
        recipe?.ingredients.map((i) => ingredientKey(i.name)).toSet() ?? {};
    final refersBack = RegExp(r'그거|그걸|이거|그 재료|그것|그 묶음').hasMatch(input);
    final mentioned = active.where((b) {
      final name = ingredientKey(b.name);
      return query.contains(name) ||
          (hasItem && name.contains(item)) ||
          (refersBack && b.id == memory.lastBatchId) ||
          recipeNames.contains(name);
    }).toList();
    final suggestsFromStock = RegExp(r'있는\s*걸로|있는\s*재료|뭘\s*먹|대신|대체')
        .hasMatch(input);
    final asksAboutInventory = RegExp(r'재고|보유|있는|남은|냉장|냉동|임박').hasMatch(input);
    final mentionedIds = mentioned.map((b) => b.id).toSet();
    final candidates = forAnswer && suggestsFromStock
        ? [...mentioned, ...active.where((b) => !mentionedIds.contains(b.id))]
        : mentioned.isNotEmpty || hasItem
        ? mentioned
        : forAnswer && asksAboutInventory
        ? active
        : const <InventoryBatch>[];
    final rows = candidates.map(
      (b) => {
        'id': b.id,
        'name': b.name,
        'storage': b.storageType.name,
        if (forAnswer) ...{
          if (b.quantityMode == QuantityMode.measured) ...{
            'quantity': b.quantity,
            'unit': b.unit,
          } else
            'stockLevel': b.stockLevel.name,
          'expiryStatus': b.expiryStatus.name,
          'daysRemaining': ?b.daysRemaining(),
        },
      },
    );
    final sent = _boundedItems(rows, 24000);
    return {'rows': sent, 'partial': sent.length < active.length};
  }

  static List<T> _boundedItems<T>(Iterable<T> values, int byteBudget) {
    final retained = <T>[];
    for (final value in values) {
      // The JSON is embedded as text in an outer JSON HTTP body.
      final size = utf8.encode(jsonEncode(jsonEncode(value))).length + 1;
      if (size > byteBudget) break;
      byteBudget -= size;
      retained.add(value);
    }
    return retained;
  }

  List<Map<String, String>> _recentTurns() =>
      _boundedItems(memory.turns.reversed.take(12), 16000).reversed.toList();

  Map<String, dynamic>? _commandContext(AssistantCommand? command) {
    if (command == null) return null;
    return {
      ...command.toJson(),
      'batchIds': _boundedItems(command.batchIds, 4096),
    };
  }

  bool _needsHistory(AssistantCommand local, String input) =>
      local.item.isEmpty ||
      !(local.changesInventory || local.intent == AssistantIntent.search) ||
      RegExp(r'그럼|그러면|그중|그거|그걸|그것|이거|이걸|그 재료|번째|번 거|대신|대체').hasMatch(input);

  Map<String, dynamic> _interpretationHistory(Recipe? recipe, int? recipeStep) {
    final session = store.cookingSession;
    final snapshot = session?['recipe'];
    if (recipe == null &&
        snapshot is Map &&
        !['ended', 'completed'].contains(session?['status'])) {
      try {
        recipe = Recipe.fromJson(Map<String, dynamic>.from(snapshot));
        recipeStep = (session?['step'] as num?)?.toInt();
      } on FormatException {
        // Other commands can still use conversational context without a valid saved recipe.
      }
    }
    return {
      '이전 추천 조건': ?_commandContext(memory.recommendation),
      '선택한 레시피명': ?memory.selectedRecipe?.title,
      if (memory.resultBatchIds.isNotEmpty)
        '최근 검색 결과 ID(순서대로)': _boundedItems(memory.resultBatchIds, 4096),
      '현재 요리 맥락': ?_recipeContext(recipe, recipeStep ?? 0),
      '이전 재료': ?memory.lastItem,
      '이전 묶음 ID': ?memory.lastBatchId,
      '확인 중 명령': ?_commandContext(memory.pending),
      if (memory.turns.isNotEmpty) '최근 대화': _recentTurns(),
      if (memory.recipes.isNotEmpty)
        '추천받은 레시피': [
          for (final (index, r) in memory.recipes.indexed)
            {'recipeIndex': index + 1, 'title': r.title},
        ],
    };
  }

  Map<String, dynamic>? _recipeContext(
    Recipe? recipe,
    int step, {
    bool includeSteps = false,
  }) {
    if (recipe == null) return null;
    return {
      'title': recipe.title,
      'step': step,
      if (recipe.steps.isNotEmpty)
        'currentStep': recipe.steps[step.clamp(0, recipe.steps.length - 1)],
      if (includeSteps) ...{
        'steps': _boundedItems(recipe.steps, 10000),
        'ingredients': _boundedItems(
          recipe.ingredients.map((i) => i.toJson()),
          10000,
        ),
        'allergens': recipe.allergens,
        'allergensKnown': recipe.allergensKnown,
      },
    };
  }

  String get requestContext => jsonEncode({
    'memoryRevision': memory.revision,
    'isDemo': store.isDemo,
    'inventory': inventoryContext(),
    'cooking': store.cookingSession,
  });

  /// Merge only explicitly supplied follow-up fields. Callers commit this to
  /// memory only after a recommendation succeeds.
  AssistantCommand recommendationConditions(
    AssistantCommand command, {
    String defaultPreferences = '',
    String defaultEquipment = '',
  }) {
    final previous = command.refineRecommendation
        ? memory.recommendation
        : null;
    final fields = command.suppliedFields;
    bool supplied(String key) => fields.contains(key);
    final ids = supplied('batchIds') || command.batchIds.isNotEmpty
        ? command.batchIds
        : command.item.isNotEmpty
        ? store.activeBatches
              .where((b) => b.name == command.item)
              .map((b) => b.id)
              .toList()
        : previous?.batchIds ?? <String>[];
    if (command.item.isNotEmpty && ids.isEmpty) {
      throw StateError('선택한 재료를 재고에서 찾지 못했어요. 재료를 다시 선택해주세요.');
    }
    if (ids.any((id) => !store.activeBatches.any((b) => b.id == id))) {
      throw StateError('추천 재료의 재고가 변경됐어요. 재료를 다시 선택해주세요.');
    }
    return AssistantCommand(
      intent: AssistantIntent.recommend,
      batchIds: ids,
      excludedIngredients:
          supplied('excludedIngredients') ||
              command.excludedIngredients.isNotEmpty
          ? command.excludedIngredients
          : previous?.excludedIngredients ?? const [],
      servings: supplied('servings') || command.servings != 1
          ? command.servings
          : previous?.servings ?? 1,
      maxMinutes: supplied('maxMinutes') || command.maxMinutes != 30
          ? command.maxMinutes
          : previous?.maxMinutes ?? 30,
      preferences: supplied('preferences') || command.preferences.isNotEmpty
          ? command.preferences
          : previous?.preferences ?? defaultPreferences,
      equipment: supplied('equipment') || command.equipment.isNotEmpty
          ? command.equipment
          : previous?.equipment ?? defaultEquipment,
    );
  }

  static int? recipeChoiceNumber(String text) {
    final choice = RegExp(
      r'^(?:추천\s*)?(\d+)(?:\s*번(?:째)?)?(?:\s*(?:요리|레시피|메뉴|것|거))?(?:\s*선택(?:해\s*줘)?)?$',
    ).firstMatch(text.trim());
    if (choice != null) return int.tryParse(choice.group(1)!);
    return switch (text.replaceAll(RegExp(r'\s'), '')) {
      '첫번째' || '첫번째요리' || '첫번째메뉴' => 1,
      '두번째' || '두번째요리' || '두번째메뉴' => 2,
      '세번째' || '세번째요리' || '세번째메뉴' => 3,
      _ => null,
    };
  }

  static AssistantCommand? _recipeShoppingCommand(String raw) {
    final text = raw.trim().replaceFirst(RegExp(r'[.!?]+$'), '');
    final hasDestination = _shoppingDestination.hasMatch(text);
    final request = text
        .replaceAll(RegExp(r'(?:장바구니|장보기(?:\s*목록)?)(?:에다가|에|으로|로)?'), '')
        .trim();
    final missing = _missingIngredients.firstMatch(request);
    if (missing == null) return null;
    final action = RegExp(
      r'(담아|담기|넣어|넣기|보내기?|추가(?:해|하기)?)(?:\s*(?:줘요?|주세요|주라|줄래요?))?$',
    ).firstMatch(request);
    if (action == null || (!hasDestination && !action[1]!.startsWith('담'))) {
      if (!hasDestination) return null;
      return const AssistantCommand(
        intent: AssistantIntent.clarify,
        question:
            '레시피의 부족한 재료를 보려면 요리를 선택해주세요. 장보기에 담으려면 “없는 재료 담아줘”라고 말씀해주세요.',
      );
    }
    if (action.start < missing.end ||
        !RegExp(r'^(?:들)?(?:을|를|만|도|는)?\s*(?:모두|전부|다|한꺼번에|한번에)?$')
            .hasMatch(request.substring(missing.end, action.start).trim())) {
      return const AssistantCommand(
        intent: AssistantIntent.clarify,
        question: '어느 요리의 부족한 재료를 담을까요? 개별 품목은 재료 이름으로 알려주세요.',
      );
    }
    final target = request
        .substring(0, missing.start)
        .trim()
        .replaceFirst(RegExp(r'\s*(?:메뉴|레시피|요리)?\s*(?:에서|의|에)?$'), '')
        .trim();
    final selected = RegExp(
      r'^(?:이|그|해당|현재|지금|방금|선택한|고른|방금\s*(?:선택한|고른)|냉장고|우리\s*집)?$',
    ).hasMatch(target);
    final index = recipeChoiceNumber(target);
    return AssistantCommand(
      intent: AssistantIntent.recipeShopping,
      recipeIndex: index,
      item: selected || index != null ? '' : target,
    );
  }

  static StorageType? _mentionedStorage(String text) {
    if (RegExp(r'냉동|freezer', caseSensitive: false).hasMatch(text)) {
      return StorageType.freezer;
    }
    if (RegExp(r'실온|상온|팬트리|pantry', caseSensitive: false).hasMatch(text)) {
      return StorageType.pantry;
    }
    if (RegExp(r'냉장|fridge', caseSensitive: false).hasMatch(text)) {
      return StorageType.fridge;
    }
    return null;
  }

  static AssistantCommand parseLocal(String raw, {AssistantMemory? memory}) {
    final recipeShopping = _recipeShoppingCommand(raw);
    if (recipeShopping != null) return recipeShopping;
    var s = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    for (final e in {
      '한 개': '1개',
      '두 개': '2개',
      '세 개': '3개',
      '네 개': '4개',
      '밀리리터': 'ml',
      '리터': 'L',
      '킬로그램': 'kg',
      '그램': 'g',
    }.entries) {
      s = s.replaceAll(e.key, e.value);
    }
    if (RegExp(r'하나|둘|셋').hasMatch(s)) {
      return const AssistantCommand(
        intent: AssistantIntent.clarify,
        question: '수량과 단위를 구체적으로 알려주세요. 예: 우유 1팩 추가',
      );
    }
    final pronoun = RegExp(r'^(그거|그걸|그것|이거|이걸|그 재료)');
    if (pronoun.hasMatch(s)) {
      if (memory?.lastItem == null) {
        return const AssistantCommand(
          intent: AssistantIntent.clarify,
          question: '어떤 재료를 말하나요? 재료 이름을 알려주세요.',
        );
      }
      s = s.replaceFirst(pronoun, memory!.lastItem!);
    }
    if (RegExp(r'다음\s*단계').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingNext);
    }
    if (RegExp(r'이전\s*단계').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingPrevious);
    }
    if (RegExp(r'다시\s*읽|읽어\s*줘').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingRead);
    }
    if (RegExp(r'일시\s*정지|잠깐\s*멈').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingPause);
    }
    if (RegExp(r'계속\s*(하기|해|요리)|조리\s*재개').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingResume);
    }
    if (RegExp(r'요리\s*완료|조리\s*완료|다\s*만들').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingFinish);
    }
    final choice = RegExp(r'(\d+)\s*(번|번째).*(선택|시작|요리)').firstMatch(s);
    if (choice != null) {
      return AssistantCommand.fromJson({
        'intent': s.contains('시작') ? 'cookingStart' : 'selectRecipe',
        'recipeIndex': int.parse(choice.group(1)!),
      });
    }
    if (RegExp(r'^(요리|조리)\s*시작(해|해줘|하기)?$').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.cookingStart);
    }
    if (RegExp(r'임박|이번\s*주|먼저\s*먹|소비기한').hasMatch(s)) {
      return const AssistantCommand(intent: AssistantIntent.expiring);
    }
    if (RegExp(r'어떻게\s*버|분리\s*배출|보관\s*(법|방법)|처리\s*방법').hasMatch(s)) {
      return AssistantCommand(
        intent: AssistantIntent.guide,
        item: s.replaceAll(RegExp(r'어떻게.*|분리\s*배출.*|보관.*|처리.*'), '').trim(),
      );
    }
    if (RegExp(r'추천|만들\s*수|뭐\s*(먹|만들)').hasMatch(s) ||
        (memory?.recommendation != null &&
            RegExp(
              r'다시|바꿔|말고|줄여|늘려|인분|분\s*(안|이내|으로)|맵지|안\s*맵|전자레인지|에어프라이어|빼고|없이',
            ).hasMatch(s))) {
      final minutes = RegExp(r'(\d+)\s*분').firstMatch(s);
      final servings = RegExp(r'(\d+)\s*인분').firstMatch(s);
      final refining =
          memory?.recommendation != null &&
          RegExp(r'다시|바꿔|말고|줄여|늘려|인분|분\s*(안|이내|으로)|맵지|안\s*맵|전자레인지|에어프라이어|빼고|없이')
              .hasMatch(s);
      final preference = RegExp(r'맵지|안\s*맵|덜\s*맵|채식|담백|저염|달지|알레르기|제외|빼고|없이')
          .hasMatch(s);
      final equipment = RegExp(r'전자레인지|에어프라이어|오븐|가스레인지|인덕션')
          .allMatches(s)
          .map((m) => m.group(0)!)
          .join(', ');
      final exclusions = RegExp(r'([가-힣a-zA-Z]+?)\s*(?:없이|빼고|제외)')
          .allMatches(s)
          .map((m) => m.group(1)!.replaceFirst(RegExp(r'(은|는|을|를)$'), ''))
          .where((name) => name.isNotEmpty)
          .toList();
      return AssistantCommand.fromJson({
        'intent': 'recommend',
        if (RegExp(r'그걸로|그거로|그 재료').hasMatch(raw) &&
            memory?.lastBatchId != null)
          'batchIds': [memory!.lastBatchId!],
        if (RegExp(r'그걸로|그거로|그 재료').hasMatch(raw))
          'item': memory?.lastItem ?? '',
        if (minutes != null) 'maxMinutes': int.parse(minutes.group(1)!),
        if (servings != null) 'servings': int.parse(servings.group(1)!),
        if (preference)
          'preferences':
              refining && memory!.recommendation!.preferences.isNotEmpty
              ? '${memory.recommendation!.preferences}; 다음 요청을 우선 적용: $s'
              : s,
        if (equipment.isNotEmpty) 'equipment': equipment,
        if (exclusions.isNotEmpty)
          'excludedIngredients': {
            if (refining) ...memory!.recommendation!.excludedIngredients,
            ...exclusions,
          }.toList(),
        'refineRecommendation': refining,
      });
    }
    final storage = _mentionedStorage(s);
    String clean(String t) => t
        .replaceAll(
          RegExp(r'냉장실|냉동실|냉장고|냉동고|냉장\s*칸|냉동\s*칸|냉장|냉동|실온|상온|팬트리'),
          '',
        )
        .replaceAll(RegExp(r'^(에|에서)\s*'), '')
        .replaceAll(RegExp(r'(을|를|은|는|이|가|로|으로|에)$'), '')
        .trim();
    final shoppingDestination = _shoppingDestination.firstMatch(s);
    if (shoppingDestination != null) {
      final name = clean(s.substring(0, shoppingDestination.start));
      final m = RegExp(r'^(.+?)\s*(\d+(?:\.\d+)?)\s*(kg|ml|g|L|개|팩)$')
          .firstMatch(name);
      return AssistantCommand(
        intent: AssistantIntent.shopping,
        item: m == null ? name : clean(m.group(1)!),
        quantity: m == null ? null : double.parse(m.group(2)!),
        unit: m?.group(3),
      );
    }
    if (RegExp(r'옮|이동').hasMatch(s)) {
      return AssistantCommand(
        intent: AssistantIntent.move,
        item: clean(s.split(RegExp(r'냉장|냉동|실온|상온|팬트리')).first),
        storage: storage,
      );
    }
    final qty = RegExp(r'^(.+?)\s*(\d+(?:\.\d+)?)\s*(kg|ml|g|L|개|팩)\s*(.*)$')
        .firstMatch(s);
    if (qty != null) {
      final suffix = qty.group(4)!;
      final intent = RegExp(r'먹|사용|소비|차감').hasMatch(suffix)
          ? AssistantIntent.consume
          : RegExp(r'버|폐기').hasMatch(suffix)
          ? AssistantIntent.discard
          : RegExp(r'수정|변경|맞춰').hasMatch(suffix)
          ? AssistantIntent.update
          : RegExp(r'추가|등록|넣어').hasMatch(suffix)
          ? AssistantIntent.create
          : null;
      if (intent != null) {
        return AssistantCommand.fromJson({
          'intent': intent.name,
          'item': clean(qty.group(1)!),
          'quantity': double.parse(qty.group(2)!),
          'unit': qty.group(3),
          if (storage != null) 'storage': storage.name,
        });
      }
    }
    if (RegExp(r'있|몇\s*개|얼마나\s*남|찾아|조회').hasMatch(s)) {
      final item = clean(
        s.replaceAll(RegExp(r'몇\s*개.*|얼마나\s*남.*|있.*|찾아.*|조회.*'), ''),
      );
      return AssistantCommand(
        intent: AssistantIntent.search,
        item: item,
        storage: storage,
      );
    }
    if (RegExp(r'얼마나\s*넣|너무\s*(짜|짠)|어떻게|대신').hasMatch(s)) {
      return AssistantCommand(intent: AssistantIntent.coach, question: raw);
    }
    final vagueUse = RegExp(r'^(.+?)\s*(?:조금|약간|적당히)?\s*(썼어|썼어요|사용했어|먹었어|버렸어)$')
        .firstMatch(s);
    if (vagueUse != null) {
      return AssistantCommand(
        intent: vagueUse.group(2) == '버렸어'
            ? AssistantIntent.discard
            : AssistantIntent.consume,
        item: clean(vagueUse.group(1)!),
      );
    }
    final incomplete = RegExp(r'^(.+?)\s*(추가|등록|사용|소비|폐기|수정)(?:해\s*줘)?$')
        .firstMatch(s);
    if (incomplete != null) {
      return AssistantCommand(
        intent: switch (incomplete.group(2)) {
          '추가' || '등록' => AssistantIntent.create,
          '사용' || '소비' => AssistantIntent.consume,
          '폐기' => AssistantIntent.discard,
          _ => AssistantIntent.update,
        },
        item: clean(incomplete.group(1)!),
      );
    }
    return const AssistantCommand(
      intent: AssistantIntent.clarify,
      question: '현재 로컬 명령은 “두부 있어?”, “두부 100g 사용”, “우유 1팩 추가”, “대파 냉동실로 이동”, “우유 장보기 추가”처럼 입력해주세요. 자연어 AI 해석은 API 연결 후 사용할 수 있어요.',
    );
  }

  List<InventoryBatch> search(AssistantCommand c) {
    final result = store.activeBatches
        .where(
          (b) =>
              (c.batchId == null || b.id == c.batchId) &&
              (c.item.isEmpty ||
                  ingredientKey(b.name).contains(ingredientKey(c.item))) &&
              (c.storage == null || b.storageType == c.storage),
        )
        .toList();
    memory.resultBatchIds = result.map((b) => b.id).toList();
    if (result.length == 1) {
      selectBatch(result.single.id);
    } else {
      memory.lastItem = c.item.isEmpty ? null : c.item;
      memory.lastBatchId = null;
    }
    return result;
  }

  List<InventoryBatch> expiring(int days) {
    final result = store.activeBatches.where((b) {
      final n = b.daysRemaining();
      return n != null && n <= days;
    }).toList()..sort(compareBatchExpiry);
    memory.resultBatchIds = result.map((b) => b.id).toList();
    if (result.length == 1) {
      selectBatch(result.single.id);
    } else {
      memory.lastItem = null;
      memory.lastBatchId = null;
    }
    return result;
  }

  AssistantCommand _groundInventoryTarget(
    AssistantCommand command,
    String input,
  ) {
    final fields = command.toJson();
    if (command.intent != AssistantIntent.move) {
      final storage = _mentionedStorage(input);
      if (storage == null) {
        fields.remove('storage');
      } else {
        fields['storage'] = storage.name;
      }
    }
    if (command.batchId != null) {
      final identified = store.activeBatches
          .where((b) => b.id == command.batchId)
          .firstOrNull;
      if (command.item.isEmpty) {
        final localItem = parseLocal(input, memory: memory).item;
        fields['item'] = localItem.isNotEmpty
            ? localItem
            : identified?.name ?? '';
        if (fields['item'] == '') {
          return const AssistantCommand(
            intent: AssistantIntent.clarify,
            question: '어떤 재료 묶음인지 확인해주세요.',
          );
        }
      }
      final matches = _matchingBatches(AssistantCommand.fromJson(fields));
      if (matches.length != 1 || matches.single.id != command.batchId) {
        fields.remove('batchId');
      }
    }
    return AssistantCommand.fromJson(fields);
  }

  List<InventoryBatch> _matchingBatches(AssistantCommand command) => store
      .activeBatches
      .where(
        (batch) =>
            ingredientKey(batch.name) == ingredientKey(command.item) &&
            (command.intent == AssistantIntent.move ||
                command.storage == null ||
                batch.storageType == command.storage),
      )
      .toList();

  PreparedAssistantAction prepare(AssistantCommand c, String original) {
    c = AssistantCommand.fromJson(c.toJson());
    final id = nextId();
    PreparedAssistantAction draft({
      InventoryBatch? before,
      InventoryBatch? after,
      String? question,
      List<InventoryBatch> candidates = const [],
    }) {
      memory.pending = c.changesInventory ? c : memory.pending;
      if (candidates.isNotEmpty) {
        memory.resultBatchIds = candidates.map((b) => b.id).toList();
      }
      return PreparedAssistantAction(
        command: c,
        requestId: id,
        isDemo: store.isDemo,
        memoryRevision: memory.revision,
        originalText: original,
        before: before,
        after: after,
        clarification: question,
        candidates: candidates,
      );
    }

    if (c.intent == AssistantIntent.clarify) return draft(question: c.question);
    if (c.item.trim().isEmpty && c.batchId == null) {
      return draft(question: '어떤 재료인가요? 이름을 알려주세요.');
    }
    if (c.intent == AssistantIntent.create) {
      if (c.quantity == null || c.quantity! <= 0 || c.unit == null) {
        return draft(question: '추가할 수량과 단위를 알려주세요. 예: 두부 1개 추가');
      }
      return draft(
        after: InventoryBatch(
          id: 'batch-$id',
          name: c.item,
          quantity: c.quantity!,
          unit: c.unit!,
          storageType: c.storage ?? StorageType.fridge,
          expiryStatus: ExpiryStatus.unknown,
        ),
      );
    }
    final candidates = c.batchId == null
        ? _matchingBatches(c)
        : store.activeBatches.where((b) => b.id == c.batchId).toList();
    if (candidates.isEmpty) {
      return draft(question: '해당 재고 묶음을 찾지 못했어요. 이름 또는 보관함을 확인해주세요.');
    }
    if (candidates.length > 1) {
      return draft(
        question: '같은 재료가 여러 묶음에 있어요. 사용할 묶음을 선택해주세요.',
        candidates: candidates,
      );
    }
    final b = candidates.single;
    selectBatch(b.id);
    if (c.intent == AssistantIntent.move) {
      if (c.storage == null) return draft(question: '이동할 보관 위치를 알려주세요.');
      return draft(
        before: b,
        after: b.copyWith(storageType: c.storage, shelfId: null, slotId: null),
      );
    }
    if (c.quantity == null || c.unit == null) {
      return draft(question: '수량과 단위를 알려주세요. 예: ${b.name} 1${b.unit} 사용');
    }
    if (b.quantityMode != QuantityMode.measured) {
      return draft(question: '상태형 재료는 상세 화면에서 충분·부족·없음으로 수정해주세요.');
    }
    double amount;
    try {
      amount = convertQuantity(c.quantity!, c.unit!, b.unit);
    } catch (_) {
      return draft(
        question: '${c.unit}를 ${b.unit}로 환산할 정보가 없어요. ${b.unit} 단위로 직접 알려주세요.',
      );
    }
    if (c.intent != AssistantIntent.update && amount <= 0) {
      return draft(question: '사용 또는 폐기 수량은 0보다 커야 해요.');
    }
    final after = c.intent == AssistantIntent.update
        ? amount
        : b.quantity - amount;
    if (after < 0) {
      return draft(question: '보유량 ${b.quantityLabel}보다 많아요. 사용량을 다시 확인해주세요.');
    }
    return draft(
      before: b,
      after: b.copyWith(quantity: after),
    );
  }

  Future<String> execute(
    PreparedAssistantAction p, {
    required bool approved,
  }) async {
    if (!p.canExecute) throw StateError('불명확한 명령은 실행할 수 없습니다.');
    if (p.needsApproval && !approved) throw StateError('확인 전에는 재고를 변경하지 않습니다.');
    if (p.isDemo != store.isDemo) throw StateError('보관함 모드가 바뀌었어요. 다시 확인해주세요.');
    if (p.memoryRevision != null && p.memoryRevision != memory.revision) {
      throw StateError('대화가 초기화되어 이전 제안은 실행할 수 없어요. 다시 요청해주세요.');
    }
    if (_executed.contains(p.requestId)) return '이미 반영한 요청입니다.';
    final c = p.command;
    if (p.before != null) {
      final now = store.batches.where((b) => b.id == p.before!.id).firstOrNull;
      if (now == null || now.revision != p.before!.revision) {
        throw StateError('재고가 변경되었어요. 최신 수량으로 다시 확인해주세요.');
      }
    }
    switch (c.intent) {
      case AssistantIntent.create:
        await store.add(p.after!, source: 'assistant', requestId: p.requestId);
      case AssistantIntent.update:
      case AssistantIntent.move:
        await store.update(
          p.after!,
          source: 'assistant',
          requestId: p.requestId,
        );
      case AssistantIntent.consume:
      case AssistantIntent.discard:
        await store.consume(
          p.before!.id,
          p.before!.quantity - p.after!.quantity,
          discard: c.intent == AssistantIntent.discard,
          source: 'assistant',
          requestId: p.requestId,
          expectedRevision: p.before!.revision,
        );
      default:
        throw StateError('실행할 수 없는 변경입니다.');
    }
    _executed.add(p.requestId);
    memory.pending = null;
    final b = store.batches.where((b) => b.id == p.after!.id).firstOrNull;
    if (b == null) throw StateError('저장 결과를 찾지 못했어요.');
    final message = c.intent == AssistantIntent.move
        ? '${b.name} → ${b.storageType.label} 이동 완료'
        : '${b.name} ${p.before?.quantityLabel ?? '신규'} → ${b.quantityLabel} 저장 완료';
    memory.remember('assistant', message);
    return message;
  }

  Future<String> coach(
    String question,
    Recipe recipe,
    int step, {
    List<String> allergies = const [],
    String preferences = '',
    String equipment = '',
  }) => converse(
    question,
    recipe: recipe,
    step: step,
    allergies: allergies,
    preferences: preferences,
    equipment: equipment,
  );

  Future<String> converse(
    String question, {
    Recipe? recipe,
    int step = 0,
    List<String> allergies = const [],
    String preferences = '',
    String equipment = '',
  }) async {
    memory.syncMode(store.isDemo);
    final initialContext = requestContext;
    final local = parseLocal(question, memory: memory);
    final needsHistory = _needsHistory(local, question);
    if (needsHistory) recipe ??= memory.selectedRecipe;
    if (!ai.isConfigured) {
      throw StateError(
        '복잡한 요리 질문은 제공 AI 연결이 필요해요. 현재 단계 읽기는 연결 없이 사용할 수 있습니다.',
      );
    }
    final data = await ai.requestStructured(
      '''이전 대화와 현재 주방 상태를 이어받아 마지막 질문에 자연스러운 한국어로 답하세요. 일반 주방 질문도 답할 수 있습니다. 레시피가 없으면 조리 중이라고 가정하지 마세요. 설명을 요청했는데 명령 예시만 반복하지 마세요. 확인되지 않은 수량이나 대상을 추측하지 말고 필요한 정보 하나만 질문하세요. 다음 행동을 한 가지 제안할 수 있지만 실제 실행한 것처럼 말하지 마세요. 임의 재고변경이나 외부영상 조회를 했다고 말하지 마세요. 식품 안전을 보장하거나 확인되지 않은 보관기한을 제시하지 마세요. 재료 정보가 부족하면 제품표시 확인을 안내하세요.
레시피: ${jsonEncode(_recipeContext(recipe, step, includeSteps: true))}
현재 날짜: ${DateTime.now().toIso8601String()}
기한의 실제/추정/미상과 경과일을 구분하세요. 날짜만으로 먹어도 안전하다고 단정하지 마세요. 이번 추천 조건에 명시된 선호·도구가 저장된 기본 설정과 다르면 이번 조건을 우선하되 알레르기는 완화하지 마세요.
이전 추천 조건: ${jsonEncode(needsHistory ? _commandContext(memory.recommendation) : null)}
최근 대상: ${jsonEncode(needsHistory ? {'item': memory.lastItem, 'batchId': memory.lastBatchId} : null)}
현재 단계: ${recipe == null ? '조리 중 아님' : step + 1}
보유 재고: ${jsonEncode(_promptInventory(question, recipe: recipe, parsed: local, forAnswer: true))}
부분 목록인 경우 누락된 재료를 구매해야 한다고 단정하지 마세요.
피해야 할 알레르기: ${jsonEncode(allergies)}
사용자 선호: ${jsonEncode(preferences)}
사용 가능한 도구: ${jsonEncode(equipment)}
최근 대화: ${jsonEncode(needsHistory ? _recentTurns() : [])}
대체 재료를 제안할 때 위 알레르기를 적용하고 불명확한 성분은 안전하다고 단정하지 마세요.
질문: ${jsonEncode(question)}
JSON {"reply":"한국어 답변"}만 반환하세요.''',
    );
    final reply = data['reply'];
    if (reply is! String || reply.trim().isEmpty || reply.length > 5000) {
      throw const FormatException('요리 답변을 확인할 수 없어요.');
    }
    if (_disposed || initialContext != requestContext) {
      throw StateError('재고 또는 조리 상태가 변경되어 이전 답변을 중단했어요.');
    }
    memory.remember('assistant', reply);
    return reply;
  }
}
