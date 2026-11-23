import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../library_store.dart' show LibraryEntry, LibraryStore;
import '../../prefs.dart' show ListeningPrefs;
import '../../theme.dart';
import '../../ui.dart';
import '../ai_consent.dart';
import '../ai_keys.dart';
import '../ai_screen.dart' show tokenCount;
import 'memory_builder.dart' show BuildEstimate, anyKey, keptKey;
import 'memory_db.dart';
import 'memory_service.dart';
import 'series_store.dart';

/// Starting a book's memory, from its page or from the Memory screen's New
/// memory: the AI's consent; a web novel's missing chapters; whether it
/// carries on from another book (a series, its earlier books built first);
/// what it will take, how far it goes and whether new chapters join it by
/// themselves; then building, in order. A memory built before: Go on
/// building (chapters left before where it stops) goes on as it was;
/// Build more chapters asks how far.
Future<void> startMemory(BuildContext context, String bookId, {MemoryService? service}) async {
  final memory = service ?? MemoryService.instance;
  if (!await ensureAiConsent(context) || !context.mounted) return;
  // A web novel's chapters not on the phone: fetched first, if wanted.
  final missing = await memory.missingChapters(bookId);
  if (missing.isNotEmpty && context.mounted) {
    final fetch = await _choice(
      context,
      title: '${missing.length} ${missing.length == 1 ? 'chapter is' : 'chapters are'} not on the phone',
      body: 'The memory is made from the chapters on the phone. Download the rest up to where you are, and they '
          'join the memory as they come: one at a time, gently on the site'
          '${missing.length > 200 ? ', so this many takes some hours' : ''}.',
      yes: 'Download them, and build',
      no: 'Build with what is here',
    );
    if (fetch == null || !context.mounted) return;
    if (fetch) await memory.download(bookId, missing);
  }
  if (!context.mounted) return;
  final keys = AiRing.instance.forJob(AiJob.builder);
  // Begun before: the reader agreed to it then. Chapters left before where
  // it stops: it goes on (with more than one key, which of them may build
  // it is asked again). None: how far to go now is asked.
  final was = memory.stateOf(bookId).value;
  if (was.noted > 0) {
    final goingOn = was.leftUnder > 0;
    if (goingOn && keys.length <= 1) {
      unawaited(memory.buildInOrder([bookId]));
      return;
    }
    final choice = await _confirmBuild(context, memory,
        queue: [bookId], title: goingOn ? 'Go on building' : 'Build more chapters', keys: keys);
    if (choice == null) return;
    await _apply(memory, bookId, choice);
    await memory.setBuildKeys(bookId, choice.keys);
    unawaited(memory.buildInOrder([bookId]));
    return;
  }
  final store = memory.library;
  if (store == null) return;
  final all = [for (final e in await store.list()) if (!store.isSecret(e.id)) e];
  if (!context.mounted) return;
  final me = all.where((e) => e.id == bookId).firstOrNull;
  // Does it carry on from another book? Asked unless it is in a series
  // already, or there is no other book to carry on from.
  if (me != null && SeriesStore.instance.ofBook(bookId) == null && all.length > 1) {
    final earlier = await showModalBottomSheet<_Carry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      builder: (_) => _CarriesOnSheet(book: me, books: all, store: store),
    );
    if (earlier == null || !context.mounted) return;
    if (earlier.id != null) {
      final from = all.firstWhere((e) => e.id == earlier.id);
      final name = (from.series?.trim().isNotEmpty ?? false) ? from.series!.trim() : from.title;
      await SeriesStore.instance.carryOn(bookId, earlier: from.id, name: name);
    }
  }
  if (!context.mounted) return;
  // The earlier books of its series with no memory yet are built first.
  final series = SeriesStore.instance.ofBook(bookId);
  final first = [
    for (final b in series?.before(bookId) ?? const <String>[])
      if (!MemoryDb.existsIn(store.bookDir(b)) || memory.stateOf(b).value.noted == 0) b,
  ];
  final queue = [...first, bookId];
  final titles = {for (final e in all) e.id: e.title};
  final choice = await _confirmBuild(
    context,
    memory,
    queue: queue,
    title: first.isEmpty ? 'Build the memory' : 'Build the series',
    keys: keys,
    before: first.isEmpty
        ? null
        : 'First ${_listed([for (final b in first) titles[b] ?? 'an earlier book'])}, which have no memory '
            'yet, then ${titles[bookId] ?? 'this book'}: each knows the people of the books before it.',
  );
  if (choice == null) return;
  for (final id in queue) {
    await memory.setBuildKeys(id, choice.keys);
  }
  await _apply(memory, bookId, choice);
  unawaited(memory.buildInOrder(queue));
}

