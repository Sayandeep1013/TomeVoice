// The first sentence of a start in a natural voice is made in two parts, so
// the voice is heard before the whole sentence is made: where it is cut,
// and the rest's word places moved into the whole sentence.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_spike/scheduler.dart';

void main() {
  group('where the first clause ends', () {
    test('just after the first comma with enough on both sides', () {
      const text = 'It was a bright cold day in April, and the clocks were striking thirteen across the town.';
      final cut = firstClauseEnd(text);
      expect(text.substring(0, cut), 'It was a bright cold day in April,');
      expect(text.substring(cut), ' and the clocks were striking thirteen across the town.');
    });

    test('a short sentence is not cut', () {
      expect(firstClauseEnd('Yes, he said, and left.'), -1);
    });

    test('no clause mark: not cut', () {
      expect(firstClauseEnd('He walked down the long road towards the old mill without looking back once at all'), -1);
    });

    test('a comma too near the start or the end is passed over', () {
      const text = 'Well, he walked down the long road towards the old mill and stopped there, tired.';
      expect(firstClauseEnd(text), -1);
    });

    test('a number is not a clause', () {
      const text = 'The town had grown to some 12,000 people by then; nobody there remembered the old mill.';
      final cut = firstClauseEnd(text);
      expect(text.substring(0, cut), 'The town had grown to some 12,000 people by then;');
    });

    test('a dash ends a clause too', () {
      final dash = String.fromCharCode(0x2014);
      final text = 'She had waited at the station for an hour$dash longer than anyone should wait for anyone.';
      expect(text.substring(0, firstClauseEnd(text)), 'She had waited at the station for an hour$dash');
    });
  });

  test("the rest's words are placed in the whole sentence", () {
    const t = WordTiming(charStart: 1, charEnd: 4, frameStart: 10, frameEnd: 50, source: WordTimingSource.modelDurations);
    final shifted = shiftTimings([t], 34).single;
    expect(shifted.charStart, 35);
    expect(shifted.charEnd, 38);
    expect(shifted.frameStart, 10);
    expect(shifted.frameEnd, 50);
    expect(shifted.source, WordTimingSource.modelDurations);
  });
}
