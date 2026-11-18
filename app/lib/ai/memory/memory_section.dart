import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../ai_keys.dart';
import '../ai_screen.dart' show tokenCount, wakeTime;
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
  });

  final String bookId;
  final String bookTitle;
  final bool compact;

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
                SheetHeader('${missing.length} ${missing.length == 1 ? 'chapter is' : 'chapters are'} not on the phone'),
                Text(
                  'The memory is made from the chapters on the phone. Download the rest up to where you are, and '
                  'they join the memory as they come: one at a time, gently on the site'
                  '${missing.length > 200 ? ', so this many takes some hours' : ''}.',
                  style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
                ),
                const SizedBox(height: Gap.l),
                FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Download them, and build')),
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
    final est = await _service.estimate(widget.bookId);
    if (!mounted) return;
    if (est.chapters == 0) {
      unawaited(_service.build(widget.bookId));
      return;
    }
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
              Text(
                '${est.chapters} ${est.chapters == 1 ? 'chapter' : 'chapters'} to read, in about '
                '${est.calls} ${est.calls == 1 ? 'call' : 'calls'}: some ${tokenCount(est.tokens)} tokens, '
                'with ${keys.map((k) => k.label).join(', then ')}. '
                'It goes on while TomeVoice is open; when a key has used its quota for now, the next takes '
                'over, and when all of them have, it waits for them.',
                style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
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
          WhosWhoScreen(bookTitle: widget.bookTitle, memoryPath: _service.pathOf(widget.bookId), line: line),
    ));
  }

  Future<void> _openGraph() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          MemoryGraphScreen(bookTitle: widget.bookTitle, memoryPath: _service.pathOf(widget.bookId), line: line),
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

  /// The book before this one in a series, picked from the books with a
  /// memory: what it remembers carried over.
  Future<void> _followOn() async {
    final books = [
      for (final b in await _service.booksWithMemory())
        if (b.id != widget.bookId) b,
    ];
    if (!mounted) return;
    if (books.isEmpty) {
      showSnack(context, 'Build the memory of the book before this one first, then link them here.');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Follows on from', subtitle: 'The book before this one in its series'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final b in books)
                    ListTile(title: Text(b.title), onTap: () => Navigator.of(ctx).pop(b.id)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final n = await _service.followOnFrom(widget.bookId, picked);
    if (mounted) showSnack(context, '$n people, places and things carried over. Building goes on from them.');
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
    if (s.noted == 0) return 'Its words are indexed: Find where… works. No notes yet.';
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
                builder: (_) => BookMemoryScreen(bookId: widget.bookId, bookTitle: widget.bookTitle),
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
                          Text('Memory',
                              style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
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
                        const PopupMenuItem(value: 'follows', child: Text('Follows on from another book…')),
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
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.guard,
                onChanged: (v) => unawaited(_service.setGuard(widget.bookId, v)),
                title: Text('Spoiler guard',
                    style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                subtitle: Text(
                  s.guard
                      ? 'The AI keeps to what you have read.'
                      : 'Off: the AI may use all it remembers of the book.',
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
  const BookMemoryScreen({super.key, required this.bookId, required this.bookTitle});

  final String bookId;
  final String bookTitle;

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
                    padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      BookMemorySection(bookId: bookId, bookTitle: bookTitle, secret: false, compact: false),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Main menu > Memory: every book with a memory, how far it is built; a
/// tap opens that book's memory.
class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  List<({String id, String title})>? _books;

  @override
  void initState() {
    super.initState();
    unawaited(MemoryService.instance.booksWithMemory().then((b) {
      if (mounted) setState(() => _books = [for (final e in b) (id: e.id, title: e.title)]);
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
                              for (final b in books)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: Gap.s),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4, bottom: 4),
                                        child: Text(b.title, style: Skin.title(context, size: 16)),
                                      ),
                                      BookMemorySection(bookId: b.id, bookTitle: b.title, secret: false),
                                    ],
                                  ),
                                ),
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