/// What the Build sheet answered: which keys may build it ([anyKey], or
/// `only:<key id>`), how far ([far], with the number typed), and whether
/// its new chapters join it by themselves.
class BuildChoice {
  const BuildChoice({required this.keys, required this.far, required this.number, required this.auto});

  final String keys;
  final BuildFar far;

  /// The chapter to stop at (1-based) for [BuildFar.upTo]; how many
  /// chapters for [BuildFar.next].
  final int number;
  final bool auto;
}

/// How far a build goes: every chapter on the phone, up to a chapter, or
/// the next so many.
enum BuildFar { all, upTo, next }

/// Where [choice] stops (0-based; null: every chapter), kept with the
/// book's memory, with whether its new chapters join it by themselves.
Future<void> _apply(MemoryService memory, String bookId, BuildChoice choice) async {
  final to = await stopFor(memory, bookId, choice.far, choice.number);
  await memory.setBuildTo(bookId, to);
  await memory.setAutoBuild(bookId, choice.auto);
}

/// The last chapter (0-based) a build that goes [far] stops at; null for
/// every chapter. The next [number] when none are left: where it is.
Future<int?> stopFor(MemoryService memory, String bookId, BuildFar far, int number) async => switch (far) {
      BuildFar.all => null,
      BuildFar.upTo => math.max(0, number - 1),
      BuildFar.next => await memory.nthLeftOf(bookId, number) ?? memory.stateOf(bookId).value.buildTo,
    };

/// The Build sheet: what building [queue] would take, how far the book
/// asked for goes (its series' earlier books are built whole), whether its
/// new chapters join it by themselves, and, with more than one key, which
/// keys may do it. Null when the sheet was closed.
Future<BuildChoice?> _confirmBuild(
  BuildContext context,
  MemoryService memory, {
  required List<String> queue,
  required String title,
  required List<AiKey> keys,
  String? before,
}) async {
  final bookId = queue.last;
  final s = memory.stateOf(bookId).value;
  final here = await memory.hereOf(bookId);
  if (!context.mounted) return null;
  // The earlier books', counted once; this book's, for each way of how far.
  final earlier = () async {
    var total = const BuildEstimate(chapters: 0, inputTokens: 0, outputTokens: 0, calls: 0);
    for (final id in queue.take(queue.length - 1)) {
      total = _plus(total, await memory.estimate(id));
    }
    return total;
  }();
  Future<BuildEstimate> counting(BuildFar far, int number) async {
    final prior = await earlier;
    final to = await stopFor(memory, bookId, far, number);
    final mine = far == BuildFar.all ? await memory.estimate(bookId, all: true) : await memory.estimate(bookId, to: to);
    return _plus(prior, mine);
  }

  // How far, as it was: every chapter; where it stops while chapters are
  // left before it; the next ten once it is there.
  final far = s.buildTo == null
      ? BuildFar.all
      : s.leftUnder > 0
          ? BuildFar.upTo
          : BuildFar.next;
  final last = s.lastNoted ?? -1;
  final upTo = s.buildTo != null && s.leftUnder > 0 ? s.buildTo! + 1 : (here > last ? here + 1 : last + 11);
  return showModalBottomSheet<BuildChoice>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    builder: (_) => _BuildSheet(
      title: title,
      before: before,
      counting: counting,
      keys: keys,
      setting: s.buildKeys,
      far: far,
      upTo: upTo,
      auto: s.noted == 0 && !s.begun ? (ListeningPrefs.loaded?.aiAutoNew ?? true) : s.autoBuild,
      firstLeft: () => memory.nthLeftOf(bookId, 1),
      stopAt: (n) => stopFor(memory, bookId, BuildFar.next, n),
    ),
  );
}

BuildEstimate _plus(BuildEstimate a, BuildEstimate b) => BuildEstimate(
      chapters: a.chapters + b.chapters,
      inputTokens: a.inputTokens + b.inputTokens,
      outputTokens: a.outputTokens + b.outputTokens,
      calls: a.calls + b.calls,
    );

class _BuildSheet extends StatefulWidget {
  const _BuildSheet({
    required this.title,
    required this.counting,
    required this.keys,
    required this.far,
    required this.upTo,
    required this.auto,
    required this.firstLeft,
    required this.stopAt,
    this.before,
    this.setting,
  });

