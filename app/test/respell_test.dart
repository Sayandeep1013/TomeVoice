// What the voice is given to say: a footnote's marker left out, a long link
// said as its site, a citation left out, and the reader's own fixes, with
// every position mapping back to the page for the highlight.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/reading_rules.dart';

void main() {
  Speakable unit(String text, {List<TextStretch> silent = const []}) => Speakable(
        sectionIndex: 0,
        blockIndex: 0,
        sentenceIndex: 0,
        text: text,
        role: BlockRole.paragraph,
        blockId: 'b0',
        silent: silent,
      );

  test("a footnote's marker is shown but not said, and the words after it map back", () {
    const text = 'It was a dark night.1 Then it rained.';
    final at = text.indexOf('1 Then');
    final said = respellUnit(unit(text, silent: [(start: at, end: at + 1)]), const []);
    expect(said.text, 'It was a dark night. Then it rained.');
    final then = said.text.indexOf('Then');
    expect(said.toOriginal(then), text.indexOf('Then'));
  });

  test('a long link is said as its site; a name like Amazon.com as written', () {
    const text = 'Watch it at https://youtu.be/Vg_HBVOvVWk?t=44 tonight, or buy it on Amazon.com today.';
    final said = respellUnit(unit(text), const []);
    expect(said.text, 'Watch it at youtu.be tonight, or buy it on Amazon.com today.');
    expect(said.toOriginal(said.text.indexOf('tonight')), text.indexOf('tonight'));
  });

  test('a citation is not said; a sentence that is only one is left as it is', () {
    expect(respellUnit(unit('As shown before [12], it holds.'), const []).text, 'As shown before, it holds.');
    // Nothing left to say: kept, for the reader's rule that passes such
    // lines over.
    expect(respellUnit(unit('[12]'), const []).text, '[12]');
  });

  test("the reader's own fixes still apply, and never over a silent stretch", () {
    const text = 'Klein looked up.2';
    final said = respellUnit(
      unit(text, silent: [(start: text.length - 1, end: text.length)]),
      const [SayRule(from: 'Klein', to: 'Kline')],
    );
    expect(said.text, 'Kline looked up.');
    expect(said.toOriginal(said.text.indexOf('looked')), text.indexOf('looked'));
  });
}
