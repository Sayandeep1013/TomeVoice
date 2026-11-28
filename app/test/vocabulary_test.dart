// Vocabulary: words kept with where they were met, and reviewed further off
// the better they are known.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/vocabulary.dart';

void main() {
  late Directory tmp;
  final vocab = VocabularyStore.instance;
  const at = ReadingCursor(sectionIndex: 2, blockIndex: 3);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tomevoice_vocab');
    await vocab.attach(tmp);
  });

  tearDown(() {
    vocab.reset();
    tmp.deleteSync(recursive: true);
  });

  Future<VocabWord?> add(String word, String sentence, {String book = 'b1', DateTime? now}) => vocab.add(
        rawWord: word,
        sentence: sentence,
        bookId: book,
        bookTitle: 'The Book',
        at: at,
        now: now,
      );

  test('a word comes without the punctuation round it, its sentence capital dropped', () async {
    expect((await add('“Ephemeral,”', '“Ephemeral,” she said, “is the word.”'))!.word, 'ephemeral');
    expect((await add('Darcy’s', 'She thought of Mr Darcy’s letter.'))!.word, 'Darcy');
    expect(await add('—', 'A dash — alone.'), isNull);
  });

  test('the same word met again gains the place, and is kept once', () async {
    await add('ephemeral', 'An ephemeral joy.');
    await add('Ephemeral', 'Ephemeral things pass.', book: 'b2');
    await add('ephemeral', 'An ephemeral joy.');
    expect(vocab.all, hasLength(1));
    expect(vocab.all.single.seen.map((s) => s.bookId), ['b1', 'b2']);
  });

  test('reviews: known goes further off each time, until learnt; not known comes back tomorrow', () async {
    final t0 = DateTime.utc(2026, 11, 28, 10);
    await add('laconic', 'A laconic reply.', now: t0);
    expect(vocab.dueCount(t0), 1, reason: 'new words are due at once');

    var t = t0;
    for (final days in VocabWord.spacing) {
      await vocab.review('laconic', knew: true, now: t);
      expect(vocab.dueCount(t), 0);
      t = t.add(Duration(days: days));
      expect(vocab.dueCount(t), 1, reason: 'due again after $days days');
    }
    await vocab.review('laconic', knew: true, now: t);
    expect(vocab.byWord('laconic')!.learnt, isTrue);
    expect(vocab.dueCount(t.add(const Duration(days: 400))), 0, reason: 'learnt words leave the reviews');

    await vocab.setLearnt('laconic', false);
    await vocab.review('laconic', knew: false, now: t);
    expect(vocab.dueCount(t), 0);
    expect(vocab.dueCount(t.add(const Duration(days: 1))), 1);
  });

  test('looking a learnt word up again brings it back to learn', () async {
    await add('laconic', 'A laconic reply.');
    await vocab.setLearnt('laconic', true);
    await add('laconic', 'He was laconic.');
    expect(vocab.byWord('laconic')!.learnt, isFalse);
    expect(vocab.dueCount(), 1);
  });

  test('kept in vocabulary.json and read back, meaning and all', () async {
    await add('laconic', 'A laconic reply.');
    await vocab.setMeaning('laconic', 'Using few words');
    await vocab.attach(tmp);
    final w = vocab.byWord('Laconic')!;
    expect(w.meaning, 'Using few words');
    expect(w.seen.single.at.sectionIndex, 2);
    expect(File('${tmp.path}/vocabulary.json').existsSync(), isTrue);
  });
}
