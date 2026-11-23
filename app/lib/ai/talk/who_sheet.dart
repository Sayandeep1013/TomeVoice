import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import 'name_card.dart' show FoundCard;
import 'phrase.dart';

/// What the "Who or what is it?" sheet was asked to do.
enum WhoChoice { card, ai, web }

/// The choice, with the words it is for ([card] for [WhoChoice.card]).
typedef WhoPick = ({WhoChoice choice, String phrase, FoundCard? card});

/// The question Talk is asked for [phrase], with [sentence] for where it
/// was met.
String whoQuestion(String phrase, String sentence) =>
    'Who or what is "$phrase" in the story so far? It comes up here: "$sentence" '
    'Answer only from what I have read up to this point, with nothing from later in the book.';

/// A web search for [phrase], in quotes, with the book's [title] when it may
/// be named (not a secret book's).
String webSearchUrl(String phrase, String? title) {
  final q = [
    '"$phrase"',
    if (title != null && title.trim().isNotEmpty) title.trim(),
  ].join(' ');
  return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(q)}';
}

/// When the book's memory has nothing on a held word: the name it is
/// probably part of ([guess]), to widen, narrow or type over, then asked of
/// the AI (with [ai]) or searched on the web. With [lookUp] (the book has a
/// memory), the words as they stand are looked for in it again, and its
/// card offered when found. Null if dismissed.
Future<WhoPick?> showWhoSheet(
  BuildContext context, {
  required PhraseSpan guess,
  required bool ai,
  required bool memory,
  Future<FoundCard?> Function(String phrase)? lookUp,
}) =>
    showModalBottomSheet<WhoPick>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => WhoSheet(guess: guess, ai: ai, memory: memory, lookUp: lookUp),
    );

class WhoSheet extends StatefulWidget {
  const WhoSheet({super.key, required this.guess, required this.ai, required this.memory, this.lookUp});

  final PhraseSpan guess;
  final bool ai;
  final bool memory;
  final Future<FoundCard?> Function(String phrase)? lookUp;

  @override
  State<WhoSheet> createState() => _WhoSheetState();
}

class _WhoSheetState extends State<WhoSheet> {
  late PhraseSpan _span = widget.guess;
  late final _field = TextEditingController(text: widget.guess.text);
  Timer? _wait;
  FoundCard? _found;

  /// Which look-up is the latest: an older answer arriving late is dropped.
  int _asked = 0;

  String get _phrase => cleanPhrase(_field.text);

  @override
  void initState() {
    super.initState();
    _lastText = _field.text;
    _field.addListener(_changed);
  }

  @override
  void dispose() {
    _wait?.cancel();
    _field.dispose();
    super.dispose();
  }

  /// The words when last looked at (set as the sheet opens).
  late String _lastText;

  void _changed() {
    // The cursor moving is no change of words.
    if (_field.text == _lastText) return;
    _lastText = _field.text;
    setState(() => _found = null);
    final lookUp = widget.lookUp;
    if (lookUp == null) return;
    _wait?.cancel();
    final phrase = _phrase;
    if (phrase.isEmpty || phrase == widget.guess.text) return;
    final asked = ++_asked;
    _wait = Timer(const Duration(milliseconds: 400), () async {
      final card = await lookUp(phrase);
      if (mounted && asked == _asked) setState(() => _found = card);
    });
  }

  void _move(PhraseSpan next) {
    if (identical(next, _span)) return;
    _span = next;
    _field.value = TextEditingValue(text: next.text, selection: TextSelection.collapsed(offset: next.text.length));
  }

  void _pick(WhoChoice choice) {
    final phrase = _phrase;
    if (phrase.isEmpty) return;
    Navigator.of(context).pop<WhoPick>((choice: choice, phrase: phrase, card: _found));
  }

  @override
  Widget build(BuildContext context) {
    final phrase = _phrase;
    final shown = phrase.isEmpty ? 'it' : '"$phrase"';
    final found = _found;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              'Who or what is it?',
              subtitle: widget.memory
                  ? "The book's memory has nothing on it yet"
                  : 'This book has no memory to look in',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: TextField(
                controller: _field,
                maxLines: 1,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _pick(widget.ai ? WhoChoice.ai : WhoChoice.web),
                decoration: const InputDecoration(
                  labelText: 'Look up',
                  helperText: 'A name can be more than one word: add or drop words, or type.',
                  helperMaxLines: 2,
                ),
              ),
            ),
            const SizedBox(height: Gap.s),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              child: Row(
                children: [
                  _Edge(
                    label: 'Start',
                    addTip: 'Add the word before',
                    dropTip: 'Drop the first word',
                    onAdd: _span.canAddBefore ? () => _move(_span.addBefore()) : null,
                    onDrop: _span.canDropFirst ? () => _move(_span.dropFirst()) : null,
                    addFirst: true,
                  ),
                  const Spacer(),
                  _Edge(
                    label: 'End',
                    addTip: 'Add the word after',
                    dropTip: 'Drop the last word',
                    onAdd: _span.canAddAfter ? () => _move(_span.addAfter()) : null,
                    onDrop: _span.canDropLast ? () => _move(_span.dropLast()) : null,
                    addFirst: false,
                  ),
                ],
              ),
            ),
            if (found != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, 0),
                child: FilledButton.tonalIcon(
                  onPressed: () => _pick(WhoChoice.card),
                  icon: const Icon(Icons.badge_outlined, size: 18),
                  label: Text('Open its card: ${found.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            const SizedBox(height: Gap.s),
            if (widget.ai)
              SheetAction(
                icon: Icons.auto_awesome_rounded,
                label: 'Ask the AI (no spoilers)',
                detail: 'Who or what $shown is, from what you have read so far. Uses your AI key.',
                onTap: () => _pick(WhoChoice.ai),
              ),
            SheetAction(
              icon: Icons.travel_explore_rounded,
              label: 'Search the web (may spoil)',
              detail: 'Opens a Google search for $shown with the book\'s title. Results can give away what comes later.',
              onTap: () => _pick(WhoChoice.web),
            ),
            if (!widget.ai)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.m),
                child: Text(
                  'With an AI key (Settings, AI), the AI can answer from what you have read so far, without spoilers.',
                  style: Skin.label(context, size: 13),
                ),
              ),
            const SizedBox(height: Gap.s),
          ],
        ),
      ),
    );
  }
}

/// One end of the words: add the word beside it, or drop the end word.
class _Edge extends StatelessWidget {
  const _Edge({
    required this.label,
    required this.addTip,
    required this.dropTip,
    required this.onAdd,
    required this.onDrop,
    required this.addFirst,
  });

  final String label;
  final String addTip;
  final String dropTip;
  final VoidCallback? onAdd;
  final VoidCallback? onDrop;

  /// The add button on the outside: left at the start, right at the end.
  final bool addFirst;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, size: 22),
          color: Skin.inkOn(context),
          disabledColor: Skin.inkFaintOn(context),
        );
    final add = button(Icons.add_circle_outline_rounded, addTip, onAdd);
    final drop = button(Icons.remove_circle_outline_rounded, dropTip, onDrop);
    final text = Text(label.toUpperCase(), style: Skin.meta(context, size: 10.5));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: addFirst ? [add, text, drop] : [drop, text, add],
    );
  }
}
