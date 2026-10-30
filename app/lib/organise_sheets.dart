import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'book_actions.dart';
import 'book_card.dart';
import 'book_search.dart' show foldForSearch;
import 'library_store.dart';
import 'organise.dart';
import 'series.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart' show languageName;

// The sheets that organise the library: narrowing the shelf, a book's tags
// and series, the tags themselves, a series in its order, and books that
// look alike. Each is given the books a page has (LibraryStore.index), so a
// shut secret shelf's books, tags and series are never among what it shows.

/// A choice in a sheet: a pill, amber when chosen, as the shelves' are.
class ChoicePill extends StatelessWidget {
  const ChoicePill(this.label, {super.key, required this.selected, required this.onTap, this.count});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? Skin.amber : Skin.capsuleOn(context),
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Gap.s),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.ui(
                        size: 14,
                        weight: selected ? FontWeight.w700 : FontWeight.w600,
                        color: selected ? Skin.onAmber : Skin.inkOn(context),
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: Skin.ui(
                        size: 12.5,
                        weight: FontWeight.w600,
                        tabular: true,
                        color: selected ? Skin.onAmber.withValues(alpha: 0.7) : Skin.inkFaintOn(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

/// A heading over a group of choices in a sheet, with [trailing] on its
/// right (an Edit).
Widget _section(BuildContext context, String title, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.m, Gap.s),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: Row(children: [Expanded(child: Eyebrow(title)), if (trailing != null) trailing]),
      ),
    );

/// A small text button for a section's heading.
final _compact = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  minimumSize: const Size(48, 28),
  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
);

Widget _pills(List<Widget> pills) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
      child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: pills),
    );

// ------------------------------------------------------------------ filter

