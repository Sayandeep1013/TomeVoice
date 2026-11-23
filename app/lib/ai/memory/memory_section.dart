import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import '../../theme.dart';
import '../../ui.dart';
import '../ai_keys.dart';
import '../ai_screen.dart' show AiScreen, wakeTime;
import '../../backup_flow.dart' show sizeLabel;
import '../../download_queue.dart';
import '../../library_store.dart' show KeptMemory, LibraryEntry;
import '../talk/talk_sheet.dart' show showTalk;
import 'chapter_notes_screen.dart';
import 'find_where_screen.dart';
import 'graph_screen.dart';
import 'hand_off.dart';
import 'memory_builder.dart';
import 'memory_service.dart';
import 'series_flow.dart';
import 'series_screen.dart';
import 'series_store.dart';
import 'theories_screen.dart';
import 'threads_screen.dart';
import 'whos_who_screen.dart';

/// A book's page > Memory: what the AI companion remembers of the book,
/// how far it is built, Build or Pause, and the spoiler guard. On the
/// book's page it is one row ([compact]) that opens its own page, so the
/// chapters are not pushed down (the owner's choice).
class BookMemorySection extends StatefulWidget {
  const BookMemorySection({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.secret,
    this.service,
    this.compact = true,
    this.onRead,
  });

  final String bookId;
  final String bookTitle;
  final bool compact;

  /// Opens the book at a place (a chapter Talk cites, from the graph).
  final void Function(ReadingCursor at)? onRead;

  /// On a secret shelf: never sent, so never built.
  final bool secret;
  final MemoryService? service;

  @override
  State<BookMemorySection> createState() => _BookMemorySectionState();
}

class _BookMemorySectionState extends State<BookMemorySection> {
  MemoryService get _service => widget.service ?? MemoryService.instance;

  @override
  void initState() {
    super.initState();
    AiRing.instance.addListener(_changed);
  }