  final String title;
  final String? before;
  final Future<BuildEstimate> Function(BuildFar far, int number) counting;
  final List<AiKey> keys;

  /// How the book was last built ([buildKeysMeta]).
  final String? setting;

  /// How far, as the sheet opens, and the chapter offered for Up to.
  final BuildFar far;
  final int upTo;
  final bool auto;

  /// The first chapter (0-based) not in the memory yet, and where the next
  /// so many end.
  final Future<int?> Function() firstLeft;
  final Future<int?> Function(int n) stopAt;

  @override
  State<_BuildSheet> createState() => _BuildSheetState();
}

class _BuildSheetState extends State<_BuildSheet> {
  /// Any key may take over; otherwise only [_first].
  late bool _any = widget.setting == anyKey;

  /// The one key it keeps to: the key it kept to before, or the first.
  late final AiKey? _first = keptKey(widget.setting == anyKey ? null : widget.setting, widget.keys);

  late BuildFar _far = widget.far;
  late final _upTo = TextEditingController(text: '${widget.upTo}');
  final _next = TextEditingController(text: '10');
  late bool _auto = widget.auto;

  /// What it would take, for the way chosen; counted again a moment after
  /// a number is typed.
  late Future<BuildEstimate> _count = widget.counting(_far, _number);
  Timer? _typed;

  /// Every chapter's count, for its line; the first chapter left, and where
  /// the next so many end, for theirs.
  late final Future<BuildEstimate> _allCount = widget.far == BuildFar.all ? _count : widget.counting(BuildFar.all, 0);
  late final Future<int?> _firstLeft = widget.firstLeft();
  Future<int?>? _nextEnd;

  int get _number {
    final c = _far == BuildFar.next ? _next : _upTo;
    return math.max(1, int.tryParse(c.text.trim()) ?? 1);
  }

  /// The way chosen, or the number typed, changed: counted again.
  void _recount({bool soon = false}) {
    _typed?.cancel();
    void go() {
      if (!mounted) return;
      setState(() {
        _count = widget.counting(_far, _number);
        if (_far == BuildFar.next) _nextEnd = widget.stopAt(_number);
      });
    }

    if (soon) {
      _typed = Timer(const Duration(milliseconds: 400), go);
    } else {
      go();
    }
  }

  void _pick(BuildFar far) {
    if (_far == far) return;
    _far = far;
    _recount();
  }

  @override
  void initState() {
    super.initState();
    if (_far == BuildFar.next) _nextEnd = widget.stopAt(_number);
  }

  @override
  void dispose() {
    _typed?.cancel();
    _upTo.dispose();
    _next.dispose();
    super.dispose();
  }

