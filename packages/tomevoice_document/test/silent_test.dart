import 'dart:convert';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

void main() {
  group('silent ranges', () {
    test('a marker stuck to a full stop still ends the sentence', () {
      final b = makeBlock(
        role: BlockRole.paragraph,
        text: 'It was a house.${silentMark('1')} The next day came.',
      );
      expect(b.text, 'It was a house.1 The next day came.');
      expect([for (final s in b.sentences) s.of(b.text)], ['It was a house.1', 'The next day came.']);
      expect(b.sentences.first.silent, [(start: 15, end: 16)]);
      expect(b.sentences.last.silent, isEmpty);
    });

    test('markers before and inside a sentence', () {
      final b = makeBlock(
        role: BlockRole.paragraph,
        text: 'He said so${silentMark('[2]')}, twice${silentMark('*')}. Then left.',
      );
      expect(b.text, 'He said so[2], twice*. Then left.');
      expect(b.sentences, hasLength(2));
      expect(b.sentences.first.silent, [(start: 10, end: 13), (start: 20, end: 21)]);
    });

    test('a decimal is still not a boundary', () {
      final b = makeBlock(role: BlockRole.paragraph, text: 'It cost 3.50 then. Fine.');
      expect(b.sentences, hasLength(2));
    });

    test('a long sentence is never cut inside a marker', () {
      final words = List.filled(60, 'word').join(' ');
      final b = makeBlock(
        role: BlockRole.paragraph,
        text: '$words${silentMark('[1, 2]')} $words.',
      );
      for (final s in b.sentences) {
        for (final r in s.silent) {
          expect(r.start, greaterThanOrEqualTo(s.startOffset));
          expect(r.end, lessThanOrEqualTo(s.endOffset));
        }
      }
      expect(b.sentences.expand((s) => s.silent), hasLength(1));
    });

    test('a drop cap joined to its word keeps the word block\'s markers', () {
      final joined = joinDropCaps([
        makeBlock(role: BlockRole.figure, text: 'Y', image: 'y.png'),
        makeBlock(role: BlockRole.paragraph, text: 'OU know it.${silentMark('1')} Yes.'),
      ]);
      expect(joined[1].text, 'YOU know it.1 Yes.');
      expect(joined[1].sentences.first.silent, [(start: 12, end: 13)]);
    });

    test('compact JSON keeps them, and books stored without them read back with none', () {
      final b = makeBlock(role: BlockRole.paragraph, text: 'A house.${silentMark('1')} Next one.');
      final json = jsonDecode(jsonEncode(b.toJson())) as Map<String, Object?>;
      expect(json['sl'], [8, 9]);
      final back = Block.fromJson(json);
      expect(back.sentences.first.silent, [(start: 8, end: 9)]);
      expect(back.sentences.last.silent, isEmpty);

      final plain = makeBlock(role: BlockRole.paragraph, text: 'Nothing silent here.');
      expect(plain.toJson().containsKey('sl'), isFalse);
      final old = Block.fromJson({'id': 'x', 'role': 'paragraph', 'text': 'Old one.', 'sb': [0, 8]});
      expect(old.sentences.single.silent, isEmpty);
    });

    test('the long JSON form round-trips too', () {
      const s = Sentence(startOffset: 0, endOffset: 9, words: [], silent: [(start: 7, end: 8)]);
      expect(Sentence.fromJson(s.toJson()).silent, [(start: 7, end: 8)]);
      expect(Sentence.fromJson(const {'start': 0, 'end': 3}).silent, isEmpty);
    });

    test('units carry their ranges, relative to their own text', () {
      final book = Book(
        id: 'b',
        metadata: const BookMetadata(title: 'T'),
        source: SourceKind.epub,
        toc: const [],
        sections: [
          Section(id: 's0', index: 0, blocks: [
            makeBlock(role: BlockRole.paragraph, text: 'First one. It was a house.${silentMark('1')} Next.'),
          ]),
        ],
      );
      final units = flattenSpeakable(book);
      expect(units.map((u) => u.text), ['First one.', 'It was a house.1', 'Next.']);
      expect(units[1].silent, [(start: 15, end: 16)]);
      expect(units.first.silent, isEmpty);
    });
  });

  group('spoken text', () {
    test('silent stretches are left out, positions map back to the page', () {
      final s = spokenText('It was a house.1 The end[2].', const [(start: 15, end: 16), (start: 24, end: 27)]);
      expect(s.text, 'It was a house. The end.');
      expect(s.changed, isTrue);
      // "The" starts at 16 in what is said and at 17 on the page.
      expect(s.toShown(16), 17);
      // "house." ends at 15; on the page its word runs on over the marker.
      expect(s.toShown(15, end: true), 16);
      // "end." ends at 24 said, 28 shown.
      expect(s.toShown(24, end: true), 28);
      expect(s.toShown(0), 0);
    });

    test('nothing silent, nothing changed', () {
      final s = spokenText('Plain.', const []);
      expect(s.text, 'Plain.');
      expect(s.changed, isFalse);
      expect(s.toShown(3), 3);
    });

    test('a marker at the very start', () {
      final s = spokenText('[1]Word here', const [(start: 0, end: 3)]);
      expect(s.text, 'Word here');
      expect(s.toShown(0), 3);
      expect(s.toShown(4, end: true), 7);
    });

    test('a sentence that is only a marker says nothing', () {
      expect(spokenText('[1]', const [(start: 0, end: 3)]).text, '');
    });
  });
}
