import 'package:flutter/material.dart';

import '../design/app_theme.dart';
import '../design/food_illustration.dart';
import '../design/storage_interior.dart';
import '../models/inventory.dart';
import '../services/inventory_store.dart';

enum _Order { expiry, name, newest }

enum _ExpiryFilter { all, soon, unknown }

/// One shared inventory source for the shelf, list and cross-storage search.
/// A valid drag commits immediately, as specified by F-HJVCNI; touch moves
/// provide an explicit destination dialog and are cancellable before saving.
class InventoryBrowser extends StatefulWidget {
  const InventoryBrowser({
    super.key,
    required this.store,
    required this.onOpen,
    required this.onAdd,
    this.onAddToShopping,
    this.selectedIds = const {},
    this.onToggleSelection,
    this.selecting = false,
    this.onSelectionModeChanged,
    this.initialStorage = StorageType.fridge,
    this.onStorageChanged,
  });
  final InventoryStore store;
  final StorageType initialStorage;
  final ValueChanged<StorageType>? onStorageChanged;
  final ValueChanged<InventoryBatch> onOpen;
  final VoidCallback onAdd;
  final ValueChanged<String>? onAddToShopping;
  final Set<String> selectedIds;
  final ValueChanged<InventoryBatch>? onToggleSelection;
  final bool selecting;
  final VoidCallback? onSelectionModeChanged;

  @override
  State<InventoryBrowser> createState() => _InventoryBrowserState();
}

class _InventoryBrowserState extends State<InventoryBrowser> {
  final _search = TextEditingController();
  late StorageType _storage;

  @override
  void initState() {
    super.initState();
    _storage = widget.initialStorage;
  }

  StorageType? _searchStorage;
  String _category = '';
  _Order _order = _Order.expiry;
  _ExpiryFilter _expiry = _ExpiryFilter.all;
  bool _list = false;
  bool _organizing = false;
  bool _filtersExpanded = false;
  bool _searchExpanded = false;
  bool _saving = false;
  InventoryBatch? _dragging;
  bool? _dragMode;
  String? _dragRequest;

  static const _shelves = ['shelf-1', 'shelf-2', 'shelf-3'];
  static const _shelfNames = ['위 선반', '가운데 선반', '아래 선반'];

