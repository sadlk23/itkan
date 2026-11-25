import 'inventory.dart';
import 'recipe.dart';

enum AssistantIntent {
  search,
  expiring,
  create,
  update,
  consume,
  discard,
  move,
  shopping,
  recipeShopping,
  recommend,
  selectRecipe,
  cookingStart,
  cookingNext,
  cookingPrevious,
  cookingPause,
  cookingResume,
  cookingFinish,
  cookingRead,
  guide,
  coach,
  clarify,
}

class AssistantCommand {
  const AssistantCommand({
    required this.intent,
    this.item = '',
    this.batchId,
    this.quantity,
    this.unit,
    this.storage,
    this.days = 7,
    this.servings = 1,
    this.maxMinutes = 30,
    this.recipeIndex,
    this.question = '',
    this.batchIds = const [],
    this.excludedIngredients = const [],
    this.preferences = '',
    this.equipment = '',
    this.refineRecommendation = false,
    this.suppliedFields = const {},
  });
  final AssistantIntent intent;
  final String item;
  final String? batchId, unit;
  final double? quantity;
  final StorageType? storage;
  final int days, servings, maxMinutes;
  final int? recipeIndex;
  final String question;
  final List<String> batchIds;
  final List<String> excludedIngredients;
  final String preferences, equipment;
  final bool refineRecommendation;
  final Set<String> suppliedFields;
  bool get changesQuantity => [
    AssistantIntent.create,
    AssistantIntent.update,
    AssistantIntent.consume,
    AssistantIntent.discard,
  ].contains(intent);
  bool get changesInventory =>
      changesQuantity || intent == AssistantIntent.move;
  bool get isLightChange => [
    AssistantIntent.move,
    AssistantIntent.shopping,
    AssistantIntent.recipeShopping,
  ].contains(intent);
  AssistantCommand withTarget(String id) => AssistantCommand(
    intent: intent,
    item: item,
    batchId: id,
    quantity: quantity,
    unit: unit,
    storage: storage,
    days: days,
    servings: servings,
    maxMinutes: maxMinutes,
    recipeIndex: recipeIndex,
    question: question,
    batchIds: batchIds,
    excludedIngredients: excludedIngredients,
    preferences: preferences,
    equipment: equipment,
    refineRecommendation: refineRecommendation,
    suppliedFields: suppliedFields,
  );
  Map<String, dynamic> toJson() => {
    'intent': intent.name,
    'item': item,
    if (batchId != null) 'batchId': batchId,
    if (quantity != null) 'quantity': quantity,
    if (unit != null) 'unit': unit,
    if (storage != null) 'storage': storage!.name,
    'days': days,
    'servings': servings,
    'maxMinutes': maxMinutes,
    if (recipeIndex != null) 'recipeIndex': recipeIndex,
    'question': question,
    'batchIds': batchIds,
    'excludedIngredients': excludedIngredients,
    'preferences': preferences,
    'equipment': equipment,
    'refineRecommendation': refineRecommendation,
  };
  factory AssistantCommand.fromJson(Map<String, dynamic> json) {
    const allowed = {
      'intent',
      'item',
      'batchId',
      'quantity',
      'unit',
      'storage',
      'days',
      'servings',
      'maxMinutes',
      'recipeIndex',
      'question',
      'batchIds',
      'excludedIngredients',
      'preferences',
      'equipment',
      'refineRecommendation',
    };
    if (json.keys.any((k) => !allowed.contains(k))) {
      throw const FormatException('허용되지 않은 명령 필드입니다.');
    }
    final intent = AssistantIntent.values
        .where((i) => i.name == json['intent'])
        .firstOrNull;
    if (intent == null) throw const FormatException('지원하지 않는 명령입니다.');
    String? optionalString(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String || v.length > 500) {
        throw FormatException('$key 형식이 올바르지 않아요.');
      }
      return v.trim();
    }

    final quantity = json['quantity'];
    if (quantity != null &&
        (quantity is! num ||
            !quantity.isFinite ||
            quantity < 0 ||
            quantity > 1000000)) {
      throw const FormatException('수량이 유효한 범위가 아니에요.');
    }
    int bounded(String key, int fallback, int max) {
      final n = json[key] ?? fallback;
      if (n is! int || n < 1 || n > max) {
        throw FormatException('$key 범위를 확인해주세요.');
      }
      return n;
    }

