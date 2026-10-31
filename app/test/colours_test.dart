// Colours that read: WCAG's contrast for every palette (the five, a book's
// colour, a reader's own, the wallpaper's) and every colour each sets text,
// icons and a control's marks in, on every surface each is drawn on; a
// reader's own colours kept, carried in a backup and guarded; the
// wallpaper's theme where the phone has one; and both on the reader's page,
// with the reader's own marks in the accent.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show
        DynamicScheme,
        Hct,
        SchemeExpressive,
        SchemeFruitSalad,
        SchemeMonochrome,
        SchemeNeutral,
        SchemeRainbow,
        SchemeTonalSpot,
        SchemeVibrant,
        TonalPalette;
import 'package:tomevoice_spike/backup.dart';
import 'package:tomevoice_spike/chapter_finder.dart';
import 'package:tomevoice_spike/contrast.dart';
import 'package:tomevoice_spike/highlights.dart' show darkPage, highlightWash;
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart' show MarkColour;
import 'package:tomevoice_spike/own_colours.dart';
import 'package:tomevoice_spike/own_colours_sheet.dart';
import 'package:tomevoice_spike/page_style.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_chrome.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/theme.dart';
import 'package:tomevoice_spike/ui.dart';
import 'package:tomevoice_spike/wallpaper_colours.dart';

const _channel = MethodChannel('tomevoice/tts');

double _tone(Color c) => Hct.fromInt(c.toARGB32()).tone;

/// The wallpaper's colour styles Android offers, from the first (the tonal
/// spot) to the plainest and the brightest.
final _styles = <DynamicScheme Function(Hct)>[
  (h) => SchemeTonalSpot(sourceColorHct: h, isDark: false, contrastLevel: 0),
  (h) => SchemeVibrant(sourceColorHct: h, isDark: false, contrastLevel: 0),
  (h) => SchemeExpressive(sourceColorHct: h, isDark: false, contrastLevel: 0),
  (h) => SchemeFruitSalad(sourceColorHct: h, isDark: false, contrastLevel: 0),
  (h) => SchemeRainbow(sourceColorHct: h, isDark: false, contrastLevel: 0),
  (h) => SchemeNeutral(sourceColorHct: h, isDark: false, contrastLevel: 0),
  (h) => SchemeMonochrome(sourceColorHct: h, isDark: false, contrastLevel: 0),
];

/// The wallpaper's colours as Android makes them from [seed] in [style]
/// (the tonal spot unless said): its five families of tones, shade 0
/// (white) to 1000 (black).
Map<String, List<int>> systemFrom(int seed, [DynamicScheme Function(Hct)? style]) {
  final s = (style ?? _styles.first)(Hct.fromInt(seed));
  const tones = [100, 99, 95, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0];
  List<int> of(TonalPalette t) => [for (final tone in tones) t.get(tone)];
  return {
    'accent1': of(s.primaryPalette),
    'accent2': of(s.secondaryPalette),
    'accent3': of(s.tertiaryPalette),
    'neutral1': of(s.neutralPalette),
    'neutral2': of(s.neutralVariantPalette),
  };
}

void _ignore(int _) {}

