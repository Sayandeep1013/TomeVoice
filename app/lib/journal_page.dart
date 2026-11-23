import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, ReadingLayout;

import 'ai/ai_keys.dart';
import 'ai/journal_tidy.dart';
import 'ai/memory/memory_service.dart' show MemoryService;
import 'book_card.dart';
import 'dictation.dart';
import 'journal.dart';
import 'library_store.dart';
import 'listening_session.dart' show BackgroundReading;
import 'notebook.dart';
import 'novel_move.dart' show chapterNumberOf;
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
/// meanwhile). Spoken words are heard in [language] (the book's); [hold]
/// pauses the book's voice while the reader speaks, and gives back how to
/// read on. The entry kept, or null when nothing was.
Future<JournalEntry?> openJournal(
  BuildContext context, {
  required String bookId,
  required String bookTitle,
  required JournalStamp Function() stampNow,
  JournalEntry? entry,
  String? language,
  Future<VoidCallback?> Function()? hold,
  List<JournalChapter>? chapters,
}) async {
  final kept = await Navigator.of(context).push<JournalEntry>(MaterialPageRoute(
    builder: (_) => JournalPage(
        bookId: bookId,
        bookTitle: bookTitle,
        stampNow: stampNow,
        entry: entry,
        language: language,
        hold: hold,
        chapters: chapters),
  ));
  if (kept != null && context.mounted) {
    showSnack(context, entry == null ? 'In your journal, ${kept.stamp.label}.' : 'Changed.');
  }
  return kept;
}

/// A chapter an entry can be stamped with, from the book's list of them
/// (for a web novel, its whole list: nothing need be downloaded to write
/// about a chapter).
typedef JournalChapter = ({int chapter, int number, String title});

