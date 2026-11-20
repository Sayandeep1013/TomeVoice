// Bodoni Moda's hyphen and dashes are hairlines that vanish at a title's
// size: a top bar draws them in the interface face.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/theme.dart';
import 'package:tomevoice_spike/ui.dart';

void main() {
  const style = TextStyle(fontFamily: Skin.titleFamily, fontSize: 26, fontWeight: FontWeight.w500);

  test('a title without dashes stays one span', () {
    final span = titleWithDashes('Who is who', style);
    expect(span.text, 'Who is who');
    expect(span.children, isNull);
  });

  test("a feed's title: the dash in Figtree, the words in Bodoni", () {
    final span = titleWithDashes('Standard Ebooks - Newest Ebooks', style);
    expect(span.toPlainText(), 'Standard Ebooks - Newest Ebooks');
    final parts = span.children!.cast<TextSpan>();
    expect(parts.map((p) => p.text), ['Standard Ebooks ', '-', ' Newest Ebooks']);
    expect(parts[1].style!.fontFamily, Skin.uiFamily);
    expect(parts[0].style, isNull, reason: 'the words keep the title face from the parent');
    expect(span.style!.fontFamily, Skin.titleFamily);
  });

  test('en and em dashes, and a hyphen inside a word, too', () {
    final span = titleWithDashes('Penny-Pincher – a note — more', style);
    final dashes = span.children!.cast<TextSpan>().where((p) => p.style?.fontFamily == Skin.uiFamily);
    expect(dashes.map((p) => p.text), ['-', '–', '—']);
  });
}
