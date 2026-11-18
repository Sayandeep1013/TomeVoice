import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'journal.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui.dart';

/// Settings > Journal questions: what the journal asks, in order. Each is
/// answered in words, or by a tap on one of its answers. Changed here, the
/// next entry asks the new questions; what was written keeps the questions
/// it was asked.
class JournalQuestionsScreen extends StatefulWidget {
  const JournalQuestionsScreen({super.key});

  @override
  State<JournalQuestionsScreen> createState() => _JournalQuestionsScreenState();
}

class _JournalQuestionsScreenState extends State<JournalQuestionsScreen> {
  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  late List<JournalQuestion> _questions = [...journalQuestionsOf(_prefs)];

  bool get _own => _prefs.journalQuestions != null;

  void _keep(List<JournalQuestion> next) {
    setState(() => _questions = next);
    // TomeVoice's own again: nothing of the reader's is kept.
    _prefs.journalQuestions = listEquals(next, defaultJournalQuestions) ? null : [for (final q in next) q.toJson()];
    _prefs.save();
  }

  Future<void> _edit({int? at}) async {
    final was = at == null ? null : _questions[at];
    final q = await showModalBottomSheet<JournalQuestion>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _QuestionSheet(question: was),
    );
    if (q == null || !mounted) return;
    _keep(at == null ? [..._questions, q] : [for (var i = 0; i < _questions.length; i++) i == at ? q : _questions[i]]);
  }

  void _remove(int at) {
    final gone = _questions[at];
    final before = [..._questions];
    _keep([..._questions]..removeAt(at));
    showSnack(context, 'Question removed.', actionLabel: 'Undo', onAction: () => _keep(before));
    // The last one gone: the journal still has a blank page.
    assert(gone.text.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: 'Journal questions', onBack: () => Navigator.of(context).maybePop()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: Text(
                    'What the journal asks when you write. Answer in words, or with a tap on an answer you set. '
                    'Hold one to move it. A blank page is always there too.',
                    style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    itemCount: _questions.length,
                    onReorderItem: (from, to) {
                      final next = [..._questions];
                      final q = next.removeAt(from);
                      next.insert(to, q);
                      _keep(next);
                    },
                    footer: Padding(
                      padding: const EdgeInsets.only(top: Gap.m),
                      child: Wrap(
                        spacing: Gap.s,
                        children: [
                          FilledButton.icon(
                            onPressed: () => unawaited(_edit()),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add a question'),
                          ),
                          if (_own)
                            TextButton(
                              onPressed: () => _keep([...defaultJournalQuestions]),
                              child: const Text("TomeVoice's questions"),
                            ),
                        ],
                      ),
                    ),
                    itemBuilder: (context, i) {
                      final q = _questions[i];
                      return Padding(
                        key: ValueKey('${q.text} $i'),
                        padding: const EdgeInsets.only(bottom: Gap.s),
                        child: Material(
                          color: Skin.capsuleOn(context),
                          borderRadius: BorderRadius.circular(Radii.card / 1.5),
                          child: ListTile(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card / 1.5)),
                            title: Text(q.text, style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                            subtitle: Text(
                              q.isPick ? q.picks.join(' · ') : 'Answered in words',
                              style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
                            ),
                            onTap: () => unawaited(_edit(at: i)),
                            trailing: IconButton(
                              tooltip: 'Remove',
                              icon: Icon(Icons.delete_outline_rounded, color: Skin.inkFaintOn(context)),
                              onPressed: () => _remove(i),
                            ),
                          ),
                        ),
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

/// One question: its words, and whether it is answered in words or by a
/// tap on one of the answers given.
class _QuestionSheet extends StatefulWidget {
  const _QuestionSheet({this.question});

  final JournalQuestion? question;

  @override
  State<_QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<_QuestionSheet> {
  late final _text = TextEditingController(text: widget.question?.text ?? '');
  late final _picks = TextEditingController(text: widget.question?.picks.join(', ') ?? '');
  late bool _tap = widget.question?.isPick ?? false;

  @override
  void dispose() {
    _text.dispose();
    _picks.dispose();
    super.dispose();
  }

  List<String> get _pickList => [
        for (final p in _picks.text.split(','))
          if (p.trim().isNotEmpty) p.trim(),
      ];

  bool get _ready => _text.text.trim().isNotEmpty && (!_tap || _pickList.length >= 2);

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(widget.question == null ? 'A new question' : 'The question'),
                TextField(
                  controller: _text,
                  autofocus: widget.question == null,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'The question', hintText: 'Who do I trust least now?'),
                ),
                const SizedBox(height: Gap.l),
                ChoiceRow<bool>(
                  options: const [(false, 'Answered in words'), (true, 'Answers to tap')],
                  value: _tap,
                  onChanged: (v) => setState(() => _tap = v),
                ),
                if (_tap) ...[
                  const SizedBox(height: Gap.m),
                  TextField(
                    controller: _picks,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'The answers, between commas',
                      hintText: 'Yes, No, Not sure',
                      helperText: 'Two or more. A word of your own can always be written beside them.',
                    ),
                  ),
                ],
                const SizedBox(height: Gap.l),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                    const SizedBox(width: Gap.s),
                    FilledButton(
                      onPressed: _ready
                          ? () => Navigator.of(context)
                              .pop(JournalQuestion(_text.text.trim(), picks: _tap ? _pickList : const []))
                          : null,
                      child: const Text('Keep'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
