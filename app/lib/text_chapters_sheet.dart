import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'organise_sheets.dart' show ChoicePill;
import 'theme.dart';
import 'ui.dart';

/// How a TXT book is cut into chapters, in a few words: its page's
/// Chapters row says this.
String textChaptersLabel(TextChapters rule) => switch (rule.kind) {
      TextChapterKind.auto => 'Found by TomeVoice',
      TextChapterKind.lines => rule.regex ? 'Lines matching ${rule.pattern}' : 'Lines starting with “${rule.pattern}”',
      TextChapterKind.words => 'Every ${_thousands(rule.words)} words',
    };

/// The lengths a book can be cut into, in words.
const textChapterLengths = [1000, 2000, 3000, 5000];

/// A TXT book's chapters, as its reader would have them: found by TomeVoice,
/// at lines that start with what they type (or match a pattern), or every
/// so many words. What each would make of the book shows as it is chosen,
/// read from the book's text as [load] gives it (see LibraryStore.textOf),
/// before anything changes. The rule chosen, or null for none (Cancel, or the
/// one the book has).
Future<TextChapters?> showTextChapters(
  BuildContext context, {
  required String title,
  required TextChapters current,
  required Future<String> Function() load,
}) =>
    showModalBottomSheet<TextChapters>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => carryTint(context, _ChaptersSheet(title: title, current: current, load: load)),
    );

class _ChaptersSheet extends StatefulWidget {
  const _ChaptersSheet({required this.title, required this.current, required this.load});

  final String title;
  final TextChapters current;
  final Future<String> Function() load;

  @override
  State<_ChaptersSheet> createState() => _ChaptersSheetState();
}

class _ChaptersSheetState extends State<_ChaptersSheet> {
  late TextChapterKind _kind = widget.current.kind;
  late final _pattern = TextEditingController(text: widget.current.pattern);
  late bool _regex = widget.current.regex;
  late int _words = widget.current.kind == TextChapterKind.words ? widget.current.words : 3000;

  String? _text;
  Object? _error;
  ({int count, List<String> titles, bool ruled})? _preview;

  /// The preview waits for typing to pause; each one asked for is
  /// numbered, and only the last is shown.
  Timer? _wait;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    widget.load().then((t) {
      if (!mounted) return;
      _text = t;
      _update(at: Duration.zero);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    _pattern.dispose();
    super.dispose();
  }

  TextChapters get _rule => switch (_kind) {
        TextChapterKind.auto => const TextChapters.auto(),
        TextChapterKind.lines => TextChapters.lines(_pattern.text.trim(), regex: _regex),
        TextChapterKind.words => TextChapters.words(_words),
      };

  /// What the rule chosen makes of the book, worked out once typing
  /// pauses for [at]: on a background isolate for a long book.
  void _update({Duration at = const Duration(milliseconds: 250)}) {
    setState(() {});
    _wait?.cancel();
    final text = _text;
    if (text == null) return;
    final asked = ++_asked;
    _wait = Timer(at, () async {
      final rule = _rule;
      final title = widget.title;
      ({int count, List<String> titles, bool ruled})? made;
      if (rule.problem == null) {
        made = text.length < 200000
            ? previewTextChapters(text, rule, fallbackTitle: title)
            : await Isolate.run(() => previewTextChapters(text, rule, fallbackTitle: title));
      }
      if (mounted && asked == _asked) setState(() => _preview = made);
    });
  }

  bool get _ready {
    final rule = _rule;
    final p = _preview;
    return rule != widget.current && rule.problem == null && (rule.isAuto || (p != null && p.ruled));
  }

  @override
  Widget build(BuildContext context) {
    final field = Skin.ui(size: 15.5, weight: FontWeight.w500, color: Skin.inkOn(context));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader('Chapters', subtitle: widget.title),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                child: ChoiceRow<TextChapterKind>(
                  options: const [
                    (TextChapterKind.auto, 'Automatic'),
                    (TextChapterKind.lines, 'Lines'),
                    (TextChapterKind.words, 'Length'),
                  ],
                  value: _kind,
                  onChanged: (k) {
                    _kind = k;
                    _update(at: Duration.zero);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
                child: Text(
                  switch (_kind) {
                    TextChapterKind.auto => 'TomeVoice finds lines such as “Chapter 12” or “第12章”, '
                        'and cuts a long text with none into parts of about 4,000 words.',
                    TextChapterKind.lines => _regex
                        ? 'A chapter starts at each line the pattern matches. Capitals don’t matter.'
                        : 'A chapter starts at each line that begins with these words. Capitals don’t matter.',
                    TextChapterKind.words => 'A chapter every so many words, cut where a paragraph ends.',
                  },
                  style: Skin.label(context, size: 14),
                ),
              ),
              if (_kind == TextChapterKind.lines) ..._lines(context, field),
              if (_kind == TextChapterKind.words)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, 0),
                  child: ChoiceRow<int>(
                    options: [for (final n in textChapterLengths) (n, _thousands(n))],
                    value: _words,
                    onChanged: (n) {
                      _words = n;
                      _update(at: Duration.zero);
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, 0),
                child: _shown(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, 0),
                child: Text(
                  'The book is split again. Your place, bookmarks and quotes stay with their words.',
                  style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.m),
                child: Row(
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    const Spacer(),
                    FilledButton(
                      onPressed: _ready ? () => Navigator.pop(context, _rule) : null,
                      child: const Text('Split the book'),
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

  List<Widget> _lines(BuildContext context, TextStyle field) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, 0),
          child: TextField(
            controller: _pattern,
            style: field,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: _regex ? 'Pattern' : 'Lines starting with',
              hintText: _regex ? r'^Chapter \d+' : 'Chapter',
            ),
            onChanged: (_) => _update(),
          ),
        ),
        if (!_regex)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
            child: Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                for (final start in const ['Chapter', 'Episode', '第', '#'])
                  ChoicePill(
                    start,
                    selected: _pattern.text.trim() == start,
                    onTap: () {
                      _pattern.text = start;
                      _update(at: Duration.zero);
                    },
                  ),
              ],
            ),
          ),
        SwitchRow(
          title: 'A regular expression',
          subtitle: r'Such as ^Chapter \d+ or ^第.+章',
          value: _regex,
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.l, 0),
          onChanged: (on) {
            _regex = on;
            _update(at: Duration.zero);
          },
        ),
      ];

  /// What the rule chosen makes of the book: how many chapters and the
  /// first of their titles, or why it makes none.
  Widget _shown(BuildContext context) {
    final soft = Skin.label(context, size: 14);
    if (_error != null) return Text('The book’s text could not be read: $_error', style: soft);
    if (_text == null) {
      return Row(children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Gap.m),
        Text('Reading the book…', style: soft),
      ]);
    }
    final rule = _rule;
    final problem = rule.problem;
    if (problem != null) {
      return Text(problem, style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.dangerOn(context)));
    }
    final p = _preview;
    if (p == null) return const SizedBox(height: 24);
    if (!p.ruled && !rule.isAuto) {
      return Text(
        rule.regex
            ? 'No line matches this pattern. The book keeps the chapters TomeVoice found.'
            : 'No line starts with that. The book keeps the chapters TomeVoice found.',
        style: soft,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow('${_thousands(p.count)} ${p.count == 1 ? 'chapter' : 'chapters'}'),
        const SizedBox(height: Gap.s),
        for (final t in p.titles)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(t,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkSoftOn(context))),
          ),
        if (p.count > p.titles.length) Text('and ${_thousands(p.count - p.titles.length)} more', style: soft),
      ],
    );
  }
}

String _thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