    final storageName = optionalString('storage');
    final storage = StorageType.values
        .where((s) => s.name == storageName)
        .firstOrNull;
    if (storageName != null && storage == null) {
      throw const FormatException('보관 위치를 확인해주세요.');
    }
    final unit = optionalString('unit');
    if (unit != null && !{'개', '팩', 'g', 'kg', 'ml', 'L'}.contains(unit)) {
      throw const FormatException('수량 단위를 확인해주세요.');
    }
    final index = json['recipeIndex'];
    final ids = json['batchIds'] ?? <String>[];
    if (ids is! List ||
        ids.length > 1000 ||
        ids.any(
          (id) => id is! String || id.trim().isEmpty || id.length > 500,
        )) {
      throw const FormatException('추천 재료 목록을 확인해주세요.');
    }
    final refine = json['refineRecommendation'] ?? false;
    final exclusions = json['excludedIngredients'] ?? <String>[];
    if (exclusions is! List ||
        exclusions.length > 100 ||
        exclusions.any(
          (v) => v is! String || v.trim().isEmpty || v.length > 100,
        )) {
      throw const FormatException('제외할 재료 목록을 확인해주세요.');
    }
    if (refine is! bool) {
      throw const FormatException('추천 조건 수정 여부를 확인해주세요.');
    }
    if (index != null && (index is! int || index < 1 || index > 10)) {
      throw const FormatException('레시피 번호를 확인해주세요.');
    }
    return AssistantCommand(
      intent: intent,
      item: optionalString('item') ?? '',
      batchId: optionalString('batchId'),
      quantity: (quantity as num?)?.toDouble(),
      unit: unit,
      storage: storage,
      days: bounded('days', 7, 365),
      servings: bounded('servings', 1, 20),
      maxMinutes: bounded('maxMinutes', 30, 600),
      recipeIndex: index as int?,
      question: optionalString('question') ?? '',
      batchIds: List<String>.unmodifiable(
        ids.cast<String>().map((id) => id.trim()).toSet(),
      ),
      preferences: optionalString('preferences') ?? '',
      excludedIngredients: List<String>.unmodifiable(
        exclusions.cast<String>().map((v) => v.trim()).toSet(),
      ),
      equipment: optionalString('equipment') ?? '',
      refineRecommendation: refine,
      suppliedFields: Set<String>.unmodifiable(json.keys),
    );
  }
}

/// Frozen preview. The action service revalidates before committing.
class PreparedAssistantAction {
  PreparedAssistantAction({
    required this.command,
    required this.requestId,
    required this.isDemo,
    required this.originalText,
    this.memoryRevision,
    this.before,
    this.after,
    this.clarification,
    this.candidates = const [],
  });
  final AssistantCommand command;
  final String requestId, originalText;
  final bool isDemo;
  final int? memoryRevision;
  final InventoryBatch? before, after;
  final String? clarification;
  final List<InventoryBatch> candidates;
  bool get canExecute => clarification == null;
  bool get needsApproval => command.changesQuantity;
}

class AssistantMemory {
  static final AssistantMemory instance = AssistantMemory();
  String? lastItem, lastBatchId;
  AssistantCommand? pending;
  AssistantCommand? recommendation;
  bool? demo;
  int revision = 0;
  String draft = '';
  List<Recipe> recipes = [];
  Recipe? selectedRecipe;
  List<String> resultBatchIds = [];
  final List<Map<String, String>> turns = [];
  void remember(String role, String text) {
    turns.add({
      'role': role,
      'text': text.length > 1500 ? text.substring(0, 1500) : text,
    });
    if (turns.length > 24) turns.removeAt(0);
  }

  void syncMode(bool isDemo) {
    if (demo != isDemo) {
      clear();
      demo = isDemo;
    }
  }

  void clear() {
    revision++;
    draft = '';
    recipes = [];
    selectedRecipe = null;
    resultBatchIds = [];
    lastItem = null;
    lastBatchId = null;
    turns.clear();
    pending = null;
    recommendation = null;
  }
}