  /// A number typed in a way's line: choosing that way.
  Widget _field(TextEditingController c, BuildFar far, String label) => SizedBox(
        width: 76,
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.s),
            border: const OutlineInputBorder(),
            semanticCounterText: label,
          ),
          onTap: () => _pick(far),
          onChanged: (_) {
            setState(() => _far = far);
            _recount(soon: true);
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final keys = widget.keys;
    final first = _first;
    final next = [for (final k in keys) if (k.id != first?.id) k];
    final soft = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(widget.title, subtitle: 'Each chapter is read once, ever'),
            if (widget.before != null) ...[
              Text(
                widget.before!,
                style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkOn(context)).copyWith(height: 1.4),
              ),
              const SizedBox(height: Gap.s),
            ],
            const Eyebrow('How far'),
            const SizedBox(height: Gap.s),
            FutureBuilder<BuildEstimate>(
              future: _allCount,
              builder: (context, snap) => _KeyChoice(
                chosen: _far == BuildFar.all,
                title: 'Every chapter on the phone',
                body: snap.hasError
                    ? 'Could not be counted.'
                    : snap.data == null
                        ? 'Counting…'
                        : snap.data!.chapters == 0
                            ? 'Every chapter on the phone is in it already.'
                            : '${snap.data!.chapters} ${snap.data!.chapters == 1 ? 'chapter is' : 'chapters are'} '
                                'not in it yet.',
                onTap: () => _pick(BuildFar.all),
              ),
            ),
            const SizedBox(height: Gap.s),
            _KeyChoice(
              chosen: _far == BuildFar.upTo,
              title: 'Up to chapter',
              body: 'It stops there until you ask for more.',
              trailing: _field(_upTo, BuildFar.upTo, 'Chapter to stop at'),
              onTap: () => _pick(BuildFar.upTo),
            ),
            const SizedBox(height: Gap.s),
            FutureBuilder<List<int?>>(
              future: Future.wait([_firstLeft, _nextEnd ?? Future.value(null)]),
              builder: (context, snap) {
                final from = snap.data?[0], to = snap.data?[1];
                return _KeyChoice(
                  chosen: _far == BuildFar.next,
                  title: 'The next',
                  titleAfter: 'chapters',
                  body: from == null
                      ? 'Each chapter after where it has got to, in order.'
                      : to == null || _far != BuildFar.next
                          ? 'From chapter ${from + 1}, in order.'
                          : 'Chapters ${from + 1} to ${to + 1}, then it stops.',
                  trailing: _field(_next, BuildFar.next, 'How many chapters'),
                  onTap: () => _pick(BuildFar.next),
                );
              },
            ),
            const SizedBox(height: Gap.m),
            FutureBuilder<BuildEstimate>(
              future: _count,
              builder: (context, snap) {
                final est = snap.data;
                return Text(
                  snap.hasError
                      ? 'What it would take could not be counted (${snap.error}). Building still works.'
                      : est == null
                          ? 'Counting what it would take…'
                          : est.chapters == 0
                              ? (_far == BuildFar.all
                                  ? 'Every chapter on the phone is read already.'
                                  : 'Every chapter up to there is read already.')
                              : '${est.chapters} ${est.chapters == 1 ? 'chapter' : 'chapters'} to read, in about '
                                  '${est.calls} ${est.calls == 1 ? 'call' : 'calls'}: some ${tokenCount(est.tokens)} '
                                  'tokens. It goes on with TomeVoice behind other apps or the screen off.'
                                  '${keys.length == 1 ? ' When ${keys.single.label} has used its quota for now, it waits for it.' : ''}',
                  style: soft,
                );
              },
            ),
            const SizedBox(height: Gap.s),
            SwitchRow(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              title: 'Build new chapters by itself',
              subtitle: _auto
                  ? 'Chapters you download or add later join the memory as they come'
                      '${_far == BuildFar.all ? '' : ', up to where it stops'}.'
                  : 'Only when you tap Build: you choose when, and how far.',
              value: _auto,
              onChanged: (v) => setState(() => _auto = v),
            ),
            if (keys.length > 1 && first != null) ...[
              const SizedBox(height: Gap.m),
              const Eyebrow('Which key builds it'),
              const SizedBox(height: Gap.s),
              _KeyChoice(
                chosen: !_any,
                title: 'Only ${first.label}',
                body: 'If ${first.label} reaches its limit, the build waits, and asks you before any other key is used.',
                onTap: () => setState(() => _any = false),
              ),
              const SizedBox(height: Gap.s),
              _KeyChoice(
                chosen: _any,
                title: 'Let the next key take over',
                body: 'If ${first.label} reaches its limit, ${next.first.label} carries on'
                    '${next.length > 1 ? ', then the others in your Building list' : ''}. It may be a paid key.',
                onTap: () => setState(() => _any = true),
              ),
            ],
            const SizedBox(height: Gap.l),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(BuildChoice(
                keys: _any ? anyKey : 'only:${first?.id ?? ''}',
                far: _far,
                number: _number,
                auto: _auto,
              )),
              child: const Text('Build'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the Build sheet's choices (how far; which keys): what it is
/// called, with a number to type when it takes one, and in a line what it
/// means.
class _KeyChoice extends StatelessWidget {
  const _KeyChoice({
    required this.chosen,
    required this.title,
    required this.body,
    required this.onTap,
    this.trailing,
    this.titleAfter,
  });

  final bool chosen;
  final String title;
  final String body;
  final VoidCallback onTap;

  /// A number field after the title, and words after it ("The next [10]
  /// chapters").
  final Widget? trailing;
  final String? titleAfter;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context));
    return Semantics(
      selected: chosen,
      button: true,
      child: Material(
        color: chosen ? Skin.accentOf(context).withValues(alpha: 0.16) : Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row + 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.row + 4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.m, Gap.m),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  chosen ? Icons.check_circle_rounded : Icons.circle_outlined,
                  size: 22,
                  color: chosen ? Skin.accentInkOf(context) : Skin.inkSoftOn(context),
                ),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (trailing == null)
                        Text(title, style: titleStyle)
                      else
                        Wrap(
                          spacing: Gap.s,
                          runSpacing: Gap.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(title, style: titleStyle),
                            trailing!,
                            if (titleAfter != null) Text(titleAfter!, style: titleStyle),
                          ],
                        ),
                      const SizedBox(height: 2),
                      Text(body, style: Skin.meta(context)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A book's Memory menu > Add to a series…: the book just before it,
/// picked as when a memory starts; the series made or joined, and the
/// book's memory made to carry on from the books before it (their cast for
/// building, Talk's look back). Null when nothing was picked.
Future<void> carryOnFrom(BuildContext context, String bookId, {MemoryService? service}) async {
  final memory = service ?? MemoryService.instance;
  final store = memory.library;
  if (store == null) return;
  final all = [for (final e in await store.list()) if (!store.isSecret(e.id)) e];
  final me = all.where((e) => e.id == bookId).firstOrNull;
  if (me == null || all.length < 2 || !context.mounted) return;
  final earlier = await showModalBottomSheet<_Carry>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    builder: (_) => _CarriesOnSheet(book: me, books: all, store: store, fresh: 'Not part of a series'),
  );
  if (earlier == null || !context.mounted) return;
  if (earlier.id == null) {
    await SeriesStore.instance.remove(bookId);
    if (MemoryDb.existsIn(store.bookDir(bookId))) await memory.followOnFromAll(bookId, const []);
    if (context.mounted) showSnack(context, '${me.title} is in no series now. Its memory stays as it is.');
    return;
  }
  final from = all.firstWhere((e) => e.id == earlier.id);
  final name = SeriesStore.instance.ofBook(from.id)?.name ??
      ((from.series?.trim().isNotEmpty ?? false) ? from.series!.trim() : from.title);
  final series = await SeriesStore.instance.carryOn(bookId, earlier: from.id, name: name);
  final before = [for (final b in series.before(bookId)) if (MemoryDb.existsIn(store.bookDir(b))) b];
  if (MemoryDb.existsIn(store.bookDir(bookId)) && before.isNotEmpty) await memory.followOnFromAll(bookId, before);
  if (context.mounted) showSnack(context, '${me.title} is now Book ${series.indexOf(bookId) + 1} of ${series.name}.');
}