/// The View menu's Filter: narrow the shelf to books in a state, of a
/// format or language, with a tag or in a series. Each choice applies at
/// once ([onChanged]), so the shelf behind is seen to follow; [onEditTags]
/// opens the tags to rename or remove.
Future<void> showShelfFilter(
  BuildContext context, {
  required List<LibraryEntry> books,
  required ShelfFilter filter,
  required ValueChanged<ShelfFilter> onChanged,
  required VoidCallback onEditTags,
}) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _FilterSheet(books: books, filter: filter, onChanged: onChanged, onEditTags: onEditTags),
    );

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.books, required this.filter, required this.onChanged, required this.onEditTags});

  final List<LibraryEntry> books;
  final ShelfFilter filter;
  final ValueChanged<ShelfFilter> onChanged;
  final VoidCallback onEditTags;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late ShelfFilter _filter = widget.filter;

  void _set(ShelfFilter next) {
    setState(() => _filter = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    final f = _filter;
    final shown = books.where(f.matches).length;
    int count(bool Function(LibraryEntry e) test) => books.where(test).length;
    final formats = {for (final b in books) b.formatLabel}.toList()..sort();
    final languages = {
      for (final b in books)
        if (languageKey(b) case final l?) l,
    }.toList()
      ..sort((a, b) => languageName(a).compareTo(languageName(b)));
    final tags = tagsIn(books);
    final series = seriesIn(books);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            'Show only',
            subtitle: f.isEmpty ? 'All ${_books(books.length)}' : '$shown of ${_books(books.length)}',
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section(context, 'Progress'),
                  _pills([
                    for (final s in ReadState.values)
                      ChoicePill(
                        s.label,
                        count: count((e) => ReadState.of(e) == s),
                        selected: f.states.contains(s),
                        onTap: () => _set(_filter.copyWith(states: toggled(_filter.states, s))),
                      ),
                  ]),
                  if (formats.length > 1) ...[
                    _section(context, 'Format'),
                    _pills([
                      for (final x in formats)
                        ChoicePill(
                          x,
                          count: count((e) => e.formatLabel == x),
                          selected: f.formats.contains(x),
                          onTap: () => _set(_filter.copyWith(formats: toggled(_filter.formats, x))),
                        ),
                    ]),
                  ],
                  if (languages.length > 1) ...[
                    _section(context, 'Language'),
                    _pills([
                      for (final l in languages)
                        ChoicePill(
                          languageName(l),
                          count: count((e) => languageKey(e) == l),
                          selected: f.languages.contains(l),
                          onTap: () => _set(_filter.copyWith(languages: toggled(_filter.languages, l))),
                        ),
                    ]),
                  ],
                  if (tags.isNotEmpty) ...[
                    _section(
                      context,
                      'Tags',
                      trailing: TextButton(
                        style: _compact,
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onEditTags();
                        },
                        child: const Text('Edit'),
                      ),
                    ),
                    _pills([
                      for (final t in tags)
                        ChoicePill(
                          t.name,
                          count: t.count,
                          selected: f.tags.contains(tagKey(t.name)),
                          onTap: () => _set(_filter.copyWith(tags: toggled(_filter.tags, tagKey(t.name)))),
                        ),
                    ]),
                  ],
                  if (series.isNotEmpty) ...[
                    _section(context, 'Series'),
                    _pills([
                      for (final s in series)
                        ChoicePill(
                          s.name,
                          count: s.count,
                          selected: f.series.contains(foldForSearch(s.name)),
                          onTap: () => _set(_filter.copyWith(series: toggled(_filter.series, foldForSearch(s.name)))),
                        ),
                    ]),
                  ],
                  if (tags.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, 0),
                      child: Text(
                        'Tag a book from its page, or select several on the shelf, to find them here.',
                        style: Skin.label(context, size: 13, color: Skin.inkFaintOn(context)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.m),
            child: Row(
              children: [
                TextButton(onPressed: f.isEmpty ? null : () => _set(const ShelfFilter()), child: const Text('Show all')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _books(int n) => '$n ${n == 1 ? 'book' : 'books'}';

/// What [filter] narrows the shelf to, each as a label and how to take it
/// away, for the pills over the shelf. Names come from [books], the books
/// shown (see ShelfFilter.within).
List<(String, ShelfFilter)> filterParts(ShelfFilter filter, List<LibraryEntry> books) {
  final tagNames = {for (final t in tagsIn(books)) tagKey(t.name): t.name};
  final seriesNames = {for (final s in seriesIn(books)) foldForSearch(s.name): s.name};
  final f = filter;
  return [
    for (final s in ReadState.values)
      if (f.states.contains(s)) (s.label, f.copyWith(states: toggled(f.states, s))),
    for (final x in f.formats) (x, f.copyWith(formats: toggled(f.formats, x))),
    for (final l in f.languages) (languageName(l), f.copyWith(languages: toggled(f.languages, l))),
    for (final t in f.tags) (tagNames[t] ?? t, f.copyWith(tags: toggled(f.tags, t))),
    for (final s in f.series) (seriesNames[s] ?? s, f.copyWith(series: toggled(f.series, s))),
  ];
}

/// The shelf's filter as it stands, over the books: a pill for each choice,
/// a tap on one taking it away, and Show all.
class ActiveFilter extends StatelessWidget {
  const ActiveFilter({super.key, required this.filter, required this.books, required this.onChanged});

  final ShelfFilter filter;
  final List<LibraryEntry> books;
  final ValueChanged<ShelfFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final parts = filterParts(filter, books);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Icon(Icons.filter_list_rounded, size: 18, color: Skin.inkSoftOn(context)),
          const SizedBox(width: Gap.s),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: parts.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final (label, without) = parts[i];
                return Tooltip(
                  message: 'Show more than $label',
                  child: Material(
                    color: Skin.capsuleOn(context),
                    shape: StadiumBorder(side: BorderSide(color: Skin.outlineOn(context))),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => onChanged(without),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(label, style: Skin.ui(size: 13, weight: FontWeight.w600, color: Skin.inkOn(context))),
                            const SizedBox(width: 4),
                            Icon(Icons.close_rounded, size: 15, color: Skin.inkSoftOn(context)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          TextButton(onPressed: () => onChanged(const ShelfFilter()), child: const Text('Show all')),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- tags and series

/// A book's tags and series, changed on one sheet: its tags among those
/// on the shelf, or new ones, and its series and number.
Future<void> editTagsAndSeries(BuildContext context, LibraryStore store, LibraryEntry entry) async {
  final shown = (await store.index()).entries;
  if (!context.mounted) return;
  final done = await showModalBottomSheet<({List<String> tags, String series, double? number})>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _OrganiseSheet(entry: entry, books: shown),
  );
  if (done == null) return;
  await store.setTags(entry.id, done.tags);
  await store.setSeries(entry.id, done.series, done.number);
}

class _OrganiseSheet extends StatefulWidget {
  const _OrganiseSheet({required this.entry, required this.books});

  final LibraryEntry entry;
  final List<LibraryEntry> books;

  @override
  State<_OrganiseSheet> createState() => _OrganiseSheetState();
}

class _OrganiseSheetState extends State<_OrganiseSheet> {
  late final List<String> _all = [
    ...tagsIn(widget.books).map((t) => t.name),
    for (final t in widget.entry.tags)
      if (!tagsIn(widget.books).any((x) => tagKey(x.name) == tagKey(t))) t,
  ];
  late final Set<String> _on = {for (final t in widget.entry.tags) tagKey(t)};
  final _newTag = TextEditingController();
  late final _series = TextEditingController(text: widget.entry.seriesName ?? '');
  late final _number = TextEditingController(
    text: widget.entry.seriesIndex == null ? '' : seriesNumber(widget.entry.seriesIndex!),
  );

  @override
  void dispose() {
    _newTag.dispose();
    _series.dispose();
    _number.dispose();
    super.dispose();
  }

  void _addTag() {
    final name = tagNamed(_newTag.text, widget.books);
    if (tagKey(name).isEmpty) return;
    setState(() {
      if (!_all.any((t) => tagKey(t) == tagKey(name))) _all.add(name);
      _on.add(tagKey(name));
      _newTag.clear();
    });
  }

  void _save() {
    if (_newTag.text.trim().isNotEmpty) _addTag();
    final number = double.tryParse(_number.text.trim().replaceAll(',', '.'));
    Navigator.pop(context, (
      tags: [for (final t in _all) if (_on.contains(tagKey(t))) t],
      series: _series.text.trim(),
      number: number,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final field = Skin.ui(size: 15.5, weight: FontWeight.w500, color: Skin.inkOn(context));
    final typed = foldForSearch(_series.text.trim());
    final known = [
      for (final s in seriesIn(widget.books))
        if (typed.isEmpty || (foldForSearch(s.name).contains(typed) && foldForSearch(s.name) != typed)) s.name,
    ].take(6).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader('Tags and series', subtitle: widget.entry.title),
              _section(context, 'Tags'),
              if (_all.isNotEmpty)
                _pills([
                  for (final t in _all)
                    ChoicePill(
                      t,
                      selected: _on.contains(tagKey(t)),
                      onTap: () => setState(() => toggledInPlace(_on, tagKey(t))),
                    ),
                ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, 0),
                child: TextField(
                  controller: _newTag,
                  style: field,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: _all.isEmpty ? 'A tag, such as Favourites' : 'A new tag',
                    suffixIcon: IconButton(tooltip: 'Add the tag', icon: const Icon(Icons.add_rounded), onPressed: _addTag),
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              _section(context, 'Series'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _series,
                        style: field,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(hintText: 'In no series'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: Gap.m),
                    SizedBox(
                      width: 76,
                      child: TextField(
                        controller: _number,
                        style: field,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(hintText: 'No.'),
                      ),
                    ),
                  ],
                ),
              ),
              if (known.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: _pills([
                    for (final s in known)
                      ChoicePill(s, selected: false, onTap: () => setState(() => _series.text = s)),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.m),
                child: Row(
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    const Spacer(),
                    FilledButton(onPressed: _save, child: const Text('Save')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [value] taken out of [set] if it is in, put in if not.
void toggledInPlace<T>(Set<T> set, T value) => set.contains(value) ? set.remove(value) : set.add(value);

/// A tag for the books [ids] (selected on the shelf): one already on the
/// shelf, or a new one. One every one of them has is taken off them.
Future<void> tagSelected(BuildContext context, LibraryStore store, Set<String> ids) async {
  final shown = (await store.index()).entries;
  final picked = shown.where((e) => ids.contains(e.id)).toList();
  if (!context.mounted || picked.isEmpty) return;
  bool onAll(String tag) => picked.every((e) => e.tags.any((t) => tagKey(t) == tagKey(tag)));
  final tags = tagsIn(shown);
  final n = picked.length;
  final choice = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader('Tag ${_books(n)}'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final t in tags)
                  SheetAction(
                    icon: onAll(t.name) ? Icons.check_circle_rounded : Icons.sell_outlined,
                    label: t.name,
                    detail: onAll(t.name) ? 'On ${n == 1 ? 'it' : 'all of them'}: tap to take it off' : _books(t.count),
                    onTap: () => Navigator.pop(ctx, t.name),
                  ),
                SheetAction(icon: Icons.add_rounded, label: 'New tag…', onTap: () => Navigator.pop(ctx, '')),
                const SizedBox(height: Gap.s),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  var tag = choice;
  if (tag.isEmpty) {
    final typed = await askText(context, title: 'New tag', hint: 'For example: Favourites', action: 'Add');
    if (typed == null) return;
    tag = typed;
  }
  final off = choice.isNotEmpty && onAll(tag);
  await store.tagBooks(ids, tag, on: !off);
  if (context.mounted) {
    final name = tagNamed(tag, (await store.index()).entries);
    if (context.mounted) showSnack(context, off ? 'Took "$name" off ${_books(n)}.' : 'Tagged ${_books(n)} "$name".', lift: 84);
  }
}

/// The shelf's tags, to rename or take off every book shown.
Future<void> editTags(BuildContext context, LibraryStore store) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _TagsSheet(store: store),
    );

class _TagsSheet extends StatefulWidget {
  const _TagsSheet({required this.store});

  final LibraryStore store;

  @override
  State<_TagsSheet> createState() => _TagsSheetState();
}

class _TagsSheetState extends State<_TagsSheet> {
  List<({String name, int count})>? _tags;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final tags = tagsIn((await widget.store.index()).entries);
    if (mounted) setState(() => _tags = tags);
  }

  Future<void> _rename(String name) async {
    final to = await askText(context, title: 'Rename the tag', initial: name, action: 'Rename');
    if (to == null || to == name) return;
    await widget.store.renameTag(name, to);
    await _load();
  }

  Future<void> _remove(String name, int count) async {
    final ok = await confirm(
      context,
      title: 'Remove "$name"?',
      body: 'It is taken off ${count == 1 ? 'the book' : 'the $count books'} it is on. The books stay.',
      action: 'Remove',
    );
    if (!ok) return;
    await widget.store.renameTag(name, '');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Tags'),
          if (tags == null)
            const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))
          else if (tags.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
              child: Text('No tags yet.', style: Skin.label(context, size: 15)),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in tags)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xl, right: Gap.s),
                      child: Row(
                        children: [
                          Icon(Icons.sell_outlined, size: 20, color: Skin.inkSoftOn(context)),
                          const SizedBox(width: Gap.l),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.name, style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context))),
                                Text(_books(t.count), style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Rename "${t.name}"',
                            icon: Icon(Icons.edit_outlined, size: 20, color: Skin.inkSoftOn(context)),
                            onPressed: () => unawaited(_rename(t.name)),
                          ),
                          IconButton(
                            tooltip: 'Remove "${t.name}"',
                            icon: Icon(Icons.delete_outline_rounded, size: 20, color: Skin.inkFaintOn(context)),
                            onPressed: () => unawaited(_remove(t.name, t.count)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: Gap.m),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Series [name]'s books on the shelf, in its order, [current] marked. The
/// one tapped is given back, to open.
Future<LibraryEntry?> showSeriesBooks(
  BuildContext context, {
  required String name,
  required List<LibraryEntry> books,
  String? current,
}) {
  final inOrder = booksInSeries(books, name);
  return showModalBottomSheet<LibraryEntry>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(name, subtitle: '${_books(inOrder.length)} on your shelves'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final e in inOrder)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, e),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.s),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 34,
                            child: Text(
                              e.seriesIndex == null ? '' : seriesNumber(e.seriesIndex!),
                              style: Skin.meta(ctx, size: 13, color: e.id == current ? Skin.accentOf(ctx) : null),
                            ),
                          ),
                          BookCover(entry: e, width: 34, shadow: false),
                          const SizedBox(width: Gap.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.ui(
                                    size: 15.5,
                                    weight: e.id == current ? FontWeight.w700 : FontWeight.w500,
                                    color: e.id == current ? Skin.accentOf(ctx) : Skin.inkOn(ctx),
                                  ),
                                ),
                                Text(progressLine(e).toUpperCase(), style: Skin.meta(ctx, size: 10)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: Gap.m),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// -------------------------------------------------------------- duplicates

/// Books that look like the same book ([groups], see duplicates.dart),
/// side by side, with Remove on each. Nothing goes unless chosen.
Future<void> showDuplicates(BuildContext context, LibraryStore store, List<(List<LibraryEntry>, String)> groups) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _DuplicatesSheet(store: store, groups: groups),
    );

class _DuplicatesSheet extends StatefulWidget {
  const _DuplicatesSheet({required this.store, required this.groups});

  final LibraryStore store;
  final List<(List<LibraryEntry>, String)> groups;

  @override
  State<_DuplicatesSheet> createState() => _DuplicatesSheetState();
}

class _DuplicatesSheetState extends State<_DuplicatesSheet> {
  late var _groups = widget.groups;
  Map<String, String> _shelves = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadShelves());
  }

  Future<void> _loadShelves() async {
    final idx = await widget.store.index();
    final names = {for (final c in idx.categories) c.id: c.name};
    if (!mounted) return;
    setState(() => _shelves = {
          for (final e in idx.entries) e.id: names[e.categoryIn(idx.categories, idx.defaultCategory)] ?? '',
        });
  }

  Future<void> _remove(LibraryEntry e) async {
    if (!await removeBook(context, widget.store, e) || !mounted) return;
    setState(() {
      _groups = [
        for (final (books, why) in _groups)
          if (books.where((b) => b.id != e.id).length > 1) ([for (final b in books) if (b.id != e.id) b], why),
      ];
    });
    if (_groups.isEmpty && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              _groups.length == 1 ? 'These look like one book' : 'Books that look alike',
              subtitle: 'Remove a copy, or keep them all',
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (books, why) in _groups) ...[
                    _section(context, why),
                    for (final e in books) _row(context, e),
                  ],
                  const SizedBox(height: Gap.m),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.m),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Nothing is removed unless you choose it.',
                      style: Skin.label(context, size: 13, color: Skin.inkFaintOn(context)),
                    ),
                  ),
                  FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Keep them')),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _row(BuildContext context, LibraryEntry e) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.s, Gap.xs),
        child: Row(
          children: [
            BookCover(entry: e, width: 40, shadow: false),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                  Text(
                    [
                      e.formatLabel,
                      if (e.authorLine.isNotEmpty) e.authorLine,
                      if (e.progress > 0) percentLabel(e.progress),
                      if (_shelves[e.id]?.isNotEmpty ?? false) _shelves[e.id]!,
                    ].join(' · ').toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.meta(context, size: 10),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove this copy',
              icon: const Icon(Icons.delete_outline_rounded, size: 21, color: Color(0xFFE5674D)),
              onPressed: () => unawaited(_remove(e)),
            ),
          ],
        ),
      );
}
