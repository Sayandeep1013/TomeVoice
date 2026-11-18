import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// A paragraph of [sentences] sentences, ten words each (numbers count),
/// numbered so that no two are alike.
String _para(int n, {int sentences = 3}) => [
      for (var s = 0; s < sentences; s++) 'Paragraph $n sentence $s goes on with more words here.',
    ].join(' ');

List<String> _titles(List<DraftSection> sections) => [for (final s in sections) s.title ?? ''];

/// Every word of [sections], in order: what no rule may change.
String _words(List<DraftSection> sections) => [
      for (final s in sections)
        for (final b in s.blocks) b.text,
    ].join(' ');

void main() {
  // A web novel saved as one file, a paragraph a line, its chapters headed
  // in a way TomeVoice does not know.
  final novel = [
    'The Long Road',
    for (var c = 1; c <= 4; c++) ...[
      '#$c The gate number $c',
      for (var p = 0; p < 3; p++) _para(c * 10 + p),
    ],
  ].join('\n');

  group('lines the reader names', () {
    test('a book with chapter lines TomeVoice does not know has one chapter', () {
      expect(sectionsFromPlainText(novel, fallbackTitle: 'Book'), hasLength(1));
    });

    test('lines starting with what the reader typed start chapters', () {
      final s = sectionsFromPlainText(novel, fallbackTitle: 'Book', chapters: const TextChapters.lines('#'));
      expect(_titles(s), ['Book', '#1 The gate number 1', '#2 The gate number 2', '#3 The gate number 3', '#4 The gate number 4']);
      // The chapter line heads its chapter.
      expect(s[1].blocks.first.role, BlockRole.heading);
      expect(_words(s), _words(sectionsFromPlainText(novel, fallbackTitle: 'Book')));
    });

    test('capitals do not matter, and a long line is not a title', () {
      final text = [
        'EPISODE 1',
        _para(1),
        'Episode two',
        _para(2),
        'episode after episode went by, and still nobody in the whole of the town had any idea at all of what was coming',
        _para(3),
      ].join('\n');
      final s = sectionsFromPlainText(text, fallbackTitle: 'Book', chapters: const TextChapters.lines('Episode'));
      expect(_titles(s), ['EPISODE 1', 'Episode two']);
    });

    test('a line named stands alone where no blank line follows it', () {
      final text = [
        'Ep. 1',
        _para(1),
        '',
        _para(2),
        '',
        'Ep. 2',
        _para(3),
        '',
        _para(4),
      ].join('\n');
      final s = sectionsFromPlainText(text, fallbackTitle: 'Book', chapters: const TextChapters.lines('Ep.'));
      expect(_titles(s), ['Ep. 1', 'Ep. 2']);
      expect(s[0].blocks.map((b) => b.text).first, 'Ep. 1');
      expect(s[0].blocks, hasLength(3));
    });

    test('a regular expression', () {
      final s = sectionsFromPlainText(
        novel,
        fallbackTitle: 'Book',
        chapters: const TextChapters.lines(r'^#\d+ the gate', regex: true),
      );
      expect(s, hasLength(5));
      expect(s[4].title, '#4 The gate number 4');
    });

    test('Chinese chapter lines, by a pattern and by their first character', () {
      final text = [
        '第一章 开始',
        '他走进了城门。天已经黑了。',
        '第二章 夜',
        '夜里很安静。第三天他读完了这一章的书。',
        '第十二章 回家',
        '他回家了。',
      ].join('\n');
      final byPattern = sectionsFromPlainText(text, fallbackTitle: '书', chapters: const TextChapters.lines(r'^第.+章', regex: true));
      expect(_titles(byPattern), ['第一章 开始', '第二章 夜', '第十二章 回家']);
      final byStart = sectionsFromPlainText(text, fallbackTitle: '书', chapters: const TextChapters.lines('第'));
      expect(_titles(byStart), _titles(byPattern));
    });

    test('a pattern with a mistake is said so, and the book keeps its own chapters', () {
      const broken = TextChapters.lines(r'^(Chapter', regex: true);
      expect(broken.problem, isNotNull);
      expect(broken.lineTest, isNull);
      final s = sectionsFromPlainText(novel, fallbackTitle: 'Book', chapters: broken);
      expect(_titles(s), _titles(sectionsFromPlainText(novel, fallbackTitle: 'Book')));
      expect(previewTextChapters(novel, broken).count, 1);
      expect(previewTextChapters(novel, broken).ruled, isFalse);
    });

    test('an empty pattern is said so', () {
      expect(const TextChapters.lines('  ').problem, isNotNull);
      expect(const TextChapters.lines('Ch').problem, isNull);
    });

    test('a pattern that matches no line leaves the book as it was', () {
      final s = sectionsFromPlainText(novel, fallbackTitle: 'Book', chapters: const TextChapters.lines('Volume'));
      expect(s, hasLength(1));
      expect(previewTextChapters(novel, const TextChapters.lines('Volume')).count, 1);
      expect(previewTextChapters(novel, const TextChapters.lines('Volume')).ruled, isFalse);
    });
  });

  group('every so many words', () {
    // Twenty paragraphs of 30 words.
    final text = [for (var p = 0; p < 20; p++) _para(p)].join('\n\n');

    test('cut where paragraphs end, into parts of about as many words', () {
      final s = sectionsFromPlainText(text, fallbackTitle: 'Book', chapters: const TextChapters.words(200));
      // 7 paragraphs (210 words) a part; the last 6 (180 words) stand alone.
      expect(_titles(s), ['Part 1', 'Part 2', 'Part 3']);
      expect([for (final x in s) x.blocks.length], [7, 7, 6]);
      expect(_words(s), _words(sectionsFromPlainText(text, fallbackTitle: 'Book')));
    });

    test('a short tail joins the part before it', () {
      final t = [for (var p = 0; p < 15; p++) _para(p)].join('\n\n');
      final s = sectionsFromPlainText(t, fallbackTitle: 'Book', chapters: const TextChapters.words(200));
      // 7, 7, then one paragraph of 30 words: under a third of 200.
      expect([for (final x in s) x.blocks.length], [7, 8]);
    });

    test('a paragraph longer than a part is cut where a sentence ends', () {
      final one = _para(1, sentences: 100);
      final s = sectionsFromPlainText(one, fallbackTitle: 'Book', chapters: const TextChapters.words(250));
      expect(s.length, 4);
      for (final x in s) {
        for (final b in x.blocks) {
          expect(b.text, endsWith('here.'));
          expect(b.sentences.first.of(b.text), startsWith('Paragraph 1 sentence'));
        }
      }
      expect(_words(s), one);
    });

    test('a book shorter than one part is one chapter, under its own title', () {
      final s = sectionsFromPlainText(_para(1), fallbackTitle: 'Book', chapters: const TextChapters.words(1000));
      expect(_titles(s), ['Book']);
    });

    test('too few words a chapter is said so', () {
      expect(const TextChapters.words(50).problem, isNotNull);
      final s = sectionsFromPlainText(text, fallbackTitle: 'Book', chapters: const TextChapters.words(50));
      expect(s, hasLength(1));
    });
  });

  group('the rule kept and shown', () {
    test('kept as JSON and read back; anything else is TomeVoice\'s own', () {
      for (final r in const [
        TextChapters.auto(),
        TextChapters.lines('Chapter'),
        TextChapters.lines(r'^第.+章', regex: true),
        TextChapters.words(3000),
      ]) {
        expect(TextChapters.fromJson(jsonDecode(jsonEncode(r.toJson()))), r);
      }
      expect(TextChapters.fromJson(null), const TextChapters.auto());
      expect(TextChapters.fromJson({'kind': 'lines'}), const TextChapters.auto());
      expect(TextChapters.fromJson('words'), const TextChapters.auto());
    });

    test('the preview counts and names the chapters the reader lists', () {
      final bytes = Uint8List.fromList(utf8.encode(novel));
      for (final r in const [TextChapters.auto(), TextChapters.lines('#'), TextChapters.words(200)]) {
        final book = ingestBytes(bytes, filename: 'road.txt', textChapters: r);
        final layout = ReadingLayout.build(book, displayOnly: true);
        final p = previewTextChapters(novel, r, fallbackTitle: book.metadata.title, titles: 3);
        expect(p.count, layout.chapters.length, reason: '$r');
        expect(p.titles, [for (var c = 0; c < 3 && c < layout.chapters.length; c++) layout.chapterTitle(c)],
            reason: '$r');
        expect(p.ruled, !r.isAuto, reason: '$r');
      }
      // The title line before the first chapter is no chapter of its own.
      expect(previewTextChapters(novel, const TextChapters.lines('#')).count, 4);
    });

    test('a TXT file is split by the rule; Markdown pays it no mind', () {
      final bytes = Uint8List.fromList(utf8.encode(novel));
      final txt = ingestBytes(bytes, filename: 'road.txt', textChapters: const TextChapters.lines('#'));
      expect(txt.sections, hasLength(5));
      final md = ingestBytes(bytes, filename: 'road.md', textChapters: const TextChapters.lines('#'));
      expect(md.sections.length, isNot(5));
      expect(plainTextOf(bytes), novel);
    });

    test('a Gutenberg licence is not in the text chapters are cut from', () {
      final text = '*** START OF THE PROJECT GUTENBERG EBOOK ROAD ***\n$novel\n*** END OF THE PROJECT GUTENBERG EBOOK ROAD ***\nLicence.';
      expect(plainTextOf(Uint8List.fromList(utf8.encode(text))).trim(), novel);
    });
  });
}
