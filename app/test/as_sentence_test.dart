// A summary may end without a full stop: the card and the AI's pack put one
// in before "First met in…", and never two.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/talk/answer_pack.dart';

void main() {
  test('a summary becomes a sentence before the next one', () {
    expect(asSentence('Remembers her mother is alive'), 'Remembers her mother is alive. ');
    expect(asSentence('Saved the city.'), 'Saved the city. ');
    expect(asSentence('Who is he?'), 'Who is he? ');
    expect(asSentence('Said "never"'), 'Said "never". ');
    expect(asSentence('Said "never."'), 'Said "never." ');
    expect(asSentence('  '), '');
    expect(asSentence(null), '');
  });
}
