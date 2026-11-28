import 'dart:async';

import 'package:flutter/material.dart';

import 'book_tint.dart';
import 'library_store.dart';
import 'marks.dart';
import 'prefs.dart';
import 'reader_screen.dart' show openBook;
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'vocabulary.dart';
import 'voices.dart';

/// The words the reader looked up or kept while reading: what each means
/// in their words, the sentences they met it in (a tap goes back there),
/// and a review that brings each back as it is due.
class VocabularyScreen extends StatefulWidget {
  const VocabularyScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<VocabularyScreen> createState() => _VocabularyScreenState();
}

enum _Show { learning, learnt }

class _VocabularyScreenState extends State<VocabularyScreen> {
  final _vocab = VocabularyStore.instance;
  _Show _show = _Show.learning;
  String _query = '';

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: _vocab.changes,
        builder: (context, _, __) => _build(context),
      );

  Widget _build(BuildContext context) {
    final all = _vocab.all;
    final learning = all.where((w) => !w.learnt).toList();
    final learnt = all.where((w) => w.learnt).toList();
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final w in _show == _Show.learning ? learning : learnt)
        if (q.isEmpty || '${w.word} ${w.meaning} ${w.seen.map((s) => s.bookTitle).join(' ')}'.toLowerCase().contains(q)) w,
    ];
    final due = _vocab.dueCount();
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Vocabulary', onBack: () => Navigator.of(context).maybePop()),
              if (all.isEmpty)
                const Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.spellcheck_rounded,
                        title: 'No words yet',
                        body: 'Hold a word while reading and pick Look up, or Keep to learn. '
                            'It comes here with the sentence you met it in, to learn by review.',
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      _reviewCard(context, due, learning.length),
                      const SizedBox(height: Gap.l),
                      ChoiceRow<_Show>(
                        options: [
                          (_Show.learning, 'Learning  ${learning.length}'),
                          (_Show.learnt, 'Learnt  ${learnt.length}'),
                        ],
                        value: _show,
                        onChanged: (s) => setState(() => _show = s),
                      ),
                      const SizedBox(height: Gap.m),
                      if (all.length > 8) ...[
                        SearchField(hint: 'Find a word', onChanged: (v) => setState(() => _query = v)),
                        const SizedBox(height: Gap.m),
                      ],
                      if (shown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: Gap.l),
                          child: Text(
                            _show == _Show.learnt ? 'Words known five reviews running come here.' : 'Nothing here.',
                            style: Skin.meta(context, size: 13),
                          ),
                        ),
                      for (final w in shown) _row(context, w),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reviewCard(BuildContext context, int due, int learning) {
    final next = _vocab.all.where((w) => !w.learnt && w.due != null).map((w) => w.due!).fold<DateTime?>(
          null,
          (a, b) => a == null || b.isBefore(a) ? b : a,
        );
    final String line;
    if (due > 0) {
      line = due == 1 ? 'One word is due for review.' : '$due words are due for review.';
    } else if (next != null) {
      final days = next.toLocal().difference(DateTime.now()).inHours / 24;
      line = days < 1 ? 'All reviewed. More are due later today.' : 'All reviewed. The next are due in ${days.ceil()} ${days.ceil() == 1 ? 'day' : 'days'}.';
    } else {
      line = learning == 0 ? 'Every word here is learnt.' : 'All reviewed.';
    }
    return Material(
      color: Skin.capsuleOn(context),
      shape: Skin.cardShape(context, Radii.card),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Review', style: Skin.label(context, size: 16, color: Skin.inkOn(context))),
                  const SizedBox(height: Gap.xs),
                  Text(line, style: Skin.meta(context, size: 12.5)),
                ],
              ),
            ),
            const SizedBox(width: Gap.m),
            FilledButton(
              onPressed: due == 0
                  ? null
                  : () => unawaited(Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => VocabularyReview(store: widget.store)),
                      )),
              child: Text(due == 0 ? 'Done' : 'Start'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, VocabWord w) {
    final sub = w.meaning.isNotEmpty ? w.meaning : (w.seen.lastOrNull?.sentence ?? '');
    final book = w.seen.lastOrNull?.bookTitle ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Material(
        color: Skin.capsuleOn(context),
        shape: Skin.cardShape(context, Radii.row),
        child: InkWell(
          customBorder: Skin.cardShape(context, Radii.row),
          onTap: () => unawaited(showWordSheet(context, widget.store, w)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(w.word, style: Skin.title(context, size: 18, weight: FontWeight.w600))),
                    if (w.dueAt(DateTime.now().toUtc()))
                      Text('DUE', style: Skin.meta(context, size: 9.5).copyWith(color: Skin.accentInkOf(context))),
                  ],
                ),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.35)),
                ],
                if (book.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(book, maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.meta(context, size: 10.5)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [w] said in its book's voice (the reader's voice for that book, else
/// for its language).
Future<void> sayWord(BuildContext context, VocabWord w) async {
  final prefs = ListeningPrefs.loaded ?? ListeningPrefs.memory;
  final catalog = VoiceCatalog.instance;
  final book = w.seen.lastOrNull?.bookId;
  final voice = (book == null ? null : prefs.voiceByBook[book]) ?? prefs.voiceByLanguage['en'] ?? catalog.bestFor('en')?.name;
  if (voice == null) return;
  try {
    await speakSample(
      voiceName: voice,
      text: w.word,
      settings: prefs.settingsFor(voice),
      engineId: prefs.engineId ?? catalog.engineId,
    );
  } on Object {
    if (context.mounted) showSnack(context, 'The voice could not say it just now.');
  }
}

/// [sentence] with [word] in it set in bold.
Widget sentenceWithWord(BuildContext context, String sentence, String word, {double size = 15}) {
  final base = Skin.title(context, size: size, weight: FontWeight.w400, italic: true).copyWith(height: 1.45);
  final i = sentence.toLowerCase().indexOf(word.toLowerCase());
  if (i < 0) return Text('“$sentence”', style: base);
  return Text.rich(TextSpan(style: base, children: [
    TextSpan(text: '“${sentence.substring(0, i)}'),
    TextSpan(
      text: sentence.substring(i, i + word.length),
      style: TextStyle(fontWeight: FontWeight.w700, fontStyle: FontStyle.normal, color: Skin.accentInkOf(context)),
    ),
    TextSpan(text: '${sentence.substring(i + word.length)}”'),
  ]));
}

Future<void> _openAt(BuildContext context, LibraryStore store, VocabWord w, WordSeen s) async {
  final entry = (await store.list()).where((e) => e.id == s.bookId).firstOrNull;
  if (!context.mounted) return;
  if (entry == null) {
    showSnack(context, 'That book is no longer in your library.');
    return;
  }
  await openBook(
    context,
    store,
    entry,
    at: Mark(
      id: 'vocabulary',
      bookId: s.bookId,
      bookTitle: s.bookTitle,
      kind: MarkKind.bookmark,
      at: s.at,
      text: s.sentence,
      created: s.when,
    ),
  );
}

/// One word: hear it, what it means, where it was met, look it up again,
/// learnt or not, or take it out.
Future<void> showWordSheet(BuildContext context, LibraryStore store, VocabWord word) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(context),
      builder: (ctx) => carryTint(context, _WordSheet(store: store, word: word)),
    );

class _WordSheet extends StatefulWidget {
  const _WordSheet({required this.store, required this.word});

  final LibraryStore store;
  final VocabWord word;

  @override
  State<_WordSheet> createState() => _WordSheetState();
}

class _WordSheetState extends State<_WordSheet> {
  late final _meaning = TextEditingController(text: widget.word.meaning);

  VocabWord get _w => VocabularyStore.instance.byWord(widget.word.word) ?? widget.word;

  @override
  void dispose() {
    final m = _meaning.text.trim();
    if (m != widget.word.meaning) unawaited(VocabularyStore.instance.setMeaning(widget.word.word, m));
    _meaning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = _w;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text(w.word, style: Skin.heading(context, size: 28))),
                  RoundButton(icon: Icons.volume_up_rounded, tooltip: 'Hear it', onTap: () => unawaited(sayWord(context, w))),
                ],
              ),
              const SizedBox(height: Gap.m),
              TextField(
                controller: _meaning,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'What it means, in your words'),
              ),
              const SizedBox(height: Gap.l),
              const Eyebrow('Where you met it'),
              const SizedBox(height: Gap.s),
              for (final s in w.seen.reversed)
                InkWell(
                  borderRadius: BorderRadius.circular(Radii.row),
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_openAt(context, widget.store, w, s));
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.s),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        sentenceWithWord(context, s.sentence, w.word),
                        const SizedBox(height: 2),
                        Text('${s.bookTitle} · tap to go there', style: Skin.meta(context, size: 10.5)),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: Gap.m),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (!await const SpeechService().lookUp(w.word) && context.mounted) {
                        showSnack(context, 'No app on this phone looks words up. A dictionary app can.');
                      }
                    },
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('Look up'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(VocabularyStore.instance.setLearnt(w.word, !w.learnt).then((_) {
                      if (mounted) setState(() {});
                    })),
                    icon: Icon(w.learnt ? Icons.replay_rounded : Icons.check_rounded, size: 18),
                    label: Text(w.learnt ? 'Learn again' : 'I know it'),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      final gone = w;
                      Navigator.of(context).pop();
                      unawaited(VocabularyStore.instance.remove(w.word));
                      showSnack(
                        context,
                        '"${gone.word}" taken out.',
                        actionLabel: 'Undo',
                        onAction: () => unawaited(VocabularyStore.instance.restore(gone)),
                      );
                    },
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Take out'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The words due, one card at a time: the word, said if asked; then where
/// it was met and what it means; then whether it was known.
class VocabularyReview extends StatefulWidget {
  const VocabularyReview({super.key, required this.store});