  @override
  void didUpdateWidget(covariant InventoryBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selecting && !oldWidget.selecting) _organizing = false;
  }

  void _openOrSelect(InventoryBatch batch) {
    if (widget.selecting) {
      widget.onToggleSelection?.call(batch);
    } else {
      widget.onOpen(batch);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _place(StorageType s) => s == StorageType.pantry ? '팬트리' : s.label;
  String _shelf(String? id) => switch (id) {
    'shelf-1' || 'top' => 'shelf-1',
    'shelf-3' || 'bottom' => 'shelf-3',
    _ => 'shelf-2',
  };
  String _shelfName(String? id) => _shelfNames[_shelves.indexOf(_shelf(id))];
  int get _activeFilters =>
      (_category.isNotEmpty ? 1 : 0) +
      (_expiry != _ExpiryFilter.all ? 1 : 0) +
      (_order != _Order.expiry ? 1 : 0);
  bool get _searching => _search.text.trim().isNotEmpty;

  List<InventoryBatch> _results() {
    final query = _search.text.trim().toLowerCase();
    final location = _searching ? _searchStorage : _storage;
    final rows = widget.store.activeBatches.where((b) {
      if (location != null && b.storageType != location) return false;
      if (query.isNotEmpty &&
          !b.name.toLowerCase().contains(query) &&
          !b.category.toLowerCase().contains(query)) {
        return false;
      }
      if (_category.isNotEmpty && b.category != _category) return false;
      final days = b.daysRemaining();
      return switch (_expiry) {
        _ExpiryFilter.all => true,
        _ExpiryFilter.soon => days != null && days >= 0 && days <= 3,
        _ExpiryFilter.unknown => days == null,
      };
    }).toList();
    rows.sort(switch (_order) {
      _Order.expiry => compareBatchExpiry,
      _Order.name => (a, b) {
        final byName = a.name.compareTo(b.name);
        return byName == 0 ? compareBatchExpiry(a, b) : byName;
      },
      _Order.newest => (a, b) {
        final byTime = b.createdAt.compareTo(a.createdAt);
        return byTime == 0 ? a.id.compareTo(b.id) : byTime;
      },
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final rows = _results();
      final categories = {
        ...widget.store.activeBatches.map((b) => b.category),
        if (_category.isNotEmpty) _category,
      }.where((c) => c.isNotEmpty).toList()..sort();
      return Stack(
        children: [
          CustomScrollView(
            key: const PageStorageKey('inventory-browser'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_searching)
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFDED8CF)),
                            ),
                          ),
                          child: Row(
                            children: StorageType.values
                                .map(
                                  (s) => Expanded(
                                    child: Semantics(
                                      selected: _storage == s,
                                      child: TextButton(
                                        key: ValueKey('storage-${s.name}'),
                                        onPressed: _saving
                                            ? null
                                            : () {
                                                setState(() => _storage = s);
                                                widget.onStorageChanged?.call(
                                                  s,
                                                );
                                              },
                                        style: TextButton.styleFrom(
                                          minimumSize: const Size(48, 48),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          backgroundColor: Colors.transparent,
                                          foregroundColor: _storage == s
                                              ? FridgeTheme.sage
                                              : FridgeTheme.muted,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          _place(s),
                                          style: TextStyle(
                                            decoration: _storage == s
                                                ? TextDecoration.underline
                                                : TextDecoration.none,
                                            decorationThickness: 2,
                                            fontWeight: _storage == s
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final controls = [
                            IconButton(
                              key: const ValueKey('inventory-search-toggle'),
                              tooltip: '검색',
                              onPressed: () => setState(
                                () => _searchExpanded = !_searchExpanded,
                              ),
                              icon: const Icon(Icons.search_rounded, size: 22),
                            ),
                            IconButton(
                              key: const ValueKey('inventory-filter-toggle'),
                              tooltip:
                                  '필터${_activeFilters == 0 ? '' : ' · $_activeFilters'}',
                              onPressed: () => setState(
                                () => _filtersExpanded = !_filtersExpanded,
                              ),
                              icon: Badge(
                                isLabelVisible: _activeFilters > 0,
                                label: Text('$_activeFilters'),
                                child: const Icon(Icons.tune_rounded, size: 20),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('inventory-view-toggle'),
                              tooltip: _list ? '선반 보기' : '목록 보기',
                              onPressed: () => setState(() => _list = !_list),
                              icon: Icon(
                                _list
                                    ? Icons.grid_view_rounded
                                    : Icons.view_agenda_outlined,
                                size: 20,
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('inventory-organize-toggle'),
                              tooltip: _organizing ? '정리 완료' : '정리',
                              isSelected: _organizing,
                              onPressed: _saving
                                  ? null
                                  : () {
                                      if (widget.selecting) {
                                        widget.onSelectionModeChanged?.call();
                                      }
                                      setState(
                                        () => _organizing = !_organizing,
                                      );
                                    },
                              icon: const Icon(
                                Icons.drive_file_move_outline,
                                size: 20,
                              ),
                              selectedIcon: const Icon(
                                Icons.check_rounded,
                                size: 20,
                              ),
                            ),
                          ];
                          final selection =
                              widget.onSelectionModeChanged == null
                              ? null
                              : TextButton(
                                  key: const ValueKey(
                                    'inventory-selection-toggle',
                                  ),
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                  ),
                                  onPressed: _saving
                                      ? null
                                      : () {
                                          setState(() => _organizing = false);
                                          widget.onSelectionModeChanged!();
                                        },
                                  child: Text(
                                    widget.selecting
                                        ? '선택 완료 · ${widget.selectedIds.length}'
                                        : '요리 재료 선택',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                          if (MediaQuery.textScalerOf(context).scale(12) > 16 ||
                              constraints.maxWidth < 310) {
                            return Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [...controls, ?selection],
                            );
                          }
                          return Row(
                            children: [
                              ...controls,
                              if (selection != null) Expanded(child: selection),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_saving) const LinearProgressIndicator(),
                      if (_organizing)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            '길게 눌러 옮기거나 위치 버튼을 누르세요.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      if (_searchExpanded || _searching)
                        TextField(
                          key: const ValueKey('inventory-search'),
                          controller: _search,
                          decoration: InputDecoration(
                            hintText: '전체 재고에서 재료·분류 찾기',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searching
                                ? IconButton(
                                    tooltip: '검색 지우기',
                                    onPressed: () {
                                      _search.clear();
                                      setState(() => _searchStorage = null);
                                    },
                                    icon: const Icon(Icons.close),
                                  )
                                : null,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      if (_searching) ...[
                        const Text(
                          '전체 보관함 검색 중',
                          style: TextStyle(
                            fontSize: 12,
                            color: FridgeTheme.sage,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Wrap(
                          spacing: 6,
                          children: [
                            ChoiceChip(
                              label: const Text('모든 위치'),
                              selected: _searchStorage == null,
                              onSelected: (_) =>
                                  setState(() => _searchStorage = null),
                            ),
                            ...StorageType.values.map(
                              (s) => ChoiceChip(
                                label: Text(_place(s)),
                                selected: _searchStorage == s,
                                onSelected: (_) =>
                                    setState(() => _searchStorage = s),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_filtersExpanded) ...[
                        Wrap(
                          spacing: 14,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            DropdownButton<_Order>(
                              key: const ValueKey('inventory-sort'),
                              value: _order,
                              underline: const SizedBox.shrink(),
                              items: const [
                                DropdownMenuItem(
                                  value: _Order.expiry,
                                  child: Text('소비기한순'),
                                ),
                                DropdownMenuItem(
                                  value: _Order.name,
                                  child: Text('이름순'),
                                ),
                                DropdownMenuItem(
                                  value: _Order.newest,
                                  child: Text('최근 등록순'),
                                ),
                              ],
                              onChanged: (v) => setState(() => _order = v!),
                            ),
                            DropdownButton<String>(
                              key: const ValueKey('inventory-category'),
                              value: categories.contains(_category)
                                  ? _category
                                  : '',
                              underline: const SizedBox.shrink(),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('모든 분류'),
                                ),
                                ...categories.map(
                                  (c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(c),
                                  ),
                                ),
                              ],
                              onChanged: (v) => setState(() => _category = v!),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final option in _ExpiryFilter.values)
                              FilterChip(
                                key: ValueKey('expiry-${option.name}'),
                                label: Text(switch (option) {
                                  _ExpiryFilter.all => '전체 기한',
                                  _ExpiryFilter.soon => '3일 이내',
                                  _ExpiryFilter.unknown => '날짜 미상',
                                }),
                                selected: _expiry == option,
                                onSelected: (_) =>
                                    setState(() => _expiry = option),
                              ),
                          ],
                        ),
                        if (_expiry == _ExpiryFilter.soon)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              '오늘부터 3일 이내 날짜를 표시합니다. 추정 날짜는 구분해 보여요.',
                              style: TextStyle(
                                fontSize: 12,
                                color: FridgeTheme.muted,
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                sliver: _inventorySliver(rows),
              ),
              SliverToBoxAdapter(
                child: SizedBox(height: _dragging == null ? 20 : 240),
              ),
            ],
          ),
          if (_dragging != null)
            Positioned(left: 12, right: 12, bottom: 8, child: _dropTray()),
        ],
      );
    },
  );

  Widget _inventorySliver(List<InventoryBatch> rows) {
    if (rows.isEmpty) return SliverToBoxAdapter(child: _empty());
    if (_list || _searching) {
      return SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, index) => _listTile(rows[index]),
      );
    }
    final grouped = {for (final id in _shelves) id: <InventoryBatch>[]};
    for (final batch in rows) {
      grouped[_shelf(batch.shelfId)]!.add(batch);
    }
    // Visible shelf segments remain drop targets. The fixed destination tray
    // exposes all nine destinations during a drag, including offscreen shelves.
    // SliverLayoutBuilder also runs when scrollOffset changes. Keep row slicing
    // outside that hot path: this cache belongs only to the current rows/build,
    // so store, sorting, organizing and theme updates still get a fresh cache.
    final entriesByColumns = <int, List<(String, List<InventoryBatch>?)>>{};
    final sliversByColumns = <int, Widget>{};
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final innerWidth = constraints.crossAxisExtent - 28;
        final columns = innerWidth < 260 || scale >= 1.8 ? 1 : 2;
        final cachedSliver = sliversByColumns[columns];
        if (cachedSliver != null) return cachedSliver;
        final entries = entriesByColumns.putIfAbsent(columns, () {
          final sliced = <(String, List<InventoryBatch>?)>[];
          for (final id in _shelves) {
            final shelfRows = grouped[id]!;
            if (shelfRows.isEmpty && !_organizing) continue;
            sliced.add((id, null));
            for (var start = 0; start < shelfRows.length; start += columns) {
              sliced.add((
                id,
                shelfRows.sublist(
                  start,
                  (start + columns).clamp(0, shelfRows.length),
                ),
              ));
            }
          }
          return sliced;
        });
        final sliver = SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final (shelfId, shelfRows) = entries[index];
            final segment = StorageInterior(
              key: ValueKey(
                shelfRows == null
                    ? 'shelf-panel-$shelfId'
                    : 'shelf-row-${shelfRows.first.id}',
              ),
              storage: _storage,
              firstSegment: index == 0,
              lastSegment: index == entries.length - 1,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: shelfRows == null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _shelfName(shelfId),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: FridgeTheme.sage,
                                  ),
                                ),
                              ),
                              Flexible(
                                child: Text(
                                  '${widget.store.isDemo ? '샘플 · ' : ''}${grouped[shelfId]!.length}개',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: FridgeTheme.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var column = 0;
                                column < columns;
                                column++
                              ) ...[
                                if (column > 0) const SizedBox(width: 8),
                                Expanded(
                                  child: column < shelfRows.length
                                      ? _tile(shelfRows[column])
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
              ],
            );
            if (!_organizing) return segment;
            return _target(
              _storage,
              shelfId,
              (hover) => DecoratedBox(
                decoration: BoxDecoration(
                  border: hover
                      ? Border.all(color: FridgeTheme.sage, width: 2)
                      : null,
                ),
                child: segment,
              ),
              keyPrefix: shelfRows == null
                  ? 'drop'
                  : 'drop-row-${shelfRows.first.id}',
            );
          },
        );
        sliversByColumns[columns] = sliver;
        return sliver;
      },
    );
  }

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        const Icon(Icons.kitchen_outlined, size: 42, color: FridgeTheme.sage),
        const SizedBox(height: 12),
        Text(
          _searching
              ? '찾는 재료가 없어요'
              : widget.store.activeBatches.isEmpty
              ? '첫 재료를 채워볼까요?'
              : '이 보관함에는 해당 재료가 없어요',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          widget.store.activeBatches.isEmpty
              ? '재료를 등록하면 선반에서 한눈에 확인할 수 있어요.'
              : '보관 위치·검색·필터를 확인하거나 재료를 추가하세요.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: widget.onAdd,
          icon: const Icon(Icons.add),
          label: const Text('재료 직접 추가'),
        ),
        if (_searching && widget.onAddToShopping != null)
          TextButton.icon(
            onPressed: () => widget.onAddToShopping!(_search.text.trim()),
            icon: const Icon(Icons.shopping_basket_outlined),
            label: const Text('장보기 목록에 추가'),
          ),
      ],
    ),
  );

  Widget _listTile(InventoryBatch b) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: _draggable(
      b,
      Material(
        color: const Color(0xFFFFFEFA),
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          key: ValueKey('item-${b.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          leading: HeroMode(
            enabled: !MediaQuery.disableAnimationsOf(context),
            child: Hero(
              tag: 'ingredient-${b.id}',
              child: FoodIllustration(
                name: b.name,
                category: b.category,
                artKey: b.artKey,
                photoFile: b.photoFile,
                size: 48,
              ),
            ),
          ),
          title: Text(
            b.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${b.quantityLabel} · ${_place(b.storageType)} / ${_shelfName(b.shelfId)}\n${b.expiryLabel()}',
          ),
          isThreeLine: true,
          trailing: !_organizing
              ? null
              : IconButton(
                  key: ValueKey('move-${b.id}'),
                  tooltip: '${b.name} 위치 변경',
                  onPressed: _saving ? null : () => _chooseMove(b),
                  icon: const Icon(Icons.drive_file_move_outline),
                ),
          onTap: () => _openOrSelect(b),
        ),
      ),
    ),
  );

  Widget _tile(InventoryBatch b) => _draggable(
    b,
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          key: ValueKey('item-${b.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openOrSelect(b),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Column(
              children: [
                HeroMode(
                  enabled: !MediaQuery.disableAnimationsOf(context),
                  child: Hero(
                    tag: 'ingredient-${b.id}',
                    child: FoodIllustration(
                      name: b.name,
                      category: b.category,
                      artKey: b.artKey,
                      photoFile: b.photoFile,
                      size: 72,
                      shelfPresentation: true,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                GlassShelfLip(pantry: _storage == StorageType.pantry),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight:
                              MediaQuery.textScalerOf(context).scale(14) * 1.4,
                        ),
                        child: Text(
                          b.name,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.quantityLabel,
                            style: const TextStyle(
                              fontSize: 12,
                              color: FridgeTheme.muted,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            b.expiryLabel(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: (b.daysRemaining() ?? 999) <= 3
                                  ? FridgeTheme.terracotta
                                  : FridgeTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_organizing)
          IconButton(
            key: ValueKey('move-${b.id}'),
            tooltip: '${b.name} 위치 변경',
            onPressed: _saving ? null : () => _chooseMove(b),
            icon: const Icon(Icons.drive_file_move_outline, size: 19),
          ),
      ],
    ),
  );

  Widget _draggable(InventoryBatch b, Widget child) => _selectionFrame(
    b,
    LongPressDraggable<InventoryBatch>(
      key: ValueKey('drag-${b.id}'),
      data: b,
      maxSimultaneousDrags: _saving || !_organizing || widget.selecting ? 0 : 1,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 140,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: FridgeTheme.cream,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: FridgeTheme.sage),
            boxShadow: const [
              BoxShadow(color: Color(0x33283C34), blurRadius: 15),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FoodIllustration(
                name: b.name,
                category: b.category,
                artKey: b.artKey,
                photoFile: b.photoFile,
              ),
              Text(
                b.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: .3, child: child),
      onDragStarted: () => setState(() {
        _dragging = b;
        _dragMode = widget.store.isDemo;
        _dragRequest = 'move-${DateTime.now().microsecondsSinceEpoch}-${b.id}';
      }),
      onDragEnd: (_) {
        if (mounted) setState(() => _dragging = null);
      },
      child: child,
    ),
  );

  Widget _selectionFrame(InventoryBatch batch, Widget child) {
    if (!widget.selecting) return child;
    final selected = widget.selectedIds.contains(batch.id);
    return Semantics(
      selected: selected,
      child: Stack(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: selected ? const Color(0xFFE3EEDC) : Colors.transparent,
              border: Border.all(
                color: selected ? FridgeTheme.sage : const Color(0xFFCBD5D1),
                width: 1.5,
              ),
            ),
            child: child,
          ),
          Positioned(
            top: 5,
            right: 5,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? FridgeTheme.sage : FridgeTheme.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _target(
    StorageType storage,
    String shelf,
    Widget Function(bool) builder, {
    String? keyPrefix,
  }) => DragTarget<InventoryBatch>(
    key: ValueKey('${keyPrefix ?? 'drop'}-${storage.name}-$shelf'),
    onWillAcceptWithDetails: (d) =>
        !_saving &&
        d.data.active &&
        !(d.data.storageType == storage && _shelf(d.data.shelfId) == shelf),
    onAcceptWithDetails: (d) => _move(
      d.data,
      storage,
      shelf,
      source: 'drag',
      requestId: _dragRequest,
      expectedMode: _dragMode,
    ),
    builder: (context, accepted, rejected) => builder(accepted.isNotEmpty),
  );

  Widget _dropTray() => Material(
    elevation: 8,
    borderRadius: BorderRadius.circular(18),
    color: FridgeTheme.cream,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '놓을 위치를 골라주세요',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ...StorageType.values.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 54,
                    child: Text(
                      _place(s),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  ..._shelves.map(
                    (id) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _target(
                          s,
                          id,
                          (hover) => Container(
                            constraints: const BoxConstraints(minHeight: 42),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: hover
                                  ? FridgeTheme.sage
                                  : const Color(0xFFE9EEE3),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _shelfName(id).replaceAll(' 선반', ''),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: hover ? Colors.white : FridgeTheme.ink,
                              ),
                            ),
                          ),
                          keyPrefix: 'tray',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _chooseMove(InventoryBatch b) async {
    var location = b.storageType;
    var shelf = _shelf(b.shelfId);
    final mode = widget.store.isDemo;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text('${b.name} 위치 변경'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '현재 ${_place(b.storageType)} · ${_shelfName(b.shelfId)}\n${b.quantityLabel} 묶음 전체를 이동합니다.',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<StorageType>(
                  key: const ValueKey('move-storage'),
                  initialValue: location,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '보관 위치'),
                  items: StorageType.values
                      .map(
                        (s) =>
                            DropdownMenuItem(value: s, child: Text(_place(s))),
                      )
                      .toList(),
                  onChanged: (v) => change(() => location = v!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('move-shelf'),
                  initialValue: shelf,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '선반'),
                  items: _shelves
                      .map(
                        (id) => DropdownMenuItem(
                          value: id,
                          child: Text(_shelfName(id)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => change(() => shelf = v!),
                ),
                const SizedBox(height: 12),
                const Text(
                  '앱 속 위치를 변경합니다. 실제 재료는 직접 옮겨주세요.',
                  style: TextStyle(fontSize: 12, color: FridgeTheme.muted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('확인하고 이동'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) {
      await _move(b, location, shelf, source: 'manual', expectedMode: mode);
    }
  }

  Future<void> _move(
    InventoryBatch b,
    StorageType location,
    String shelf, {
    required String source,
    String? requestId,
    bool? expectedMode,
  }) async {
    if (_saving || !_shelves.contains(shelf)) return;
    if (b.storageType == location && _shelf(b.shelfId) == shelf) return;
    if (expectedMode != null && expectedMode != widget.store.isDemo) {
      _message('보관함 모드가 바뀌었어요. 다시 이동해주세요.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.store.update(
        b.copyWith(storageType: location, shelfId: shelf, slotId: null),
        source: source,
        requestId:
            requestId ??
            'move-${DateTime.now().microsecondsSinceEpoch}-${b.id}',
      );
      if (!mounted) return;
      final change = widget.store.history.first;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${b.name} → ${_place(location)} · ${_shelfName(shelf)}',
          ),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '실행 취소',
            onPressed: () async {
              try {
                await widget.store.undo(change.id);
                if (mounted) _message('이동 전 위치로 되돌렸어요.');
              } catch (_) {
                if (mounted) _message('후속 변경이 있어 되돌릴 수 없어요. 변경 이력을 확인해주세요.');
              }
            },
          ),
        ),
      );
    } catch (_) {
      if (mounted) _message('이동을 저장하지 못했어요. 재료의 현재 위치를 다시 확인해주세요.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
