import 'dart:async';

import 'package:flutter/material.dart';

import '../../library_store.dart' show LibraryEntry, LibraryStore;
import '../../theme.dart';
import '../../ui.dart';
import '../ai_consent.dart';
import '../ai_keys.dart';
import '../ai_screen.dart' show tokenCount;
import 'memory_builder.dart' show BuildEstimate;
import 'memory_db.dart';
import 'memory_service.dart';
import 'series_store.dart';

/// Starting a book's memory, from its page or from the Memory screen's New
/// memory: the AI's consent; a web novel's missing chapters; whether it
/// carries on from another book (a series, its earlier books built first);
/// what it will take; then building, in order.
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
  // Begun before: the reader agreed to it then; it simply goes on.
  if (memory.stateOf(bookId).value.noted > 0) {
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
  // The sheet at once; what it would take, counted meanwhile.
  final counting = () async {
    var total = const BuildEstimate(chapters: 0, inputTokens: 0, outputTokens: 0, calls: 0);
    for (final id in queue) {
      final e = await memory.estimate(id);
      total = BuildEstimate(
        chapters: total.chapters + e.chapters,
        inputTokens: total.inputTokens + e.inputTokens,
        outputTokens: total.outputTokens + e.outputTokens,
        calls: total.calls + e.calls,
      );
    }
    return total;
  }();
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
            SheetHeader(
              first.isEmpty ? 'Build the memory' : 'Build the series',
              subtitle: 'Each chapter is read once, ever',
            ),
            if (first.isNotEmpty) ...[
              Text(
                'First ${_listed([for (final b in first) titles[b] ?? 'an earlier book'])}, which have no memory '
                'yet, then ${titles[bookId] ?? 'this book'}: each knows the people of the books before it.',
                style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkOn(context)).copyWith(height: 1.4),
              ),
              const SizedBox(height: Gap.s),
            ],
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
                              'It goes on with TomeVoice behind other apps or the screen off; when a key has used its '
                              'quota for now, the next takes over, and when all of them have, it waits for them.',
                  style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
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
  if (go == true) unawaited(memory.buildInOrder(queue));
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
  const _CarriesOnSheet({required this.book, required this.books, required this.store});

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
        child: const Text('No, it starts fresh'),
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
