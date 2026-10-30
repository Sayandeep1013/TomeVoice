// Who says each line, found from a book's speech tags: on Pride and
// Prejudice as the app bundles it, the characters its tags name (by the name
// used most, the others folded in, each with their sex), and who speaks
// paragraph by paragraph against labels made by hand from the text
// (speakers_pp.tsv): nearly every line given a speaker is right, about half
// are given one, and the rest stay in the dialogue voice. Then the ways a
// speaker is found, and the ways it is not, on lines written for them.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/speakers.dart';

final _o = String.fromCharCode(0x201C);
final _c = String.fromCharCode(0x201D);

/// [paragraphs] as one chapter, a unit a paragraph.
BookText _text(List<String> paragraphs) => BookText(
      paragraphs: paragraphs,
      chapterOf: Int32List(paragraphs.length),
      firstUnit: Int32List.fromList([for (var i = 0; i < paragraphs.length; i++) i]),
      unitCount: Int32List.fromList([for (final _ in paragraphs) 1]),
      unitStart: Int32List(paragraphs.length),
      unitLength: Int32List.fromList([for (final p in paragraphs) p.length]),
    );

/// Who says each paragraph's quotations, by name: '?' for nobody known,
/// '' for a paragraph with none, two names joined with '+'.
List<String> _who(List<String> paragraphs, List<Character> cast) {
  final spoken = Attributor(CastIndex(cast)).attribute(_text(paragraphs), 0, paragraphs.length);
  return [
    for (final quotes in spoken)
      quotes.isEmpty
          ? ''
          : {for (final q in quotes) q.who < 0 || q.who >= cast.length ? '?' : cast[q.who].name}.join('+'),
  ];
}