  @override
  void dispose() {
    AiRing.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Consent, missing chapters, whether it carries on from another book
  /// (a series), what it will take, then building (see startMemory).
  Future<void> _build() => startMemory(context, widget.bookId, service: _service);

  Future<void> _openWho() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          WhosWhoScreen(
        bookTitle: widget.bookTitle,
        memoryPath: _service.pathOf(widget.bookId),
        line: line,
        mayTidy: _service.maySend(widget.bookId),
      ),
    ));
  }

  Future<void> _openGraph() async {
    final line = await _service.lineOf(widget.bookId);
    final here = await _service.hereOf(widget.bookId);
    final stamp = await _service.stampOf(widget.bookId);
    if (!mounted) return;
    final path = _service.pathOf(widget.bookId);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (graph) => MemoryGraphScreen(
        bookTitle: widget.bookTitle,
        memoryPath: path,
        line: line,
        here: here,
        nameGroups: line == null && _service.maySend(widget.bookId),
        // "Ask about this": the book's Talk, over the graph.
        onAsk: stamp == null || !_service.maySend(widget.bookId)
            ? null
            : (question) => showTalk(
                  graph,
                  bookId: widget.bookId,
                  bookTitle: widget.bookTitle,
                  memoryPath: path,
                  stampNow: () => stamp,
                  line: () => line,
                  here: () => here,
                  passage: () => '',
                  // A chapter it cites: the book opened there.
                  onLook: (p) => widget.onRead
                      ?.call(ReadingCursor(sectionIndex: p.section, blockIndex: p.block, sentenceIndex: p.sentence)),
                  firstQuestion: question,
                ),
      ),
    ));
  }

  Future<void> _openFind() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FindWhereScreen(
        bookTitle: widget.bookTitle,
        memoryPath: _service.pathOf(widget.bookId),
        line: line,
        onRead: widget.onRead,
      ),
    ));
  }

  Future<void> _openChapters() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    final path = _service.pathOf(widget.bookId);
    final id = widget.bookId;
    final service = _service;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChapterNotesScreen(
        bookTitle: widget.bookTitle,
        memoryPath: path,
        line: line,
        onReadAgain: service.maySend(id)
            ? (ch) async {
                await forgetChapterNotesOff(path, ch);
                await service.refresh(id);
                unawaited(service.build(id));
              }
            : null,
      ),
    ));
  }

  Future<void> _openThreads() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ThreadsScreen(memoryPath: _service.pathOf(widget.bookId), line: line, onRead: widget.onRead),
    ));
  }

  Future<void> _openTheories() async {
    final here = await _service.hereOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          TheoriesScreen(bookTitle: widget.bookTitle, memoryPath: _service.pathOf(widget.bookId), here: here),
    ));
  }

  Future<void> _handOff() async {
    final line = await _service.lineOf(widget.bookId);
    final here = await _service.hereOf(widget.bookId);
    if (!mounted) return;
    await showHandOff(
      context,
      memoryPath: _service.pathOf(widget.bookId),
      bookId: widget.bookId,
      title: widget.bookTitle,
      line: line,
      here: here,
    );
  }

  /// "I've read up to chapter N": for a book read elsewhere before, so the
  /// spoiler guard keeps to there, not to where TomeVoice's place is.
  Future<void> _readUpTo(BookMemoryState s) async {
    final typed = await askText(
      context,
      title: "I've read up to chapter",
      message: 'For a book you read partly elsewhere: with the spoiler guard on, the AI keeps to this chapter '
          'or your place here, whichever is further. Leave it empty to go by your place alone.',
      initial: s.readUpTo == null ? '' : '${s.readUpTo! + 1}',
      hint: '1800',
    );
    if (typed == null) return;
    final n = int.tryParse(typed.trim());
    await _service.setReadUpTo(widget.bookId, n == null || n < 1 ? null : n - 1);
  }

  /// The books before this one in a series, picked from the books with a
  /// memory (several for an omnibus or a spin-off): what they remember
  /// carried over. None picked undoes it.
  Future<void> _forget() async {
    final sure = await confirm(context,
        title: 'Forget what it remembers?',
        body: "This book's memory is deleted: its chapter notes, cast, graph, threads, theories and word index. "
            'The book, its downloaded chapters, your place, your journal and your AI chats stay. '
            'Building it again costs the calls again.',
        action: 'Forget');
    if (sure) await _service.forget(widget.bookId);
  }

  /// The key the reader may go on with while the one key the build keeps
  /// to is resting (or turned it down): the next of the Building list that
  /// can take it now. Null when the build may use any key, or none can.
  AiKey? _nextKey(BookMemoryState s) {
    final phase = s.build.phase;
    if (phase != BuildPhase.resting && phase != BuildPhase.failed) return null;
    final order = AiRing.instance.forJob(AiJob.builder);
    final kept = keptKey(s.buildKeys, order);
    if (kept == null) return null;
    final now = DateTime.now();
    final after = order.indexWhere((k) => k.id == kept.id);
    for (final k in [...order.skip(after + 1), ...order.take(math.max(0, after))]) {
      final st = AiRing.instance.stateOf(k.id);
      if (st.refused == null && !st.restingAt(now)) return k;
    }
    return null;
  }

  String _line(BookMemoryState s) {
    final b = s.build;
    final ix = s.indexing;
    if (ix != null) return ix.total == 0 ? 'Indexing its words…' : 'Indexing its words · ${ix.done} of ${ix.total}';
    switch (b.phase) {
      case BuildPhase.running:
        return 'Building · ${s.noted} of ${s.indexed} chapters';
      case BuildPhase.resting:
        final kept = keptKey(s.buildKeys, AiRing.instance.forJob(AiJob.builder));
        final at = wakeTime(b.until!);
        if (kept == null) return 'Waiting: every key has used its quota for now. Goes on at $at.';
        return 'Waiting: ${kept.label} ${b.error ?? 'has reached its limit for now'}. It goes on by itself at $at, '
            'with ${kept.label} only.';
      case BuildPhase.failed:
        return 'Stopped: ${b.error ?? 'no key could build it'}';
      case BuildPhase.paused:
        return 'Paused · ${s.noted} of ${s.indexed} chapters';
      case BuildPhase.idle || BuildPhase.done:
        break;
    }
    if (!s.exists || s.indexed == 0) return 'Not built yet';
    if (s.noted == 0) return 'Its words are indexed, so Talk can search the text. No notes yet.';
    final things = '${s.entities} ${s.entities == 1 ? 'person, place or thing' : 'people, places and things'}';
    if (s.noted + s.skipped >= s.indexed) return 'Built to chapter ${(s.lastNoted ?? 0) + 1} · $things';
    return '${s.noted} of ${s.indexed} chapters built · $things';
  }

  /// What the memory holds, each a row that says what it is: the everyday
  /// ones first (who someone is, what happened lately), then the rest. While
  /// nothing is noted yet, a line saying they come as it builds.
  List<Widget> _explore(BookMemoryState s) {
    final rows = memoryRows(s);
    final hint = s.noted == 0 && (s.exists || s.building)
        ? [
            const SizedBox(height: Gap.s),
            Text(
              "As chapters are read, Who's who, the graph and each chapter's notes appear here.",
              style:
                  Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
            ),
          ]
        : const <Widget>[];
    if (rows.isEmpty) return hint;
    VoidCallback open(MemoryRow r) => switch (r) {
          MemoryRow.who => () => unawaited(_openWho()),
          MemoryRow.chapters => () => unawaited(_openChapters()),
          MemoryRow.graph => () => unawaited(_openGraph()),
          MemoryRow.threads => () => unawaited(_openThreads()),
          MemoryRow.theories => () => unawaited(_openTheories()),
          MemoryRow.find => () => unawaited(_openFind()),
          MemoryRow.elsewhere => () => unawaited(_handOff()),
        };
    return [
      ...hint,
      const SizedBox(height: Gap.m),
      const Eyebrow('Look through it'),
      const SizedBox(height: Gap.s),
      Material(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row + 4),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) Divider(height: 1, indent: Gap.l + 22 + Gap.m, color: Skin.outlineOn(context)),
              _ExploreRow(row: r, state: s, onTap: open(r)),
            ],
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Off until the reader turns the AI on (adds a key), and never for a
    // book on a secret shelf.
    if (widget.secret || !AiRing.instance.hasKeys) return const SizedBox.shrink();
    return ValueListenableBuilder<BookMemoryState>(
      valueListenable: _service.stateOf(widget.bookId),
      builder: (context, s, _) {
        final busy = s.building || s.build.phase == BuildPhase.resting;
        final left = s.indexed == 0 || s.noted + s.skipped < s.indexed;
        if (widget.compact) {
          return Material(
            color: Skin.capsuleOn(context),
            borderRadius: BorderRadius.circular(Radii.row + 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.row + 4),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    BookMemoryScreen(bookId: widget.bookId, bookTitle: widget.bookTitle, onRead: widget.onRead),
              )),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, color: Skin.accentInkOf(context)),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Memory', style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                          const SizedBox(height: 2),
                          Text(
                            s.private ? 'Kept away from the AI' : _line(s),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.meta(context),
                          ),
                          if (s.build.phase == BuildPhase.running && s.indexed > 0) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(value: s.noted / s.indexed, minHeight: 3),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: Skin.inkSoftOn(context)),
                  ],
                ),
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: SectionTitle('Memory', note: 'AI')),
                PopupMenuButton<String>(
                  tooltip: 'More about the memory',
                  onSelected: (v) {
                    if (v == 'forget') unawaited(_forget());
                    if (v == 'follows') unawaited(carryOnFrom(context, widget.bookId, service: _service));
                    if (v == 'private') unawaited(_service.setPrivate(widget.bookId, !s.private));
                    if (v == 'read') unawaited(_readUpTo(s));
                  },
                  itemBuilder: (_) => [
                    if (!s.private) ...[
                      PopupMenuItem(
                        value: 'read',
                        child: Text(s.readUpTo == null
                            ? "I've read up to chapter…"
                            : "I've read up to chapter ${s.readUpTo! + 1}…"),
                      ),
                      const PopupMenuItem(value: 'follows', child: Text('Add to a series…')),
                    ],
                    PopupMenuItem(
                      value: 'private',
                      child: Text(s.private ? 'Let the AI read this book' : 'Keep this book away from the AI'),
                    ),
                    if (s.exists) const PopupMenuItem(value: 'forget', child: Text('Forget this memory')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              s.private ? 'Kept away from the AI: nothing of this book is sent, built or talked about.' : _line(s),
              style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
            ),
            if (s.build.phase == BuildPhase.running && s.indexed > 0) ...[
              const SizedBox(height: Gap.s),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: s.noted / s.indexed, minHeight: 4),
              ),
            ],
            if (!s.private && s.exists)
              _FollowsLine(
                key: ValueKey('follows ${s.entities} ${s.noted}'),
                service: _service,
                bookId: widget.bookId,
                onChange: () => unawaited(carryOnFrom(context, widget.bookId, service: _service)),
              ),
            if (!s.private) ...[
              if (busy || left) ...[
                const SizedBox(height: Gap.s),
                Wrap(
                  spacing: Gap.s,
                  runSpacing: Gap.s,
                  children: [
                    if (busy)
                      OutlinedButton.icon(
                        onPressed: () => _service.pause(widget.bookId),
                        icon: const Icon(Icons.pause_rounded, size: 18),
                        label: const Text('Pause'),
                      )
                    else if (left)
                      FilledButton.tonalIcon(
                        onPressed: () => unawaited(_build()),
                        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                        label: Text(s.noted == 0 ? 'Build memory' : 'Go on building'),
                      ),
                    if (_nextKey(s) case final next?)
                      FilledButton.tonal(
                        onPressed: () => unawaited(_service.goOnWith(widget.bookId, next)),
                        child: Text('Go on with ${next.label}'),
                      ),
                  ],
                ),
                if (_nextKey(s) case final next?)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text('${next.label} then builds it, and only ${next.label}.', style: Skin.meta(context)),
                  ),
              ],
              if (s.skipped > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: TextButton.icon(
                    onPressed: () => unawaited(_service.retrySkipped(widget.bookId)),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                    label: Text('Try the ${s.skipped} passed-over ${s.skipped == 1 ? 'chapter' : 'chapters'} again'),
                  ),
                ),
              // The guard near the top: it decides what every page below shows.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.guard,
                onChanged: (v) => unawaited(_service.setGuard(widget.bookId, v)),
                title: Text('Spoiler guard',
                    style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                subtitle: Text(
                  s.guard
                      ? "On: Who's who, the graph, the notes and Talk keep to what you have read."
                      : 'Off: they may show all it remembers, past where you are.',
                  style: Skin.meta(context),
                ),
              ),
              ..._explore(s),
              _ChaptersBlock(bookId: widget.bookId, service: _service, memory: s),
            ],
          ],
        );
      },
    );
  }
}

