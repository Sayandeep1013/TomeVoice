import 'dart:async';

import 'package:flutter/material.dart';

import '../../journal.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../ai_router.dart';
import '../ai_screen.dart' show wakeTime;
import '../memory/memory_db.dart';
import '../memory/theories.dart';
import 'talk_engine.dart';

/// One turn shown in the sheet.
class _Turn {
  _Turn.mine(this.text)
      : mine = true,
        sources = const {};
  _Turn.ai()
      : mine = false,
        text = '',
        sources = const {};

  final bool mine;
  String text;
  Map<int, TalkSource> sources;
  bool done = false;
  String? error;
}

/// Opens Talk over the reader: half the screen, the book still showing
/// (and still read aloud) above it.
Future<void> showTalk(
  BuildContext context, {
  required String bookId,
  required String bookTitle,
  required String memoryPath,
  required JournalStamp Function() stampNow,
  required int? Function() line,
  required int? Function() here,
  required String Function() passage,
  required void Function(MemoryPlace place) onLook,
  String? firstQuestion,
  TalkEngine? engine,
}) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      // The page shows through above: it is still the book being talked of.
      barrierColor: Colors.black26,
      builder: (_) => TalkSheet(
        bookId: bookId,
        bookTitle: bookTitle,
        memoryPath: memoryPath,
        stampNow: stampNow,
        line: line,
        here: here,
        passage: passage,
        onLook: onLook,
        firstQuestion: firstQuestion,
        engine: engine,
      ),
    );

/// Talk: questions about the book answered from its memory, each answer
/// citing chapters a tap looks at; kept in the book's journal when closed.
class TalkSheet extends StatefulWidget {
  const TalkSheet({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.memoryPath,
    required this.stampNow,
    required this.line,
    required this.here,
    required this.passage,
    required this.onLook,
    this.firstQuestion,
    this.engine,
    this.journal,
  });

  final String bookId;
  final String bookTitle;
  final String memoryPath;
  final JournalStamp Function() stampNow;

  /// The spoiler line, when the guard is on (null: off).
  final int? Function() line;
  final int? Function() here;
  final String Function() passage;
  final void Function(MemoryPlace place) onLook;
  final String? firstQuestion;
  final TalkEngine? engine;
  final JournalStore? journal;

  @override
  State<TalkSheet> createState() => _TalkSheetState();
}

class _TalkSheetState extends State<TalkSheet> {
  late final TalkEngine _engine =
      widget.engine ?? TalkEngine(memoryPath: widget.memoryPath, bookTitle: widget.bookTitle);
  final _turns = <_Turn>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  JournalStamp? _stamp;

  /// The next thing sent is a theory: kept, weighed, and checked as the
  /// story goes on.
  bool _theory = false;

  JournalStore get _journal => widget.journal ?? JournalStore.instance;

