// A book's colour from its cover: the seed picked from the picture's pixels,
// and the palette made from it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;
import 'package:tomevoice_spike/book_tint.dart';
import 'package:tomevoice_spike/theme.dart';

/// A 32 x 32 RGBA picture: [main] over most of it, [rest] over a strip.
Uint8List picture(List<int> main, List<int> rest) {
  final out = Uint8List(32 * 32 * 4);
  for (var i = 0; i < 32 * 32; i++) {
    final c = i < 32 * 26 ? main : rest;
    out.setAll(i * 4, [...c, 255]);
  }
  return out;
}

void main() {
  test('a blue cover gives a blue seed', () async {
    final seed = await seedFromRgba(picture([40, 80, 200], [20, 20, 20]));
    expect(seed, isNot(0));
    final hue = Hct.fromInt(seed).hue;
    expect(hue, inInclusiveRange(240, 300), reason: 'hue $hue');
  });

  test('a grey cover gives none', () async {
    expect(await seedFromRgba(picture([128, 128, 128], [40, 40, 40])), 0);
  });

  test('a transparent picture gives none', () async {
    expect(await seedFromRgba(Uint8List(16)), 0);
  });

  test('a tinted palette keeps the grounds and takes the hue', () {
    const seed = 0xFF2E7D32; // green
    final p = Palette.forest.withTint(seed);
    expect(p.day, Palette.forest.day);
    expect(p.night, Palette.forest.night);
    expect((Hct.fromInt(p.accent.toARGB32()).hue - Hct.fromInt(seed).hue).abs(), lessThan(8));
    // Text on the fill is dark and the deep tone is darker than the fill.
    expect(Hct.fromInt(p.onAccent.toARGB32()).tone, lessThan(20));
    expect(Hct.fromInt(p.accentDeep.toARGB32()).tone, lessThan(Hct.fromInt(p.accent.toARGB32()).tone));
    // Tinting a tinted palette starts from the palette, not the last tint.
    expect(p.withTint(seed).id, p.id);
  });
}
