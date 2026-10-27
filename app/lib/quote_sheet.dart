import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'theme.dart';
import 'ui.dart';

/// What to keep: [count] sentences from [first], and a note if one was written.
class QuoteChoice {
  const QuoteChoice(this.first, this.count, this.note);

  final int first;
  final int count;
  final String? note;
}

/// The most sentences one quote takes in.
const _most = 8;

/// Save the sentence [unit] as a quote: take in the sentences before or after
/// it (within its chapter), add a note, then Save. Null if closed instead.
Future<QuoteChoice?> showQuoteSheet(BuildContext context, {required ReadingLayout layout, required int unit}) {
  final (chapterFirst, chapterCount) = layout.chapterRange(layout.chapterOfUnit(unit));
  final chapterEnd = chapterFirst + chapterCount;
  var first = unit;
  var end = unit + 1;
  // Not disposed when the sheet closes: it is still drawn while it slides away.
  final note = TextEditingController();
  return showModalBottomSheet<QuoteChoice>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => carryTint(
      context,
      Padding(
        // Above the keyboard while the note is typed.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: StatefulBuilder(
          builder: (ctx, setState) {
            final text = [for (var i = first; i < end; i++) layout.units[i].text].join(' ');
            final count = end - first;
            Widget step(String label, {required VoidCallback? less, required VoidCallback? more}) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.outlined(
                      tooltip: 'One sentence fewer $label',
                      onPressed: less,
                      icon: const Icon(Icons.remove_rounded, size: 18),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                      child: Text(label, style: Skin.ui(size: 13.5, weight: FontWeight.w600, color: Skin.inkSoftOn(ctx))),
                    ),
                    IconButton.outlined(
                      tooltip: 'One sentence more $label',
                      onPressed: more,
                      icon: const Icon(Icons.add_rounded, size: 18),
                    ),
                  ],
                );
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Save a quote', style: Skin.title(ctx, size: 20)),
                    const SizedBox(height: Gap.m),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.3),
                      child: SingleChildScrollView(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontFamily: 'Newsreader',
                            fontStyle: FontStyle.italic,
                            fontSize: 17,
                            height: 1.45,
                            color: Skin.inkOn(ctx),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Gap.m),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: Gap.m,
                      runSpacing: Gap.s,
                      children: [
                        step(
                          'before',
                          less: first < unit ? () => setState(() => first++) : null,
                          more: first > chapterFirst && count < _most ? () => setState(() => first--) : null,
                        ),
                        step(
                          'after',
                          less: end > unit + 1 ? () => setState(() => end--) : null,
                          more: end < chapterEnd && count < _most ? () => setState(() => end++) : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: Gap.m),
                    TextField(
                      controller: note,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 280,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Add a note (optional)'),
                    ),
                    const SizedBox(height: Gap.s),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, QuoteChoice(first, count, note.text)),
                      child: Text(count == 1 ? 'Save' : 'Save $count sentences'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Write or change the note on a saved quote. Null if cancelled; empty to
/// remove the note.
Future<String?> askNote(BuildContext context, {String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    animationStyle: sheetMotion(context),
    builder: (ctx) => AlertDialog(
      title: Text(initial.isEmpty ? 'Add a note' : 'Your note'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 280,
        textCapitalization: TextCapitalization.sentences,
        style: Skin.ui(size: 15.5, weight: FontWeight.w500, color: Skin.inkOn(ctx)),
        decoration: const InputDecoration(hintText: 'Why this line?'),
      ),
      actions: [
        if (initial.isNotEmpty) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
  // Not disposed: the dialog still draws the field while it closes.
  return result;
}
