import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'marks.dart';
import 'quote_sheet.dart';
import 'share_card.dart';
import 'theme.dart';
import 'ui.dart';

// The three highlighter colours; the fourth is the book's own accent.
const _yellow = Color(0xFFF2C230);
const _green = Color(0xFF5DB866);
const _blue = Color(0xFF4F8EDF);

/// [colour] at full strength: a swatch, a quote's edge in Saved.
Color markSwatch(MarkColour colour, Color accent) => switch (colour) {
      MarkColour.accent => accent,
      MarkColour.yellow => _yellow,
      MarkColour.green => _green,
      MarkColour.blue => _blue,
    };

/// A saved quote's wash on the page: soft enough to read through, and
/// lighter than the voice's sentence, which is laid over it.
Color highlightWash(MarkColour colour, {required Color accent, required bool dark}) =>
    markSwatch(colour, accent).withValues(
      alpha: switch (colour) {
        MarkColour.accent => dark ? 0.16 : 0.12,
        MarkColour.yellow => dark ? 0.22 : 0.34,
        MarkColour.green => dark ? 0.22 : 0.24,
        MarkColour.blue => dark ? 0.24 : 0.22,
      },
    );

/// Whether text in [ink] sits on a dark page (light ink).
bool darkPage(Color? ink) => (ink?.computeLuminance() ?? 0) > 0.4;

/// Sentence -> the quote washing it, for every quote of [layout]'s book in
/// one of its chapters (a web novel's chapter not on the phone has none).
/// Where two quotes take in one sentence, the newer one's colour shows.
Map<int, Mark> highlightUnits(ReadingLayout layout, Iterable<Mark> marks) {
  final out = <int, Mark>{};
  if (layout.isEmpty) return out;
  final chapters = layout.chapters.toSet();
  // Saved newest first: laid oldest first, so the newest is on top.
  for (final m in marks.toList().reversed) {
    if (m.kind != MarkKind.quote || !chapters.contains(m.at.sectionIndex)) continue;
    final first = unitOfMark(layout, m);
    for (var u = first; u < first + m.span && u < layout.units.length; u++) {
      out[u] = m;
    }
  }
  return out;
}

/// The saved quotes of one book by the sentences they hold, kept up to date
/// as quotes are saved, coloured, changed and removed: what the page washes.
class Highlights extends ChangeNotifier implements ValueListenable<Map<int, Mark>> {
  Highlights(this.layout) {
    MarkStore.instance.changes.addListener(_update);
    _value = highlightUnits(layout, MarkStore.instance.forBook(layout.book.id));
  }

  final ReadingLayout layout;
  Map<int, Mark> _value = const {};

  @override
  Map<int, Mark> get value => _value;

  /// The quote over sentence [unit], if one is.
  Mark? at(int unit) => _value[unit];

  /// The first sentence of quote [m] on the page.
  int? startOf(Mark m) {
    int? first;
    _value.forEach((u, q) {
      if (q.id == m.id && (first == null || u < first!)) first = u;
    });
    return first;
  }

  void _update() {
    final next = highlightUnits(layout, MarkStore.instance.forBook(layout.book.id));
    if (sameQuotes(next, _value)) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    MarkStore.instance.changes.removeListener(_update);
    super.dispose();
  }
}

/// Whether [a] and [b] wash the same sentences the same way.
bool sameQuotes(Map<int, Mark> a, Map<int, Mark> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || o.id != e.value.id || o.colour != e.value.colour) return false;
  }
  return true;
}

/// One piece of a paragraph and what lies behind it.
typedef WashRun = ({int start, int end, Color? wash, bool spoken});

