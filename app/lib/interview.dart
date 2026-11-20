import 'dart:async';

import 'package:flutter/material.dart';

import 'dictation.dart';
import 'journal.dart';
import 'theme.dart';
import 'ui.dart';

/// A journal question as the voice asks it: the reader's own words ("How am
/// I feeling?") turned to them ("How are you feeling?"), a pick question's
/// answers said after it.
String askedAloud(JournalQuestion q) {
  var t = q.text.trim();
  for (final (from, to) in const [
    (r"\bam I\b", 'are you'),
    (r"\bI am\b", 'you are'),
    (r"\bI'm\b", "you're"),
    (r"\bI've\b", "you've"),
    (r"\bI\b", 'you'),
    (r"\bmy\b", 'your'),
    (r"\bme\b", 'you'),
    (r"\bmine\b", 'yours'),
    (r"\bmyself\b", 'yourself'),
  ]) {
    t = t.replaceAllMapped(RegExp(from, caseSensitive: false), (m) {
      final w = m.group(0)!;
      return w[0] == w[0].toUpperCase() && w[0] != w[0].toLowerCase() && m.start == 0
          ? to[0].toUpperCase() + to.substring(1)
          : to;
    });
  }
  if (q.isPick) {
    final picks = q.picks;
    final said = picks.length == 1 ? picks.first : '${picks.take(picks.length - 1).join(', ')} or ${picks.last}';
    t = '$t $said?';
  }
  return t;
}

/// What a spoken answer comes to: the end of the interview, a question
/// passed, or the answer.
sealed class Heard {
  const Heard();
}

class HeardStop extends Heard {
  const HeardStop();
}

class HeardSkip extends Heard {
  const HeardSkip();
}

class HeardAnswer extends Heard {
  const HeardAnswer(this.answer);

  final JournalAnswer answer;
}

final _stop = RegExp(r"^(stop|stop it|stop the interview|that'?s all|that is all|enough|done|i'?m done|finish)\W*$",
    caseSensitive: false);
final _skip = RegExp(r'^(skip|skip it|next|pass|no answer|nothing|nothing really)\W*$', caseSensitive: false);

/// [words] said to [q]: a pick question's pick matched in them ("pretty
/// good, actually" is Good), and the words kept beside it.
Heard heardFor(JournalQuestion q, String words) {
  final w = words.trim();
  if (w.isEmpty || _skip.hasMatch(w)) return const HeardSkip();
  if (_stop.hasMatch(w)) return const HeardStop();
  if (q.isPick) {
    final low = w.toLowerCase();
    // The longest pick said wins: "not good" over "good" when both are picks.
    final said = [...q.picks]..sort((a, b) => b.length - a.length);
    final pick = said.where((p) => RegExp('\\b${RegExp.escape(p.toLowerCase())}\\b').hasMatch(low)).firstOrNull;
    if (pick != null) {
      final rest = w.trim().toLowerCase() == pick.toLowerCase() ? '' : _sentence(w);
      return HeardAnswer(JournalAnswer(question: q.text, pick: pick, text: rest));
    }
  }
  return HeardAnswer(JournalAnswer(question: q.text, text: _sentence(w)));
}

/// Spoken words written as a sentence: a capital, and a stop.
String _sentence(String w) {
  final t = w.trim();
  if (t.isEmpty) return t;
  final first = t[0].toUpperCase() + t.substring(1);
  return RegExp(r'[.!?]$').hasMatch(first) ? first : '$first.';
}

/// Interview me: the journal's [questions] about chapter [chapter] asked
/// aloud with [say], each answer heard and written down. The answers given
/// (none when the reader stopped before any), or null when closed at once.
Future<List<JournalAnswer>?> runInterview(
  BuildContext context, {
  required List<JournalQuestion> questions,
  required int chapter,
  required Future<void> Function(String text) say,
  VoidCallback? hush,
  String? language,
  Dictation Function()? dictation,
  Duration patience = const Duration(seconds: 12),
  Duration settle = const Duration(milliseconds: 1600),
}) =>
    showModalBottomSheet<List<JournalAnswer>>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => InterviewSheet(
        questions: questions,
        chapter: chapter,
        say: say,
        hush: hush,
        language: language,
        dictation: dictation,
        patience: patience,
        settle: settle,
      ),
    );

class InterviewSheet extends StatefulWidget {
  const InterviewSheet({
    super.key,
    required this.questions,
    required this.chapter,
    required this.say,
    this.hush,
    this.language,
    this.dictation,
    this.patience = const Duration(seconds: 12),
    this.settle = const Duration(milliseconds: 1600),
  });

