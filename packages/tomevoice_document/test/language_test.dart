import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// A plain-text book with [headings], each followed by a paragraph.
Book _txt(List<String> headings) => ingestString(
      [
        for (final h in headings) '$h\n\nThe text of this part goes on for a sentence or two, as books do.',
      ].join('\n\n'),
      filename: 'book.txt',
    );

String _cp(List<int> codes) => String.fromCharCodes(codes);

const _fr = "Il était une fois une petite fille qui vivait dans une maison au bord de la forêt. Elle avait "
    "un chat et un chien, et elle les aimait beaucoup. Tous les jours, elle allait chercher de l'eau à la "
    'rivière avec sa mère.';
const _es = 'Había una vez una niña que vivía en una casa cerca del bosque. Tenía un gato y un perro, y los '
    'quería mucho. Todos los días iba al río con su madre para buscar agua.';
const _de = 'Es war einmal ein kleines Mädchen, das in einem Haus am Rand des Waldes wohnte. Sie hatte eine Katze '
    'und einen Hund, und sie liebte sie sehr. Jeden Tag ging sie mit ihrer Mutter zum Fluss, um Wasser zu holen.';
const _it = "C'era una volta una bambina che viveva in una casa vicino al bosco. Aveva un gatto e un cane, e li "
    "amava molto. Ogni giorno andava al fiume con sua madre per prendere l'acqua.";
const _pt = 'Era uma vez uma menina que morava numa casa perto da floresta. Ela tinha um gato e um cão, e gostava '
    'muito deles. Todos os dias ia ao rio com a sua mãe para buscar água.';
const _nl = 'Er was eens een klein meisje dat in een huis aan de rand van het bos woonde. Ze had een kat en een hond, '
    'en ze hield heel veel van ze. Elke dag ging ze met haar moeder naar de rivier om water te halen.';
const _en = 'Once upon a time there was a little girl who lived in a house at the edge of the forest. She had a cat '
    'and a dog, and she loved them very much. Every day she went to the river with her mother to fetch water.';
const _uk = 'Це дуже гарна книжка. Я прочитав її вчора ввечері і дуже нею задоволений. Їжак і єнот жили в лісі.';
const _ru = 'Это очень хорошая книга. Я прочитал её вчера вечером и остался очень доволен. Ёж и енот жили в лесу.';

// Urdu, Persian and Arabic sentences ("this is a very good book...").
final _urdu = _cp([0x6CC, 0x6C1, 0x20, 0x627, 0x6CC, 0x6A9, 0x20, 0x628, 0x6C1, 0x62A, 0x20, 0x627, 0x686, 0x6BE, 0x6CC, 0x20, 0x6A9, 0x62A, 0x627, 0x628, 0x20, 0x6C1, 0x6D2, 0x6D4, 0x20, 0x645, 0x6CC, 0x6BA, 0x20, 0x646, 0x6D2, 0x20, 0x627, 0x633, 0x6D2, 0x20, 0x6A9, 0x644, 0x20, 0x631, 0x627, 0x62A, 0x20, 0x67E, 0x691, 0x6BE, 0x627, 0x20, 0x627, 0x648, 0x631, 0x20, 0x645, 0x62C, 0x6BE, 0x6D2, 0x20, 0x628, 0x6C1, 0x62A, 0x20, 0x67E, 0x633, 0x646, 0x62F, 0x20, 0x622, 0x626, 0x6CC, 0x6D4]);
final _persian = _cp([0x627, 0x6CC, 0x646, 0x20, 0x6CC, 0x6A9, 0x20, 0x6A9, 0x62A, 0x627, 0x628, 0x20, 0x628, 0x633, 0x6CC, 0x627, 0x631, 0x20, 0x62E, 0x648, 0x628, 0x20, 0x627, 0x633, 0x62A, 0x2E, 0x20, 0x645, 0x646, 0x20, 0x62F, 0x6CC, 0x634, 0x628, 0x20, 0x622, 0x646, 0x20, 0x631, 0x627, 0x20, 0x62E, 0x648, 0x627, 0x646, 0x62F, 0x645, 0x20, 0x648, 0x20, 0x627, 0x632, 0x20, 0x622, 0x646, 0x20, 0x644, 0x630, 0x62A, 0x20, 0x628, 0x631, 0x62F, 0x645, 0x2E]);
final _arabic = _cp([0x647, 0x630, 0x627, 0x20, 0x643, 0x62A, 0x627, 0x628, 0x20, 0x62C, 0x64A, 0x62F, 0x20, 0x62C, 0x62F, 0x627, 0x2E, 0x20, 0x642, 0x631, 0x623, 0x62A, 0x647, 0x20, 0x627, 0x644, 0x644, 0x64A, 0x644, 0x629, 0x20, 0x627, 0x644, 0x645, 0x627, 0x636, 0x64A, 0x629, 0x20, 0x648, 0x627, 0x633, 0x62A, 0x645, 0x62A, 0x639, 0x62A, 0x20, 0x628, 0x647, 0x20, 0x643, 0x62B, 0x64A, 0x631, 0x627, 0x2E]);

