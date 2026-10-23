// Find and keep: search, pronunciation rules, and saved places that survive
// a book's text being re-parsed.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_search.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/reader_screen.dart' show wordAt;
import 'package:tomevoice_spike/reading_rules.dart';

void main() {
  group('search', () {
    final texts = [
      'The café opened at dawn.',
      'Nobody came to the Cafe that day.',
      'They talked about concatenation.',
      'A cat sat. Another cat watched.',
    ];

    test('ignores case and accents', () {
      final hits = searchTexts(texts, 'CAFÉ');
      expect([for (final h in hits) h.unit], [0, 1]);
      expect(texts[0].substring(hits[0].start, hits[0].end), 'café');
    });

    test('finds every match in a sentence, and whole words when asked', () {
      expect(searchTexts(texts, 'cat').length, 3);
      expect([for (final h in searchTexts(texts, 'cat', wholeWords: true)) h.unit], [3, 3]);
    });

    test('a chapter is a range of sentences', () {
      expect(searchTexts(texts, 'cat', from: 3, to: 4).length, 2);
      expect(searchTexts(texts, 'café', from: 1, to: 3).single.unit, 1);
    });

    test('folding keeps every position', () {
      const s = 'Ærøskøbing — naïve façade';
      expect(foldForSearch(s).length, s.length);
    });
  });

  group('pronunciation', () {
    const rules = [
      SayRule(from: 'Zorian', to: 'Zor-ee-an'),
      SayRule(from: 'Kael', to: 'Kale'),
      SayRule(from: 'Kael Ardent', to: 'Kale Ar-dent'),
    ];

    test('whole words in any case, the longest first, and positions come back to the page', () {
      const page = 'Zorian looked at Kael. kael Ardent? zoriana';
      final said = respell(page, rules);
      expect(said.text, 'Zor-ee-an looked at Kale. Kale Ar-dent? zoriana');
      final looked = said.text.indexOf('looked');
      expect(said.toOriginal(looked), page.indexOf('looked'));
      final name = said.text.indexOf('Kale Ar-dent');
      expect(said.toOriginal(name), page.indexOf('kael Ardent'));
      expect(said.toOriginal(name + 'Kale Ar-dent'.length, end: true), page.indexOf('?'));
    });

    test('a book rule comes before the same word for every book', () {
      ReadingRules.instance.say = const [
        SayRule(from: 'Sunny', to: 'Sun-nee'),
        SayRule(from: 'Sunny', to: 'Sonny', book: 'shadow'),
      ];
      expect(respell('Sunny ran.', ReadingRules.instance.sayFor('shadow')).text, 'Sonny ran.');
      expect(respell('Sunny ran.', ReadingRules.instance.sayFor('other')).text, 'Sun-nee ran.');
    });

    test('the word under a finger', () {
      const t = "He said, “Zorian’s idea—no.”";
      expect(wordAt(t, t.indexOf('Zorian') + 2), 'Zorian’s');
      expect(wordAt(t, t.indexOf(',')), 'said');
      expect(wordAt(t, t.indexOf('idea') + 4), 'idea');
    });
  });

  test('a saved place is found again by its words after the book is re-parsed', () {
    Book book(List<String> paras) => ingestString(paras.join(String.fromCharCodes([10, 10])), title: 'B');
    final before = ReadingLayout.build(book(['First paragraph here.', 'The line I loved most of all.']));
    final u = before.units.indexWhere((x) => x.text.startsWith('The line'));
    final mark = Mark(
      id: 'm',
      bookId: 'b',
      bookTitle: 'B',
      kind: MarkKind.quote,
      at: cursorOf(before.units[u]),
      text: before.units[u].text,
      created: DateTime(2026),
    );
    // A paragraph found in front of it on re-parsing.
    final after = ReadingLayout.build(
        book(['A preface that was missed before.', 'First paragraph here.', 'The line I loved most of all.']));
    expect(after.units[unitOfMark(after, mark)].text, startsWith('The line I loved'));
  });
}
