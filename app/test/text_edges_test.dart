// Text that is not English or has no spaces: the word under a finger in
// Bengali and Hindi keeps its vowel signs, and a long quote with no spaces
// (Chinese, Japanese) still makes a share card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/reader_screen.dart' show wordAt;
import 'package:tomevoice_spike/share_card.dart';

void main() {
  test('the word under a finger keeps its vowel signs', () {
    const bengali = 'আমি বাংলা ভাষায় পড়ি';
    final at = bengali.indexOf('বাংলা');
    expect(wordAt(bengali, at), 'বাংলা');
    expect(wordAt(bengali, at + 2), 'বাংলা', reason: 'a finger on a vowel sign');
    const hindi = 'मैं हिन्दी पढ़ता हूँ';
    expect(wordAt(hindi, hindi.indexOf('हिन्दी')), 'हिन्दी');
    expect(wordAt(hindi, hindi.indexOf('हूँ')), 'हूँ');
    // English as before.
    expect(wordAt("He didn't stop.", 6), "didn't");
    expect(wordAt('Stop, now.', 4), 'Stop');
  });

  Future<String> cardText(WidgetTester tester, String text) async {
    final mark = Mark(
      id: 'm',
      bookId: 'b',
      bookTitle: 'Book',
      kind: MarkKind.quote,
      at: const ReadingCursor(),
      text: text,
      created: DateTime(2026, 10, 30),
    );
    // The size it is drawn at to share.
    await tester.pumpWidget(MaterialApp(
      home: Center(child: SizedBox(width: 360, child: QuoteCard(mark: mark))),
    ));
    return tester.widget<Text>(find.byWidgetPredicate((w) => w is Text && (w.data?.length ?? 0) > 100)).data!;
  }

  testWidgets('a long quote with no spaces makes a card that holds it', (tester) async {
    // The test font draws every character a square, as wide as a Chinese
    // one really is: what fits here fits on the phone.
    final shown = await cardText(tester, List.filled(500, '字').join());
    expect(tester.takeException(), isNull, reason: 'no throw and no overflow');
    expect(shown, '${List.filled(210, '字').join()}…', reason: 'a wide character takes two letters of room');
  });

  testWidgets('an English quote of 400 letters is not cut', (tester) async {
    final text = List.filled(40, 'line of a').join(' ');
    expect(text.length, lessThan(420));
    expect(await cardText(tester, text), text);
    // Latin letters are squares in the test font, so it overflows here only.
    tester.takeException();
  });
}