void main() {
  group('language', () {
    test('Latin-script text is told apart by its commonest words', () {
      expect(detectLatinLanguage(_fr), 'fr');
      expect(detectLatinLanguage(_es), 'es');
      expect(detectLatinLanguage(_de), 'de');
      expect(detectLatinLanguage(_it), 'it');
      expect(detectLatinLanguage(_pt), 'pt');
      expect(detectLatinLanguage(_nl), 'nl');
      expect(detectLatinLanguage(_en), 'en');
      expect(detectLatinLanguage('Hello there.'), isNull, reason: 'too little to tell');
    });

    test('a book that does not say gets the language its text is in', () {
      expect(ingestString('$_fr\n\n$_fr', filename: 'conte.txt').metadata.language, 'fr');
      expect(ingestString('$_de\n\n$_de', filename: 'maerchen.txt').metadata.language, 'de');
      expect(ingestString('$_en\n\n$_en', filename: 'tale.txt').metadata.language, 'en');
    });

    test('Urdu and Persian are not Arabic, Ukrainian is not Russian', () {
      expect(detectScriptLanguage(_urdu), 'ur');
      expect(detectScriptLanguage(_persian), 'fa');
      expect(detectScriptLanguage(_arabic), 'ar');
      expect(detectScriptLanguage(_uk), 'uk');
      expect(detectScriptLanguage(_ru), 'ru');
    });

    test('a paragraph marked in another language keeps it', () {
      final blocks = blocksFromHtml(
        '<html xml:lang="en"><body><p>English words.</p><p xml:lang="fr">Des mots.</p>'
        '<div lang="de"><p>Deutsche Worte.</p><p lang="it">Parole.</p></div></body></html>',
        language: 'en',
      );
      expect(blocks.map((b) => b.language), ['en', 'fr', 'de', 'it']);
    });
  });

  group('chapter headings beyond English', () {
    test('each language splits its book into chapters', () {
      final cases = <List<String>>[
        ['第一章 开始', '第二章 继续', '第十二章 结束'],
        ['第1話', '第2話', '第3話'],
        ['제1장', '제2장', '제3장'],
        ['Глава 1', 'ГЛАВА 2', 'Глава третья'],
        ['Capítulo I', 'CAPÍTULO II', 'Capítulo XII'],
        ['Chapitre 1', 'Chapitre premier', 'Chapitre deux'],
        ['Kapitel 1', 'Erstes Kapitel', 'Zweites Kapitel'],
        ['Capitolo 1', 'Capitolo 2', 'Capitolo 3'],
        ['Hoofdstuk 1', 'Hoofdstuk 2', 'Hoofdstuk 3'],
        ['Rozdział 1', 'Rozdział 2', 'Rozdział 3'],
        // "प्रथम अध्याय", "अध्याय 2", "अध्याय तीन"
        [
          _cp([0x92A, 0x94D, 0x930, 0x925, 0x92E, 0x20, 0x905, 0x927, 0x94D, 0x92F, 0x93E, 0x92F]),
          '${_cp([0x905, 0x927, 0x94D, 0x92F, 0x93E, 0x92F])} 2',
          '${_cp([0x905, 0x927, 0x94D, 0x92F, 0x93E, 0x92F])} ${_cp([0x924, 0x940, 0x928])}',
        ],
      ];
      for (final headings in cases) {
        final book = _txt(headings);
        expect(book.sections.map((s) => s.displayTitle), headings, reason: headings.first);
      }
    });

    test('Bengali ordinals, with either form of the nukta letters', () {
      // "প্রথম অধ্যায়" written with the precomposed য় (U+09DF) and the
      // decomposed one (য + ়), and "দ্বিতীয় অধ্যায়".
      final adhyayPrecomposed = _cp([0x985, 0x9A7, 0x9CD, 0x9AF, 0x9BE, 0x9DF]);
      final adhyayDecomposed = _cp([0x985, 0x9A7, 0x9CD, 0x9AF, 0x9BE, 0x9AF, 0x9BC]);
      final prothom = _cp([0x9AA, 0x9CD, 0x9B0, 0x9A5, 0x9AE]);
      final ditiyo = _cp([0x9A6, 0x9CD, 0x9AC, 0x9BF, 0x9A4, 0x9C0, 0x9DF]);
      final headings = ['$prothom $adhyayPrecomposed', '$ditiyo $adhyayDecomposed', '$adhyayDecomposed ${_cp([0x9E9])}'];
      expect(_txt(headings).sections, hasLength(3));
    });

    test('prose that starts with a keyword is not a heading', () {
      expect(looksLikeChapterLine('Глава семьи вернулся домой поздно вечером, и все уже спали.'), isFalse);
      expect(looksLikeChapterLine('Livre un colis demain.'), isFalse);
      expect(looksLikeChapterLine('Boek een kamer in het hotel.'), isFalse);
      expect(looksLikeChapterLine('Kapitel 1'), isTrue);
    });

    test('a long text with no chapters is cut into parts at paragraphs', () {
      final paragraphs = [
        // 800 paragraphs of 14 words: about three parts' worth.
        for (var i = 0; i < 800; i++) 'Paragraph $i of the long story has a few words in it, enough to count.',
      ];
      final book = ingestString(paragraphs.join('\n\n'), filename: 'long.txt');
      expect(book.sections.length, greaterThan(1));
      expect(book.sections.first.displayTitle, 'Part 1');
      // Nothing lost, nothing doubled, no paragraph cut.
      expect([for (final s in book.sections) ...s.blocks.map((b) => b.text)], paragraphs);
      final short = ingestString(paragraphs.take(30).join('\n\n'), filename: 'short.txt');
      expect(short.sections, hasLength(1));
    });
  });
}
