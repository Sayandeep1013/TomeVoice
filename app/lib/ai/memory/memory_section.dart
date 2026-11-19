import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import '../../theme.dart';
import '../../ui.dart';
import '../ai_keys.dart';
import '../ai_screen.dart' show tokenCount, wakeTime;
import '../../backup_flow.dart' show sizeLabel;
import '../../download_queue.dart';
import '../../library_store.dart' show LibraryEntry;
import '../talk/talk_sheet.dart' show showTalk;
import 'graph_screen.dart';
import 'hand_off.dart';
import 'memory_builder.dart';
import 'memory_service.dart';
import 'theories_screen.dart';
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

  Future<void> _build() async {
    // A web novel's chapters not on the phone: fetched first, if wanted.
    final missing = await _service.missingChapters(widget.bookId);
    if (missing.isNotEmpty && mounted) {
      final fetch = await showModalBottomSheet<bool>(
        context: context,
        sheetAnimationStyle: sheetMotion(context),
        useSafeArea: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(
                    '${missing.length} ${missing.length == 1 ? 'chapter is' : 'chapters are'} not on the phone'),
                Text(
                  'The memory is made from the chapters on the phone. Download the rest up to where you are, and '
                  'they join the memory as they come: one at a time, gently on the site'
                  '${missing.length > 200 ? ', so this many takes some hours' : ''}.',
                  style:
                      Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
                ),
                const SizedBox(height: Gap.l),
                FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Download them, and build')),
                const SizedBox(height: Gap.s),
                OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Build with what is here'),
                ),
              ],
            ),
          ),
        ),
      );
      if (fetch == null || !mounted) return;
      if (fetch) await _service.download(widget.bookId, missing);
    }
    if (!mounted) return;
    // Begun before: the reader agreed to it then; it simply goes on.
    if (_service.stateOf(widget.bookId).value.noted > 0) {
      unawaited(_service.build(widget.bookId));
      return;
    }
    // The book before it in its series has a memory: offered, once, to
    // carry on from it.
    final earlier = await _service.earlierInSeries(widget.bookId);
    final linked = earlier == null ? const <FollowedBook>[] : await _service.followedBy(widget.bookId);
    if (!mounted) return;
    if (earlier != null && linked.isEmpty) {
      final carry = await showModalBottomSheet<bool>(
        context: context,
        sheetAnimationStyle: sheetMotion(context),
        useSafeArea: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader('Carry on from ${earlier.title}?', subtitle: 'The book before this one in its series'),
                Text(
                  'Its memory comes over: the people, places and things as they stood, the threads left open and '
                  'the story so far. This book builds on from them, and Talk can look back into it.',
                  style:
                      Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
                ),
                const SizedBox(height: Gap.l),
                FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Carry on from it')),
                const SizedBox(height: Gap.s),
                OutlinedButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Start fresh')),
              ],
            ),
          ),
        ),
      );
      if (carry == null || !mounted) return;
      if (carry) {
        final n = await _service.followOnFromAll(widget.bookId, [earlier.id]);
        if (mounted) showSnack(context, '$n people, places and things carried over from ${earlier.title}.');
      }
      if (!mounted) return;
    }
    // The sheet at once; what it would take, counted meanwhile.
    final counting = _service.estimate(widget.bookId);
    final keys = AiRing.instance.forJob(AiJob.builder);
    final go = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('Build the memory', subtitle: 'Each chapter is read once, ever'),
              FutureBuilder<BuildEstimate>(
                future: counting,
                builder: (context, snap) {
                  final est = snap.data;
                  return Text(
                    est == null
                        ? 'Counting what it would take…'
                        : est.chapters == 0
                            ? 'Every chapter on the phone is read already.'
                            : '${est.chapters} ${est.chapters == 1 ? 'chapter' : 'chapters'} to read, in about '
                                '${est.calls} ${est.calls == 1 ? 'call' : 'calls'}: some ${tokenCount(est.tokens)} '
                                'tokens, with ${keys.map((k) => k.label).join(', then ')}. '
                                'It goes on while TomeVoice is open; when a key has used its quota for now, the next '
                                'takes over, and when all of them have, it waits for them.',
                    style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                        .copyWith(height: 1.4),
                  );
                },
              ),
              const SizedBox(height: Gap.l),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Build')),
            ],
          ),
        ),
      ),
    );
    if (go == true) unawaited(_service.build(widget.bookId));
  }

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
  Future<void> _followOn() async {
    final books = [
      for (final b in await _service.booksWithMemory())
        if (b.id != widget.bookId) b,
    ]..sort((a, b) {
        final s = (a.series ?? '').compareTo(b.series ?? '');
        return s != 0 ? s : (a.seriesIndex ?? 0).compareTo(b.seriesIndex ?? 0);
      });
    final linked = {for (final f in await _service.followedBy(widget.bookId)) f.id};
    if (!mounted) return;
    if (books.isEmpty) {
      showSnack(context, 'Build the memory of the book before this one first, then link them here.');
      return;
    }
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => _FollowsSheet(books: books, linked: linked),
    );
    if (picked == null || !mounted) return;
    final order = [for (final b in books) if (picked.contains(b.id)) b.id];
    final n = await _service.followOnFromAll(widget.bookId, order);
    if (mounted) {
      showSnack(
          context,
          order.isEmpty
              ? 'It no longer carries on from another book.'
              : '$n people, places and things carried over. Building goes on from them.');
    }
  }

  Future<void> _forget() async {
    final sure = await confirm(context,
        title: 'Forget what it remembers?',
        body: 'The notes, the cast and the word index of this book are deleted. Your journal stays.',
        action: 'Forget');
    if (sure) await _service.forget(widget.bookId);
  }

  String _line(BookMemoryState s) {
    final b = s.build;
    final ix = s.indexing;
    if (ix != null) return ix.total == 0 ? 'Indexing its words…' : 'Indexing its words · ${ix.done} of ${ix.total}';
    switch (b.phase) {
      case BuildPhase.running:
        return 'Building · ${s.noted} of ${s.indexed} chapters';
      case BuildPhase.resting:
        return 'Waiting: every key has used its quota for now. Goes on at ${wakeTime(b.until!)}.';
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
                    if (v == 'follows') unawaited(_followOn());
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
                      const PopupMenuItem(value: 'follows', child: Text('Carries on from another book…')),
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
                onChange: () => unawaited(_followOn()),
              ),
            if (!s.private) ...[
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
                  if (s.exists && s.noted > 0)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_openTheories()),
                      icon: const Icon(Icons.lightbulb_outline_rounded, size: 18),
                      label: const Text('Theories'),
                    ),
                  if (s.entities > 0) ...[
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_openWho()),
                      icon: const Icon(Icons.groups_outlined, size: 18),
                      label: const Text("Who's who"),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_openGraph()),
                      icon: const Icon(Icons.hub_outlined, size: 18),
                      label: const Text('Graph'),
                    ),
                  ],
                  if (s.exists && s.noted > 0)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_handOff()),
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: const Text('Talk elsewhere'),
                    ),
                ],
              ),
              if (s.skipped > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: TextButton.icon(
                    onPressed: () => unawaited(_service.retrySkipped(widget.bookId)),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                    label: Text('Try the ${s.skipped} passed-over ${s.skipped == 1 ? 'chapter' : 'chapters'} again'),
                  ),
                ),
              _ChaptersBlock(bookId: widget.bookId, service: _service, memory: s),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.guard,
                onChanged: (v) => unawaited(_service.setGuard(widget.bookId, v)),
                title: Text('Spoiler guard',
                    style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                subtitle: Text(
                  s.guard ? 'The AI keeps to what you have read.' : 'Off: the AI may use all it remembers of the book.',
                  style: Skin.meta(context),
                ),
              ),
            ],
          ],
        );
      },
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
          decoration: BoxDecoration(gradient: Skin.ground(context)),
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
    unawaited(MemoryService.instance.booksWithMemory().then((b) {
      if (mounted) setState(() => _books = [for (final e in b) (id: e.id, title: e.title, author: e.authors.join(', '))]);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Memory', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: books == null
                    ? const SizedBox.shrink()
                    : books.isEmpty
                        ? EmptyState(
                            icon: Icons.auto_awesome_outlined,
                            title: 'No memories yet',
                            body: AiRing.instance.hasKeys
                                ? "Open a book and tap Memory on its page: the AI reads it once, chapter by chapter, "
                                    'and remembers who is who and what happened.'
                                : 'Add a key in AI first. Then, from a book\'s page, the AI reads it once and remembers '
                                    'who is who and what happened.',
                          )
                        : ListView(
                            padding: EdgeInsets.fromLTRB(
                                Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                            children: [
                              for (final (i, b) in books.indexed) ...[
                                if (i > 0)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: Gap.l),
                                    child: Divider(height: 1, color: Skin.inkOn(context).withValues(alpha: 0.14)),
                                  ),
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
                                          decoration: BoxDecoration(
                                            color: Skin.accentOf(context),
                                            borderRadius: BorderRadius.circular(2),
                                          ),
                                        ),
                                        const SizedBox(width: Gap.m),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(b.title,
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: Skin.title(context, size: 20)),
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

/// A web novel's chapters, for its memory: how many are on the phone and
/// the space they take; Download all, its progress and failures (Try
/// again); and, once the memory has read them, Free the space (the memory
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
    final sure = await confirm(
      context,
      title: 'Free the space?',
      body: 'The chapters the memory has already read are taken off the phone. The memory keeps its own copy of '
          "their words, so Talk, search and Who's who go on working, and any chapter you open to read is "
          'fetched again from the site. Chapters it has not read yet stay.',
      action: 'Free the space',
    );
    if (!sure) return;
    setState(() => _busy = true);
    final r = await widget.service.freeSpace(widget.bookId);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(
        context, r.chapters == 0 ? 'Nothing to free yet.' : 'Freed ${sizeLabel(r.bytes)}: ${r.chapters} chapters.');
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
                  label: const Text('Free the space'),
                ),
            ],
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