/// Paragraph [item] of [layout] cut where its washes change: [quotes]' colours
/// first, and over them the sentence being read ([spoken], -1 for none) and
/// its word ([wordStart] to [wordEnd] in that sentence, -1 for none). A quote
/// of several sentences is washed across the gaps between them too.
List<WashRun> washRuns({
  required ReadingLayout layout,
  required LayoutItem item,
  required Map<int, Mark> quotes,
  required Color Function(Mark m) quoteWash,
  required int spoken,
  required Color sentenceWash,
  required Color wordWash,
  int wordStart = -1,
  int wordEnd = -1,
}) {
  final text = item.block?.text ?? '';
  final n = text.length;
  final cuts = <int>{0, n};
  final under = <(int, int, Color)>[];
  final end = item.firstUnit + item.unitCount;
  for (var u = item.firstUnit; u < end; u++) {
    final m = quotes[u];
    if (m == null) continue;
    final s = layout.unitOffset[u].clamp(0, n);
    final next = u + 1 < end && quotes[u + 1]?.id == m.id
        ? layout.unitOffset[u + 1].clamp(s, n)
        : (s + layout.units[u].text.length).clamp(s, n);
    if (next > s) {
      under.add((s, next, quoteWash(m)));
      cuts
        ..add(s)
        ..add(next);
    }
  }
  var ss = -1, se = -1, ws = -1, we = -1;
  if (spoken >= 0 && item.containsUnit(spoken)) {
    ss = layout.unitOffset[spoken].clamp(0, n);
    se = (ss + layout.units[spoken].text.length).clamp(ss, n);
    cuts
      ..add(ss)
      ..add(se);
    if (wordStart >= 0) {
      ws = (ss + wordStart).clamp(ss, se);
      we = (ss + wordEnd).clamp(ws, se);
      if (we > ws) {
        cuts
          ..add(ws)
          ..add(we);
      } else {
        ws = we = -1;
      }
    }
  }
  final points = cuts.toList()..sort();
  final out = <WashRun>[];
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i], b = points[i + 1];
    if (b <= a) continue;
    Color? base;
    for (final (s, e, c) in under) {
      if (a >= s && a < e) base = c;
    }
    final inSentence = a >= ss && a < se;
    final over = a >= ws && a < we ? wordWash : (inSentence ? sentenceWash : null);
    final wash = over == null ? base : (base == null ? over : Color.alphaBlend(over, base));
    if (out.isNotEmpty && out.last.wash == wash && out.last.spoken == inSentence && out.last.end == a) {
      final last = out.removeLast();
      out.add((start: last.start, end: b, wash: wash, spoken: inSentence));
    } else {
      out.add((start: a, end: b, wash: wash, spoken: inSentence));
    }
  }
  return out;
}

/// A tap on a saved quote on the page: its words and note, its colour, and
/// what can be done with it. True when the reader chose to read from it.
Future<bool> showQuoteActions(BuildContext context, Mark mark, {String? cover, String? author}) async {
  final store = MarkStore.instance;
  var shown = mark;
  final picked = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => carryTint(
      context,
      SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
                  child: Text(
                    shown.text,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Newsreader',
                      fontStyle: FontStyle.italic,
                      fontSize: 16,
                      height: 1.4,
                      color: Skin.inkSoftOn(ctx),
                    ),
                  ),
                ),
                if (shown.note != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: Gap.s),
                          child: Icon(Icons.sticky_note_2_outlined, size: 18, color: Skin.accentInkOf(ctx)),
                        ),
                        Expanded(
                          child: Text(shown.note!,
                              style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(ctx))),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.s),
                  child: ColourChoice(
                    value: shown.colour,
                    onChanged: (c) {
                      shown = shown.withColour(c);
                      setSheet(() {});
                      unawaited(store.update(shown));
                    },
                  ),
                ),
                SheetAction(
                  icon: Icons.edit_note_rounded,
                  label: shown.note == null ? 'Add a note' : 'Change the note',
                  onTap: () => Navigator.pop(ctx, 'note'),
                ),
                SheetAction(
                    icon: Icons.ios_share_rounded, label: 'Share as a picture', onTap: () => Navigator.pop(ctx, 'share')),
                SheetAction(icon: Icons.play_arrow_rounded, label: 'Read from here', onTap: () => Navigator.pop(ctx, 'read')),
                SheetAction(
                  icon: Icons.delete_outline_rounded,
                  label: 'Remove the quote',
                  onTap: () => Navigator.pop(ctx, 'remove'),
                ),
                const SizedBox(height: Gap.s),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (!context.mounted) return false;
  switch (picked) {
    case 'note':
      final note = await askNote(context, initial: shown.note ?? '');
      if (note != null) await store.update(shown.withNote(note));
    case 'share':
      await showQuoteShare(context, shown, cover: cover, author: author);
    case 'read':
      return true;
    case 'remove':
      await store.remove(shown.id);
      if (context.mounted) {
        showSnack(context, 'Quote removed.', actionLabel: 'Undo', onAction: () => unawaited(store.restore(shown)));
      }
  }
  return false;
}

/// The four colours a quote can be washed in, as a row of swatches.
class ColourChoice extends StatelessWidget {
  const ColourChoice({super.key, required this.value, required this.onChanged, this.size = 30});

  final MarkColour value;
  final ValueChanged<MarkColour> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accent = Skin.accentOf(context);
    return Row(
      children: [
        for (final c in MarkColour.values)
          Padding(
            padding: const EdgeInsets.only(right: Gap.m),
            child: Semantics(
              button: true,
              selected: c == value,
              label: '${c.label} highlight',
              child: InkResponse(
                onTap: () => onChanged(c),
                radius: size * 0.8,
                child: AnimatedContainer(
                  duration: Motion.of(context, Motion.quick),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: markSwatch(c, accent),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == value ? Skin.inkOn(context) : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: c == value ? Icon(Icons.check_rounded, size: size * 0.55, color: Colors.white) : null,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
