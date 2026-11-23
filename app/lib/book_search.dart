import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'theme.dart';
import 'ui.dart';

/// A match: [unit] (a sentence) and where in its text.
class SearchHit {
  const SearchHit(this.unit, this.start, this.end);

  final int unit;
  final int start;
  final int end;
}

/// Letters with accents, and the plain letter each one is searched as. One
/// letter for one, so positions in the folded text are positions in the real
/// text.
const _accents = {
  'àáâãäåāăą': 'a',
  'çćĉċč': 'c',
  'ďđ': 'd',
  'èéêëēĕėęě': 'e',
  'ĝğġģ': 'g',
  'ĥħ': 'h',
  'ìíîïĩīĭįı': 'i',
  'ĵ': 'j',
  'ķ': 'k',
  'ĺļľŀł': 'l',
  'ñńņňŉ': 'n',
  'òóôõöøōŏő': 'o',
  'ŕŗř': 'r',
  'śŝşšș': 's',
  'ţťŧț': 't',
  'ùúûüũūŭůűų': 'u',
  'ŵ': 'w',
  'ýÿŷ': 'y',
  'źżž': 'z',
  '’‘': "'",
  '“”': '"',
};

final Map<int, int> _fold = {
  for (final e in _accents.entries)
    for (final c in e.key.codeUnits) c: e.value.codeUnitAt(0),
};

/// [text] in lower case without accents, the same length.
String foldForSearch(String text) {
  final lower = text.toLowerCase();
  if (lower.length != text.length) return text; // A rare letter that changes length: search as is.
  return String.fromCharCodes([for (final c in lower.codeUnits) _fold[c] ?? c]);
}

/// Every match of [query] in [texts] (one per sentence), from sentence
/// [from] up to (not including) [to]. Case and accents are ignored;
/// [wholeWords] keeps "cat" from finding "concatenate". At most [limit].
List<SearchHit> searchTexts(
  List<String> texts,
  String query, {
  int from = 0,
  int? to,
  bool wholeWords = false,
  int limit = 2000,
}) {
  final q = foldForSearch(query.trim());
  if (q.isEmpty) return const [];
  final word = RegExp(r'[\p{L}\p{N}]', unicode: true);
  bool isWord(String s, int i) => i >= 0 && i < s.length && word.hasMatch(s[i]);
  final hits = <SearchHit>[];
  final end = to ?? texts.length;
  for (var u = from; u < end && hits.length < limit; u++) {
    final t = foldForSearch(texts[u]);
    var at = t.indexOf(q);
    while (at >= 0 && hits.length < limit) {
      if (!wholeWords || (!isWord(t, at - 1) && !isWord(t, at + q.length))) {
        hits.add(SearchHit(u, at, at + q.length));
      }
      at = t.indexOf(q, at + q.length);
    }
  }
  return hits;
}

typedef _Job = ({List<String> texts, String query, int from, int? to, bool whole});

List<SearchHit> _searchJob(_Job j) => searchTexts(j.texts, j.query, from: j.from, to: j.to, wholeWords: j.whole);