/// The chapters of a laid-out book, for the journal's chapter picker.
List<JournalChapter> journalChaptersOf(ReadingLayout layout) => [
      for (var c = 0; c < layout.chapters.length; c++)
        (chapter: c, number: c + 1, title: layout.chapterTitle(c)),
    ];

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
    this.language,
    this.hold,
    this.dictation,
    this.chapters,
  });

  /// The book's chapters, when known: the stamp can then be changed to
  /// another (the entry is about chapter 300, written at 412).
  final List<JournalChapter>? chapters;

  final String bookId;
  final String bookTitle;
  final JournalStamp Function() stampNow;

  /// Written before: changed here, its stamp kept.
  final JournalEntry? entry;

  /// The questions asked (the reader's template by default).
  final List<JournalQuestion>? questions;

  /// The book's language, for hearing what is said (null: the phone's).
  final String? language;

  /// Pauses the book's voice while the reader speaks; gives back how to
  /// read on (null: nothing was reading).
  final Future<VoidCallback?> Function()? hold;

  /// The speech recogniser (a stand-in in tests).
  final Dictation Function()? dictation;

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

  /// A chapter picked for the entry, in place of where the story is.
  JournalStamp? _picked;

  /// Another chapter for this entry, picked from the book's list.
  Future<void> _pickChapter() async {
    final list = widget.chapters;
    if (list == null || list.isEmpty) return;
    final current = (_picked ?? _began).chapter;
    final picked = await showModalBottomSheet<JournalChapter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ChapterSheet(chapters: list, current: current),
    );
    if (picked == null || !mounted) return;
    setState(() => _picked = JournalStamp(
          at: ReadingCursor(sectionIndex: picked.chapter, blockIndex: 0, sentenceIndex: 0),
          chapter: picked.chapter,
          number: picked.number,
          title: picked.title,
        ));
  }

  /// Speaking instead of writing: made when first asked.
  Dictation? _dictation;

  /// The field the words go into: the one last written in.
  TextEditingController? _target;

  /// The fields spoken into, which "Tidy" offers to tidy.
  final _spoken = <TextEditingController>{};

  /// How to read on once the reader has finished speaking.
  VoidCallback? _readOn;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _began = e?.stamp ?? widget.stampNow();
    final template = widget.questions ?? journalQuestionsOf(ListeningPrefs.loaded ?? ListeningPrefs.memory);
    // An entry written before keeps the questions it was asked, and the
    // template's others follow, to answer now.
    _questions = e != null && !e.isPage
        ? [
            // Asked then, no longer in the template: first, as they were.
            for (final a in e.answers)
              if (!template.any((q) => q.text == a.question))
                JournalQuestion(a.question, picks: a.pick == null ? const [] : [a.pick!]),
            ...template,
          ]
        : template;
    _words = [for (var i = 0; i < _questions.length; i++) TextEditingController()];
    _own = [for (var i = 0; i < _questions.length; i++) TextEditingController()];
    _picks = List.filled(_questions.length, null);
    _blank = e != null && e.isPage;
    if (e != null) {
      _page.text = e.page;
      for (final a in e.answers) {
        final i = _questions.indexWhere((q) => q.text == a.question);
        if (i < 0) continue;
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
    _dictation?.dispose();
    _readOn?.call();
    for (final c in [..._words, ..._own, _page]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Where spoken words go: the field last written in, else the page or
  /// the first question asked in words.
  TextEditingController? get _into {
    if (_blank) return _page;
    final t = _target;
    if (t != null && t != _page) return t;
    for (var i = 0; i < _questions.length; i++) {
      if (!_questions[i].isPick) return _words[i];
    }
    return null;
  }

  bool get _listening => _dictation?.listening.value ?? false;

  Future<void> _speak() async {
    final d = _dictation ??= widget.dictation?.call() ?? Dictation()
      ..onWords = _heard
      ..onProblem = (p) {
        if (mounted) showSnack(context, p);
      };
    if (_listening) {
      await d.stop();
      return;
    }
    if (!await _toldOfDictation()) return;
    // The book's voice would be heard too: it waits.
    _readOn ??= await widget.hold?.call();
    final ok = await d.start(language: widget.language);
    if (!ok) _readsOn();
    if (mounted) setState(() {});
  }

  Future<bool> _toldOfDictation() async => await tellOfDictation(context) && mounted;

  /// The book's voice reads on, once the reader has finished speaking.
  void _readsOn() {
    final go = _readOn;
    _readOn = null;
    go?.call();
  }

  void _heard(String words) {
    final c = _into;
    if (c == null || !mounted) return;
    final sel = c.selection;
    final r = insertWords(c.text, words, at: sel.isValid ? sel.end : null);
    c.value = TextEditingValue(text: r.text, selection: TextSelection.collapsed(offset: r.at));
    _spoken.add(c);
    setState(() {});
  }

  Future<void> _tidy() async {
    if (_listening) await _dictation?.stop();
    if (!mounted) return;
    final fields = [for (final c in _spoken) if (c.text.trim().isNotEmpty) c];
    if (fields.isEmpty) return;
    final tidied = await tidyJournalText(context, [for (final c in fields) c.text], about: widget.bookTitle);
    if (tidied == null || !mounted) return;
    for (final (i, c) in fields.indexed) {
      if (i < tidied.length) c.text = tidied[i];
    }
    _spoken.clear();
    setState(() {});
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
    if (_picked != null) {
      stamp = _picked!;
    } else if (old != null) {
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
        ? old.copyWith(
            answers: answers, page: _blank ? _page.text.trim() : '', edited: DateTime.now().toUtc(), stamp: stamp)
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

  /// Where the entry is stamped; with the book's chapters known, a tap
  /// picks another.
  Widget _stampLine(BuildContext context, Color soft) {
    final stamp = _picked ?? _began;
    final text = _picked != null
        ? 'about ${stamp.label.replaceFirst('up to ', '')}'
        : widget.entry == null
            ? 'writing at ${stamp.label.replaceFirst('up to ', '')}'
            : stamp.label;
    final style = Skin.meta(context, size: 10.5, color: soft);
    if (widget.chapters == null || widget.chapters!.isEmpty) return Text(text.toUpperCase(), style: style);
    return InkWell(
      onTap: () => unawaited(_pickChapter()),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(text.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 16, color: soft),
            Text('CHANGE', style: style.copyWith(decoration: TextDecoration.underline)),
          ],
        ),
      ),
    );
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
                                _stampLine(context, soft),
                              ],
                            ),
                          ),
                          // Never for a book on a secret shelf or kept away from the AI.
                          if (_spoken.isNotEmpty &&
                              AiRing.instance.hasKeys &&
                              MemoryService.instance.maySend(widget.bookId))
                            IconButton(
                              tooltip: 'Tidy what you said',
                              icon: Icon(Icons.auto_fix_high_rounded, color: soft),
                              onPressed: () => unawaited(_tidy()),
                            ),
                          _MicButton(
                            listening: _dictation?.listening,
                            level: _dictation?.level,
                            colour: tone.accent ?? Skin.accentOf(context),
                            idle: soft,
                            onTap: () => unawaited(_speak()),
                          ),
                          const SizedBox(width: Gap.xs),
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
                                onTap: () => _target = _page,
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
                    if (_dictation != null)
                      ValueListenableBuilder<bool>(
                        valueListenable: _dictation!.listening,
                        builder: (context, on, _) {
                          if (!on) {
                            // Finished speaking: the book reads on.
                            if (_readOn != null) WidgetsBinding.instance.addPostFrameCallback((_) => _readsOn());
                            return const SizedBox.shrink();
                          }
                          return ValueListenableBuilder<String>(
                            valueListenable: _dictation!.heard,
                            builder: (context, heard, _) => Padding(
                              padding: const EdgeInsets.fromLTRB(34, Gap.s, Gap.l, Gap.m),
                              child: Text(
                                heard.isEmpty ? 'Listening… say what you think, then tap the microphone.' : heard,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: heard.isEmpty
                                    ? Skin.meta(context, color: soft)
                                    : handwriting(21, soft.withValues(alpha: 0.8)).copyWith(height: 1.2),
                              ),
                            ),
                          );
                        },
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
            // A word of the reader's own, when none of the picks is it. It
            // wraps like the other answers: a longer one, written here,
            // never runs on along one line out of sight.
            TextField(
              controller: _own[i],
              onChanged: (v) => setState(() {
                if (v.trim().isNotEmpty) _picks[i] = null;
              }),
              maxLines: null,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.sentences,
              style: handwriting(22, ink.pen),
              decoration: _onPaper('or in a word of your own…',handwriting(20, soft.withValues(alpha: 0.6))),
            ),
          ] else
            TextField(
              controller: _words[i],
              onTap: () => _target = _words[i],
              onChanged: (_) {
                _target = _words[i];
                setState(() {});
              },
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
  const JournalEntryCard(
      {super.key, required this.entry, required this.ink, this.onTap, this.onHold, this.boxed = true});

  /// Drawn as a box of its own (on a notebook page, among others); off
  /// where its card is the box already.
  final bool boxed;

  final JournalEntry entry;
  final NotebookInk ink;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  @override
  Widget build(BuildContext context) {
    final tone = ink.tone;
    final soft = tone.inkSoft!;
    final feeling = entry.feeling;
    // A feeling in the reader's own words, longer than a sticker holds,
    // is written out on a line of its own instead.
    final longFeeling = feeling != null && feeling.length > 24;
    final shown = entry.isPage ? const <JournalAnswer>[] : [for (final a in entry.answers) if (a.text.trim().isNotEmpty) a];
    // Each entry a box of its own on the paper: where one ends and the
    // next begins is plain, and each is tapped by itself.
    final box = BorderRadius.circular(12);
    return Material(
      color: boxed ? tone.ink!.withValues(alpha: tone.dark ? 0.06 : 0.035) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: box,
        side: boxed ? BorderSide(color: tone.ink!.withValues(alpha: 0.16)) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
      onTap: onTap,
      onLongPress: onHold,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (entry.isTalk)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(Icons.auto_awesome_rounded, size: 16, color: soft),
                  ),
                Expanded(
                  child: Text(
                    '${entry.isTalk ? 'A talk' : 'Thoughts'} ${entry.stamp.label} · ${savedWhen(entry.created)}',
                    style: handwriting(18, soft, weight: FontWeight.w600),
                  ),
                ),
                if (feeling != null && !longFeeling)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(color: ink.tab(_pickColour(feeling)), borderRadius: BorderRadius.circular(99)),
                    child: Text(feeling, style: handwriting(17, ink.tabInk, weight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (feeling != null && longFeeling)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(feeling,
                    maxLines: 4, overflow: TextOverflow.ellipsis, style: handwriting(21, ink.pen).copyWith(height: 1.2)),
              ),
            if (entry.isTalk)
              for (final l in entry.talk.take(4))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: l.mine
                      ? Text(l.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: handwriting(21, ink.pen).copyWith(height: 1.2))
                      : Text(l.text,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: tone.ink).copyWith(height: 1.35)),
                )
            else if (entry.isPage)
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
  const BookJournalSection(
      {super.key, required this.bookId, required this.bookTitle, required this.stampNow, this.onSeeAll, this.chapters});

  /// The book's chapters, for picking which one an entry is about.
  final List<JournalChapter> Function()? chapters;

  /// The book's whole journal (the Journal, this book's alone).
  final VoidCallback? onSeeAll;

  final String bookId;
  final String bookTitle;
  final JournalStamp Function() stampNow;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: JournalStore.instance.changes,
        builder: (context, _, __) {
          final entries = JournalStore.instance.forBook(bookId);
          void write() => unawaited(openJournal(context,
              bookId: bookId, bookTitle: bookTitle, stampNow: stampNow, chapters: chapters?.call()));
          final latest = entries.firstOrNull;
          // A compact block, so the chapters are not pushed far down: how
          // many, the latest, and its first lines as written (each answer on
          // a line of its own, wrapping, not run together on one cut line);
          // the whole journal a tap away.
          final line = latest == null
              ? 'Write how the book makes you feel, as you read'
              : '${entries.length} ${entries.length == 1 ? 'entry' : 'entries'} · '
                  '${latest.isTalk ? 'a talk' : 'thoughts'} ${latest.stamp.label}, ${savedWhen(latest.created)}';
          final words = latest?.preview ?? '';
          return Material(
            color: Skin.capsuleOn(context),
            borderRadius: BorderRadius.circular(Radii.row + 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.row + 4),
              onTap: latest == null ? write : onSeeAll,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.xs, Gap.m),
                child: Row(
                  children: [
                    Icon(Icons.edit_note_rounded, color: Skin.accentInkOf(context)),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Journal', style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                          const SizedBox(height: 2),
                          Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.meta(context)),
                          // Always two lines high, cut with "…": the row is
                          // the same size however much was written.
                          if (words.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: SizedBox(
                                height: 13.5 * 1.3 * 2,
                                child: Text(
                                  words,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                                      .copyWith(height: 1.3),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(tooltip: 'Write', icon: const Icon(Icons.edit_outlined), onPressed: write),
                    if (latest != null) Icon(Icons.chevron_right_rounded, color: Skin.inkSoftOn(context)),
                  ],
                ),
              ),
            ),
          );
        },
      );
}

