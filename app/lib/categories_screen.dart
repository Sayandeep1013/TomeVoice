import 'dart:async';

import 'package:flutter/material.dart';

import 'library_store.dart';
import 'theme.dart';
import 'ui.dart';

/// Categories: rename, reorder by dragging, choose the default for new
/// books, delete (its books move to the first category), add.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  LibraryIndex? _index;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final idx = await widget.store.index();
    if (mounted) setState(() => _index = idx);
  }

  Future<void> _save(List<Category> cats, {String? defaultCategory}) async {
    await widget.store.saveCategories(cats, defaultCategory: defaultCategory);
    await _load();
  }

  Future<void> _add() async {
    final name = await askText(context, title: 'New category', hint: 'For example: Favourites', action: 'Create');
    if (name == null) return;
    await widget.store.addCategory(name);
    await _load();
  }

  Future<void> _rename(Category c) async {
    final idx = _index!;
    final name = await askText(context, title: 'Rename', initial: c.name);
    if (name == null || name == c.name) return;
    await _save([for (final x in idx.categories) x.id == c.id ? x.renamed(name) : x]);
  }

  Future<void> _delete(Category c) async {
    final idx = _index!;
    final rest = [for (final x in idx.categories) if (x.id != c.id) x];
    final count = idx.inCategory(c.id).length;
    final ok = await confirm(
      context,
      title: 'Delete "${c.name}"?',
      body: count == 0
          ? 'The category is empty.'
          : 'Its $count ${count == 1 ? 'book moves' : 'books move'} to "${rest.first.name}". No books are deleted.',
      action: 'Delete',
    );
    if (!ok) return;
    await _save(rest);
  }

  /// A row being dragged: lifted a touch with a soft shadow in its own
  /// rounded shape (the default is a square Material shadow), and set down
  /// the same way.
  Widget _lifted(Widget child, int index, Animation<double> animation) => AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final t = Motion.out.transform(animation.value);
          return Transform.scale(
            scale: 1 + 0.02 * t,
            child: Stack(
              children: [
                // The row's own box: the item carries the gap below it.
                Positioned.fill(
                  bottom: Gap.s,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.row),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: (Skin.isDark(context) ? 0.4 : 0.16) * t),
                          blurRadius: 18 * t,
                          offset: Offset(0, 6 * t),
                        ),
                      ],
                    ),
                  ),
                ),
                child!,
              ],
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final idx = _index;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Categories', onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                child: Text(
                  'Drag to reorder. New books go to the default category.',
                  style: Skin.label(context, size: 14, color: Skin.inkFaintOn(context)),
                ),
              ),
              Expanded(
                child: idx == null
                    ? const SizedBox.shrink()
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xl),
                        itemCount: idx.categories.length,
                        proxyDecorator: _lifted,
                        onReorderItem: (from, to) {
                          final list = [...idx.categories];
                          list.insert(to, list.removeAt(from));
                          unawaited(_save(list));
                        },
                        itemBuilder: (context, i) {
                          final c = idx.categories[i];
                          return Padding(
                            key: ValueKey(c.id),
                            padding: const EdgeInsets.only(bottom: Gap.s),
                            child: _CategoryRow(
                              category: c,
                              count: idx.inCategory(c.id).length,
                              isDefault: c.id == idx.defaultCategory,
                              index: i,
                              canDelete: idx.categories.length > 1,
                              onRename: () => _rename(c),
                              onDefault: () => _save(idx.categories, defaultCategory: c.id),
                              onDelete: () => _delete(c),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.l),
                child: FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New category'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.count,
    required this.isDefault,
    required this.index,
    required this.canDelete,
    required this.onRename,
    required this.onDefault,
    required this.onDelete,
  });

  final Category category;
  final int count;
  final bool isDefault;
  final int index;
  final bool canDelete;
  final VoidCallback onRename;
  final VoidCallback onDefault;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Material(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.row),
          onTap: onRename,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, Gap.xs),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.m),
                    child: Icon(Icons.drag_indicator_rounded, color: Skin.inkFaintOn(context)),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(category.name, style: Skin.title(context, size: 18)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text('$count ${count == 1 ? 'BOOK' : 'BOOKS'}', style: Skin.meta(context)),
                          if (isDefault) ...[
                            const SizedBox(width: Gap.s),
                            const TagChip('Default', accent: true),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Options for ${category.name}',
                  icon: Icon(Icons.more_vert_rounded, color: Skin.inkSoftOn(context)),
                  onSelected: (v) => switch (v) {
                    'rename' => onRename(),
                    'default' => onDefault(),
                    'delete' => onDelete(),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    if (!isDefault)
                      const PopupMenuItem(value: 'default', child: Text('Make default')),
                    if (canDelete) const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
