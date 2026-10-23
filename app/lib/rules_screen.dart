import 'dart:async';

import 'package:flutter/material.dart';

import 'reading_rules.dart';
import 'theme.dart';
import 'ui.dart';

/// "Say this as that": [word] (from a long-pressed sentence) and how it
/// should sound, for this book or every book. [preview] says a line aloud in
/// the book's voice.
Future<void> showSayDialog(
  BuildContext context, {
  required String word,
  String? bookId,
  String? bookTitle,
  Future<void> Function(String text)? preview,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SayDialog(word: word, bookId: bookId, bookTitle: bookTitle, preview: preview),
    );

class _SayDialog extends StatefulWidget {
  const _SayDialog({required this.word, this.bookId, this.bookTitle, this.preview});

  final String word;
  final String? bookId;
  final String? bookTitle;
  final Future<void> Function(String text)? preview;

  @override
  State<_SayDialog> createState() => _SayDialogState();
}

class _SayDialogState extends State<_SayDialog> {
  late final _from = TextEditingController(text: widget.word);
  late final _to = TextEditingController(text: _existing ?? widget.word);
  late bool _onlyThisBook = widget.bookId != null;

  String? get _existing => ReadingRules.instance.say
      .where((r) => r.from.toLowerCase() == widget.word.toLowerCase())
      .firstOrNull
      ?.to;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final from = _from.text.trim();
    final to = _to.text.trim();
    if (from.isEmpty || to.isEmpty) return;
    await ReadingRules.instance.addSay(SayRule(from: from, to: to, book: _onlyThisBook ? widget.bookId : null));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Fix the pronunciation'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _from,
                decoration: const InputDecoration(labelText: 'Word on the page'),
              ),
              const SizedBox(height: Gap.m),
              TextField(
                controller: _to,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Say it as',
                  helperText: 'Spell it the way it sounds: Zor-ee-an',
                  suffixIcon: widget.preview == null
                      ? null
                      : IconButton(
                          tooltip: 'Hear it',
                          icon: const Icon(Icons.play_circle_outline_rounded),
                          onPressed: () => unawaited(widget.preview!(_to.text.trim())),
                        ),
                ),
                onSubmitted: (_) => _save(),
              ),
              if (widget.bookId != null) ...[
                const SizedBox(height: Gap.s),
                SwitchRow(
                  title: 'Only in this book',
                  subtitle: widget.bookTitle,
                  value: _onlyThisBook,
                  padding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _onlyThisBook = v),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

/// "Don't read lines like this", for a web novel's line [line]: the words
/// that mark such lines, for this site ([plugin], [siteName]) or every site.
/// True when a rule was added.
Future<bool> showSkipDialog(
  BuildContext context, {
  required String line,
  required String plugin,
  required String siteName,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _SkipDialog(line: line, plugin: plugin, siteName: siteName),
    ) ==
    true;

class _SkipDialog extends StatefulWidget {
  const _SkipDialog({required this.line, required this.plugin, required this.siteName});

  final String line;
  final String plugin;
  final String siteName;

  @override
  State<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends State<_SkipDialog> {
  late final _text = TextEditingController(text: widget.line.length > 80 ? widget.line.substring(0, 80) : widget.line);
  bool _thisSite = true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.length < 3) return;
    await ReadingRules.instance.addSkip(SkipRule(text: text, plugin: _thisSite ? widget.plugin : null));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text("Don't read lines like this"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Lines containing these words are left out, in chapters already downloaded too. '
                'Keep only the words that mark them, such as "Patreon".',
                style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
              ),
              const SizedBox(height: Gap.m),
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Lines containing'),
              ),
              const SizedBox(height: Gap.s),
              SwitchRow(
                title: 'Only on ${widget.siteName}',
                value: _thisSite,
                padding: EdgeInsets.zero,
                onChanged: (v) => setState(() => _thisSite = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: _save, child: const Text('Skip them')),
        ],
      );
}

/// Settings → Pronunciations and skipped lines: every rule, to check or
/// remove.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key, required this.bookTitles});

  /// Book id → title, to say which book a rule is for.
  final Map<String, String> bookTitles;

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final _rules = ReadingRules.instance;

  @override
  void initState() {
    super.initState();
    _rules.changes.addListener(_changed);
  }

  @override
  void dispose() {
    _rules.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final say = _rules.say;
    final skip = _rules.skip;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Reading rules', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    SectionTitle('Pronunciations', note: say.isEmpty ? null : '${say.length}'),
                    const SizedBox(height: Gap.s),
                    if (say.isEmpty)
                      _hint(context, "Press and hold a word while reading, then Fix how it's said.")
                    else
                      for (final r in say)
                        _row(
                          context,
                          title: '${r.from}  →  ${r.to}',
                          detail: r.book == null ? 'Every book' : (widget.bookTitles[r.book] ?? 'One book'),
                          onDelete: () => _rules.removeSay(r),
                        ),
                    const SizedBox(height: Gap.xl),
                    SectionTitle('Skipped lines', note: skip.isEmpty ? null : '${skip.length}'),
                    const SizedBox(height: Gap.s),
                    if (skip.isEmpty)
                      _hint(context, 'In a web novel, press and hold a line, then Don\'t read lines like this.')
                    else
                      for (final r in skip)
                        _row(
                          context,
                          title: '“${r.text}”',
                          detail: r.plugin == null ? 'Every site' : 'Only on ${r.plugin}',
                          onDelete: () => _rules.removeSkip(r),
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

  Widget _hint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Text(text, style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
      );

  Widget _row(BuildContext context, {required String title, required String detail, required VoidCallback onDelete}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                  Text(detail.toUpperCase(), style: Skin.meta(context, size: 10)),
                ],
              ),
            ),
            IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline_rounded), onPressed: onDelete),
          ],
        ),
      );
}