  final LibraryStore store;

  @override
  State<VocabularyReview> createState() => _VocabularyReviewState();
}

class _VocabularyReviewState extends State<VocabularyReview> {
  late final List<VocabWord> _cards = VocabularyStore.instance.due();
  int _at = 0;
  bool _shown = false;
  int _knew = 0;
  final _again = <VocabWord>[];

  Future<void> _answer(bool knew) async {
    final w = _cards[_at];
    await VocabularyStore.instance.review(w.word, knew: knew);
    if (knew) {
      _knew++;
    } else {
      _again.add(w);
    }
    if (!mounted) return;
    setState(() {
      _at++;
      _shown = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final done = _at >= _cards.length;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(
                title: done ? 'Review' : 'Review  ${_at + 1} of ${_cards.length}',
                onBack: () => Navigator.of(context).maybePop(),
              ),
              Expanded(child: done ? _end(context) : _card(context, VocabularyStore.instance.byWord(_cards[_at].word) ?? _cards[_at])),
            ],
          ),
        ),
      ),
    );
  }

  Widget _end(BuildContext context) => Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: Icons.check_circle_outline_rounded,
            title: 'Reviewed',
            body: _cards.isEmpty
                ? 'No words are due now.'
                : '$_knew of ${_cards.length} known. '
                    '${_again.isEmpty ? 'Each comes back later, further off the better you know it.' : '${_again.length == 1 ? 'The one' : 'The ${_again.length}'} not known come back tomorrow.'}',
            action: FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Done')),
          ),
        ),
      );

  Widget _card(BuildContext context, VocabWord w) {
    final s = w.seen.lastOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Material(
              color: Skin.capsuleOn(context),
              shape: Skin.cardShape(context, Radii.card),
              child: InkWell(
                customBorder: Skin.cardShape(context, Radii.card),
                onTap: _shown ? null : () => setState(() => _shown = true),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: Gap.xl),
                        Text(w.word, textAlign: TextAlign.center, style: Skin.heading(context, size: 34)),
                        const SizedBox(height: Gap.s),
                        RoundButton(icon: Icons.volume_up_rounded, tooltip: 'Hear it', onTap: () => unawaited(sayWord(context, w))),
                        const SizedBox(height: Gap.xl),
                        AnimatedSwitcher(
                          duration: Motion.of(context, Motion.standard),
                          child: !_shown
                              ? Text('Do you know what it means? Tap to see.',
                                  key: const ValueKey('ask'), textAlign: TextAlign.center, style: Skin.meta(context, size: 13))
                              : Column(
                                  key: const ValueKey('shown'),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (w.meaning.isNotEmpty) ...[
                                      Text(w.meaning, style: Skin.ui(size: 17, weight: FontWeight.w500, color: Skin.inkOn(context))),
                                      const SizedBox(height: Gap.l),
                                    ],
                                    if (s != null) ...[
                                      sentenceWithWord(context, s.sentence, w.word, size: 16),
                                      const SizedBox(height: Gap.xs),
                                      Text(s.bookTitle, style: Skin.meta(context, size: 10.5)),
                                    ],
                                    const SizedBox(height: Gap.l),
                                    Wrap(
                                      spacing: Gap.s,
                                      children: [
                                        TextButton.icon(
                                          onPressed: () => unawaited(const SpeechService().lookUp(w.word)),
                                          icon: const Icon(Icons.menu_book_outlined, size: 18),
                                          label: const Text('Look up'),
                                        ),
                                        TextButton.icon(
                                          onPressed: () => unawaited(showWordSheet(context, widget.store, w)),
                                          icon: const Icon(Icons.edit_outlined, size: 18),
                                          label: Text(w.meaning.isEmpty ? 'Write its meaning' : 'Edit'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Gap.l),
          if (!_shown)
            FilledButton(onPressed: () => setState(() => _shown = true), child: const Text('Show'))
          else
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: () => unawaited(_answer(false)), child: const Text('Not yet'))),
                const SizedBox(width: Gap.m),
                Expanded(child: FilledButton(onPressed: () => unawaited(_answer(true)), child: const Text('Knew it'))),
              ],
            ),
        ],
      ),
    );
  }
}
