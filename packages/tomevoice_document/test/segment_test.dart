import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

List<String> _split(String t) => [for (final s in segmentSentences(t)) s.of(t)];

String _cp(List<int> codes) => String.fromCharCodes(codes);

void main() {
  group('sentence boundaries', () {
    test('titles before a name never end a sentence', () {
      for (final t in [
        'Capt. Smith came. He left.',
        'Gen. Lee rode. He won.',
        'We saw Mt. Everest today. It was tall.',
        'Rev. Brown spoke. All listened.',
        'Prof. Xavier taught. They learned.',
        'St. Paul is a city. It is cold.',
        'Lt. Col. Hart arrived. He sat.',
      ]) {
        expect(_split(t), hasLength(2), reason: t);
      }
    });

    test('an abbreviation that ends a sentence ends it', () {
      expect(_split('"No." She turned away.'), ['"No."', 'She turned away.']);
      expect(_split('Apples, pears, etc. The list goes on.'), ['Apples, pears, etc.', 'The list goes on.']);
      expect(_split('He said no. The next day he came.'), hasLength(2));
      expect(_split('Smith et al. (2004) agree. Others do not.'), hasLength(2));
    });

    test('but not before a number, a lowercase word or another abbreviation', () {
      expect(_split('See No. 5 for details. Then stop.'), hasLength(2));
      expect(_split('Read Vol. IV and Ch. 3 first. Then stop.'), hasLength(2));
      expect(_split('Smith & Co. Ltd. sold it. Then stop.'), hasLength(2));
      expect(_split('Dr. Smith saw Mr. Jones today. Then they left.'), hasLength(2));
    });

    test('Russian abbreviations and initials', () {
      expect(_split('Он сказал, т. е. согласился. Потом ушёл.'), hasLength(2));
      expect(_split('А. С. Пушкин писал стихи. Он жил давно.'), hasLength(2));
      expect(_split('Были яблоки, груши и т. д. Потом он ушёл.'), hasLength(2));
    });

    test('a dash after "!" or "?", then who spoke in lower case, goes on with the sentence', () {
      // Russian and Ukrainian dialogue: the speaker's words, then a dash and
      // who said them. Cut after "!", "крикнул Андреич" was read on its own.
      expect(_split('— Огонь держать до утра! — крикнул Андреич коту. Кот молчал.'), [
        '— Огонь держать до утра! — крикнул Андреич коту.',
        'Кот молчал.',
      ]);
      expect(_split('— Кто там? — спросила мать. — Не знаю! — ответил он.'), [
        '— Кто там? — спросила мать.',
        '— Не знаю! — ответил он.',
      ]);
      expect(_split('— Тримай вогонь до ранку! — гукнув Андрій. — Хто там? – спитала мати.'), [
        '— Тримай вогонь до ранку! — гукнув Андрій.',
        '— Хто там? – спитала мати.',
      ]);
      expect(_split('«Огонь!» — крикнул он, и все проснулись.'), ['«Огонь!» — крикнул он, и все проснулись.']);
      // A capital after the dash is a sentence of its own; so is one after a
      // full stop.
      expect(_split('— Стой! — Андрей остановился.'), ['— Стой!', '— Андрей остановился.']);
      expect(_split('Он ушёл. — сказала она тихо.'), ['Он ушёл.', '— сказала она тихо.']);
    });

    test('a long Chinese sentence is cut at its commas, not mid-word', () {
      // Clauses of 18 characters (so the 280-character limit falls inside
      // one) joined by fullwidth commas, no spaces at all.
      final clause = _cp(List.filled(17, 0x6587)) + _cp([0xFF0C]);
      final t = clause * 30 + _cp([0x3002]);
      final s = segmentSentences(t);
      expect(s.length, greaterThan(1));
      for (final x in s) {
        expect(x.endOffset - x.startOffset, lessThanOrEqualTo(maxSentenceChars));
        final last = t.codeUnitAt(x.endOffset - 1);
        expect(last == 0xFF0C || last == 0x3002, isTrue, reason: 'cut after a comma or the stop');
      }
    });
  });

  group('words', () {
    test('Chinese and Japanese get a word unit per character', () {
      // "吾輩は猫である。" and an English word beside them.
      final t = '${_cp([0x543E, 0x8F29, 0x306F, 0x732B, 0x3067, 0x3042, 0x308B, 0x3002])} Neko';
      final words = wordSpans(t, 0, t.length).map((w) => w.of(t)).toList();
      expect(words, [
        _cp([0x543E]),
        _cp([0x8F29]),
        _cp([0x306F]),
        _cp([0x732B]),
        _cp([0x3067]),
        _cp([0x3042]),
        _cp([0x308B, 0x3002]),
        'Neko',
      ]);
    });

    test('word counts are unchanged for spaced scripts', () {
      for (final t in [
        'The quick brown fox, jumps over the lazy dog.',
        'Он пришёл домой поздно вечером.',
        'আমি বাড়ি যাই। তুমি কোথায় যাও?',
        'Tab\tand${_cp([0xA0])}no-break${_cp([0x2003])}spaces',
      ]) {
        expect(countWords(t), RegExp(r'\S+').allMatches(t).length, reason: t);
      }
    });

    test('Chinese, Japanese and Thai count in word-equivalents', () {
      // 90 Han characters: about 50 words' worth of time, not one.
      final han = _cp(List.filled(90, 0x6587));
      expect(countWords(han), 50);
      // Punctuation is not a word.
      expect(countWords('$han${_cp([0x3002])}'), 50);
      // 100 Thai letters with no spaces: about 20 words.
      expect(countWords(_cp(List.filled(100, 0x0E01))), 20);
      // Mixed: an English word and nine Han characters.
      expect(countWords('iPhone${_cp(List.filled(9, 0x6587))}'), 6);
    });
  });
}
