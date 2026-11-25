import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/assistant_command.dart';
import '../models/inventory.dart';
import '../models/recipe.dart';
import '../models/shopping.dart';
import '../services/assistant_service.dart';
import '../services/ai_service.dart';
import '../services/cooking_preferences.dart';
import '../services/inventory_store.dart';
import '../services/shopping_store.dart';
import 'guide_screen.dart';
import 'intake_screen.dart';
import 'recipe_screen.dart';

class OpenShoppingListIntent extends Intent {
  const OpenShoppingListIntent();
}

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.store,
    this.selectedBatchId,
    this.recipe,
    this.recipeStep,
    this.initialText,
    this.aiService,
  });
  final InventoryStore store;
  final String? selectedBatchId;
  final Recipe? recipe;
  final int? recipeStep;
  final String? initialText;
  final AiService? aiService;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantCard {
  _AssistantCard(
    this.text, {
    this.batches = const [],
    this.recipes = const [],
    this.proposal,
    this.original = '',
    this.voice = false,
    this.lightCommand,
    this.shoppingRecipe,
    this.shoppingPreview,
    this.guideItem,
    this.cookingRecipe,
  });
  String text;
  final List<InventoryBatch> batches;
  final List<Recipe> recipes;
  final PreparedAssistantAction? proposal;
  final AssistantCommand? lightCommand;
  final Recipe? shoppingRecipe;
  RecipeShoppingResult? shoppingPreview;
  bool get choosingShoppingRecipe =>
      lightCommand?.intent == AssistantIntent.recipeShopping &&
      recipes.isNotEmpty;
  final String original;
  final bool voice;
  final String? guideItem;
  final Recipe? cookingRecipe;
  bool closed = false;
  String? undoId;
  int? shoppingUndoRevision;
}

class _AssistantScreenState extends State<AssistantScreen> {
  late final service = AssistantService(
    store: widget.store,
    ai: widget.aiService,
  );
  late final shopping = ShoppingStore(inventory: widget.store);
  final input = TextEditingController();
  final inputFocus = FocusNode();
  final scroll = ScrollController();
  final speech = SpeechToText();
  final tts = FlutterTts();
  final cards = <_AssistantCard>[];
  bool busy = false,
      listening = false,
      voiceInput = false,
      readAloud = true,
      useAi = false;
  static const _aiPreference = 'assistant_ai_interpretation_enabled';
  late final Future<void> _privacyReady;
  SharedPreferences? _preferences;
  bool _savingAiMode = false;
  String? error;
  String? failedInput;
  bool failedVoice = false;
  String? requestContext;
  late int memoryRevision;
  String progress = '앞선 대화와 지금 주방을 함께 살펴보고 있어요…';
  void checkRequestContext() {
    if (!mounted || requestContext != service.requestContext) {
      throw StateError('재고 또는 조리 상태가 변경되어 이전 요청을 중단했어요. 현재 상태로 다시 시도해주세요.');
    }
  }

  Recipe? selectedRecipe;
  bool get hasActiveCookingSession {
    final session = widget.store.cookingSession;
    return session != null &&
        !['ended', 'completed'].contains(session['status']);
  }

