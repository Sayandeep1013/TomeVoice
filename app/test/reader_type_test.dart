// The page's type as the reader sets it: letter spacing, weight, and a font
// of their own from a file.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/own_fonts.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('spacing and weight reach the page, its variable fonts too', (tester) async {
    late BuildContext c;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => SizedBox.shrink(key: ValueKey(c = ctx)))));
    final normal = Skin.page(c);
    final set = Skin.page(c, spacing: 0.6, weight: 600);
    expect(set.letterSpacing! - normal.letterSpacing!, closeTo(0.6, 1e-9));
    expect(set.fontWeight, FontWeight.w600);
    expect(set.fontVariations, contains(const FontVariation('wght', 600)));
    expect(normal.fontVariations, contains(const FontVariation('wght', 400)));
    final light = Skin.page(c, font: BookFont.sans, weight: 300);
    expect(light.fontVariations, [const FontVariation('wght', 320)]);
  });

  test('they are kept, and kept within bounds', () {
    final p = ListeningPrefs()
      ..letterSpacing = 0.6
      ..textWeight = 500
      ..ownFont = 'Atkinson.ttf'
      ..bookFont = BookFont.own;
    final back = ListeningPrefs.fromJson(p.toJson());
    expect(back.letterSpacing, 0.6);
    expect(back.textWeight, 500);
    expect(back.ownFont, 'Atkinson.ttf');
    expect(back.bookFont, BookFont.own);
    final wild = ListeningPrefs.fromJson({'letterSpacing': 9, 'textWeight': 950});
    expect(wild.letterSpacing, 2.0);
    expect(wild.textWeight, 600);
    final old = ListeningPrefs.fromJson(const {});
    expect((old.letterSpacing, old.textWeight, old.ownFont), (0, 400, null));
  });

  group('own fonts', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('tv_fonts'));
    tearDown(() => root.deleteSync(recursive: true));

    File picked(String name, List<int> head) =>
        File('${root.path}/$name')..writeAsBytesSync([...head, ...List.filled(64, 0)]);

    test('a TrueType or OpenType file is kept; a web font or anything else is not', () async {
      expect(OwnFonts.isFont(Uint8List.fromList([0, 1, 0, 0, ...List.filled(20, 0)])), isTrue);
      expect(OwnFonts.isFont(Uint8List.fromList([...'OTTO'.codeUnits, ...List.filled(20, 0)])), isTrue);
      expect(OwnFonts.isFont(Uint8List.fromList([...'wOFF'.codeUnits, ...List.filled(20, 0)])), isFalse);
      expect(OwnFonts.isFont(Uint8List.fromList('%PDF-1.7 not a font'.codeUnits)), isFalse);

      final ttf = picked('in.ttf', [0, 1, 0, 0]);
      expect(await OwnFonts.add(root.path, ttf.path, 'Atkinson Hyperlegible.ttf'), 'Atkinson Hyperlegible.ttf');
      // A name without its ending gets one, as what it is.
      final otf = picked('in2', 'OTTO'.codeUnits);
      expect(await OwnFonts.add(root.path, otf.path, 'Lexend'), 'Lexend.otf');
      final woff = picked('in3', 'wOFF'.codeUnits);
      expect(await OwnFonts.add(root.path, woff.path, 'Web.woff'), isNull);
      expect(await OwnFonts.list(root.path), ['Atkinson Hyperlegible.ttf', 'Lexend.otf']);
      expect(OwnFonts.label('Atkinson_Hyperlegible-Regular.ttf'), 'Atkinson Hyperlegible Regular');

      await OwnFonts.remove(root.path, 'Lexend.otf');
      expect(await OwnFonts.list(root.path), ['Atkinson Hyperlegible.ttf']);
    });

    test('a font that cannot be read leaves the page on its fallback', () async {
      expect(await OwnFonts.use(root.path, 'gone.ttf'), isFalse);
      expect(OwnFonts.family, isNull);
      expect(await OwnFonts.use(root.path, null), isFalse);
    });
  });
}