void main() {
  group('Pride and Prejudice', () {
    final book = ingestBytes(
      File('assets/starter/pride-and-prejudice.epub').readAsBytesSync(),
      filename: 'pride-and-prejudice.epub',
    );
    final text = BookText.of(ReadingLayout.build(book));
    late final people = findCharacters(text);
    Character of(String name) => people.firstWhere((c) => c.name == name);

    test('its cast: who speaks most, the names each goes by, and their sex', () {
      expect(people.take(5).map((c) => c.name), containsAll(['Elizabeth', 'Darcy', 'Mrs. Bennet', 'Jane']));
      expect(people.first.name, 'Elizabeth', reason: 'the heroine speaks most');
      expect(of('Darcy').also, contains('Mr. Darcy'), reason: '"Darcy" and "Mr. Darcy" are one man');
      expect(of('Bingley').also, contains('Mr. Bingley'));
      expect(of('Miss Bingley').also, isNot(contains('Bingley')), reason: 'his sister is not him');
      expect(people.where((c) => c.name == 'Mr. Bennet'), hasLength(1));
      for (final (name, gender) in [
        ('Elizabeth', Gender.female),
        ('Jane', Gender.female),
        ('Darcy', Gender.male),
        ('Bingley', Gender.male),
        ('Wickham', Gender.male),
        ('Mrs. Bennet', Gender.female),
        ('Mr. Bennet', Gender.male),
        ('Lady Catherine', Gender.female),
        ('Mr. Collins', Gender.male),
      ]) {
        expect(of(name).gender, gender, reason: name);
      }
      for (final c in people) {
        expect(c.lines, greaterThanOrEqualTo(2), reason: '${c.name} is listed with fewer than two lines');
        if (c.lines >= 10) expect(c.sample.length, inInclusiveRange(24, 180), reason: '${c.name} has no line to hear');
      }
    });

    test('labelled by hand: nearly every line given a speaker is right', () {
      final index = CastIndex(people);
      // Each paragraph's speaker, as reading would give its quotations.
      final said = <String, String>{};
      for (final (from, to) in text.stretches()) {
        final spoken = Attributor(index).attribute(text, from, to);
        for (var p = from; p < to; p++) {
          final whos = {for (final q in spoken[p - from]) q.who};
          final known = {for (final w in whos) if (w >= 0 && w < people.length) people[w]};
          said[text.paragraphs[p]] = known.length == 1 && !whos.contains(-1)
              ? known.single.name
              : known.isEmpty
                  ? '?'
                  : '+';
        }
      }
      // "Miss Lucas" is Charlotte, and "Miss Bennet" is Jane, in this book.
      const same = {'Miss Lucas': 'Charlotte', 'Miss Bennet': 'Jane'};
      bool right(String name, String label) {
        final c = people.firstWhere((p) => p.name == name);
        final names = {for (final n in c.names) same[n] ?? n};
        return label.split('|').any((l) => names.contains(same[l] ?? l));
      }

      var labelled = 0, given = 0, correct = 0;
      final wrong = <String>[];
      for (final line in File('test/speakers_pp.tsv').readAsLinesSync()) {
        if (line.startsWith('#') || line.trim().isEmpty) continue;
        final cols = line.split('\t');
        final label = cols[0];
        final paragraph = said.keys.where((p) => p.startsWith(cols[1])).single;
        final who = said[paragraph]!;
        labelled++;
        if (who == '?') continue;
        given++;
        if (who != '+' && label != 'NONE' && right(who, label)) {
          correct++;
        } else {
          wrong.add('$who for $label: ${cols[1]}');
        }
      }
      final precision = correct / given;
      final share = given / labelled;
      final measured = 'given a speaker $given of $labelled (${(100 * share).toStringAsFixed(1)}%), '
          'right $correct (${(100 * precision).toStringAsFixed(1)}%); wrong: $wrong';
      expect(labelled, greaterThan(450), reason: 'the labels no longer find their paragraphs');
      expect(precision, greaterThanOrEqualTo(0.98), reason: measured);
      expect(share, greaterThanOrEqualTo(0.45), reason: measured);
    });

    test("a reading's speakers are the book's, a chapter at a time", () {
      final index = CastIndex(people);
      final whole = speakersOf(text, index);
      // A stretch with speakers in it (the preface has none).
      final (from, to) = text.stretches().firstWhere((s) {
        final u0 = text.firstUnit[s.$1];
        final u1 = text.firstUnit[s.$2 - 1] + text.unitCount[s.$2 - 1];
        return s.$2 - s.$1 > 20 && whole.sublist(u0, u1).where((w) => w >= 0).length > 10;
      });
      final part = speakersOf(text.part(from, to), index);
      final u0 = text.firstUnit[from];
      expect(part, whole.sublist(u0, u0 + part.length), reason: 'a stretch read alone gave other speakers');
    });
  });

  group('found', () {
    final cast = [
      Character('Zorian', gender: Gender.male),
      Character('Kirielle', gender: Gender.female),
      Character('Taiven', gender: Gender.female),
      Character('Benisek', gender: Gender.male),
      Character(firstPerson),
    ];

    test('by a tag on either side of the words, in either order', () {
      expect(
        _who([
          '${_o}We should go,$_c said Zorian.',
          '${_o}Not yet,$_c Kirielle replied. ${_o}I want to see it.$_c',
          'Zorian said, ${_o}Then we wait.$_c',
          '${_o}Never,$_c I said.',
        ], cast),
        ['Zorian', 'Kirielle', 'Zorian', firstPerson],
      );
    });

    test('by "he" and "she" for the one person of that sex it can be', () {
      expect(
        _who([
          'Taiven came in from the rain and shook out her coat.',
          '${_o}Late again,$_c she said.',
          'Zorian looked up from his book.',
          '${_o}You are soaked,$_c he said.',
          '${_o}So would you be,$_c she answered.',
        ], cast),
        ['', 'Taiven', '', 'Zorian', 'Taiven'],
      );
    });

    test('but "she" in a new line is not the one who spoke the line before', () {
      expect(
        _who([
          '${_o}It is late,$_c said Kirielle.',
          '${_o}Later than you think,$_c she said.',
        ], cast),
        ['Kirielle', '?'],
        reason: 'a new paragraph of dialogue is someone else speaking',
      );
    });

    test("by a character's own beat beside the words", () {
      expect(_who(['Kirielle folded her arms. ${_o}I am not going.$_c'], cast), ['Kirielle']);
    });

    test('by the turns of an exchange between two people', () {
      expect(
        _who([
          '${_o}Are you coming?$_c asked Zorian.',
          '${_o}No,$_c said Kirielle.',
          '${_o}Why not?$_c',
          '${_o}Because it is cold.$_c',
          '${_o}It is summer.$_c',
        ], cast),
        ['Zorian', 'Kirielle', 'Zorian', 'Kirielle', 'Zorian'],
      );
    });
  });

  group('left to the dialogue voice', () {
    final cast = [
      Character('Zorian', gender: Gender.male),
      Character('Kirielle', gender: Gender.female),
      Character('Benisek', gender: Gender.male),
    ];

    test('"he" with two men in the scene', () {
      expect(
        _who([
          'Zorian and Benisek stood at the gate.',
          '${_o}It is late,$_c he said.',
        ], cast),
        ['', '?'],
      );
    });

    test('someone named only by what they are', () {
      expect(_who(['${_o}Who goes there?$_c called a guard.'], cast), ['?']);
    });

    test('an exchange of three, where the turns cannot tell who', () {
      expect(
        _who([
          '${_o}Ready?$_c asked Zorian.',
          '${_o}Yes,$_c said Kirielle.',
          '${_o}Almost,$_c said Benisek.',
          '${_o}Then go.$_c',
        ], cast),
        ['Zorian', 'Kirielle', 'Benisek', '?'],
      );
    });

    test('a line spoken to the one the turns would give it to', () {
      expect(
        _who([
          '${_o}Are you coming?$_c asked Zorian.',
          '${_o}No,$_c said Kirielle.',
          '${_o}Zorian, why not?$_c',
        ], cast),
        ['Zorian', 'Kirielle', '?'],
      );
    });

    test('a quotation that names a thing, and a thought between two lines', () {
      expect(_who(['${_o}Bread and Circuses$_c was the name of the inn.'], cast), ['?']);
      expect(
        _who([
          '${_o}Are you coming?$_c asked Zorian.',
          '${_o}Strange,$_c thought Kirielle.',
          '${_o}Well?$_c',
        ], cast),
        ['Zorian', 'Kirielle', '?'],
        reason: 'a thought is not a turn of the conversation',
      );
    });
  });

  test("each sentence's speaker: one person's words, or nobody's", () {
    // One paragraph, three sentences: two in one quotation, then narration.
    final p = '${_o}We go now. Tonight.$_c said Zorian. The rain went on.';
    final s2 = p.indexOf('Tonight');
    final s3 = p.indexOf('The rain');
    final text = BookText(
      paragraphs: [p],
      chapterOf: Int32List(1),
      firstUnit: Int32List.fromList([0]),
      unitCount: Int32List.fromList([3]),
      unitStart: Int32List.fromList([0, s2, s3]),
      unitLength: Int32List.fromList([s2 - 1, s3 - 1 - s2, p.length - s3]),
    );
    final who = speakersOf(text, CastIndex([Character('Zorian', gender: Gender.male)]));
    expect(who, [0, 0, -1]);
  });
}