/// Search [layout]: this chapter ([chapter]) or the whole book. Picking a
/// match calls [onPick] with all of them and the one picked, so the reader
/// can step through the rest.
Future<void> showBookSearch(
  BuildContext context, {
  required ReadingLayout layout,
  required int chapter,
  bool wholeBook = false,
  required void Function(List<SearchHit> hits, int index, String query) onPick,
}) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => carryTint(
        context,
        _SearchSheet(layout: layout, chapter: chapter, wholeBook: wholeBook, onPick: onPick),
      ),
    );

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.layout, required this.chapter, required this.wholeBook, required this.onPick});

  final ReadingLayout layout;
  final int chapter;
  final bool wholeBook;
  final void Function(List<SearchHit> hits, int index, String query) onPick;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  late bool _whole = widget.wholeBook || widget.layout.chapters.length < 2;
  bool _wholeWords = false;
  String _query = '';
  List<SearchHit> _hits = const [];
  bool _busy = false;
  Timer? _debounce;
  int _run = 0;

  late final List<String> _texts = [for (final u in widget.layout.units) u.text];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final q = _query.trim();
      final run = ++_run;
      if (q.length < 2) {
        // A search still running for the longer query will not report back
        // (it is out of date): "Searching…" goes with it.
        setState(() {
          _hits = const [];
          _busy = false;
        });
        return;
      }
      final l = widget.layout;
      final (first, count) = l.chapterRange(widget.chapter);
      setState(() => _busy = true);
      final job = (
        texts: _texts,
        query: q,
        from: _whole ? 0 : first,
        to: _whole ? null : first + count,
        whole: _wholeWords,
      );
      // A long book on a background isolate; a chapter is quick enough here.
      final hits = _whole && _texts.length > 3000 ? await compute(_searchJob, job) : _searchJob(job);
      if (!mounted || run != _run) return;
      setState(() {
        _hits = hits;
        _busy = false;
      });
    });
  }

  /// Chapters with text out of all chapters, for web novels with chapters
  /// not downloaded yet.
  (int, int) get _coverage {
    final sections = widget.layout.book.sections;
    return (sections.where((s) => s.blocks.isNotEmpty).length, sections.length);
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.layout;
    final byChapter = <int, List<int>>{};
    for (var i = 0; i < _hits.length; i++) {
      byChapter.putIfAbsent(l.chapterOfUnit(_hits[i].unit), () => []).add(i);
    }
    // Each row: a chapter's heading (hit -1, only for the whole book), or hit i.
    final rows = <(int, int)>[
      for (final e in byChapter.entries) ...[
        if (_whole) (e.key, -1),
        for (final i in e.value) (e.key, i),
      ],
    ];
    final (have, all) = _coverage;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Find a passage'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: SearchField(
                hint: _whole ? 'Search the whole book' : 'Search this chapter',
                autofocus: true,
                onChanged: (v) {
                  _query = v;
                  _search();
                },
              ),
            ),
            const SizedBox(height: Gap.m),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: Row(
                children: [
                  if (l.chapters.length > 1)
                    Expanded(
                      child: ChoiceRow<bool>(
                        options: const [(false, 'This chapter'), (true, 'Whole book')],
                        value: _whole,
                        onChanged: (v) {
                          setState(() => _whole = v);
                          _search();
                        },
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: Gap.s),
                  FilterChip(
                    label: const Text('Whole words'),
                    selected: _wholeWords,
                    onSelected: (v) {
                      setState(() => _wholeWords = v);
                      _search();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.xs),
              child: Text(
                [
                  if (_busy) 'Searching…' else if (_query.trim().length >= 2) _count(_hits.length),
                  if (_whole && have < all) 'Searched $have of $all chapters (the ones on the phone)',
                ].join(' · ').toUpperCase(),
                style: Skin.meta(context, size: 10.5),
              ),
            ),
            Expanded(
              // Rows made as they scroll into view: a search for "the" has
              // 2,000, and the sheet is built again on every frame of the
              // keyboard sliding.
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
                itemCount: rows.length,
                itemBuilder: (context, k) {
                  final (chapter, i) = rows[k];
                  if (i >= 0) return _row(context, i);
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.s, Gap.m, Gap.s, Gap.xs),
                    child: Text(
                      '${l.chapterTitle(chapter)}  ·  ${byChapter[chapter]!.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.title(context, size: 15),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _count(int n) => switch (n) {
        0 => 'Not found',
        1 => 'One match',
        >= 2000 => 'Over 2000 matches',
        _ => '$n matches',
      };

  Widget _row(BuildContext context, int i) {
    final h = _hits[i];
    final text = _texts[h.unit];
    // A window of the sentence around the match.
    final s = (h.start - 50).clamp(0, text.length);
    final e = (h.end + 90).clamp(0, text.length);
    final base = Skin.ui(size: 14.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.card / 2),
      onTap: () {
        Navigator.of(context).pop();
        widget.onPick(_hits, i, _query.trim());
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 10),
        child: Text.rich(
          TextSpan(style: base, children: [
            TextSpan(text: '${s > 0 ? '…' : ''}${text.substring(s, h.start)}'),
            TextSpan(
              text: text.substring(h.start, h.end),
              style: TextStyle(
                color: Skin.inkOn(context),
                fontWeight: FontWeight.w700,
                backgroundColor: Skin.accentOf(context).withValues(alpha: 0.28),
              ),
            ),
            TextSpan(text: '${text.substring(h.end, e)}${e < text.length ? '…' : ''}'),
          ]),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// ------------------------------------------------- a web novel's chapters

/// A match found in a web novel's chapter files (see
/// LibraryStore.findInWebNovel): its chapter, the place of its sentence,
/// and where in the sentence's [text].
class FoundPassage {
  const FoundPassage({
    required this.chapter,
    required this.title,
    required this.at,
    required this.text,
    required this.start,
    required this.end,
  });

  final int chapter;
  final String title;
  final ReadingCursor at;
  final String text;
  final int start;
  final int end;
}

/// What a search of a web novel's chapters found, and how many of its
/// [all] chapters were [searched] (those on the phone).
typedef PassageFind = ({List<FoundPassage> found, int searched, int all});

/// Find a passage in a web novel's chapters on the phone, each searched in
/// its own file by [find] (never the whole novel in memory at once).
/// Picking a match calls [onPick] with it.
Future<void> showPassageFinder(
  BuildContext context, {
  required Future<PassageFind> Function(String query, bool wholeWords) find,
  required void Function(FoundPassage passage) onPick,
}) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => carryTint(context, _FinderSheet(find: find, onPick: onPick)),
    );

class _FinderSheet extends StatefulWidget {
  const _FinderSheet({required this.find, required this.onPick});

  final Future<PassageFind> Function(String query, bool wholeWords) find;
  final void Function(FoundPassage passage) onPick;

  @override
  State<_FinderSheet> createState() => _FinderSheetState();
}

class _FinderSheetState extends State<_FinderSheet> {
  bool _wholeWords = false;
  String _query = '';
  PassageFind? _result;
  bool _busy = false;
  Timer? _debounce;
  int _run = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search() {
    _debounce?.cancel();
    // A little longer than a book's: each search reads the chapter files.
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final q = _query.trim();
      final run = ++_run;
      if (q.length < 2) {
        setState(() {
          _result = null;
          _busy = false;
        });
        return;
      }
      setState(() => _busy = true);
      PassageFind? result;
      try {
        result = await widget.find(q, _wholeWords);
      } on Object {
        result = null;
      }
      if (!mounted || run != _run) return;
      setState(() {
        _result = result ?? (found: const <FoundPassage>[], searched: 0, all: 0);
        _busy = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final found = result?.found ?? const <FoundPassage>[];
    // Each row: a chapter's heading (match -1), or match i.
    final rows = <(int, int)>[];
    final counts = <int, int>{};
    for (var i = 0; i < found.length; i++) {
      final c = found[i].chapter;
      if (i == 0 || found[i - 1].chapter != c) rows.add((c, -1));
      rows.add((c, i));
      counts[c] = (counts[c] ?? 0) + 1;
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Find a passage'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: SearchField(
                hint: 'Search the chapters on the phone',
                autofocus: true,
                onChanged: (v) {
                  _query = v;
                  _search();
                },
              ),
            ),
            const SizedBox(height: Gap.m),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: Row(
                children: [
                  const Spacer(),
                  FilterChip(
                    label: const Text('Whole words'),
                    selected: _wholeWords,
                    onSelected: (v) {
                      setState(() => _wholeWords = v);
                      _search();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.xs),
              child: Text(
                [
                  if (_busy)
                    'Searching…'
                  else if (_query.trim().length >= 2 && result != null)
                    _SearchSheetState._count(found.length),
                  if (!_busy && result != null && result.searched < result.all)
                    'Searched ${result.searched} of ${result.all} chapters (the ones on the phone)',
                ].join(' · ').toUpperCase(),
                style: Skin.meta(context, size: 10.5),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
                itemCount: rows.length,
                itemBuilder: (context, k) {
                  final (chapter, i) = rows[k];
                  if (i >= 0) return _row(context, found[i]);
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.s, Gap.m, Gap.s, Gap.xs),
                    child: Text(
                      '${found[rows[k + 1].$2].title}  ·  ${counts[chapter]}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.title(context, size: 15),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, FoundPassage p) {
    final text = p.text;
    final s = (p.start - 50).clamp(0, text.length);
    final e = (p.end + 90).clamp(0, text.length);
    final base = Skin.ui(size: 14.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.card / 2),
      onTap: () {
        Navigator.of(context).pop();
        widget.onPick(p);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 10),
        child: Text.rich(
          TextSpan(style: base, children: [
            TextSpan(text: '${s > 0 ? '…' : ''}${text.substring(s, p.start)}'),
            TextSpan(
              text: text.substring(p.start, p.end),
              style: TextStyle(
                color: Skin.inkOn(context),
                fontWeight: FontWeight.w700,
                backgroundColor: Skin.accentOf(context).withValues(alpha: 0.28),
              ),
            ),
            TextSpan(text: '${text.substring(p.end, e)}${e < text.length ? '…' : ''}'),
          ]),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
