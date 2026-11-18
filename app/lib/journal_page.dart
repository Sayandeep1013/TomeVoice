import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, ReadingLayout;

import 'journal.dart';
import 'notebook.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui.dart';

/// Where [layout]'s sentence [unit] is, as a journal's stamp: its place,
/// its chapter, the number that chapter goes by ([numberOf]; its place in
/// the book from 1 otherwise) and its title.
JournalStamp stampAt(ReadingLayout layout, int unit, {int Function(int chapter)? numberOf}) {
  if (layout.isEmpty) return const JournalStamp(at: ReadingCursor.zero, chapter: 0);
  final u = unit.clamp(0, layout.units.length - 1);
  final s = layout.units[u];
  final c = layout.chapterOfUnit(u);
  return JournalStamp(
    at: ReadingCursor(sectionIndex: s.sectionIndex, blockIndex: s.blockIndex, sentenceIndex: s.sentenceIndex),
    chapter: c,
    number: numberOf?.call(c) ?? c + 1,
    title: layout.chapterTitle(c),
  );
}

/// Open the journal to write in it for [bookId], or to change [entry].
/// [stampNow] says where the story is the moment it is asked: once as the
/// pen is taken up, and again at Done (the voice may have read on
/// meanwhile). The entry kept, or null when nothing was.
Future<JournalEntry?> openJournal(
  BuildContext context, {
  required String bookId,
  required String bookTitle,
  required JournalStamp Function() stampNow,
  JournalEntry? entry,
}) async {
  final kept = await Navigator.of(context).push<JournalEntry>(MaterialPageRoute(
    builder: (_) => JournalPage(bookId: bookId, bookTitle: bookTitle, stampNow: stampNow, entry: entry),
  ));
  if (kept != null && context.mounted) {
    showSnack(context, entry == null ? 'In your journal, ${kept.stamp.label}.' : 'Changed.');
  }
  return kept;
}

/// The journal's page: the template's questions on the notebook's squared
/// paper, answered in handwriting, the feelings as stickers to tap; or a
/// blank page. Done keeps it, stamped with where the story had reached.
class JournalPage extends StatefulWidget {
  const JournalPage({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.stampNow,
    this.entry,
    this.questions,
  });

  final String bookId;
  final String bookTitle;
  final JournalStamp Function() stampNow;

  /// Written before: changed here, its stamp kept.
  final JournalEntry? entry;