/// Books linked the old way ("Carries on from another book", before series)
/// made into series, once: each book after the ones it carried on from.
Future<void> seriesFromOldLinks({MemoryService? service}) async {
  final memory = service ?? MemoryService.instance;
  for (final e in await memory.booksWithMemory()) {
    if (SeriesStore.instance.ofBook(e.id) != null) continue;
    final linked = await memory.followedBy(e.id);
    if (linked.isEmpty) continue;
    final name = (e.series?.trim().isNotEmpty ?? false) ? e.series!.trim() : linked.first.title;
    // The chain first (each after the one before), then this book last.
    for (var i = 1; i < linked.length; i++) {
      if (SeriesStore.instance.ofBook(linked[i].id) == null) {
        await SeriesStore.instance.carryOn(linked[i].id, earlier: linked[i - 1].id, name: name);
      }
    }
    await SeriesStore.instance.carryOn(e.id, earlier: linked.last.id, name: name);
  }
}

/// The Memory screen's New memory: which book. Every book of the library
/// (not a shut secret shelf's), the latest read first, found by a search;
/// those with a memory already marked.
Future<LibraryEntry?> pickBookForMemory(BuildContext context, LibraryStore store) async {
  final books = [for (final e in await store.list()) if (!store.isSecret(e.id)) e]..sort((a, b) {
      final x = a.openedAt ?? a.addedAt, y = b.openedAt ?? b.addedAt;
      return y.compareTo(x);
    });
  if (!context.mounted) return null;
  return showModalBottomSheet<LibraryEntry>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    builder: (_) => _BookList(
      title: 'A memory for which book?',
      books: books,
      store: store,
      onPick: (e) => Navigator.of(context).pop(e),
    ),
  );
}

/// What the carries-on step answered: an earlier book, or none (it starts
/// fresh).
class _Carry {
  const _Carry(this.id);

  final String? id;
}

/// "Does this carry on from another book?": the likely ones first (the
/// same series in the library, an earlier number; then the same author),
/// then every other book, found by a search; "No, it starts fresh" a tap.
class _CarriesOnSheet extends StatelessWidget {
  const _CarriesOnSheet({required this.book, required this.books, required this.store, this.fresh = 'No, it starts fresh'});

