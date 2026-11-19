import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import '../../theme.dart';
import '../../ui.dart';
import 'memory_db.dart';

/// What was found: where, and the words round it, the match in «».
typedef FoundPlace = ({MemoryPlace place, String snippet});

/// [query] in the word index of the memory at [path], in the book's order,
/// within chapter [upTo] when the spoiler guard is on; and how many chapters
/// it is in.
({List<FoundPlace> hits, int chapters}) findWhere(String path, String query, int? upTo) {
  if (!MemoryDb.existsAt(path)) return (hits: const [], chapters: 0);
  final m = MemoryDb.open(path);
  try {
    final hits = m.search(query, upTo: upTo, limit: 300, inOrder: true);
    return (
      hits: [for (final h in hits) (place: h.place, snippet: h.snippet)],
      chapters: {for (final h in hits) h.place.chapter}.length,
    );
  } finally {
    m.close();
  }
}

Future<({List<FoundPlace> hits, int chapters})> _findOff(String path, String query, int? upTo) =>
    Isolate.run(() => findWhere(path, query, upTo));

/// A book's memory > Find where…: every word of every chapter searched,
/// even chapters not open (a long web novel's), each place found with the
/// words round it; a tap opens the book there.
class FindWhereScreen extends StatefulWidget {
  const FindWhereScreen({super.key, required this.bookTitle, required this.memoryPath, this.line, this.onRead});

  final String bookTitle;
  final String memoryPath;

  /// The spoiler guard's line: nothing past it is shown.
  final int? line;
  final void Function(ReadingCursor at)? onRead;

  @override
  State<FindWhereScreen> createState() => _FindWhereScreenState();
}

class _FindWhereScreenState extends State<FindWhereScreen> {
  final _query = TextEditingController();
  ({List<FoundPlace> hits, int chapters})? _found;
  int _asked = 0;
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 300), () => unawaited(_find()));
  }

  Future<void> _find() async {
    final q = _query.text.trim();
    final n = ++_asked;
    if (q.isEmpty) {
      setState(() => _found = null);
      return;
    }
    final r = await _findOff(widget.memoryPath, q, widget.line);
    if (mounted && n == _asked) setState(() => _found = r);
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Find where…', onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _changed,
                  onSubmitted: (_) => unawaited(_find()),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: 'Words, or "a phrase" in quotes',
                    helperText: widget.line == null
                        ? 'The whole of ${widget.bookTitle}'
                        : 'Up to chapter ${widget.line! + 1}: the spoiler guard is on',
                  ),
                ),
              ),
              if (found != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, Gap.s),
                  child: Text(
                    found.hits.isEmpty
                        ? 'Not found.'
                        : '${found.hits.length >= 300 ? 'Over 300' : found.hits.length} '
                            '${found.hits.length == 1 ? 'place' : 'places'}, in ${found.chapters} '
                            '${found.chapters == 1 ? 'chapter' : 'chapters'}',
                    style: Skin.meta(context),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.only(bottom: Gap.xl + bottom),
                  itemCount: found?.hits.length ?? 0,
                  itemBuilder: (context, i) {
                    final h = found!.hits[i];
                    return ListTile(
                      title: Text('Chapter ${h.place.chapter + 1}',
                          style: Skin.ui(size: 13, weight: FontWeight.w600, color: Skin.accentInkOf(context))),
                      subtitle: Text.rich(_marked(context, h.snippet)),
                      onTap: widget.onRead == null
                          ? null
                          : () {
                              final p = h.place;
                              widget.onRead!(
                                  ReadingCursor(sectionIndex: p.section, blockIndex: p.block, sentenceIndex: p.sentence));
                            },
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

  /// The snippet with the words found («like this») in bold.
  TextSpan _marked(BuildContext context, String snippet) {
    final base = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkOn(context)).copyWith(height: 1.35);
    final spans = <TextSpan>[];
    final mark = RegExp('«([^»]*)»');
    var at = 0;
    for (final m in mark.allMatches(snippet)) {
      if (m.start > at) spans.add(TextSpan(text: snippet.substring(at, m.start)));
      spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      at = m.end;
    }
    if (at < snippet.length) spans.add(TextSpan(text: snippet.substring(at)));
    return TextSpan(style: base, children: spans);
  }
}