/// The ways into a memory, as its page lists them.
enum MemoryRow { who, chapters, graph, threads, theories, find, elsewhere }

/// The rows a memory in state [s] has something for, the everyday ones
/// first: who someone is, what happened lately, how they are linked.
List<MemoryRow> memoryRows(BookMemoryState s) => [
      if (s.entities > 0) MemoryRow.who,
      // Passed-over chapters too: seen there, and read again one by one.
      if (s.exists && (s.noted > 0 || s.skipped > 0)) MemoryRow.chapters,
      if (s.entities > 0) MemoryRow.graph,
      if (s.exists && s.noted > 0) ...[MemoryRow.threads, MemoryRow.theories],
      if (s.exists && s.indexed > 0) MemoryRow.find,
      if (s.exists && s.noted > 0) MemoryRow.elsewhere,
    ];

/// One way into the memory: what it is called, what it is for, and how
/// many there are when that helps.
class _ExploreRow extends StatelessWidget {
  const _ExploreRow({required this.row, required this.state, required this.onTap});

  final MemoryRow row;
  final BookMemoryState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, title, about, count) = switch (row) {
      MemoryRow.who => (
          Icons.groups_outlined,
          "Who's who",
          'Everyone and everything met so far, found by any name',
          state.entities,
        ),
      MemoryRow.chapters => (
          Icons.format_list_bulleted_rounded,
          'Chapter by chapter',
          'What happened in each chapter, the newest first',
          state.noted,
        ),
      MemoryRow.graph => (Icons.hub_outlined, 'Graph', 'Who is linked to whom, and how it grew', null),
      MemoryRow.threads => (
          Icons.timeline_rounded,
          'Threads',
          "The story's open questions, and how each moved on",
          null,
        ),
      MemoryRow.theories => (
          Icons.lightbulb_outline_rounded,
          'Theories',
          'Your guesses about the story, and what came of them',
          null,
        ),
      MemoryRow.find => (
          Icons.manage_search_rounded,
          'Find where…',
          'Every word of the book searched, to the chapter it is in',
          null,
        ),
      MemoryRow.elsewhere => (
          Icons.forum_outlined,
          'Talk elsewhere',
          'What it remembers, ready to take to another AI chat',
          null,
        ),
    };
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
          child: Row(
            children: [
              Icon(icon, size: 22, color: Skin.accentInkOf(context)),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                    const SizedBox(height: 2),
                    Text(about,
                        style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                            .copyWith(height: 1.3)),
                  ],
                ),
              ),
              if (count != null && count > 0) ...[
                const SizedBox(width: Gap.s),
                Text('$count',
                    style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.inkSoftOn(context), tabular: true)),
              ],
              Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A book's memory, on a page of its own: how far it is built, Build or