  int get selectedRecipeStep =>
      selectedRecipe?.id == widget.recipe?.id ? widget.recipeStep ?? 0 : 0;
  @override
  void initState() {
    super.initState();
    selectedRecipe = widget.recipe ?? service.memory.selectedRecipe;
    if (widget.recipe != null) service.selectRecipe(widget.recipe!);
    input.text = widget.initialText ?? service.memory.draft;
    input.addListener(saveDraft);
    restoreConversation();
    _privacyReady = _loadAiMode();
    memoryRevision = service.memory.revision;
    widget.store.addListener(syncConversation);
    if (widget.selectedBatchId != null) {
      service.selectBatch(widget.selectedBatchId!);
    }
    shopping.initialize().catchError((e) {
      if (mounted) setState(() => error = '장보기 저장소를 열지 못했어요.');
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(syncConversation);
    speech.cancel();
    tts.stop().catchError((_) => null);
    service.dispose();
    shopping.dispose();
    input.dispose();
    inputFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _loadAiMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _preferences = prefs;
        useAi =
            service.ai.isConfigured && (prefs.getBool(_aiPreference) ?? true);
      });
    } catch (_) {
      if (mounted) setState(() => error = '대화 설정을 읽지 못해 기기에서 명령을 해석해요.');
    }
  }

  void addCard(
    _AssistantCard card, {
    String? conversationText,
    bool remember = true,
  }) {
    if (!mounted) return;
    if (card.proposal != null || card.lightCommand != null) {
      for (final previous in cards.where(
        (c) => (c.proposal != null || c.lightCommand != null) && !c.closed,
      )) {
        previous.closed = true;
        previous.text = '${previous.text}\n이어진 요청으로 확인 내용을 갱신했어요.';
      }
    }
    if (remember) rememberReply(conversationText ?? card.text);
    setState(() => cards.add(card));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        if (MediaQuery.disableAnimationsOf(context)) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
          return;
        }
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void saveDraft() => service.memory.draft = input.text;

  void syncConversation() {
    service.memory.syncMode(widget.store.isDemo);
    if (!mounted || memoryRevision == service.memory.revision) return;
    memoryRevision = service.memory.revision;
    setState(() {
      cards.clear();
      selectedRecipe = null;
      input.clear();
      error = null;
      failedInput = null;
    });
  }

  void rememberReply(String text) {
    final last = service.memory.turns.lastOrNull;
    if (last?['role'] != 'assistant' || last?['text'] != text) {
      service.memory.remember('assistant', text);
    }
  }

  void restoreConversation() {
    String previousInput = '';
    for (final turn in service.memory.turns) {
      if (turn['role'] == 'user') {
        previousInput = turn['text'] ?? '';
      } else if (turn['role'] == 'assistant') {
        // Past proposals are text only: reopening never revives an approval.
        cards.add(_AssistantCard(turn['text'] ?? '', original: previousInput));
        previousInput = '';
      }
    }
  }

  void compose(String text) {
    if (busy) return;
    input.text = text;
    input.selection = TextSelection.collapsed(offset: text.length);
    voiceInput = false;
    inputFocus.requestFocus();
  }

  Future<void> read(String value) async {
    try {
      await tts.stop();
      await tts.setLanguage('ko-KR');
      await tts.speak(value.length > 500 ? value.substring(0, 500) : value);
    } catch (_) {
      if (mounted) setState(() => error = '음성 안내를 사용할 수 없어 화면에 표시합니다.');
    }
  }

  Future<void> listen() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    try {
      await tts.stop();
      final available = await speech.initialize(
        onError: (_) {
          if (mounted) {
            setState(() {
              listening = false;
              error = '마이크 또는 음성 인식을 사용할 수 없어요. 글로 입력해주세요.';
            });
          }
        },
        onStatus: (status) {
          if (mounted && status != 'listening') {
            setState(() => listening = false);
          }
        },
      );
      if (!available) {
        if (mounted) {
          setState(
            () => error = '마이크 권한이 없거나 음성 서비스가 없어요. 텍스트 입력은 계속 사용할 수 있습니다.',
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        listening = true;
        voiceInput = true;
      });
      await speech.listen(
        listenOptions: SpeechListenOptions(localeId: 'ko_KR'),
        onResult: (result) {
          if (mounted) setState(() => input.text = result.recognizedWords);
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          listening = false;
          error = '음성 연결 실패. 글로 명령을 입력해주세요.';
        });
      }
    }
  }

  Future<void> submit() async {
    if (busy || input.text.trim().isEmpty) return;
    await _privacyReady;
    if (!mounted || busy) return;
    await speech.stop();
    if (!mounted || busy) return;
    syncConversation();
    final text = input.text.trim(), voice = voiceInput;
    if (text.isEmpty) return;
    final submittedRevision = service.memory.revision;
    requestContext = service.requestContext;
    setState(() {
      busy = true;
      listening = false;
      error = null;
      progress = '앞선 대화와 지금 주방을 함께 살펴보고 있어요…';
      input.clear();
      voiceInput = false;
    });
    try {
      final previous = cards.lastOrNull;
      if (previous != null &&
          !previous.closed &&
          previous.lightCommand?.intent == AssistantIntent.recipeShopping) {
        previous.closed = true;
        if (previous.choosingShoppingRecipe) {
          final index = AssistantService.recipeChoiceNumber(text);
          final choice = index == null
              ? previous.recipes.where((r) => r.title == text).singleOrNull
              : recipeAt(previous.recipes, index);
          if (choice != null) {
            service.memory.remember('user', text);
            await prepareRecipeShopping(choice, text, voice || previous.voice);
            return;
          }
          if (index != null) {
            service.memory.remember('user', text);
            askShoppingRecipe(previous.recipes, text, voice || previous.voice);
            return;
          }
        }
      }
      if (AssistantService.isMultiItemIntake(text)) {
        service.memory.remember('user', text);
        final previousContext = service.requestContext;
        final mode = widget.store.isDemo;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => VoiceScreen(store: widget.store, initialText: text),
          ),
        );
        if (!mounted) return;
        service.memory.syncMode(widget.store.isDemo);
        if (mode == widget.store.isDemo) {
          addCard(
            _AssistantCard(
              previousContext == service.requestContext
                  ? '재료 등록 화면에서 돌아왔어요. 재고는 바뀌지 않았어요. 다른 요청도 이어서 말씀해주세요.'
                  : '재료 등록 화면에서 돌아왔어요. 바뀐 재고를 기준으로 이어서 도와드릴게요.',
              original: text,
            ),
          );
        }
        if (mounted) setState(() => failedInput = null);
        return;
      }
      final local = AssistantService.parseLocal(text, memory: service.memory);
      final simpleCooking = local.intent.name.startsWith('cooking');
      final command = simpleCooking
          ? local
          : await service.interpret(
              text,
              useAi: useAi,
              recipe: hasActiveCookingSession ? null : selectedRecipe,
              recipeStep: selectedRecipeStep,
            );
      if (simpleCooking) service.memory.remember('user', text);
      checkRequestContext();
      await dispatch(command, text, voice);
      if (mounted) setState(() => failedInput = null);
    } catch (e) {
      if (mounted) {
        if (submittedRevision != service.memory.revision) {
          setState(() => error = '대화가 초기화되어 이전 요청을 중단했어요. 새로 말씀해주세요.');
          return;
        }
        setState(() {
          failedInput = text;
          failedVoice = voice;
          input.text = text;
          voiceInput = voice;
          error =
              '${e.toString().replaceFirst('Bad state: ', '').replaceFirst('FormatException: ', '')}\n입력 내용을 보관했어요. 수정하거나 다시 시도할 수 있어요.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> dispatch(AssistantCommand c, String text, bool voice) async {
    switch (c.intent) {
      case AssistantIntent.search:
      case AssistantIntent.expiring:
        final result = c.intent == AssistantIntent.search
            ? service.search(c)
            : service.expiring(c.days);
        final answer = result.isEmpty
            ? '조건에 맞는 보유 재료가 없어요.'
            : result
                  .map(
                    (b) =>
                        '${b.name} ${b.quantityLabel} · ${b.storageType.label} · ${b.expiryLabel()}',
                  )
                  .join('\n');
        addCard(
          _AssistantCard(
            result.isEmpty
                ? answer
                : '${result.length}개 묶음을 찾았어요. 아래 재료를 누르면 이어서 이야기할 수 있어요.',
            batches: result,
            original: text,
            voice: voice,
          ),
          conversationText: answer,
        );
        if (voice && readAloud) {
          await read(
            result.isEmpty ? answer : '${result.length}개 묶음을 찾았어요. $answer',
          );
        }
      case AssistantIntent.create:
        if (RegExp(r'\d+(?:\.\d+)?\s*(kg|ml|g|L|개|팩)').allMatches(text).length >
                1 ||
            RegExp(r',|그리고|하고').hasMatch(text)) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  VoiceScreen(store: widget.store, initialText: text),
            ),
          );
          return;
        }
        final prepared = service.prepare(c, text);
        addCard(
          _AssistantCard(
            prepared.clarification ?? '변경 내용을 확인해주세요.',
            proposal: prepared,
            original: text,
            voice: voice,
          ),
        );
      case AssistantIntent.update:
      case AssistantIntent.consume:
      case AssistantIntent.discard:
      case AssistantIntent.move:
        final prepared = service.prepare(c, text);
        final card = _AssistantCard(
          prepared.clarification ?? '변경 내용을 확인해주세요.',
          proposal: prepared,
          original: text,
          voice: voice,
        );
        addCard(card);
        if (prepared.canExecute && !prepared.needsApproval && !voice) {
          await execute(card);
        }
      case AssistantIntent.shopping:
        if (c.item.trim().isEmpty) {
          addCard(_AssistantCard('장볼 재료 이름을 알려주세요.', original: text));
          return;
        }
        final card = _AssistantCard(
          '장보기: ${c.item}${c.quantity == null ? '' : ' ${formatQuantity(c.quantity!)}${c.unit ?? ''}'}',
          lightCommand: c,
          original: text,
          voice: voice,
        );
        addCard(card);
        if (!voice) await addShopping(card);
      case AssistantIntent.recipeShopping:
        final recommendations = service.memory.recipes;
        final selected = service.memory.selectedRecipe;
        final choices = <String, Recipe>{
          for (final r in recommendations) r.id: r,
          ?selected?.id: ?selected,
        }.values.toList();
        final index = c.recipeIndex;
        final recipe = index != null
            ? recipeAt(recommendations, index)
            : c.item.isNotEmpty
            ? choices.where((r) => r.title == c.item).singleOrNull
            : selected;
        if (recipe == null) {
          askShoppingRecipe(choices, text, voice);
          return;
        }
        await prepareRecipeShopping(recipe, text, voice);
      case AssistantIntent.recommend:
        setState(() => progress = '말씀하신 조건을 이어받아 요리를 고르고 있어요…');
        final prefs = await SharedPreferences.getInstance();
        final defaults = await CookingPreferences.load(
          isDemo: widget.store.isDemo,
        );
        final conditions = service.recommendationConditions(
          c,
          defaultPreferences: defaults.preferences,
          defaultEquipment: defaults.equipment,
        );
        checkRequestContext();
        final result = await service.ai.recommend(
          widget.store.activeBatches,
          allergies: prefs.getStringList('allergies') ?? [],
          servings: conditions.servings,
          maxMinutes: conditions.maxMinutes,
          preferences: conditions.preferences,
          equipment: conditions.equipment,
          excludedIngredients: conditions.excludedIngredients,
          selectedBatchIds: conditions.batchIds.isEmpty
              ? null
              : conditions.batchIds.toSet(),
        );
        checkRequestContext();
        service.memory.recommendation = conditions;
        AssistantService.lastRecipes = result;
        selectedRecipe = null;
        addCard(
          _AssistantCard(
            result.isEmpty
                ? '조건에 맞는 추천이 없어요.'
                : '${conditions.servings}인분 · ${conditions.maxMinutes}분 이내로 ${result.length}가지 골랐어요. 조건을 바꾸거나 마음에 드는 요리를 선택해주세요.',
            recipes: result,
            original: text,
          ),
          conversationText:
              '${result.length}개 추천: ${result.asMap().entries.map((e) => '${e.key + 1}. ${e.value.title}').join(' / ')}. ${conditions.servings}인분 · ${conditions.maxMinutes}분 이내.',
        );
      case AssistantIntent.selectRecipe:
        final index = c.recipeIndex;
        if (index == null || index > AssistantService.lastRecipes.length) {
          addCard(
            _AssistantCard('먼저 요리를 추천받거나, 표시된 번호를 선택해주세요.', original: text),
          );
          return;
        }
        final r = AssistantService.lastRecipes[index - 1];
        selectedRecipe = r;
        service.selectRecipe(r);
        addCard(
          _AssistantCard('${r.title}를 선택했어요.', recipes: [r], original: text),
        );
      case AssistantIntent.guide:
        addCard(
          _AssistantCard(
            '제품 표시와 지역별 공식 출처를 확인해주세요.',
            guideItem: c.item.isEmpty ? service.memory.lastItem : c.item,
            original: text,
          ),
        );
      case AssistantIntent.coach:
        final session = widget.store.cookingSession;
        final activeSession =
            session != null &&
            !['ended', 'completed'].contains(session['status']);
        final recipe = activeSession
            ? Recipe.fromJson(
                Map<String, dynamic>.from(session['recipe'] as Map),
              )
            : selectedRecipe;
        final question = c.question.isEmpty ? text : c.question;
        // Exact ingredient questions are answered from the saved recipe locally.
        final exact =
            recipe?.ingredients
                .where((i) => question.contains(i.name))
                .toList() ??
            <RecipeIngredient>[];
        String answer;
        if (exact.isNotEmpty && RegExp(r'얼마나|몇|수량').hasMatch(question)) {
          answer = exact
              .map(
                (i) =>
                    '${i.name}: ${i.quantity == null ? '수량 미상 · 직접 확인' : '${formatQuantity(i.quantity!)} ${i.unit}'}',
              )
              .join('\n');
        } else {
          final prefs = await SharedPreferences.getInstance();
          final defaults = await CookingPreferences.load(
            isDemo: widget.store.isDemo,
          );
          checkRequestContext();
          answer = await service.converse(
            question,
            recipe: recipe,
            step: activeSession
                ? (session['step'] as num).toInt()
                : selectedRecipeStep,
            allergies: prefs.getStringList('allergies') ?? [],
            preferences: defaults.preferences,
            equipment: defaults.equipment,
          );
          checkRequestContext();
        }
        addCard(_AssistantCard(answer, original: text, voice: voice));
        if (voice && readAloud) await read(answer);
      case AssistantIntent.cookingStart:
        await startCooking(c, text, voice);
      case AssistantIntent.cookingNext:
      case AssistantIntent.cookingPrevious:
      case AssistantIntent.cookingPause:
      case AssistantIntent.cookingResume:
      case AssistantIntent.cookingFinish:
      case AssistantIntent.cookingRead:
        await cooking(c, text, voice);
      case AssistantIntent.clarify:
        addCard(
          _AssistantCard(
            c.question.isEmpty ? '대상과 수량을 더 구체적으로 알려주세요.' : c.question,
            original: text,
          ),
        );
    }
  }

  Future<void> execute(_AssistantCard card) async {
    if (card.closed) return;
    try {
      final text = await service.execute(card.proposal!, approved: true);
      card.closed = true;
      card.text = text;
      card.undoId = widget.store.history.firstOrNull?.id;
      if (mounted) setState(() {});
      if (card.voice && readAloud) await read(text);
    } catch (e) {
      card.text = e.toString();
      if (mounted) setState(() {});
    }
  }

  Recipe? recipeAt(List<Recipe> choices, int number) =>
      number > 0 && number <= choices.length ? choices[number - 1] : null;

  void askShoppingRecipe(List<Recipe> choices, String text, bool voice) {
    addCard(
      _AssistantCard(
        choices.isEmpty
            ? '요리를 먼저 선택해주세요. 레시피 상세에서 도우미를 열거나 요리를 추천받을 수 있어요.'
            : '어느 요리의 부족한 재료를 담을까요? 요리를 누르거나 번호를 알려주세요.',
        recipes: choices,
        lightCommand: choices.isEmpty
            ? null
            : const AssistantCommand(intent: AssistantIntent.recipeShopping),
        original: text,
        voice: voice,
      ),
    );
  }

  String recipeShoppingText(
    Recipe recipe,
    RecipeShoppingResult result, {
    bool preview = false,
  }) {
    if (result.alreadyPlanned) return '이미 장보기 계획에 담은 요리예요. ${recipe.title}';
    if (!result.hasMissing) return '${recipe.title} · 장보기에 새로 담을 재료가 없어요.';
    return [
      preview
          ? '${recipe.title}의 부족한 재료를 장보기에 담을까요?'
          : '${recipe.title} · 장보기 계획에 반영했어요.',
      for (final item in result.amounts)
        '${item.name} ${formatQuantity(item.quantity)}${item.unit}',
      if (result.unknown.isNotEmpty) '수량 직접 확인 · ${result.unknown.join(', ')}',
    ].join('\n');
  }

  Future<void> prepareRecipeShopping(
    Recipe recipe,
    String text,
    bool voice,
  ) async {
    final initialContext = service.requestContext;
    await shopping.reload();
    if (!mounted || initialContext != service.requestContext) return;
    selectedRecipe = recipe;
    service.selectRecipe(recipe);
    final preview = shopping.previewRecipeShopping(recipe);
    final canAdd = !preview.alreadyPlanned && preview.hasMissing;
    final card = _AssistantCard(
      recipeShoppingText(recipe, preview, preview: canAdd),
      shoppingRecipe: recipe,
      shoppingPreview: preview,
      lightCommand: canAdd
          ? const AssistantCommand(intent: AssistantIntent.recipeShopping)
          : null,
      original: text,
      voice: voice,
    );
    addCard(card, remember: voice || !canAdd);
    if (canAdd && !voice) await addShopping(card);
  }

  Future<void> addShopping(_AssistantCard card) async {
    syncConversation();
    if (card.closed || !cards.contains(card)) return;
    final revision = service.memory.revision;
    bool active() =>
        mounted && service.memory.revision == revision && cards.contains(card);
    final c = card.lightCommand!;
    final previousUndo = shopping.undoRevision;
    try {
      final recipe = card.shoppingRecipe;
      if (recipe != null) {
        final expected = card.voice ? card.shoppingPreview : null;
        final result = await shopping.addRecipeToPlan(
          recipe,
          onlyIfMissing: true,
          expected: expected,
        );
        if (!active()) return;
        if (expected != null &&
            !expected.matches(result) &&
            result.hasMissing &&
            !result.alreadyPlanned) {
          card.shoppingPreview = result;
          card.text =
              '장보기 수량이 달라졌어요.\n${recipeShoppingText(recipe, result, preview: true)}';
          rememberReply(card.text);
          setState(() {});
          return;
        }
        card.shoppingPreview = result;
        card.text = recipeShoppingText(recipe, result);
      } else {
        await shopping.addManual(
          c.item,
          quantity: c.quantity,
          unit: c.unit ?? '',
        );
        if (!active()) return;
        card.text = '${c.item}를 장보기에 반영했어요. 재고는 그대로예요.';
      }
      card.closed = true;
      if (previousUndo != shopping.undoRevision) {
        card.shoppingUndoRevision = shopping.undoRevision;
      }
      rememberReply(card.text);
      setState(() {});
      if (card.voice && readAloud) await read(card.text);
    } catch (e) {
      if (!active()) return;
      setState(() => card.text = e.toString());
    }
  }

  Future<void> startCooking(
    AssistantCommand command,
    String text,
    bool voice,
  ) async {
    final index = command.recipeIndex;
    final recipe = index != null
        ? (index <= AssistantService.lastRecipes.length
              ? AssistantService.lastRecipes[index - 1]
              : null)
        : selectedRecipe;
    if (recipe == null) {
      addCard(
        _AssistantCard(
          '시작할 레시피를 먼저 선택해주세요. 추천 카드의 번호를 선택하거나 레시피 상세에서 요리 도우미를 열어주세요.',
          original: text,
        ),
      );
      return;
    }
    final current = widget.store.cookingSession;
    final active =
        current != null && !['ended', 'completed'].contains(current['status']);
    if (active) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('진행 중인 요리를 종료할까요?'),
          content: Text(
            '기존 조리를 종료하고 ${recipe.title}를 시작합니다. 종료만으로 재고를 차감하지 않습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('종료하고 시작'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    await service.startCooking(
      recipe,
      replacingSessionId: active ? current['id'] as String : null,
    );
    selectedRecipe = recipe;
    service.selectRecipe(recipe);
    final answer = '${recipe.title} 요리를 시작했어요. 1단계. ${recipe.steps.first}';
    addCard(_AssistantCard(answer, original: text, cookingRecipe: recipe));
    if (voice && readAloud) await read(answer);
  }

  Future<void> cooking(AssistantCommand c, String text, bool voice) async {
    final s = widget.store.cookingSession;
    if (s == null || ['ended', 'completed'].contains(s['status'])) {
      addCard(_AssistantCard('진행 중인 요리가 없어요. 먼저 레시피를 선택해주세요.', original: text));
      return;
    }
    final recipe = Recipe.fromJson(
      Map<String, dynamic>.from(s['recipe'] as Map),
    );
    var step = ((s['step'] as num?)?.toInt() ?? 0).clamp(
      0,
      recipe.steps.length - 1,
    );
    String status = s['status'] as String;
    if (status == 'paused' &&
        [
          AssistantIntent.cookingNext,
          AssistantIntent.cookingPrevious,
        ].contains(c.intent)) {
      addCard(_AssistantCard('일시정지 중이에요. “계속 요리”라고 말해주세요.'));
      return;
    }
    switch (c.intent) {
      case AssistantIntent.cookingNext:
        step = (step + 1).clamp(0, recipe.steps.length - 1);
      case AssistantIntent.cookingPrevious:
        step = (step - 1).clamp(0, recipe.steps.length - 1);
      case AssistantIntent.cookingPause:
        status = 'paused';
      case AssistantIntent.cookingResume:
        status = 'cooking';
      case AssistantIntent.cookingFinish:
        status = 'awaitingUsage';
      default:
        break;
    }
    if (c.intent != AssistantIntent.cookingRead) {
      await widget.store.saveCookingSessionIfCurrent({
        ...s,
        'step': step,
        'status': status,
      }, expectedSessionId: s['id'] as String);
    }
    final answer = status == 'awaitingUsage'
        ? '요리 완료를 확인했어요. 실제 사용량 확인 화면에서 확정해야 재고가 줄어듭니다.'
        : status == 'paused'
        ? '요리를 일시정지했어요.'
        : '${step + 1}단계. ${recipe.steps[step]}';
    addCard(_AssistantCard(answer, original: text, cookingRecipe: recipe));
    if ((voice && readAloud) || c.intent == AssistantIntent.cookingRead) {
      await read(answer);
    }
  }

  Future<void> safely(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<String> get followups {
    if (service.memory.pending != null) return const [];
    if (hasActiveCookingSession) {
      return ['다음 단계', '이 단계에서 주의할 점은?', '요리 완료'];
    }
    if (selectedRecipe != null) {
      return [
        '요리 시작',
        '이 요리에 부족한 재료가 있어?',
        '없는 재료 장보기에 담아줘',
        '더 간단하게 만들 수 있어?',
      ];
    }
    if (service.memory.recommendation != null) {
      return ['시간만 15분으로 바꿔줘', '2인분으로 바꿔줘'];
    }
    if (service.memory.lastBatchId != null) {
      return ['그걸로 추천해줘', '그 재료는 어떻게 보관해?'];
    }
    return ['오늘 뭐 먹을까?', '먼저 먹을 재료 알려줘', '지금 재료로 간단한 요리 추천해줘'];
  }

  Widget contextSummary() {
    final condition = service.memory.recommendation;
    final parts = <String>[
      if (hasActiveCookingSession) '조리 중',
      if (selectedRecipe != null) selectedRecipe!.title,
      if (service.memory.lastItem != null) '재료: ${service.memory.lastItem}',
      if (condition != null)
        '${condition.servings}인분 · ${condition.maxMinutes}분 이내',
      if (condition != null && condition.preferences.isNotEmpty)
        condition.preferences,
      if (condition != null && condition.equipment.isNotEmpty)
        condition.equipment,
      if (condition != null && condition.excludedIngredients.isNotEmpty)
        '제외: ${condition.excludedIngredients.join(', ')}',
    ];
    if (parts.isEmpty && service.memory.pending == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.forum_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              service.memory.pending != null
                  ? '앞선 요청을 이어가는 중 · 필요한 정보만 답해주세요'
                  : parts.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: '이어받은 맥락 자세히 보기',
            visualDensity: VisualDensity.compact,
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('지금 이어받은 맥락'),
                content: SingleChildScrollView(
                  child: Text(
                    [
                      ...parts,
                      if (service.memory.pending != null)
                        '확인 중인 요청: ${service.memory.pending!.item}',
                      '이 내용은 현재 대화에서만 이어집니다. 새 대화를 시작하면 초기화돼요.',
                    ].join('\n'),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('닫기'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.info_outline, size: 18),
          ),
        ],
      ),
    );
  }

  Future<void> conversationOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('AI로 대화 이해'),
                subtitle: const Text(
                  '입력·최근 대화·재고·요리 맥락을 AI에 보내요. 끄면 정해진 명령만 해석하며, 추천과 요리 답변은 온라인 AI를 사용해요.',
                ),
                value: useAi,
                onChanged:
                    service.ai.isConfigured &&
                        _preferences != null &&
                        !busy &&
                        !_savingAiMode
                    ? (value) async {
                        setState(() {
                          _savingAiMode = true;
                          if (!value) useAi = false;
                        });
                        updateSheet(() {});
                        try {
                          if (!await _preferences!.setBool(
                            _aiPreference,
                            value,
                          )) {
                            throw StateError('설정을 저장하지 못했어요.');
                          }
                          if (mounted) setState(() => useAi = value);
                        } catch (_) {
                          if (mounted) {
                            setState(() {
                              useAi = false;
                              error = '대화 설정을 저장하지 못했어요. 다시 시도해주세요.';
                            });
                          }
                        } finally {
                          if (mounted) setState(() => _savingAiMode = false);
                          if (ctx.mounted) updateSheet(() {});
                        }
                      }
                    : null,
              ),
              SwitchListTile(
                title: const Text('음성으로 물으면 답변 읽어주기'),
                value: readAloud,
                onChanged: (value) {
                  setState(() => readAloud = value);
                  updateSheet(() {});
                },
              ),
              TextButton(
                onPressed: () => tts.stop(),
                child: const Text('읽기 중지'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('주방 도우미'),
      actions: [
        IconButton(
          tooltip: '대화 설정',
          onPressed: conversationOptions,
          icon: const Icon(Icons.tune),
        ),
        IconButton(
          tooltip: '대화 맥락 초기화',
          onPressed: busy
              ? null
              : () {
                  service.memory.clear();
                  memoryRevision = service.memory.revision;
                  setState(() {
                    cards.clear();
                    selectedRecipe = null;
                    input.clear();
                    error = null;
                    failedInput = null;
                  });
                },
          icon: const Icon(Icons.edit_square),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    useAi
                        ? 'AI 연결됨 · 앞선 대화와 주방 상태를 함께 참고해요'
                        : '정해진 명령으로 대화 중 · 대화 설정에서 AI 연결을 확인해요',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                contextSummary(),
                if (error != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          failedInput == null
                              ? error!
                              : '요청을 완료하지 못했어요. 입력은 보관했어요.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      if (failedInput != null)
                        IconButton(
                          tooltip: error!,
                          icon: const Icon(Icons.info_outline),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('요청 오류 상세'),
                              content: Text(error!),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('닫기'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                if (busy) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        progress,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
                if (failedInput != null && !busy)
                  TextButton.icon(
                    onPressed: () {
                      input.text = failedInput!;
                      voiceInput = failedVoice;
                      submit();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('실패한 입력 다시 시도'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              children: [
                if (cards.isEmpty && selectedRecipe == null) ...[
                  const Text(
                    '오늘 주방에서 무엇을 도와드릴까요?\n“두부로 간단한 저녁” 다음에 “2인분으로, 맵지 않게”처럼 이어서 말해보세요.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    children:
                        [
                              '두부 있어?',
                              '이번 주 먼저 먹을 거',
                              '우유 1팩 추가',
                              '대파 냉동실로 이동',
                              '우유 장보기 추가',
                            ]
                            .map(
                              (s) => ActionChip(
                                label: Text(s),
                                onPressed: () {
                                  compose(s);
                                },
                              ),
                            )
                            .toList(),
                  ),
                ],
                ...cards.map(cardWidget),
                if ((cards.isNotEmpty || selectedRecipe != null) &&
                    !busy &&
                    followups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: followups
                          .map(
                            (text) => ActionChip(
                              label: Text(text),
                              onPressed: () => compose(text),
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: listening ? '듣기 종료' : '마이크로 말하기',
                      onPressed: busy ? null : listen,
                      icon: Icon(
                        listening ? Icons.stop_circle : Icons.mic_none,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: input,
                        focusNode: inputFocus,
                        minLines: 1,
                        maxLines: 3,
                        enabled: !busy,
                        decoration: InputDecoration(
                          hintText: listening
                              ? '듣고 있어요…'
                              : service.memory.pending != null
                              ? '필요한 정보만 이어서 답해주세요'
                              : cards.isEmpty
                              ? '오늘 먹을 것부터 함께 생각해요'
                              : '앞선 이야기에 이어서 물어보세요',
                        ),
                        onSubmitted: (_) => submit(),
                      ),
                    ),
                    IconButton(
                      tooltip: '명령 보내기',
                      onPressed: busy ? null : submit,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '재고 수량은 변경 내용을 확인한 뒤 반영해요.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget cardWidget(_AssistantCard card) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (card.original.isNotEmpty)
            Text(
              '${card.voice ? '인식 문장' : '입력'}: ${card.original}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          const SizedBox(height: 8),
          Text(card.text),
          ...card.batches.map(
            (b) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(b.name),
              subtitle: Text(
                '${b.quantityLabel} · ${b.storageType.label} · ${b.expiryLabel()}',
              ),
              onTap: busy
                  ? null
                  : () {
                      service.selectBatch(b.id);
                      addCard(
                        _AssistantCard('${b.name} 묶음을 다음 대화 대상으로 선택했어요.'),
                      );
                    },
            ),
          ),
          if (card.proposal != null && !card.closed) ...[
            if (card.proposal!.before != null)
              Text(
                '변경 전: ${card.proposal!.before!.name} ${card.proposal!.before!.quantityLabel} · ${card.proposal!.before!.storageType.label}',
              ),
            if (card.proposal!.after != null)
              Text(
                '변경 후: ${card.proposal!.after!.name} ${card.proposal!.after!.quantityLabel} · ${card.proposal!.after!.storageType.label}',
              ),
            ...card.proposal!.candidates.map(
              (b) => OutlinedButton(
                onPressed: busy
                    ? null
                    : () => safely(() async {
                        card.closed = true;
                        await dispatch(
                          card.proposal!.command.withTarget(b.id),
                          card.original,
                          card.voice,
                        );
                      }),
                child: Text(
                  '${b.name} ${b.quantityLabel} · ${b.storageType.label} · ${b.expiryLabel()}',
                ),
              ),
            ),
            if (card.proposal!.canExecute)
              FilledButton(
                onPressed: busy ? null : () => safely(() => execute(card)),
                child: const Text('확인하고 반영'),
              ),
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      setState(() {
                        card.closed = true;
                        service.memory.pending = null;
                        card.text = '취소했어요. 재고는 바뀌지 않았습니다.';
                        rememberReply(card.text);
                      });
                    },
              child: const Text('취소'),
            ),
          ],
          if (card.lightCommand != null && !card.closed) ...[
            if (!card.choosingShoppingRecipe)
              FilledButton(
                onPressed: busy ? null : () => safely(() => addShopping(card)),
                child: const Text('인식 내용 확인하고 실행'),
              ),
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      setState(() {
                        card.closed = true;
                        service.memory.pending = null;
                        card.text = '취소했어요.';
                        rememberReply(card.text);
                      });
                    },
              child: const Text('취소'),
            ),
          ],
          if (card.undoId != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () => safely(() async {
                      await widget.store.undo(card.undoId!);
                      card.undoId = null;
                      card.text += '\n변경을 되돌렸어요.';
                      rememberReply(card.text);
                    }),
              child: const Text('실행 취소'),
            ),
          if (card.shoppingRecipe != null &&
              (card.shoppingPreview?.alreadyPlanned == true ||
                  card.shoppingUndoRevision != null) &&
              shopping.plans.any(
                (p) => p.recipes.any((r) => r.id == card.shoppingRecipe!.id),
              ) &&
              Actions.maybeFind<OpenShoppingListIntent>(context) != null)
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => Actions.invoke(context, const OpenShoppingListIntent()),
              icon: const Icon(Icons.shopping_basket_outlined),
              label: const Text('장보기 목록 보기'),
            ),
          if (card.shoppingUndoRevision != null &&
              card.shoppingUndoRevision == shopping.undoRevision)
            TextButton(
              onPressed: busy
                  ? null
                  : () => safely(() async {
                      if (card.shoppingUndoRevision != shopping.undoRevision) {
                        return;
                      }
                      await shopping.undoLast();
                      if (!mounted || !cards.contains(card)) return;
                      card.shoppingUndoRevision = null;
                      card.text += '\n장보기 변경을 되돌렸어요.';
                      rememberReply(card.text);
                    }),
              child: const Text('장보기 실행 취소'),
            ),
          if (!card.choosingShoppingRecipe || !card.closed)
            ...card.recipes.asMap().entries.map(
              (e) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${e.key + 1}. ${e.value.title}'),
                subtitle: Text('${e.value.minutes}분 · ${e.value.servings}인분'),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : card.choosingShoppingRecipe
                    ? () => safely(() async {
                        if (card.closed || !cards.contains(card)) return;
                        card.closed = true;
                        await prepareRecipeShopping(
                          e.value,
                          card.original,
                          card.voice,
                        );
                      })
                    : () {
                        setState(() => selectedRecipe = e.value);
                        service.selectRecipe(e.value);
                        rememberReply('${e.value.title}를 선택했어요.');
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => RecipeScreen(
                              recipe: e.value,
                              store: widget.store,
                            ),
                          ),
                        );
                      },
              ),
            ),
          if (card.guideItem != null)
            OutlinedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => GuideScreen(
                    store: widget.store,
                    itemName: card.guideItem,
                  ),
                ),
              ),
              child: const Text('공식 처리·보관 안내 열기'),
            ),
          if (card.cookingRecipe != null)
            OutlinedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RecipeScreen(
                    recipe: card.cookingRecipe!,
                    store: widget.store,
                    autoResume: true,
                  ),
                ),
              ),
              child: const Text('조리 · 사용량 화면 열기'),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: '이 결과 읽기',
              onPressed: () => read(card.text),
              icon: const Icon(Icons.volume_up_outlined),
            ),
          ),
        ],
      ),
    ),
  );
}