  /// The questions asked (the reader's template by default).
  final List<JournalQuestion>? questions;

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  late final List<JournalQuestion> _questions;
  late final List<TextEditingController> _words;
  late final List<TextEditingController> _own;
  late final List<String?> _picks;
  final _page = TextEditingController();
  late bool _blank;
  late final JournalStamp _began;
  bool _kept = false;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _began = e?.stamp ?? widget.stampNow();
    // An entry written before keeps the questions it was asked.
    _questions = e != null && !e.isPage
        ? [
            for (final a in e.answers)
              (widget.questions ?? journalQuestionsOf(ListeningPrefs.loaded ?? ListeningPrefs.memory))
                      .where((q) => q.text == a.question)
                      .firstOrNull ??
                  JournalQuestion(a.question, picks: a.pick == null ? const [] : [a.pick!]),
          ]
        : (widget.questions ?? journalQuestionsOf(ListeningPrefs.loaded ?? ListeningPrefs.memory));
    _words = [for (var i = 0; i < _questions.length; i++) TextEditingController()];
    _own = [for (var i = 0; i < _questions.length; i++) TextEditingController()];
    _picks = List.filled(_questions.length, null);
    _blank = e != null && e.isPage;
    if (e != null) {
      _page.text = e.page;
      for (final (i, a) in e.answers.indexed) {
        if (i >= _questions.length) break;
        _words[i].text = a.text;
        final q = _questions[i];
        if (a.pick != null) {
          if (q.picks.contains(a.pick)) {
            _picks[i] = a.pick;
          } else {
            _own[i].text = a.pick!;
          }
        }
      }
    }
  }

  @override
  void dispose() {
    for (final c in [..._words, ..._own, _page]) {
      c.dispose();
    }
    super.dispose();
  }

  List<JournalAnswer> get _answers => [
        for (var i = 0; i < _questions.length; i++)
          JournalAnswer(
            question: _questions[i].text,
            pick: _own[i].text.trim().isNotEmpty ? _own[i].text.trim() : _picks[i],
            text: _questions[i].isPick ? '' : _words[i].text,
          ),
      ];

  /// What would be kept now: the page, or the answers.
  bool get _empty => _blank ? _page.text.trim().isEmpty : _answers.every((a) => a.isEmpty);

  Future<void> _done() async {
    if (_empty) {
      Navigator.of(context).pop();
      return;
    }
    final old = widget.entry;
    final JournalStamp stamp;
    if (old != null) {
      stamp = old.stamp;
    } else {
      // Where the story is now: the voice may have read on while the pen
      // was out, and the chapter it began in is kept beside it.
      final now = widget.stampNow();
      stamp = now.number != null && _began.number != null && now.number != _began.number
          ? JournalStamp(at: now.at, chapter: now.chapter, number: now.number, title: now.title, fromNumber: _began.number)
          : now;
    }
    final answers = _blank ? const <JournalAnswer>[] : [for (final a in _answers) if (!a.isEmpty) a];
    final entry = old != null
        ? old.copyWith(answers: answers, page: _blank ? _page.text.trim() : '', edited: DateTime.now().toUtc())
        : JournalEntry(
            id: JournalStore.newId(),
            bookId: widget.bookId,
            bookTitle: widget.bookTitle,
            created: DateTime.now().toUtc(),
            stamp: stamp,
            answers: answers,
            page: _blank ? _page.text.trim() : '',
          );
    await JournalStore.instance.put(entry);
    _kept = true;
    if (mounted) Navigator.of(context).pop(entry);
  }

  /// Leaving with words written and not kept: asked first.
  Future<void> _leave() async {
    if (_empty) {
      _kept = true;
      Navigator.of(context).pop();
      return;
    }
    final keep = await confirm(
      context,
      title: 'Keep what you wrote?',
      body: 'It goes in your journal, stamped with where the story is.',
      action: 'Keep',
    );
    if (!mounted) return;
    if (keep) {
      await _done();
    } else {
      _kept = true;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = NotebookInk.of(context);
    final tone = ink.tone;
    final text = tone.ink!;
    final soft = tone.inkSoft!;
    final insets = MediaQuery.paddingOf(context);
    return PopScope(
      canPop: _kept,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: tone.paper!.first,
        body: DecoratedBox(
          decoration: tone.paperOf(context),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: insets.top,
                bottom: 0,
                width: 20,
                child: IgnorePointer(child: CustomPaint(painter: NotebookSpiral(ink.rings, tone.paper!.last))),
              ),
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, Gap.s, Gap.s, 0),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Close',
                            icon: Icon(Icons.close_rounded, color: soft),
                            onPressed: () => unawaited(_leave()),
                          ),
                          const SizedBox(width: Gap.xs),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(widget.bookTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: handwriting(26, text, weight: FontWeight.w700)),
                                Text(
                                  (widget.entry == null ? 'writing at ${_began.label.replaceFirst('up to ', '')}' : _began.label)
                                      .toUpperCase(),
                                  style: Skin.meta(context, size: 10.5, color: soft),
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: tone.accent, foregroundColor: Colors.white),
                            onPressed: () => unawaited(_done()),
                            child: const Text('Done'),
                          ),
                        ],
                      ),
                    ),
                    if (widget.entry == null || !widget.entry!.isPage)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(34, Gap.m, Gap.l, 0),
                        child: ChoiceRow<bool>(
                          options: const [(false, 'Questions'), (true, 'Blank page')],
                          value: _blank,
                          onChanged: (b) => setState(() => _blank = b),
                        ),
                      ),
                    Expanded(
                      child: _blank
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(34, Gap.m, Gap.l, Gap.l),
                              child: TextField(
                                controller: _page,
                                autofocus: widget.entry == null,
                                maxLines: null,
                                expands: true,
                                textAlignVertical: TextAlignVertical.top,
                                keyboardType: TextInputType.multiline,
                                textCapitalization: TextCapitalization.sentences,
                                style: handwriting(23, ink.pen).copyWith(height: 1.25),
                                decoration: _onPaper('Write whatever comes…', handwriting(23, soft.withValues(alpha: 0.6))),
                              ),
                            )
                          : ListView(
                              padding: EdgeInsets.fromLTRB(34, Gap.l, Gap.l, Gap.xxl + insets.bottom),
                              children: [
                                for (var i = 0; i < _questions.length; i++) _question(context, i, ink),
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

  Widget _question(BuildContext context, int i, NotebookInk ink) {
    final q = _questions[i];
    final soft = ink.tone.inkSoft!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q.text.toUpperCase(), style: Skin.meta(context, size: 11, color: soft)),
          const SizedBox(height: Gap.s),
          if (q.isPick) ...[
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                for (final (n, p) in q.picks.indexed) _sticker(context, i, p, ink.tab(n), ink),
              ],
            ),
            // A word of the reader's own, when none of the picks is it.
            TextField(
              controller: _own[i],
              onChanged: (v) => setState(() {
                if (v.trim().isNotEmpty) _picks[i] = null;
              }),
              textCapitalization: TextCapitalization.sentences,
              style: handwriting(22, ink.pen),
              decoration: _onPaper('or something more…', handwriting(20, soft.withValues(alpha: 0.6))),
            ),
          ] else
            TextField(
              controller: _words[i],
              onChanged: (_) => setState(() {}),
              maxLines: null,
              minLines: 2,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: handwriting(22, ink.pen).copyWith(height: 1.25),
              decoration: _onPaper('Write here…', handwriting(20, soft.withValues(alpha: 0.6))),
            ),
        ],
      ),
    );
  }

  /// A field written straight onto the paper: none of the app's own boxes
  /// (its fields are filled capsules), only the words.
  static InputDecoration _onPaper(String hint, TextStyle hintStyle) => InputDecoration(
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
        hintText: hint,
        hintStyle: hintStyle,
      );

  /// A pick as a round sticker: filled in its colour when picked.
  Widget _sticker(BuildContext context, int i, String pick, Color colour, NotebookInk ink) {
    final on = _picks[i] == pick && _own[i].text.trim().isEmpty;
    return Semantics(
      button: true,
      selected: on,
      child: GestureDetector(
        onTap: () => setState(() {
          _picks[i] = on ? null : pick;
          if (!on) _own[i].clear();
        }),
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.quick),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: on ? colour : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: colour, width: 2),
          ),
          child: Text(pick, style: handwriting(20, on ? ink.tabInk : ink.tone.ink!, weight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// One entry as the notebook shows it: where the story had reached and
/// when, the feeling as a sticker, the answers (or the page) in
/// handwriting. A tap opens it to change; held, [onHold] (to remove it).
class JournalEntryCard extends StatelessWidget {
  const JournalEntryCard({super.key, required this.entry, required this.ink, this.onTap, this.onHold});

  final JournalEntry entry;
  final NotebookInk ink;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  @override
  Widget build(BuildContext context) {
    final tone = ink.tone;
    final soft = tone.inkSoft!;
    final feeling = entry.feeling;
    final shown = entry.isPage ? const <JournalAnswer>[] : [for (final a in entry.answers) if (a.text.trim().isNotEmpty) a];
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      onLongPress: onHold,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.s, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Thoughts ${entry.stamp.label} · ${savedWhen(entry.created)}',
                    style: handwriting(18, soft, weight: FontWeight.w600),
                  ),
                ),
                if (feeling != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(color: ink.tab(_pickColour(feeling)), borderRadius: BorderRadius.circular(99)),
                    child: Text(feeling, style: handwriting(17, ink.tabInk, weight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (entry.isPage)
              Text(entry.page, maxLines: 12, overflow: TextOverflow.ellipsis, style: handwriting(21, ink.pen).copyWith(height: 1.25))
            else
              for (final a in shown) ...[
                Text(a.question.toUpperCase(), style: Skin.meta(context, size: 9.5, color: soft)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(a.text, maxLines: 6, overflow: TextOverflow.ellipsis, style: handwriting(21, ink.pen).copyWith(height: 1.2)),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

/// The colour [pick] had as a sticker when it was tapped: its place among
/// its question's answers.
int _pickColour(String pick) {
  for (final q in journalQuestionsOf(ListeningPrefs.loaded ?? ListeningPrefs.memory)) {
    final i = q.picks.indexOf(pick);
    if (i >= 0) return i;
  }
  return pick.length;
}

/// Remove [entry], once the reader has said so, with Undo.
Future<void> removeJournalEntry(BuildContext context, JournalEntry entry) async {
  final ok = await confirm(
    context,
    title: 'Remove these thoughts?',
    body: 'Written ${entry.stamp.label}, ${savedWhen(entry.created)}.',
    action: 'Remove',
  );
  if (!ok) return;
  await JournalStore.instance.remove(entry.id);
  if (!context.mounted) return;
  showSnack(context, 'Removed from your journal.', actionLabel: 'Undo', onAction: () => unawaited(JournalStore.instance.put(entry)));
}

/// On a book's page: its journal, the latest entries on a strip of the
/// notebook's paper, and Write.
class BookJournalSection extends StatelessWidget {
  const BookJournalSection({super.key, required this.bookId, required this.bookTitle, required this.stampNow});

  final String bookId;
  final String bookTitle;
  final JournalStamp Function() stampNow;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: JournalStore.instance.changes,
        builder: (context, _, __) {
          final entries = JournalStore.instance.forBook(bookId);
          final ink = NotebookInk.of(context);
          void write() => unawaited(openJournal(context, bookId: bookId, bookTitle: bookTitle, stampNow: stampNow));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: SectionTitle('Journal', note: entries.isEmpty ? null : '${entries.length}')),
                  TextButton.icon(
                    onPressed: write,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Write'),
                  ),
                ],
              ),
              // None yet: the row alone (the pen on the player says the rest).
              if (entries.isNotEmpty)
                DecoratedBox(
                  decoration: ink.tone.paperOf(context).copyWith(borderRadius: BorderRadius.circular(Radii.card / 1.5)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final e in entries.take(3))
                          JournalEntryCard(
                            entry: e,
                            ink: ink,
                            onTap: () => unawaited(openJournal(context,
                                bookId: bookId, bookTitle: bookTitle, stampNow: () => e.stamp, entry: e)),
                            onHold: () => unawaited(removeJournalEntry(context, e)),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      );
}