/// Seeds round the colour wheel, strong and muted.
final _seeds = [
  for (var hue = 0.0; hue < 360; hue += 30)
    for (final (chroma, tone) in const [(60.0, 50.0), (24.0, 70.0), (90.0, 40.0)]) Hct.from(hue, chroma, tone).toInt(),
];

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_colours');
    ListeningPrefs.reset();
    WallpaperColours.reset();
    Skin.palette = Palette.forest;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (call) async => call.method == 'appVersion' ? '1.3.0' : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    WallpaperColours.reset();
    Skin.palette = Palette.forest;
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

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

  group("a reader's own colours", () {
    test('make a theme that reads whatever is picked', () {
      final pages = [
        for (final hue in const [30.0, 140.0, 250.0])
          for (var tone = 0.0; tone <= 100; tone += 10) Color(Hct.from(hue, 12, tone).toInt()),
      ];
      const accents = [Color(0xFFE07B39), Color(0xFFF2D541), Color(0xFF1D2A6B), Color(0xFF808080)];
      const inks = [null, Color(0xFF14170F), Color(0xFFF2EADA), Color(0xFF808080)];
      for (final page in pages) {
        for (final accent in accents) {
          for (final ink in inks) {
            final made = OwnColours(page: page, accent: accent, ink: ink).made;
            expect(unmetNeeds(made.palette), isEmpty,
                reason: '${colourToHex(page.toARGB32())} ${colourToHex(accent.toARGB32())} $ink');
          }
        }
      }
    });

    test('a light page makes a light theme and a dark page a dark one', () {
      expect(const OwnColours(page: Color(0xFFF3EBDD), accent: Color(0xFFE07B39)).made.palette.only, Brightness.light);
      expect(const OwnColours(page: Color(0xFF141B2B), accent: Color(0xFFE07B39)).made.palette.only, Brightness.dark);
    });

    test('colours that read are used as picked', () {
      const c = OwnColours(page: Color(0xFFF3EBDD), accent: Color(0xFF1FA39A), ink: Color(0xFF1D2840));
      final made = c.made;
      expect(made.adjusted, isFalse);
      expect(made.palette.day[1], c.page);
      expect(made.palette.accent, c.accent);
      expect(made.palette.dayInk, c.ink);
    });

    test('text too close to the page moves to the nearest shade that reads, and says so', () {
      const c = OwnColours(page: Color(0xFFF3EBDD), accent: Color(0xFFE07B39), ink: Color(0xFFC8C0B0));
      final made = c.made;
      expect(made.ink, isNotNull);
      expect(_tone(made.ink!), lessThan(_tone(c.ink!)), reason: 'darker, on a light page');
      expect(unmetNeeds(made.palette), isEmpty);
      // Taken as picked, it reads as it is.
      expect(c.withInk(made.ink).made.adjusted, isFalse);
    });

    test('an accent too dark to show on a dark page is lightened, and says so', () {
      const c = OwnColours(page: Color(0xFF000000), accent: Color(0xFF14204A));
      final made = c.made;
      expect(made.accent, isNotNull);
      expect(_tone(made.accent!), greaterThan(_tone(c.accent)));
      expect(unmetNeeds(made.palette), isEmpty);
    });

    test('a page too mid-toned for any text gives way to the nearest shade that reads', () {
      final grey = Color(Hct.from(250, 8, 50).toInt());
      final made = OwnColours(page: grey, accent: const Color(0xFFE07B39)).made;
      expect(made.page, isNotNull);
      expect(unmetNeeds(made.palette), isEmpty);
      // A step nearer the picked shade does not read: it is the nearest.
      final t = _tone(made.page!);
      final nearer = Color(Hct.from(250, 8, t + (t > 50 ? -1.5 : 1.5)).toInt());
      expect(OwnColours(page: nearer, accent: const Color(0xFFE07B39)).made.page, isNotNull);
    });

    test('are kept with the appearance settings, and an older file without them still loads', () {
      final prefs = ListeningPrefs(paletteId: 'own', ownPage: 0xFF141B2B, ownAccent: 0xFF1FA39A, ownInk: 0xFFF2EADA);
      final json = jsonDecode(jsonEncode(prefs.toJson())) as Map<String, Object?>;
      expect(json['ownPage'], '#141B2B');
      final back = ListeningPrefs.fromJson(json);
      expect([back.paletteId, back.ownPage, back.ownAccent, back.ownInk], ['own', 0xFF141B2B, 0xFF1FA39A, 0xFFF2EADA]);
      expect(OwnColours.of(back), const OwnColours(page: Color(0xFF141B2B), accent: Color(0xFF1FA39A), ink: Color(0xFFF2EADA)));

      final older = ListeningPrefs.fromJson({'palette': 'ocean', 'themeMode': 'dark'});
      expect([older.paletteId, older.ownPage, older.ownAccent, older.ownInk], ['ocean', null, null, null]);
      expect(OwnColours.of(older), OwnColours.start);
      // Text made to suit the page is kept as no text at all.
      expect(ListeningPrefs(ownPage: 0xFFF3EBDD).toJson().containsKey('ownInk'), isFalse);
      // A damaged value is as if never set.
      final damaged = ListeningPrefs.fromJson({'ownPage': 'teal', 'ownAccent': 12, 'ownInk': '#12345'});
      expect([damaged.ownPage, damaged.ownAccent, damaged.ownInk], [null, null, null]);
    });

    test('a backup carries them, and one made before them restores as it was', () async {
      final root = Directory('${tmp.path}/files')..createSync();
      Future<ListeningPrefs> restore(Map<String, Object?> prefs) async {
        final staging = stagingDir(root)..createSync(recursive: true);
        File('${staging.path}/library.json').writeAsStringSync(jsonEncode({'books': []}));
        File('${staging.path}/prefs.json').writeAsStringSync(jsonEncode(prefs));
        await replaceLibrary(
          root,
          StagedBackup(staging, BackupInfo(format: backupFormat, created: DateTime(2026, 10, 31), root: root.path, books: 0, chapters: true)),
        );
        return ListeningPrefs.fromJson(
            Map<String, Object?>.from(jsonDecode(File('${root.path}/prefs.json').readAsStringSync()) as Map));
      }

      final mine = ListeningPrefs(paletteId: 'own', ownPage: 0xFFE9DAC1, ownAccent: 0xFF9B6CEB);
      final back = await restore(mine.toJson());
      expect([back.paletteId, back.ownPage, back.ownAccent, back.ownInk], ['own', 0xFFE9DAC1, 0xFF9B6CEB, null]);

      final before = await restore({'palette': 'lavender', 'textSize': 21});
      expect([before.paletteId, before.ownPage, before.textSize], ['lavender', null, 21]);
      expect(chosenPalette(before), Palette.lavender);
    });
  });

  group("the wallpaper's colours", () {
    test('make a theme that reads, whatever the wallpaper and its style', () {
      for (final (i, style) in _styles.indexed) {
        for (final seed in _seeds) {
          final s = SystemColours.fromPlatform(systemFrom(seed, style))!;
          expect(unmetNeeds(wallpaperPalette(s)), isEmpty, reason: 'style $i, ${seed.toRadixString(16)}');
        }
      }
    });

    test('take the main colour as the accent and its companions as the ground', () {
      final raw = systemFrom(0xFF3A8FDB);
      final p = wallpaperPalette(SystemColours.fromPlatform(raw)!);
      expect(p.accent, Color(raw['accent1']![6]));
      expect(p.day[0], Color(raw['accent2']![3]));
      expect(p.only, isNull, reason: 'it follows light and dark');
    });

    test('are none where the phone sends none or too few', () {
      expect(SystemColours.fromPlatform(null), isNull);
      expect(SystemColours.fromPlatform({'accent1': [1, 2, 3]}), isNull);
      final short = systemFrom(0xFF3A8FDB)..remove('neutral2');
      expect(SystemColours.fromPlatform(short), isNull);
    });

    test('are read from the phone, and a theme kept from a newer phone shows Forest on one without', () async {
      final prefs = ListeningPrefs(paletteId: 'wallpaper');
      await WallpaperColours.refresh();
      expect(WallpaperColours.palette, isNull);
      expect(chosenPalette(prefs), Palette.forest);
      expect(chosenPaletteId(prefs), 'forest');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        (call) async => call.method == 'systemColours' ? systemFrom(0xFF1FA39A) : null,
      );
      await WallpaperColours.refresh();
      expect(WallpaperColours.palette, isNotNull);
      expect(chosenPalette(prefs).label, 'Wallpaper');
      expect(chosenPaletteId(prefs), 'wallpaper');
    });
  });

  group("on the reader's page", () {
    testWidgets("the page in the app's own colours is the palette's: ground, ink and the accent as text", (tester) async {
      final own = const OwnColours(page: Color(0xFFE6DFF2), accent: Color(0xFF1FA39A)).made.palette;
      Skin.palette = own;
      late BuildContext page, inside;
      await tester.pumpWidget(MaterialApp(
        theme: Skin.themeFor(own, Brightness.light),
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
      expect(((ground.decoration as BoxDecoration).gradient! as LinearGradient).colors, own.day);
      expect(PageTone.app.inkOf(page), own.dayInk);
      expect(PageTone.app.accentOf(page), own.accentDeep, reason: 'headings and labels in the accent that reads');
      expect(Skin.accentOf(inside), own.accent, reason: 'the washes in the fill');
      expect(Skin.inkFaintOn(inside), own.dayInkFaint);
    });

    testWidgets("a page tone keeps its own paper and ink, and the app's type round it", (tester) async {
      final own = const OwnColours(page: Color(0xFF141B2B), accent: Color(0xFFE07B39)).made.palette;
      Skin.palette = own;
      late BuildContext inside;
      await tester.pumpWidget(MaterialApp(
        theme: Skin.themeFor(own, Brightness.dark),
        home: Builder(builder: (c) => toned(c, PageTone.papyrus, Builder(builder: (c) {
              inside = c;
              return const SizedBox.expand();
            }))),
      ));
      expect(Skin.accentOf(inside), PageTone.papyrus.accent);
      expect(Skin.accentInkOf(inside), PageTone.papyrus.accent);
      expect(Skin.inkOn(inside), own.nightInk);
    });

    /// Every palette, and a reader's own with an accent dark enough to vanish
    /// on the player's dark bar by day.
    final palettes = [
      ...Palette.all,
      const OwnColours(page: Color(0xFFF3EBDD), accent: Color(0xFF1D2A6B)).made.palette,
      const OwnColours(page: Color(0xFF141B2B), accent: Color(0xFFF2D541)).made.palette,
    ];

    testWidgets('what is read aloud reads on its washes, in every palette and page tone, by day and by night',
        (tester) async {
      // Unguarded before: in pages the word being read lay over the
      // sentence's wash (3.9:1 in Lavender by night, a quote under both
      // 3.35:1), on Dusk it was 2.6:1, and a heading read in the accent was
      // 2.7:1 by night.
      for (final p in [...palettes, Palette.forest.withTint(0xFF3A8FDB)]) {
        for (final b in Brightness.values) {
          if (p.only != null && p.only != b) continue;
          for (final tone in PageTone.all) {
            Skin.palette = p;
            late BuildContext page;
            await tester.pumpWidget(MaterialApp(
              key: ValueKey((p.id, b, tone.id)),
              theme: Skin.themeFor(p, b),
              home: Builder(builder: (c) {
                page = c;
                return const SizedBox.expand();
              }),
            ));
            final look = PageStyle.of(page, ListeningPrefs(pageTone: tone.id)).look;
            final shades = tone.shadesOf(page);
            List<Color> on(Color wash, [List<Color>? under]) => [
                  for (final s in under ?? shades) Color.alphaBlend(wash, s),
                ];
            final why = '${p.label}, ${b.name}, ${tone.label}';
            void reads(String what, Color c, List<Color> grounds) {
              for (final g in grounds) {
                expect(contrast(c, g), greaterThanOrEqualTo(smallText), reason: '$what in $why');
              }
            }

            reads('the text read aloud', look.text.color!, [...shades, ...on(look.sentenceWash)]);
            reads('the word read aloud', look.wordInk!, on(look.wordWash));
            reads("a chapter's heading, read aloud", look.chapterHeading.color!, [...shades, ...on(look.sentenceWash)]);
            if (!tone.isApp) continue;
            // Saved quotes, and the sentence read over one (the word lies on
            // its own wash). Dusk's quotes are not yet held to this.
            final dark = darkPage(look.text.color);
            for (final c in MarkColour.values) {
              for (final accent in [look.accent, look.sentenceWash.withValues(alpha: 1)]) {
                final quote = on(highlightWash(c, accent: accent, dark: dark));
                reads('the text on a ${c.name} quote', look.text.color!, [...quote, ...on(look.sentenceWash, quote)]);
              }
            }
          }
        }
      }
    });

    testWidgets("the way back to the voice, and to where the reader was, reads on its dark pill", (tester) async {
      for (final p in palettes) {
        for (final b in Brightness.values) {
          if (p.only != null && p.only != b) continue;
          Skin.palette = p;
          await tester.pumpWidget(MaterialApp(
            key: ValueKey((p.id, b)),
            theme: Skin.themeFor(p, b),
            home: Scaffold(
              body: Column(
                children: [
                  BackToReadingPill(detached: ValueNotifier(true), onTap: () {}),
                  ReturnPill(onBack: () {}, onStay: () {}),
                ],
              ),
            ),
          ));
          await tester.pumpAndSettle();
          final pill = Skin.darkFor(p, b);
          for (final icon in [Icons.my_location_rounded, Icons.undo_rounded]) {
            final c = tester.widget<Icon>(find.byIcon(icon)).color!;
            expect(contrast(c, pill), greaterThanOrEqualTo(largeText), reason: '$icon in ${p.label}, ${b.name}');
          }
        }
      }
    });

    testWidgets("the chapter being read stands out in the Contents in the accent as type", (tester) async {
      for (final p in palettes) {
        for (final b in Brightness.values) {
          if (p.only != null && p.only != b) continue;
          Skin.palette = p;
          await tester.pumpWidget(MaterialApp(
            key: ValueKey((p.id, b)),
            theme: Skin.themeFor(p, b),
            home: Scaffold(
              backgroundColor: b == Brightness.dark ? p.nightSheet : p.daySheet,
              body: Column(
                children: [
                  ChapterRow(number: 7, title: 'The River', current: true, onTap: () {}),
                  ChapterRow(number: 8, title: 'Part Two', current: true, parts: true, onTap: () {}),
                ],
              ),
            ),
          ));
          await tester.pumpAndSettle();
          final row = surfacesOf(p, b)['a choice chosen on a sheet']!.single;
          final why = '${p.label}, ${b.name}';
          for (final t in ['7', 'The River', '8', 'PART TWO']) {
            final c = tester.widget<Text>(find.text(t)).style!.color!;
            expect(contrast(c, row), greaterThanOrEqualTo(smallText), reason: '$t in $why');
          }
          final sign = tester.widget<Icon>(find.byIcon(Icons.graphic_eq_rounded).first).color!;
          expect(contrast(sign, row), greaterThanOrEqualTo(largeText), reason: why);
        }
      }
    });
  });

  group('settings', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }

    testWidgets('Your own opens its colours; a page and an accent picked show, and Use keeps them', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(tmp))));
      await settle(tester);
      expect(find.text('Your own'), findsOneWidget);
      expect(find.text('Wallpaper'), findsNothing, reason: 'no wallpaper colours on this phone');

      await tester.tap(find.text('Your own'));
      await tester.pumpAndSettle();
      expect(find.text('Your own colours'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Night page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accent'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Teal accent'));
      await tester.pumpAndSettle();
      final preview = tester.widget<Container>(
          find.descendant(of: find.byType(OwnPreview), matching: find.byType(Container)).first);
      final colours = ((preview.decoration! as BoxDecoration).gradient! as LinearGradient).colors;
      expect(colours, contains(const Color(0xFF141B2B)), reason: 'the preview is on the night page');

      await tester.ensureVisible(find.text('Use these colours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use these colours'));
      await tester.pumpAndSettle();
      final prefs = ListeningPrefs.memory;
      expect([prefs.paletteId, prefs.ownPage, prefs.ownAccent, prefs.ownInk], ['own', 0xFF141B2B, 0xFF1FA39A, null]);
      expect(find.text('Your own colours are dark, as their page is.'), findsOneWidget);
      expect(find.text('Change your colours'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('text that cannot be read is moved and said, and Use this shade takes it', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(tmp))));
      await settle(tester);
      await tester.tap(find.text('Your own'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('White text'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The text is darker than you chose'), findsOneWidget);
      await tester.tap(find.text('Use this shade'));
      await tester.pumpAndSettle();
      expect(find.textContaining('than you chose'), findsNothing);
      await tester.ensureVisible(find.text('Use these colours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use these colours'));
      await tester.pumpAndSettle();
      final ink = Color(ListeningPrefs.memory.ownInk!);
      expect(contrast(ink, const Color(0xFFF3EBDD)), greaterThanOrEqualTo(smallText));
      await finish(tester);
    });

    testWidgets("the wallpaper's theme shows where the phone has its colours, and can be picked", (tester) async {
      phone(tester);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        (call) async => call.method == 'systemColours' ? systemFrom(0xFF3A8FDB) : null,
      );
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(tmp))));
      await settle(tester);
      expect(find.text('Wallpaper'), findsNothing);
      await tester.runAsync(WallpaperColours.refresh);
      await tester.pumpAndSettle();
      expect(find.text('Wallpaper'), findsOneWidget);
      await tester.tap(find.text('Wallpaper'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.paletteId, 'wallpaper');
      expect(find.text('Light'), findsOneWidget, reason: 'it follows light and dark');
      await finish(tester);
    });

    testWidgets('the hue and shade bars keep the rest of the colour', (tester) async {
      Color? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HueShadePicker(colour: const Color(0xFFE07B39), onChanged: (c) => picked = c),
        ),
      ));
      final bars = tester.widgetList<Slider>(find.byType(Slider)).toList();
      final start = Hct.fromInt(0xFFE07B39);
      bars[1].onChanged!(30);
      expect(_tone(picked!), closeTo(30, 1));
      expect((Hct.fromInt(picked!.toARGB32()).hue - start.hue).abs(), lessThan(4));
      bars[0].onChanged!(250);
      expect(Hct.fromInt(picked!.toARGB32()).hue, closeTo(250, 4));
      expect(_tone(picked!), closeTo(start.tone, 1));
    });

    testWidgets('the shade taken to black or white and back keeps the hue and its colour', (tester) async {
      // Read from the colour each time, they went at either end (black and
      // white have neither), and the colour came back grey.
      var colour = const Color(0xFFE07B39);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => HueShadePicker(colour: colour, onChanged: (c) => setState(() => colour = c)),
          ),
        ),
      ));
      final start = Hct.fromInt(0xFFE07B39);
      Slider shade() => tester.widgetList<Slider>(find.byType(Slider)).toList()[1];
      for (final end in [0.0, 100.0]) {
        shade().onChanged!(end);
        await tester.pump();
        expect(_tone(colour), closeTo(end, 1));
        shade().onChanged!(start.tone);
        await tester.pump();
        final back = Hct.fromInt(colour.toARGB32());
        expect((back.hue - start.hue).abs(), lessThan(4), reason: 'from $end');
        expect(back.chroma, closeTo(start.chroma, 4), reason: 'from $end');
      }
      // A colour from outside (a swatch) is taken as it is.
      colour = const Color(0xFF3A8FDB);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => HueShadePicker(colour: colour, onChanged: (c) => setState(() => colour = c)),
          ),
        ),
      ));
      shade().onChanged!(40);
      await tester.pump();
      expect((Hct.fromInt(colour.toARGB32()).hue - Hct.fromInt(0xFF3A8FDB).hue).abs(), lessThan(4));
    });
  });
}
