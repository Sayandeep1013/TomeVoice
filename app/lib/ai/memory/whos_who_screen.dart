import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../talk/name_card.dart';
import 'graph_screen.dart';
import 'ledger.dart';

/// Who's who: everyone and everything with a name in the book's memory, by
/// kind, found by any of their names, as of the spoiler line when the guard
/// is on. A tap opens the card; the graph shows how they connect.
class WhosWhoScreen extends StatefulWidget {
  const WhosWhoScreen({super.key, required this.bookTitle, required this.memoryPath, this.line});

  final String bookTitle;
  final String memoryPath;

  /// The spoiler line (null: the guard is off).
  final int? line;

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
                                leading: CircleAvatar(
                                  radius: 16,
                                  backgroundColor: kindColour(e.kind).withValues(alpha: 0.22),
                                  child: Icon(kindIcon(e.kind), size: 17, color: kindColour(e.kind)),
                                ),
                                title: Text(e.name,
                                    style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                                subtitle: Text(
                                  [
                                    if (e.about != null && e.about!.isNotEmpty) e.about!,
                                    '${kindLabel(e.kind)} · first in chapter ${(e.firstCh ?? 0) + 1} · '
                                        'in ${e.mentions} ${e.mentions == 1 ? 'chapter' : 'chapters'}',
                                  ].join('\n'),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.meta(context),
                                ),
                                onTap: () => unawaited(_open(e)),
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
      _ => kind.isEmpty ? 'Other' : '${kind[0].toUpperCase()}${kind.substring(1)}${kind.endsWith('s') ? '' : 's'}',
    };

IconData kindIcon(String kind) => switch (kind) {
      'person' => Icons.person_rounded,
      'place' => Icons.place_rounded,
      'faction' => Icons.groups_rounded,
      'item' => Icons.diamond_outlined,
      'power' => Icons.bolt_rounded,
      'title' => Icons.military_tech_rounded,
      'creature' => Icons.pets_rounded,
      'term' => Icons.menu_book_rounded,
      _ => Icons.category_rounded,
    };

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