/// Where the story is in book [e], for an entry written away from its
/// reader (the Journal's Write): the voice's sentence when it reads this
/// book, else the saved place, found in the book as it is laid out.
Future<JournalStamp> stampForBook(LibraryStore store, LibraryEntry e) async {
  final bg = BackgroundReading.current.value;
  if (bg != null && bg.bookId == e.id) {
    return stampAt(bg.layout, bg.unit, numberOf: (c) => chapterNumberOf(bg.layout.chapterTitle(c))?.floor() ?? c + 1);
  }
  final cursor = await store.cursorFor(e.id);
  try {
    final layout = await store.loadLayout(e.id, around: e.isWeb ? cursor.sectionIndex : null);
    if (layout.isEmpty) throw StateError('empty');
    return stampAt(layout, layout.unitForCursor(cursor, saved: true),
        numberOf: e.isWeb ? (c) => chapterNumberOf(layout.chapterTitle(c))?.floor() ?? c + 1 : null);
  } on Object {
    // Not to be read now: the chapter its place is in, as it is counted.
    return JournalStamp(at: cursor, chapter: cursor.sectionIndex, number: cursor.sectionIndex + 1);
  }
}

/// Which book to write about: the library's, the most lately opened first.
Future<LibraryEntry?> pickBookToWrite(BuildContext context, LibraryStore store) async {
  final books = [...await store.list()]..sort((a, b) {
      final x = a.openedAt, y = b.openedAt;
      if (x == null && y == null) return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
  if (!context.mounted) return null;
  if (books.isEmpty) {
    showSnack(context, 'Add a book first: the journal is written about one.');
    return null;
  }
  return showModalBottomSheet<LibraryEntry>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Write about', subtitle: 'The book you were last in, first'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: Gap.l),
              children: [
                for (final b in books)
                  ListTile(
                    leading: SizedBox(width: 30, child: BookCover(entry: b, width: 30, titled: false)),
                    title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: b.authorLine.isEmpty
                        ? null
                        : Text(b.authorLine, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(context).pop(b),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The Journal's Write: a new entry about [e], stamped where its story is.
Future<void> writeAbout(BuildContext context, LibraryStore store, LibraryEntry e) async {
  final stamp = await stampForBook(store, e);
  if (!context.mounted) return;
  await openJournal(context, bookId: e.id, bookTitle: e.title, stampNow: () => stamp);
}

/// The journal's microphone: tap to speak, tap again to stop. While it
/// listens it is filled, with a ring that swells as the voice does.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.listening,
    required this.level,
    required this.colour,
    required this.idle,
    required this.onTap,
  });

  final ValueNotifier<bool>? listening;
  final ValueNotifier<double>? level;
  final Color colour;
  final Color idle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Widget button(bool on, double loud) => Semantics(
          button: true,
          toggled: on,
          label: on ? 'Stop speaking' : 'Speak instead of writing',
          child: InkResponse(
            onTap: onTap,
            radius: 24,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (on)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      width: 30 + 14 * loud,
                      height: 30 + 14 * loud,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: colour.withValues(alpha: 0.22)),
                    ),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: on ? colour : Colors.transparent),
                    child: Icon(on ? Icons.stop_rounded : Icons.mic_none_rounded,
                        size: 22, color: on ? Colors.white : idle),
                  ),
                ],
              ),
            ),
          ),
        );
    final l = listening, v = level;
    if (l == null || v == null) return button(false, 0);
    return ValueListenableBuilder<bool>(
      valueListenable: l,
      builder: (context, on, _) => ValueListenableBuilder<double>(
        valueListenable: v,
        builder: (context, loud, _) => button(on, on ? loud : 0),
      ),
    );
  }
}