  final List<JournalQuestion> questions;
  final int chapter;
  final Future<void> Function(String text) say;
  final VoidCallback? hush;
  final String? language;
  final Dictation Function()? dictation;

  /// How long silence is waited out before a question is passed.
  final Duration patience;

  /// How long after the last words before an answer is taken as whole.
  final Duration settle;

  @override
  State<InterviewSheet> createState() => _InterviewSheetState();
}

class _InterviewSheetState extends State<InterviewSheet> {
  late final Dictation _d = widget.dictation?.call() ?? Dictation();
  final _answers = <JournalAnswer>[];
  int _at = 0;
  bool _asking = false;
  bool _ended = false;
  String? _problem;
  Completer<String>? _listen;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _ended = true;
    if (!(_listen?.isCompleted ?? true)) _listen!.complete('');
    widget.hush?.call();
    // Its listening cancelled; the loop, woken, touches it no more.
    _d.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    for (_at = 0; _at < widget.questions.length && !_ended; _at++) {
      final q = widget.questions[_at];
      if (mounted) setState(() => _asking = true);
      try {
        await widget.say(askedAloud(q));
      } on Object {
        // Unsaid, it is still shown.
      }
      if (_ended || !mounted) return;
      setState(() => _asking = false);
      final words = await _hear();
      if (_ended || !mounted) return;
      if (_problem != null) break;
      switch (heardFor(q, words)) {
        case HeardStop():
          _finish();
          return;
        case HeardSkip():
          break;
        case HeardAnswer(:final answer):
          setState(() => _answers.add(answer));
      }
    }
    if (_problem == null) _finish();
  }

  /// One answer, heard: what is said until a pause, or nothing.
  Future<String> _hear() async {
    final done = _listen = Completer<String>();
    final said = <String>[];
    Timer? quiet;
    void finish() {
      if (!done.isCompleted) done.complete(said.join(' '));
    }

    void heard() {
      // Still speaking: not over yet.
      if (_d.heard.value.isNotEmpty) quiet?.cancel();
    }

    _d
      ..onWords = (w) {
        said.add(w);
        quiet?.cancel();
        quiet = Timer(widget.settle, finish);
      }
      ..onProblem = (p) {
        if (mounted) setState(() => _problem = p);
        finish();
      };
    _d.heard.addListener(heard);
    final ok = await _d.start(language: widget.language);
    if (!ok) {
      finish();
    } else {
      quiet = Timer(widget.patience, finish);
    }
    final words = await done.future;
    quiet?.cancel();
    if (_ended) return '';
    _d.heard.removeListener(heard);
    await _d.stop();
    return words;
  }

  void _finish() {
    if (_ended) return;
    _ended = true;
    if (mounted) Navigator.of(context).pop(List<JournalAnswer>.of(_answers));
  }

  /// The question passed by a tap.
  void _skip() {
    final l = _listen;
    if (l != null && !l.isCompleted) l.complete('');
  }

  @override
  Widget build(BuildContext context) {
    final q = _at < widget.questions.length ? widget.questions[_at] : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader('Interview', subtitle: 'About chapter ${widget.chapter}'),
            if (q != null)
              Text(askedAloud(q), style: Skin.title(context, size: 24)),
            const SizedBox(height: Gap.m),
            if (_problem != null)
              Text(_problem!, style: Skin.ui(size: 14, weight: FontWeight.w500, color: Theme.of(context).colorScheme.error))
            else if (_asking)
              Text('Asking…', style: Skin.meta(context))
            else
              ValueListenableBuilder<String>(
                valueListenable: _d.heard,
                builder: (context, heard, _) => Text(
                  heard.isEmpty ? 'Listening… say "skip" to pass, "stop" to end' : heard,
                  style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkSoftOn(context)),
                ),
              ),
            if (_answers.isNotEmpty) ...[
              const SizedBox(height: Gap.l),
              for (final a in _answers)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Text(
                    '${a.question} ${[if (a.pick != null) a.pick!, if (a.text.isNotEmpty) a.text].join(' · ')}',
                    style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkOn(context)),
                  ),
                ),
            ],
            const SizedBox(height: Gap.l),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _problem == null ? _skip : null, child: const Text('Skip')),
                const SizedBox(width: Gap.s),
                FilledButton(onPressed: _finish, child: const Text('Done')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