/// Pause, the spoiler guard, Who's who, the graph, theories, Talk elsewhere.
class BookMemoryScreen extends StatelessWidget {
  const BookMemoryScreen({super.key, required this.bookId, required this.bookTitle, this.onRead});

  final String bookId;
  final String bookTitle;
  final void Function(ReadingCursor at)? onRead;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: Skin.groundDecoration(context),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: 'Memory', onBack: () => Navigator.of(context).maybePop()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: Text(bookTitle, style: Skin.meta(context)),
                ),
                Expanded(
                  child: ListView(
                    padding:
                        EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      BookMemorySection(
                          bookId: bookId, bookTitle: bookTitle, secret: false, compact: false, onRead: onRead),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Main menu > Memory: every book with a memory, each under its own name
/// (a tap opens that book's memory on a page of its own), how far it is
/// built.
class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  List<({String id, String title, String author})>? _books;

  @override
  void initState() {
    super.initState();
    SeriesStore.instance.changes.addListener(_load);
    // Books linked the old way become series, once.
    unawaited(seriesFromOldLinks().whenComplete(_load));
  }

  @override
  void dispose() {
    SeriesStore.instance.changes.removeListener(_load);
    super.dispose();
  }

  /// Memories kept from books that were removed (LibraryStore.keptMemories).
  List<KeptMemory> _kept = const [];

  void _load() {
    unawaited(MemoryService.instance.booksWithMemory().then((b) async {
      final kept = await MemoryService.instance.library?.keptMemories() ?? const <KeptMemory>[];
      if (mounted) {
        setState(() {
          _books = [for (final e in b) (id: e.id, title: e.title, author: e.authors.join(', '))];
          _kept = kept;
        });
      }
    }));
  }

  Future<void> _deleteKept(KeptMemory k) async {
    final store = MemoryService.instance.library;
    if (store == null) return;
    final sure = await confirm(
      context,
      title: 'Delete this memory?',
      body: 'What the AI remembers of "${k.title}" is deleted for good. Adding the book again would mean '
          'building its memory again, which sends the book to your AI key once more.',
      action: 'Delete',
    );
    if (!sure) return;
    await store.deleteKeptMemory(k.id);
    _load();
  }

  Widget _keptRow(BuildContext context, KeptMemory k) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(color: Skin.inkFaintOn(context), borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(k.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 18)),
                  Text(
                    [
                      if (k.author.isNotEmpty) k.author,
                      if (k.chapters > 0) 'built from ${k.chapters} ${k.chapters == 1 ? 'chapter' : 'chapters'}',
                    ].join(' · '),
                    style: Skin.meta(context),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Delete this memory',
              icon: Icon(Icons.delete_outline_rounded, color: Skin.inkSoftOn(context)),
              onPressed: () => unawaited(_deleteKept(k)),
            ),
          ],
        ),
      );

  /// New memory: a book picked, then started as from its page.
  Future<void> _newMemory() async {
    final store = MemoryService.instance.library;
    if (store == null) return;
    final book = await pickBookForMemory(context, store);
    if (book == null || !mounted) return;
    await startMemory(context, book.id);
    if (!mounted) return;
    _load();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookMemoryScreen(bookId: book.id, bookTitle: book.title),
    ));
    _load();
  }

  Widget _bookRow(BuildContext context, ({String id, String title, String author}) b, {String? number}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The book first, plainly its own: its name, then its memory.
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => BookMemoryScreen(bookId: b.id, bookTitle: b.title),
            )),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 40,
                    decoration: BoxDecoration(color: Skin.accentOf(context), borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (number != null) Text(number.toUpperCase(), style: Skin.meta(context, size: 10.5)),
                        Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 20)),
                        if (b.author.isNotEmpty) Text(b.author, style: Skin.meta(context)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: Skin.inkOn(context).withValues(alpha: 0.5)),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.s),
          BookMemorySection(bookId: b.id, bookTitle: b.title, secret: false),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final books = _books;
    final byId = {for (final b in books ?? const <({String id, String title, String author})>[]) b.id: b};
    // A series shows once, as a card of its books; the rest one by one.
    final series = [
      for (final s in SeriesStore.instance.all)
        if (s.books.any(byId.containsKey)) s,
    ];
    final inSeries = {for (final s in series) ...s.books};
    final single = [for (final b in books ?? const <({String id, String title, String author})>[]) if (!inSeries.contains(b.id)) b];
    final items = <Widget>[
      for (final s in series) _SeriesCard(series: s, books: byId),
      for (final b in single) _bookRow(context, b),
      // Books removed with their memory kept: theirs again if added again.
      if (_kept.isNotEmpty)
        Column(
          key: const Key('kept-memories'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle('From removed books'),
            const SizedBox(height: Gap.xs),
            Text(
              'Kept when the book was removed. Add the same book again and its memory is back, as it was.',
              style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
            ),
            const SizedBox(height: Gap.s),
            for (final k in _kept) _keptRow(context, k),
          ],
        ),
    ];
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Named as the button that opens it ("Book memories" in AI chat).
              ScreenTopBar(title: 'Book memories', onBack: () => Navigator.of(context).maybePop()),
              if (AiRing.instance.hasKeys)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => unawaited(_newMemory()),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('New memory'),
                    ),
                  ),
                ),
              Expanded(
                child: books == null
                    ? const SizedBox.shrink()
                    : books.isEmpty && _kept.isEmpty
                        ? EmptyState(
                            icon: Icons.auto_awesome_outlined,
                            title: 'No memories yet',
                            body: AiRing.instance.hasKeys
                                ? 'Tap New memory and pick a book, or tap Memory on a book\'s page: the AI reads it '
                                    'once, chapter by chapter, and remembers who is who and what happened.'
                                : 'Add a key in AI settings first. Then, from a book\'s page, the AI reads it once and remembers '
                                    'who is who and what happened.',
                            // The same way on as AI chat's own empty page.
                            action: AiRing.instance.hasKeys
                                ? null
                                : FilledButton.icon(
                                    onPressed: () async {
                                      await Navigator.of(context)
                                          .push(MaterialPageRoute<void>(builder: (_) => const AiScreen()));
                                      if (mounted) setState(() {});
                                    },
                                    icon: const Icon(Icons.settings_outlined),
                                    label: const Text('Open AI settings'),
                                  ),
                          )
                        : ListView(
                            padding: EdgeInsets.fromLTRB(
                                Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                            children: [
                              for (final (i, w) in items.indexed) ...[
                                if (i > 0)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: Gap.l),
                                    child: Divider(height: 1, color: Skin.inkOn(context).withValues(alpha: 0.14)),
                                  ),
                                w,
                              ],
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

/// A series on the Memory screen: its name and books in order, how far
/// each is built; a tap opens the series' memory (every book together, or
/// one at a time).
class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.series, required this.books});

  final MemorySeries series;
  final Map<String, ({String id, String title, String author})> books;

  @override
  Widget build(BuildContext context) {
    final service = MemoryService.instance;
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: BorderRadius.circular(Radii.row + 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row + 4),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => SeriesMemoryScreen(seriesId: series.id))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SERIES · ${series.books.length} BOOKS', style: Skin.meta(context, size: 10.5)),
                    Text(series.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 20)),
                    const SizedBox(height: Gap.xs),
                    for (final (i, id) in series.books.indexed)
                      ValueListenableBuilder<BookMemoryState>(
                        valueListenable: service.stateOf(id),
                        builder: (context, st, _) => Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Book ${i + 1} · ${books[id]?.title ?? 'not in the library'} · '
                            '${!st.exists || st.noted == 0 ? 'no memory yet' : 'built to chapter ${st.noted}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Skin.inkSoftOn(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A web novel's chapters, for its memory: how many are on the phone and
/// the space they take; Download all, its progress and failures (Try
/// again); and, once the memory has read them, Free up space (the memory
/// keeps its own copy of their words, and a chapter is fetched again when
/// it is opened to read). Nothing for a book that is not a web novel.
class _ChaptersBlock extends StatefulWidget {
  const _ChaptersBlock({required this.bookId, required this.service, required this.memory});

  final String bookId;
  final MemoryService service;

  /// The memory's state: when it changes, the counts are read again.
  final BookMemoryState memory;

  @override
  State<_ChaptersBlock> createState() => _ChaptersBlockState();
}

class _ChaptersBlockState extends State<_ChaptersBlock> {
  ({int total, int onPhone, int bytes, int noted})? _c;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    DownloadQueue.instance.changes.addListener(_changed);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_ChaptersBlock old) {
    super.didUpdateWidget(old);
    if (old.memory.noted != widget.memory.noted || old.memory.indexed != widget.memory.indexed) unawaited(_load());
  }

  @override
  void dispose() {
    DownloadQueue.instance.changes.removeListener(_changed);
    super.dispose();
  }

  Timer? _soon;
  void _changed() {
    _soon ??= Timer(const Duration(seconds: 2), () {
      _soon = null;
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final c = await widget.service.chaptersOf(widget.bookId);
    if (mounted) setState(() => _c = c);
  }

  Future<void> _downloadAll() async {
    setState(() => _busy = true);
    final n = await widget.service.downloadAll(widget.bookId);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context,
        n == 0 ? 'Every chapter is on the phone or on its way.' : '$n chapters are on their way, one at a time.');
    // They join the memory as they come; it is built as they do.
    unawaited(widget.service.build(widget.bookId));
    await _load();
  }

  Future<void> _free() async {
    final c = _c;
    if (c == null) return;
    final read = math.min(c.onPhone, c.noted);
    final sure = await confirm(
      context,
      title: 'Free up space?',
      body: 'Deletes only the downloaded chapter files the memory has already read '
          '(${read == 1 ? 'one chapter' : 'about $read chapters'}). '
          'The memory you built is not touched: its notes, cast, graph and its own copy of the words stay, '
          "so Talk, search and Who's who go on working. Your place and journal stay too.\n\n"
          'A chapter you open to read is downloaded again from the site. Chapters the memory has not read yet '
          'stay on the phone.',
      action: 'Free up space',
    );
    if (!sure) return;
    setState(() => _busy = true);
    final r = await widget.service.freeSpace(widget.bookId);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(
        context,
        r.chapters == 0
            ? 'Nothing to free yet.'
            : 'Freed ${sizeLabel(r.bytes)}: ${r.chapters} chapter files. The memory is as it was.');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return const SizedBox.shrink();
    final q = DownloadQueue.instance.of(widget.bookId);
    final missing = c.total - c.onPhone;
    final readOnPhone = math.min(c.onPhone, c.noted);
    final line = [
      '${c.onPhone} of ${c.total} chapters on the phone · ${sizeLabel(c.bytes)}',
      if (q != null && q.waiting > 0)
        'Downloading: ${q.waiting} to go${q.resting ? ' (the site asked for a rest)' : ''}',
      if (q != null && q.failed > 0) '${q.failed} could not be downloaded${q.problem == null ? '' : ': ${q.problem}'}',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: Gap.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Chapters for the memory'),
          const SizedBox(height: Gap.xs),
          for (final l in line)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(l, style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))),
            ),
          const SizedBox(height: Gap.s),
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              if (missing > 0 && (q == null || q.waiting == 0))
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_downloadAll()),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text('Download all ($missing)'),
                ),
              if (q != null && q.failed > 0)
                OutlinedButton.icon(
                  onPressed: () => unawaited(DownloadQueue.instance.retry(widget.bookId)),
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  label: const Text('Try again'),
                ),
              if (readOnPhone > 0 && c.bytes > 0)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_free()),
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('Free up space'),
                ),
            ],
          ),
          if (readOnPhone > 0 && c.bytes > 0)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Text(
                'Free up space deletes the chapter files the memory has read. The memory itself stays.',
                style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Carries on from Book 1", under a memory that does: and when that
/// book's memory has changed since, a button to bring it over again.
class _FollowsLine extends StatefulWidget {
  const _FollowsLine({super.key, required this.service, required this.bookId, required this.onChange});

  final MemoryService service;
  final String bookId;
  final VoidCallback onChange;

  @override
  State<_FollowsLine> createState() => _FollowsLineState();
}

class _FollowsLineState extends State<_FollowsLine> {
  List<FollowedBook> _books = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final b = await widget.service.followedBy(widget.bookId);
    if (mounted) setState(() => _books = b);
  }

  Future<void> _again() async {
    setState(() => _busy = true);
    final n = await widget.service.followOnFromAll(widget.bookId, [for (final b in _books) b.id]);
    if (!mounted) return;
    showSnack(context, 'Brought over again: $n people, places and things.');
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_books.isEmpty) return const SizedBox.shrink();
    final changed = _books.where((b) => b.changed).toList();
    return Padding(
      padding: const EdgeInsets.only(top: Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: widget.onChange,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.link_rounded, size: 18, color: Skin.accentInkOf(context)),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(
                      'Carries on from ${_books.map((b) => b.title).join(', then ')}',
                      style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkOn(context)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (changed.isNotEmpty)
            TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_again()),
              icon: const Icon(Icons.sync_rounded, size: 18),
              label: Text(changed.length == 1 && _books.length == 1
                  ? "${changed.first.title}'s memory has changed: bring it over again"
                  : 'An earlier book has changed: bring them over again'),
            ),
        ],
      ),
    );
  }
}

/// Which books this one carries on from: ticked, in the series' order.
class _FollowsSheet extends StatefulWidget {
  const _FollowsSheet({required this.books, required this.linked});

  final List<LibraryEntry> books;
  final Set<String> linked;

  @override
  State<_FollowsSheet> createState() => _FollowsSheetState();
}

class _FollowsSheetState extends State<_FollowsSheet> {
  late final Set<String> _on = {...widget.linked};

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Carries on from',
                subtitle: 'The books before this one: their memories come over, earliest first'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final b in widget.books)
                    CheckboxListTile(
                      value: _on.contains(b.id),
                      title: Text(b.title),
                      subtitle: b.series == null
                          ? null
                          : Text('${b.series}${b.seriesIndex == null ? '' : ' ${_number(b.seriesIndex!)}'}',
                              style: Skin.meta(context)),
                      onChanged: (v) => setState(() => v == true ? _on.add(b.id) : _on.remove(b.id)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_on),
                child: Text(_on.isEmpty && widget.linked.isNotEmpty ? 'Carry on from none' : 'Carry on from these'),
              ),
            ),
          ],
        ),
      );

  static String _number(double n) => n == n.roundToDouble() ? '${n.round()}' : '$n';
}