/// Before speaking is first heard: where what is said goes. False when the
/// reader would rather not. Asked once (ListeningPrefs.dictationTold).
Future<bool> tellOfDictation(BuildContext context, {String into = 'into your journal'}) async {
  final p = ListeningPrefs.loaded;
  if (p == null || p.dictationTold) return true;
  final go = await confirm(
    context,
    title: 'Speak instead of typing',
    body: "Your phone's own speech service (on most phones, Google's) turns what you say into words. "
        'It may send your voice to that service to do it. TomeVoice keeps no recording: only the words '
        'come back, $into.',
    action: 'Speak',
  );
  if (!go) return false;
  p.dictationTold = true;
  p.save();
  return true;
}

/// The book's chapters to pick one from: opened at the one given, with a
/// box to jump to a number or find a title (a web novel may have
/// thousands).
class _ChapterSheet extends StatefulWidget {
  const _ChapterSheet({required this.chapters, required this.current});

  final List<JournalChapter> chapters;
  final int current;

  @override
  State<_ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends State<_ChapterSheet> {
  static const _row = 56.0;
  String _query = '';
  late final _scroll = ScrollController(
    initialScrollOffset: math.max(0, widget.chapters.indexWhere((c) => c.chapter == widget.current) - 3) * _row,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final n = int.tryParse(q);
    final shown = q.isEmpty
        ? widget.chapters
        : [
            for (final c in widget.chapters)
              if (c.number == n || c.title.toLowerCase().contains(q)) c,
          ];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
            child: Text('Which chapter is it about?', style: Skin.title(context, size: 18)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
            child: SearchField(hint: 'A number, or words of its title', onChanged: (v) => setState(() => _query = v)),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text('No chapter matches.', style: Skin.meta(context)))
                : ListView.builder(
                    controller: q.isEmpty ? _scroll : null,
                    itemExtent: _row,
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final c = shown[i];
                      final here = c.chapter == widget.current;
                      final title = c.title.trim();
                      return ListTile(
                        selected: here,
                        title: Text(
                          title.isEmpty
                              ? 'Chapter ${c.number}'
                              // A title that says its number already is not
                              // given it twice ("Chapter 12 The Fall").
                              : RegExp('\\b${c.number}\\b').hasMatch(title)
                                  ? title
                                  : '${c.number}. $title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: here ? const Icon(Icons.check_rounded) : null,
                        onTap: () => Navigator.of(context).pop(c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
