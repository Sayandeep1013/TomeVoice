// Colours that read: WCAG's contrast for every palette (the five, and a
// book's colour) and every colour each sets text, icons and a control's
// marks in, on every surface each is drawn on; and the reader's page in the
// app's own colours.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;
import 'package:tomevoice_spike/contrast.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/theme.dart';
import 'package:tomevoice_spike/ui.dart';

void _ignore(int _) {}

/// Seeds round the colour wheel, strong and muted.
final _seeds = [
  for (var hue = 0.0; hue < 360; hue += 30)
    for (final (chroma, tone) in const [(60.0, 50.0), (24.0, 70.0), (90.0, 40.0)]) Hct.from(hue, chroma, tone).toInt(),
];

void main() {
  setUp(() => Skin.palette = Palette.forest);
  tearDown(() => Skin.palette = Palette.forest);

  group("WCAG's contrast", () {
    test('is 21:1 for black on white, 1:1 for a colour on itself, either way round', () {
      expect(contrast(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 1e-9));
      expect(contrast(const Color(0xFFFFFFFF), const Color(0xFF000000)), closeTo(21, 1e-9));
      expect(contrast(const Color(0xFF7A3E22), const Color(0xFF7A3E22)), 1);
    });

    test('puts the greys either side of 4.5:1 on white where WCAG does', () {
      // #767676 is the lightest grey that passes on white; #777777 fails.
      expect(contrast(const Color(0xFF767676), const Color(0xFFFFFFFF)), closeTo(4.54, 0.005));
      expect(contrast(const Color(0xFF777777), const Color(0xFFFFFFFF)), closeTo(4.48, 0.005));
    });

    test('makes each channel linear with the 0.04045 knee, then weighs them as the eye does', () {
      // Middle grey: ((128/255 + 0.055) / 1.055) ^ 2.4.
      expect(luminance(const Color(0xFF808080)), closeTo(0.2158605, 1e-6));
      // 10/255 is under the knee: a straight line.
      expect(luminance(const Color(0xFF0A0A0A)), closeTo(10 / 255 / 12.92, 1e-12));
      expect(luminance(const Color(0xFFFF0000)), closeTo(0.2126, 1e-9));
      expect(luminance(const Color(0xFF00FF00)), closeTo(0.7152, 1e-9));
      expect(luminance(const Color(0xFF0000FF)), closeTo(0.0722, 1e-9));
    });

    test('lays a translucent colour over what it is drawn on', () {
      const half = Color(0x80000000);
      final laid = Color.alphaBlend(half, const Color(0xFFFFFFFF));
      expect(contrast(half, const Color(0xFFFFFFFF)), contrast(laid, const Color(0xFFFFFFFF)));
    });

    test('a tone found to read reads, as near the colour as it can be', () {
      const sheet = Color(0xFFF7F1E6);
      final fitted = readableOn(const Color(0xFFE07B39), [sheet], smallText, darker: true);
      expect(contrast(fitted, sheet), greaterThanOrEqualTo(smallText));
      expect(contrast(fitted, sheet), lessThan(smallText + 0.1), reason: 'no further than it takes');
      expect((Hct.fromInt(fitted.toARGB32()).hue - Hct.fromInt(0xFFE07B39).hue).abs(), lessThan(3), reason: 'the same hue');
    });
  });

  group('every palette reads', () {
    for (final p in Palette.all) {
      test('${p.label}: its type, its accent as text, icons and marks, on every surface they are drawn on', () {
        expect(unmetNeeds(p), isEmpty);
      });
    }

    test('in light and dark, each palette shown both ways is checked both ways', () {
      for (final p in Palette.all) {
        final ways = {for (final n in needsOf(p, Brightness.light)) n.what};
        expect(ways, containsAll(['the ink', 'the soft ink', 'the faint ink', 'the accent as text', 'text on the accent']));
      }
    });

    test('the type keeps its order: the ink strongest, the faint ink no stronger than the soft', () {
      for (final p in Palette.all) {
        for (final b in Brightness.values) {
          if (p.only != null && p.only != b) continue;
          for (final s in surfacesOf(p, b).values.expand((s) => s)) {
            expect(contrast(p.inkFor(b), s), greaterThan(contrast(p.inkSoftFor(b), s)), reason: '${p.label} ${b.name}');
            expect(contrast(p.inkSoftFor(b), s), greaterThanOrEqualTo(contrast(p.inkFaintFor(b), s) - 0.01),
                reason: '${p.label} ${b.name}');
          }
        }
      }
    });

    test("each keeps its character: an accent's deep and soft tones keep its hue", () {
      for (final p in Palette.all) {
        final hue = Hct.fromInt(p.accent.toARGB32()).hue;
        for (final c in [p.accentDeep, p.accentSoft]) {
          final d = (Hct.fromInt(c.toARGB32()).hue - hue).abs();
          expect(d > 180 ? 360 - d : d, lessThan(12), reason: p.label);
        }
      }
    });

    test("a book's colour from its cover reads in every palette", () {
      for (final p in Palette.all) {
        for (final seed in _seeds) {
          expect(unmetNeeds(p.withTint(seed)), isEmpty, reason: '${p.label} ~ ${seed.toRadixString(16)}');
        }
      }
    });

    test("a page tone's ink, soft ink and accent read at 4.5:1 down its whole paper", () {
      for (final tone in PageTone.all.where((t) => !t.isApp)) {
        final paper = [
          for (var t = 0.0; t <= 1; t += 0.25) Color.lerp(tone.paper!.first, tone.paper!.last, t)!,
        ];
        for (final c in [tone.ink!, tone.inkSoft!, tone.accent!]) {
          expect(readsOn(c, paper, smallText), isTrue, reason: tone.label);
        }
      }
    });

    test("the warning red reads in every palette, by day and by night", () {
      for (final p in Palette.all) {
        for (final b in Brightness.values) {
          if (p.only != null && p.only != b) continue;
          expect(needsOf(p, b).where((n) => n.what == 'the warning red' && !n.met), isEmpty, reason: p.label);
        }
      }
    });

    testWidgets("text and marks in the accent take its ink, the fill only what is drawn on it", (tester) async {
      Future<(Color?, Color?, Color?)> pump(Brightness b) async {
        await tester.pumpWidget(MaterialApp(
          theme: Skin.themeFor(Palette.forest, b),
          home: const Scaffold(
            body: Column(
              children: [
                TagChip('Finished', accent: true),
                Progress(0.5),
                ChoiceRow<int>(options: [(1, 'One'), (2, 'Two')], value: 1, onChanged: _ignore),
              ],
            ),
          ),
        ));
        // A change of theme eases across.
        await tester.pumpAndSettle();
        final tag = tester.widget<Text>(find.text('FINISHED')).style?.color;
        final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).color;
        final chosen = tester.widget<AnimatedDefaultTextStyle>(
                find.ancestor(of: find.text('One'), matching: find.byType(AnimatedDefaultTextStyle)).first)
            .style
            .color;
        return (tag, bar, chosen);
      }

      final (dayTag, dayBar, dayChosen) = await pump(Brightness.light);
      expect(dayTag, Palette.forest.accentDeep, reason: 'a 10 px label on a light card');
      expect(dayBar, Palette.forest.accentDeep, reason: "a bar's fill on a light card");
      expect(dayChosen, Palette.forest.onAccent, reason: 'on the full accent');
      final (nightTag, nightBar, _) = await pump(Brightness.dark);
      expect(nightTag, Palette.forest.accentSoft);
      expect(nightBar, Palette.forest.accent);
    });
  });

  group("on the reader's page", () {
    testWidgets("the page in the app's own colours is the palette's: ground, ink and the accent as text", (tester) async {
      const p = Palette.forest;
      late BuildContext page, inside;
      await tester.pumpWidget(MaterialApp(
        theme: Skin.themeFor(p, Brightness.light),
        home: PageGround(
          tone: PageTone.app,
          child: Builder(builder: (c) {
            page = c;
            return toned(c, PageTone.app, Builder(builder: (c) {
              inside = c;
              return const SizedBox.expand();
            }));
          }),
        ),
      ));
      final ground = tester.widget<DecoratedBox>(
          find.descendant(of: find.byType(PageGround), matching: find.byType(DecoratedBox)).first);
      expect(((ground.decoration as BoxDecoration).gradient! as LinearGradient).colors, p.day);
      expect(PageTone.app.inkOf(page), p.dayInk);
      expect(PageTone.app.accentOf(page), p.accentDeep, reason: 'headings and labels in the accent that reads');
      expect(Skin.accentOf(inside), p.accent, reason: 'the washes in the fill');
      expect(Skin.inkFaintOn(inside), p.dayInkFaint);
    });
  });
}