  @override
  void initState() {
    super.initState();
    final q = widget.firstQuestion;
    if (q != null) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_ask(q)));
  }

  @override
  void dispose() {
    unawaited(_keep());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The talk kept in the book's journal, stamped where the story was when
  /// it began.
  Future<void> _keep() async {
    // Its [S3] marks kept as the chapters they named: the sources go.
    String kept(_Turn t) => t.text
        .replaceAllMapped(citeMarks, (m) {
          final labels = {
            for (final n in citeNumbers(m.group(0)!))
              if (t.sources[n]?.place != null) t.sources[n]!.label,
          };
          return labels.isEmpty ? '' : ' (${labels.join(', ')})';
        })
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAllMapped(RegExp(r'\s+([.,;:!?])'), (m) => m.group(1)!)
        .trim();
    final lines = [
      for (final t in _turns)
        if (t.text.trim().isNotEmpty && t.error == null) TalkLine(mine: t.mine, text: t.mine ? t.text.trim() : kept(t)),
    ];
    if (!lines.any((l) => !l.mine)) return;
    await _journal.put(JournalEntry(
      id: JournalStore.newId(),
      bookId: widget.bookId,
      bookTitle: widget.bookTitle,
      created: DateTime.now().toUtc(),
      stamp: _stamp ?? widget.stampNow(),
      talk: lines,
    ));
  }

  /// The reader's journal for the book, within the line, for the AI to read.
  List<String> _journalLines(int? line) => [
        for (final e in _journal.all)
          if (e.bookId == widget.bookId && !e.isTalk && (line == null || e.stamp.chapter <= line))
            '${e.stamp.label}, ${e.created.toLocal().toString().substring(0, 10)}: ${e.words}',
      ];

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
      }
    });
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    _stamp ??= widget.stampNow();
    final theory = _theory;
    final answer = _Turn.ai();
    setState(() {
      _busy = true;
      _theory = false;
      _turns
        ..add(_Turn.mine(theory ? 'My theory: $q' : q))
        ..add(answer);
      _input.clear();
    });
    if (theory) unawaited(addTheoryOff(widget.memoryPath, q, widget.here() ?? 0));
    _toEnd();
    final line = widget.line();
    try {
      final a = await _engine.ask(
        q,
        line: line,
        here: widget.here(),
        passage: widget.passage(),
        journal: _journalLines(line),
        theory: theory,
        onText: (piece) {
          if (!mounted) return;
          setState(() => answer.text += piece);
          _toEnd();
        },
      );
      if (!mounted) return;
      setState(() {
        answer
          ..text = a.text
          ..sources = a.sources
          ..done = true;
      });
    } on AiResting catch (e) {
      if (!mounted) return;
      setState(() => answer.error = e.until != null
          ? 'Every key has used its quota for now. Ask again at ${wakeTime(e.until!)}.'
          : e.last == null
              ? 'No key can talk yet: give one a model for Talking, in AI.'
              : 'The AI could not answer: ${e.last!.message}');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => answer.error = 'The AI could not answer: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _toEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, sheetScroll) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          children: [
            SheetHeader(
              'Talk about ${widget.bookTitle}',
              subtitle: line == null ? 'Kept in your journal' : 'Keeping to chapter ${line + 1}',
            ),
            Expanded(
              child: _turns.isEmpty
                  ? ListView(
                      controller: sheetScroll,
                      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                      children: [
                        Text(
                          'Ask anything about the book: who someone is, what happened, why. Answers come from '
                          "what TomeVoice remembers of it, and cite the chapters they come from.",
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                              .copyWith(height: 1.4),
                        ),
                        const SizedBox(height: Gap.m),
                        Wrap(
                          spacing: Gap.s,
                          runSpacing: Gap.s,
                          children: [
                            for (final s in const [
                              'What just happened?',
                              'Catch me up on the story so far',
                              'Who is in this chapter?',
                              'What mysteries are still open?',
                            ])
                              ActionChip(label: Text(s), onPressed: () => unawaited(_ask(s))),
                            ActionChip(
                              avatar: const Icon(Icons.lightbulb_outline_rounded, size: 18),
                              label: const Text('I have a theory…'),
                              onPressed: () => setState(() => _theory = true),
                            ),
                          ],
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
                      itemCount: _turns.length,
                      itemBuilder: (context, i) => _turn(context, _turns[i]),
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, Gap.s),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: _theory ? 'Ask instead' : 'State a theory',
                      isSelected: _theory,
                      icon: const Icon(Icons.lightbulb_outline_rounded),
                      selectedIcon: Icon(Icons.lightbulb_rounded, color: Skin.accentInkOf(context)),
                      onPressed: () => setState(() => _theory = !_theory),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (v) => unawaited(_ask(v)),
                        decoration: InputDecoration(
                          hintText: _theory ? 'Your theory: what you think is going on' : 'Ask about the book',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Ask',
                      onPressed: _busy ? null : () => unawaited(_ask(_input.text)),
                      icon: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _turn(BuildContext context, _Turn t) {
    if (t.mine) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: Gap.m, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Skin.capsuleOn(context),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(t.text, style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context))),
        ),
      );
    }
    if (t.error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.m),
        child: Text(t.error!, style: Skin.ui(size: 14, weight: FontWeight.w500, color: Theme.of(context).colorScheme.error)),
      );
    }
    if (t.text.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.m),
        child: Row(
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Gap.s),
            Text('Remembering…', style: Skin.meta(context)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.m, right: 24),
      child: CitedText(
        text: t.text,
        sources: t.sources,
        onLook: (p) {
          Navigator.of(context).maybePop();
          widget.onLook(p);
        },
      ),
    );
  }
}

/// An answer's text, its [S3] marks drawn as small chapter chips that look
/// at the place a tap.
class CitedText extends StatelessWidget {
  const CitedText({super.key, required this.text, required this.sources, this.onLook});

  final String text;
  final Map<int, TalkSource> sources;
  final void Function(MemoryPlace place)? onLook;

  @override
  Widget build(BuildContext context) {
    final style = Skin.ui(size: 15.5, weight: FontWeight.w400, color: Skin.inkOn(context)).copyWith(height: 1.45);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in citeMarks.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final seen = <String>{};
      for (final n in citeNumbers(m.group(0)!)) {
        final s = sources[n];
        // An unknown number (the model made it up) is left out.
        if (s == null || !seen.add(s.label)) continue;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Material(
              color: Skin.capsuleOn(context),
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: s.place == null || onLook == null ? null : () => onLook!(s.place!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  child: Text(s.label, style: Skin.meta(context, size: 10.5, color: Skin.accentInkOf(context))),
                ),
              ),
            ),
          ),
        ));
      }
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