  /// The words of the choice that it carries on from no book.
  final String fresh;
  final LibraryEntry book;
  final List<LibraryEntry> books;
  final LibraryStore store;

  @override
  Widget build(BuildContext context) {
    final series = book.series?.trim().toLowerCase();
    final authors = {for (final a in book.authors) a.trim().toLowerCase()};
    int score(LibraryEntry e) {
      final s = e.series?.trim().toLowerCase();
      if (series != null && series.isNotEmpty && s == series) {
        final before = e.seriesIndex != null && book.seriesIndex != null && e.seriesIndex! < book.seriesIndex!;
        return before ? 3 : 2;
      }
      if (e.authors.any((a) => authors.contains(a.trim().toLowerCase()))) return 1;
      return 0;
    }

    final others = [for (final e in books) if (e.id != book.id) e]..sort((a, b) {
        final d = score(b).compareTo(score(a));
        if (d != 0) return d;
        if (score(a) >= 2 && a.seriesIndex != null && b.seriesIndex != null) {
          return b.seriesIndex!.compareTo(a.seriesIndex!);
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    final likely = {for (final e in others) if (score(e) > 0) e.id};
    return _BookList(
      title: 'Does ${book.title} carry on from another book?',
      subtitle: 'Pick the book just before it. Their memories are read together as a series, each kept on its '
          'own; one with no memory yet is built first.',
      books: others,
      store: store,
      likely: likely,
      header: OutlinedButton(
        onPressed: () => Navigator.of(context).pop(const _Carry(null)),
        child: Text(fresh),
      ),
      onPick: (e) => Navigator.of(context).pop(_Carry(e.id)),
    );
  }
}

/// A list of books to pick one from, with a search; [likely] ones first,
/// under their own heading.
class _BookList extends StatefulWidget {
  const _BookList({
    required this.title,
    required this.books,
    required this.store,
    required this.onPick,
    this.subtitle,
    this.likely = const {},
    this.header,
  });

  final String title;
  final String? subtitle;
  final List<LibraryEntry> books;
  final LibraryStore store;
  final Set<String> likely;
  final Widget? header;
  final ValueChanged<LibraryEntry> onPick;

  @override
  State<_BookList> createState() => _BookListState();
}

class _BookListState extends State<_BookList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final e in widget.books)
        if (q.isEmpty || e.title.toLowerCase().contains(q) || e.authors.any((a) => a.toLowerCase().contains(q))) e,
    ];
    final likely = [for (final e in shown) if (widget.likely.contains(e.id)) e];
    final rest = [for (final e in shown) if (!widget.likely.contains(e.id)) e];
    Widget row(LibraryEntry e) {
      final has = MemoryDb.existsIn(widget.store.bookDir(e.id));
      final inSeries = SeriesStore.instance.ofBook(e.id);
      return ListTile(
        title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (e.authors.isNotEmpty) e.authors.join(', '),
            if (inSeries != null) 'in ${inSeries.name}',
            has ? 'has a memory' : 'no memory yet',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => widget.onPick(e),
      );
    }

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
            child: Text(widget.title, style: Skin.title(context, size: 19)),
          ),
          if (widget.subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
              child: Text(widget.subtitle!, style: Skin.meta(context)),
            ),
          if (widget.header != null)
            Padding(padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s), child: widget.header),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
            child: SearchField(hint: 'Find a book', onChanged: (v) => setState(() => _query = v)),
          ),
          Expanded(
            child: ListView(
              children: [
                if (likely.isNotEmpty) ...[
                  const Padding(padding: EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0), child: Eyebrow('Likely')),
                  for (final e in likely) row(e),
                  if (rest.isNotEmpty)
                    const Padding(
                        padding: EdgeInsets.fromLTRB(Gap.page, Gap.m, Gap.page, 0), child: Eyebrow('Other books')),
                ],
                for (final e in rest) row(e),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.page),
                    child: Text('No book matches.', style: Skin.meta(context)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A yes-or-no sheet: null when it was closed.
Future<bool?> _choice(BuildContext context,
        {required String title, required String body, required String yes, required String no}) =>
    showModalBottomSheet<bool>(
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
              SheetHeader(title),
              Text(body,
                  style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4)),
              const SizedBox(height: Gap.l),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(yes)),
              const SizedBox(height: Gap.s),
              OutlinedButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(no)),
            ],
          ),
        ),
      ),
    );

String _listed(List<String> items) =>
    items.length == 1 ? items.first : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
