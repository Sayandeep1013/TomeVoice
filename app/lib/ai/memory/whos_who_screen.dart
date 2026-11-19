import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../ai_keys.dart';
import '../ai_router.dart';
import '../talk/name_card.dart';
import 'cast_tidy.dart';
import 'graph_screen.dart';
import 'ledger.dart';

/// Who's who: everyone and everything with a name in the book's memory, by
/// kind, found by any of their names, as of the spoiler line when the guard
/// is on. A tap opens the card; the graph shows how they connect. A long
/// press renames one, or makes two cards for one character one; the AI can
/// tidy the names of all.
class WhosWhoScreen extends StatefulWidget {
  const WhosWhoScreen(
      {super.key, required this.bookTitle, required this.memoryPath, this.line, this.mayTidy = false});

  final String bookTitle;
  final String memoryPath;

  /// The spoiler line (null: the guard is off).
  final int? line;

  /// Whether the AI may be asked to tidy the names (not for a book kept
  /// from the AI).
  final bool mayTidy;

  @override
  State<WhosWhoScreen> createState() => _WhosWhoScreenState();
}

class _WhosWhoScreenState extends State<WhosWhoScreen> {
  String? _kind;
  String _query = '';
  LedgerOrder _order = LedgerOrder.importance;
  List<LedgerEntry>? _entries;
  List<({String kind, int count, bool core})> _kinds = const [];
  int _asked = 0;
  bool _tidying = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final n = ++_asked;
    final r = await _fetch(widget.memoryPath, widget.line, _kind, _query, _order);
    if (!mounted || n != _asked) return;
    setState(() {
      _entries = r.entries;
      _kinds = r.kinds;
    });
  }

  Future<void> _open(LedgerEntry e) async {
    final card = await cardOff(widget.memoryPath, e.id, widget.line);
    if (card == null || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => NameCardSheet(card: card, line: widget.line),
    );
  }

  /// The names of all tidied by the AI: one character split over two cards
  /// made one, a description replaced by the name, names on the wrong card
  /// taken off.
  Future<void> _tidy() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _tidying = true);
    String said;
    try {
      final n = await tidyCast(widget.memoryPath, AiRouter());
      said = n == 0 ? 'The names were already in order' : 'Names tidied: $n ${n == 1 ? 'change' : 'changes'}';
    } on AiResting {
      said = 'No AI key can take this now. Try again later.';
    } on Object {
      said = 'The names could not be tidied this time.';
    }
    if (!mounted) return;
    setState(() => _tidying = false);
    messenger.showSnackBar(SnackBar(content: Text(said)));
    unawaited(_load());
  }

  /// Renamed, or made one with another card.
  Future<void> _edit(LedgerEntry e) async {
    final what = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: KindDot(e.kind),
              title: Text(e.name, style: Skin.ui(size: 16, weight: FontWeight.w700, color: Skin.inkOn(ctx))),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.merge_type_rounded),
              title: const Text('The same as…'),
              subtitle: const Text('Two cards for one character made one'),
              onTap: () => Navigator.of(ctx).pop('same'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || what == null) return;
    if (what == 'rename') {
      final name = await askText(context, title: 'Rename', initial: e.name, hint: 'Name');
      if (name == null || name.trim().isEmpty || name.trim() == e.name) return;
      await renameEntity(widget.memoryPath, e.id, name.trim());
    } else {
      final other = await showDialog<LedgerEntry>(
        context: context,
        animationStyle: sheetMotion(context),
        builder: (_) => _SamePicker(memoryPath: widget.memoryPath, line: widget.line, not: e),
      );
      if (other == null) return;
      // The better known keeps its card and name; the other's names,
      // chapters and links go to it.
      final (keep, gone) = other.mentions >= e.mentions ? (other, e) : (e, other);
      await mergeEntity(widget.memoryPath, gone.id, keep.id);
    }
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: ScreenTopBar(title: "Who's who", onBack: () => Navigator.of(context).maybePop())),
                  IconButton(
                    tooltip: 'The memory graph',
                    icon: const Icon(Icons.hub_outlined),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => MemoryGraphScreen(
                        bookTitle: widget.bookTitle,
                        memoryPath: widget.memoryPath,
                        line: widget.line,
                      ),
                    )),
                  ),
                  if (widget.mayTidy && AiRing.instance.hasKeys)
                    _tidying
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            tooltip: 'Tidy the names with AI',
                            icon: const Icon(Icons.auto_fix_high_outlined),
                            onPressed: () => unawaited(_tidy()),
                          ),
                  PopupMenuButton<LedgerOrder>(
                    tooltip: 'Order',
                    icon: const Icon(Icons.sort_rounded),
                    initialValue: _order,
                    onSelected: (o) {
                      setState(() => _order = o);
                      unawaited(_load());
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: LedgerOrder.importance, child: Text('Seen most')),
                      PopupMenuItem(value: LedgerOrder.firstMet, child: Text('First met')),
                      PopupMenuItem(value: LedgerOrder.name, child: Text('By name')),
                    ],
                  ),
                  const SizedBox(width: Gap.s),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: Text(
                  '${widget.bookTitle}${widget.line == null ? '' : ' · as of chapter ${widget.line! + 1}'}',
                  style: Skin.meta(context),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                  children: [
                    for (final k in [null, ..._kinds.map((k) => k.kind)])
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.s),
                        child: ChoiceChip(
                          label: Text(k == null
                              ? 'All'
                              : '${kindLabel(k)} ${_kinds.firstWhere((x) => x.kind == k).count}'),
                          selected: _kind == k,
                          onSelected: (_) {
                            setState(() => _kind = k);
                            unawaited(_load());
                          },
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, Gap.s),
                child: SearchField(
                  hint: 'Find by any name',
                  onChanged: (v) {
                    _query = v;
                    unawaited(_load());
                  },
                ),
              ),
              Expanded(
                child: entries == null
                    ? const SizedBox.shrink()
                    : entries.isEmpty
                        ? EmptyState(
                            icon: Icons.person_search_rounded,
                            title: _query.isEmpty && _kind == null ? 'Nobody yet' : 'Nothing matches',
                            body: _query.isEmpty && _kind == null
                                ? 'Build the memory from the book\'s page, and the people, places and things of '
                                    'the story gather here.'
                                : 'Try another name or kind.',
                          )
                        : ListView.builder(
                            padding: EdgeInsets.only(bottom: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                            itemCount: entries.length,
                            itemBuilder: (context, i) {
                              final e = entries[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
                                leading: KindDot(e.kind),
                                title: Text(e.name,
                                    style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                                subtitle: Text(
                                  [
                                    if (e.about != null && e.about!.isNotEmpty) e.about!,
                                    '${kindLabel(e.kind)} · ${(e.firstCh ?? 0) < 0 ? 'from an earlier book' : 'first in chapter ${(e.firstCh ?? 0) + 1}'} · '
                                        'in ${e.mentions} ${e.mentions == 1 ? 'chapter' : 'chapters'}',
                                  ].join('\n'),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.meta(context),
                                ),
                                onTap: () => unawaited(_open(e)),
                                onLongPress: () => unawaited(_edit(e)),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Off the UI thread's isolate, from a function of its own: a closure made
// in a State's method can carry the State (and the whole app) with it, and
// sending that to another isolate fails.
Future<({List<LedgerEntry> entries, List<({String kind, int count, bool core})> kinds})> _fetch(
  String path,
  int? at,
  String? kind,
  String query,
  LedgerOrder order,
) =>
    Isolate.run(() => (
          entries: ledger(path, at: at, kind: kind, query: query, order: order),
          kinds: ledgerKinds(path, at: at),
        ));

/// Another card to make one with: found by any of its names.
class _SamePicker extends StatefulWidget {
  const _SamePicker({required this.memoryPath, required this.line, required this.not});

  final String memoryPath;
  final int? line;
  final LedgerEntry not;

  @override
  State<_SamePicker> createState() => _SamePickerState();
}

class _SamePickerState extends State<_SamePicker> {
  List<LedgerEntry> _found = const [];
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_find(''));
  }

  Future<void> _find(String q) async {
    final n = ++_asked;
    final r = await _fetch(widget.memoryPath, widget.line, null, q, LedgerOrder.importance);
    if (!mounted || n != _asked) return;
    setState(() => _found = [for (final e in r.entries) if (e.id != widget.not.id) e].take(40).toList());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.not.name} is the same as…'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: Column(
            children: [
              SearchField(hint: 'Find by any name', autofocus: true, onChanged: (v) => unawaited(_find(v))),
              const SizedBox(height: Gap.s),
              Expanded(
                child: ListView(
                  children: [
                    for (final e in _found)
                      ListTile(
                        dense: true,
                        leading: KindDot(e.kind),
                        title: Text(e.name),
                        subtitle: Text('in ${e.mentions} ${e.mentions == 1 ? 'chapter' : 'chapters'}'),
                        onTap: () => Navigator.of(context).pop(e),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
      );
}

/// A kind as the reader reads it: "People", "Powers", "Aspects".
String kindLabel(String kind) => switch (kind) {
      'person' => 'People',
      'place' => 'Places',
      'faction' => 'Groups',
      'item' => 'Things',
      'power' => 'Powers',
      'title' => 'Titles',
      'creature' => 'Creatures',
      'term' => 'Terms',
      _ => kind.isEmpty ? 'Other' : _plural('${kind[0].toUpperCase()}${kind.substring(1)}'),
    };

/// A kind the book brought, as many: Deity, Deities; Aspect, Aspects.
String _plural(String w) {
  if (w.endsWith('s') || w.endsWith('x') || w.endsWith('ch') || w.endsWith('sh')) {
    return w.endsWith('s') ? w : '${w}es';
  }
  if (w.length > 1 && w.endsWith('y') && !'aeiou'.contains(w[w.length - 2])) return '${w.substring(0, w.length - 1)}ies';
  return '${w}s';
}

/// A kind shown as a plain dot of its colour.
class KindDot extends StatelessWidget {
  const KindDot(this.kind, {super.key, this.size = 12});

  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: kindColour(kind), shape: BoxShape.circle),
      );
}

/// Each kind its colour, the same on the list and the graph; a kind the
/// book brought gets one from its name.
Color kindColour(String kind) => switch (kind) {
      'person' => const Color(0xFFE0A33A),
      'place' => const Color(0xFF3AA79A),
      'faction' => const Color(0xFF8E6CD8),
      'item' => const Color(0xFF4C8FD6),
      'power' => const Color(0xFFD9534F),
      'title' => const Color(0xFFC9A227),
      'creature' => const Color(0xFF5FAE4E),
      'term' => const Color(0xFF8C8C96),
      _ => HSLColor.fromAHSL(1, (kind.hashCode % 360).toDouble().abs(), 0.5, 0.55).toColor(),
    };
