// Pronunciation lists passed from phone to phone: a book's or a series'
// words as a small file, read back as they went out, and taken in beside
// this phone's own, which win, with what was added said; and the Reading
// rules screen that shares them, takes them in and switches the presets.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/pronunciation_list.dart';
import 'package:tomevoice_spike/reading_rules.dart';
import 'package:tomevoice_spike/rules_screen.dart';

const _channel = MethodChannel('tomevoice/tts');

const _rules = [
  SayRule(from: 'Zorian', to: 'Zor-ee-an', book: 'mol1'),
  SayRule(from: 'Kael Ardent', to: 'Kale Ar-dent', book: 'mol1'),
  SayRule(from: 'Zach', to: 'Zack', book: 'mol2'),
  SayRule(from: 'Zorian', to: 'Zorry', book: 'mol2'),
  SayRule(from: 'Cyoria', to: 'Kee-or-ee-a'),
  SayRule(from: 'Sunny', to: 'Sonny', book: 'shadow'),
];

const _titles = {'mol1': 'Mother of Learning', 'mol2': 'Mother of Learning 2', 'shadow': 'Shadow Slave'};

Set<String> _words(PronunciationList l) => {for (final w in l.words) '${w.word}=${w.say}'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(ReadingRules.instance.reset);

  group('a list out and back', () {
    test('a book’s words, its name and the book go out and come back as they were', () {
      final out = PronunciationList.of(_rules, name: 'Mother of Learning', books: ['mol1'], titles: _titles);
      expect(_words(out), {'Zorian=Zor-ee-an', 'Kael Ardent=Kale Ar-dent'});
      final back = PronunciationList.decode(out.encode())!;
      expect(back.name, 'Mother of Learning');
      expect(back.books, [(id: 'mol1', title: 'Mother of Learning')]);
      expect(_words(back), _words(out));
      // As plain text too, for a forum post or a note.
      final text = PronunciationList.decode(out.encodeText())!;
      expect(text.name, 'Mother of Learning');
      expect(_words(text), _words(out));
    });

    test('a series: its books’ words in one list, the first book’s saying of a word kept', () {
      final out = PronunciationList.of(_rules, name: 'Mother of Learning', books: ['mol1', 'mol2', null], titles: _titles);
      expect(out.words, [
        (word: 'Zorian', say: 'Zor-ee-an'),
        (word: 'Kael Ardent', say: 'Kale Ar-dent'),
        (word: 'Zach', say: 'Zack'),
        (word: 'Cyoria', say: 'Kee-or-ee-a'),
      ]);
      expect(out.books.map((b) => b.id), ['mol1', 'mol2']);
      expect(PronunciationList.decode(out.encode())!.words.length, 4);
    });

    test('the file says what it is, and reads as a glossary', () {
      final out = PronunciationList.of(_rules, name: 'Mother of Learning', books: ['mol1'], titles: _titles);
      final json = jsonDecode(out.encode()) as Map;
      expect(json['kind'], PronunciationList.kind);
      expect(json['version'], 1);
      expect([for (final w in json['words'] as List) (w as Map)['word']], ['Kael Ardent', 'Zorian']);
      expect(PronunciationList.fileNameFor('Mother of Learning'), 'Mother of Learning pronunciations.json');
      expect(PronunciationList.fileNameFor('A/B: "C"?'), 'A B C pronunciations.json');
      expect(PronunciationList.fileNameFor(''), 'pronunciations.json');
    });

    test('through a file: written on one phone, read and taken in on another', () async {
      final dir = Directory.systemTemp.createTempSync('tomevoice_list');
      addTearDown(() => dir.deleteSync(recursive: true));
      final out = PronunciationList.of(_rules, name: 'Mother of Learning', books: ['mol1'], titles: _titles);
      final file = File('${dir.path}/${PronunciationList.fileNameFor(out.name)}')..writeAsStringSync(out.encode());

      // The other phone: an empty list of its own, the same book.
      final rules = ReadingRules.instance;
      await rules.attach(dir);
      final list = (await PronunciationList.read(file, name: 'Mother of Learning pronunciations.json'))!;
      final plan = planImport(rules.say, list.words, ['mol1']);
      await rules.addAll(plan.add);
      expect([for (final r in rules.sayFor('mol1')) '${r.from}=${r.to}'], unorderedEquals(_words(out)));
      expect(respell('Zorian met Kael Ardent.', rules.sayFor('mol1')).text, 'Zor-ee-an met Kale Ar-dent.');
      expect(respell('Zorian met Kael Ardent.', rules.sayFor('other')).text, 'Zorian met Kael Ardent.',
          reason: 'for that book alone');

      // Kept: the rules are there when the library is opened again.
      rules.reset();
      await rules.attach(dir);
      expect(rules.say.length, 2);
    });
  });

  group('lists from elsewhere', () {
    test('a rules.json, a map of words, and lines of text are read', () {
      final fromRules = PronunciationList.decode(jsonEncode({
        'say': [
          {'from': 'Kael', 'to': 'Kale', 'book': 'x'},
          {'from': 'Zorian', 'to': 'Zor-ee-an'},
        ],
        'skip': [],
      }))!;
      expect(_words(fromRules), {'Kael=Kale', 'Zorian=Zor-ee-an'});
      expect(_words(PronunciationList.decode('{"Hermione": "Her-my-oh-nee"}')!), {'Hermione=Her-my-oh-nee'});
      final text = PronunciationList.decode([
        '# TomeVoice pronunciations: Harry Potter',
        '',
        'Hermione = Her-my-oh-nee',
        'Voldemort → Vol-de-mor',
        'Sirius -> Seer-ee-us',
        'Remus\tRee-mus',
        '"Quidditch" = "Kwid-itch"',
        '// a comment',
        'a line that says nothing of how',
      ].join('\n'), fileName: 'hp.txt')!;
      expect(text.name, 'Harry Potter');
      expect(_words(text), {
        'Hermione=Her-my-oh-nee',
        'Voldemort=Vol-de-mor',
        'Sirius=Seer-ee-us',
        'Remus=Ree-mus',
        'Quidditch=Kwid-itch',
      });
    });

    test('a name from the file when the list has none', () {
      expect(PronunciationList.decode('Zorian = Zor-ee-an', fileName: '/x/incoming/1/Mother_of_Learning pronunciations.txt')!.name,
          'Mother of Learning');
      expect(PronunciationList.decode('Zorian = Zor-ee-an')!.name, 'Pronunciations');
    });

    test('what cannot be a rule is left out: no letters, nothing said, the same word twice, too long', () {
      final list = PronunciationList.decode(jsonEncode({
        'kind': PronunciationList.kind,
        'name': 'Odd',
        'words': [
          {'word': '...', 'say': 'dots'},
          {'word': 'Kael', 'say': ''},
          {'word': 'Kael', 'say': 'Kael'},
          {'word': 'Zorian', 'say': 'Zor-ee-an'},
          {'word': 'zorian', 'say': 'Zorry'},
          {'word': 'x' * 81, 'say': 'long'},
          {'word': '  Kael   Ardent ', 'say': 'Kale  Ar-dent'},
          ['Cyoria', 'Kee-or-ee-a'],
          {'word': 3, 'say': 'three'},
        ],
      }))!;
      expect(list.words, [
        (word: 'Zorian', say: 'Zor-ee-an'),
        (word: 'Kael Ardent', say: 'Kale Ar-dent'),
        (word: 'Cyoria', say: 'Kee-or-ee-a'),
      ]);
    });

    test('a file with no pronunciations in it is none', () async {
      expect(PronunciationList.decode(''), isNull);
      expect(PronunciationList.decode('Just a story about a girl and her dog.'), isNull);
      expect(PronunciationList.decode('{"words": []}'), isNull);
      expect(PronunciationList.decode('[1, 2, 3]'), isNull);
      final dir = Directory.systemTemp.createTempSync('tomevoice_list_none');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await PronunciationList.read(File('${dir.path}/gone.json')), isNull);
    });
  });

  group('taken in beside this phone’s own', () {
    const words = [
      (word: 'Zorian', say: 'Zor-ee-an'),
      (word: 'Kael', say: 'Kale'),
      (word: 'Cyoria', say: 'Kee-or-ee-a'),
    ];

    test('new words are added, the same are left, and where this phone says a word its own way, it wins', () {
      const have = [SayRule(from: 'zorian', to: 'Zorry'), SayRule(from: 'Cyoria', to: 'kee-or-ee-a')];
      final plan = planImport(have, words, [null]);
      expect(plan.added, [(word: 'Kael', say: 'Kale')]);
      expect(plan.same, [(word: 'Cyoria', say: 'Kee-or-ee-a')]);
      expect(plan.kept, [(theirs: (word: 'Zorian', say: 'Zor-ee-an'), mine: 'Zorry')]);
      expect(plan.add.single.book, isNull);
    });

    test('for one book: what this phone says in every book is what it says in that one too', () {
      const have = [SayRule(from: 'Zorian', to: 'Zorry')];
      final plan = planImport(have, words, ['mol1']);
      expect(plan.kept.single.mine, 'Zorry', reason: 'its every-book saying would lose to a rule for the book');
      expect([for (final r in plan.add) '${r.from}:${r.book}'], ['Kael:mol1', 'Cyoria:mol1']);
    });

    test('for every book: a book’s own saying stays, and the word is added for the others', () {
      const have = [SayRule(from: 'Zorian', to: 'Zorry', book: 'mol2')];
      final plan = planImport(have, words, [null]);
      expect(plan.kept, isEmpty);
      expect(plan.added.map((w) => w.word), ['Zorian', 'Kael', 'Cyoria']);
    });

    test('for a series: each of its books, a book that says a word its own way keeping it', () {
      const have = [SayRule(from: 'Zorian', to: 'Zorry', book: 'mol2')];
      final plan = planImport(have, words, ['mol1', 'mol2']);
      expect([for (final r in plan.add) '${r.from}:${r.book}'],
          ['Zorian:mol1', 'Kael:mol1', 'Kael:mol2', 'Cyoria:mol1', 'Cyoria:mol2']);
      expect(plan.kept.single.theirs.word, 'Zorian');
      expect(plan.added.map((w) => w.word), ['Zorian', 'Kael', 'Cyoria']);
    });

    test('taken in twice, nothing is added the second time', () async {
      final rules = ReadingRules.instance;
      await rules.addAll(planImport(rules.say, words, [null]).add);
      expect(rules.say.length, 3);
      final again = planImport(rules.say, words, [null]);
      expect(again.changesNothing, isTrue);
      expect(again.same.length, 3);
      await rules.addAll(again.add);
      expect(rules.say.length, 3);
    });

    test('a book’s own saying is used over every book’s, however many rules there are', () {
      final many = [
        for (var i = 0; i < 300; i++) SayRule(from: 'Name$i', to: 'Said$i'),
        const SayRule(from: 'Sunny', to: 'Sun-nee'),
      ];
      final rules = ReadingRules.instance..say = [...many, const SayRule(from: 'Sunny', to: 'Sonny', book: 'shadow')];
      expect(respell('Sunny ran.', rules.sayFor('shadow')).text, 'Sonny ran.');
      expect(respell('Sunny ran.', rules.sayFor('other')).text, 'Sun-nee ran.');
    });
  });

  test('a series’ name from its volumes’ titles', () {
    expect(commonTitle(['Mother of Learning: Arc 1', 'Mother of Learning: Arc 2']), 'Mother of Learning');
    expect(commonTitle(['The Wandering Inn Volume 1', 'The Wandering Inn Volume 2']), 'The Wandering Inn');
    expect(commonTitle(['Mother of Learning', 'Mother of Learning 2']), 'Mother of Learning');
    expect(commonTitle(['Dune', 'Emma']), isNull);
  });

  group('on the Reading rules screen', () {
    late Directory tmp;
    late List<MethodCall> calls;
    late List<Object?> picked;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tomevoice_rules_screen');
      calls = [];
      picked = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'shareDir' => (Directory('${tmp.path}/share')..createSync(recursive: true)).path,
          'pickDocuments' => picked,
          'outputDir' => tmp.path,
          _ => null,
        };
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    Future<void> pump(WidgetTester tester, Widget screen) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: screen));
      await tester.pumpAndSettle();
    }

    /// Frames, with the files read and written meanwhile, until [done] (a
    /// few seconds at most: slower while the other tests run beside it).
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    /// The words drawn struck through: what an example's preset leaves out.
    Set<String> struck(WidgetTester tester) {
      final out = <String>{};
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        t.textSpan?.visitChildren((s) {
          if (s is TextSpan && s.style?.decoration == TextDecoration.lineThrough) out.add(s.text ?? '');
          return true;
        });
      }
      return out;
    }

    testWidgets('each preset shows what it leaves out, and is off until switched on for every book', (tester) async {
      await pump(tester, const RulesScreen(bookTitles: _titles));
      final gone = <String>{};
      for (final p in SkipPreset.values) {
        await tester.scrollUntilVisible(find.text(p.title), 200);
        expect(find.text(p.title), findsOneWidget);
        gone.addAll(struck(tester));
      }
      expect(gone, contains('A/N: Sorry this one is late, exams ate my week!'));
      expect(gone, contains(' [TL: shixiong, an older disciple]'));
      expect(gone, contains('o0o0o0o'));
      expect(gone, contains('https://www.artstation.com/mira/gallery?id=42'));

      expect(ReadingRules.instance.presetOn(SkipPreset.symbols), isFalse);
      await tester.scrollUntilVisible(find.text('Symbols and separators'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Symbols and separators'));
      await tester.pumpAndSettle();
      expect(ReadingRules.instance.presetOn(SkipPreset.symbols), isTrue);
      expect(ReadingRules.instance.presetsFor('mol1'), contains(SkipPreset.symbols));
    });

    testWidgets('a book’s rules: its own words, and presets of its own', (tester) async {
      ReadingRules.instance.say = [..._rules];
      await pump(tester, const RulesScreen(bookTitles: {}, bookId: 'mol1', bookTitle: 'Mother of Learning'));
      expect(find.text('MOTHER OF LEARNING'), findsOneWidget);
      expect(find.text('Zorian  →  Zor-ee-an'), findsOneWidget);
      expect(find.text('Kael Ardent  →  Kale Ar-dent'), findsOneWidget);
      expect(find.text('Zach  →  Zack'), findsNothing, reason: 'another book’s');
      expect(find.textContaining('1 word is also said your way in every book'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('For this book only'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('For this book only'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(SkipPreset.authorNotes.title), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text(SkipPreset.authorNotes.title));
      await tester.pumpAndSettle();
      expect(ReadingRules.instance.presetOn(SkipPreset.authorNotes, book: 'mol1'), isTrue);
      expect(ReadingRules.instance.presetOn(SkipPreset.authorNotes), isFalse, reason: 'every other book’s stays');
    });

    testWidgets('share: the lists picked go out as one file, through the share sheet', (tester) async {
      ReadingRules.instance.say = [..._rules];
      await pump(tester, const RulesScreen(bookTitles: _titles));
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(find.text('Share pronunciations'), findsOneWidget);
      await tester.tap(find.text('Mother of Learning · 2'));
      await tester.pump();
      await tester.tap(find.text('Mother of Learning 2 · 2'));
      await tester.pump();
      await tester.tap(find.text('Every book · 1'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Mother of Learning'), findsOneWidget, reason: 'named for the series');
      await tester.tap(find.text('Share 3 words'));
      await settle(tester, () => calls.any((c) => c.method == 'shareFile'));

      final share = calls.where((c) => c.method == 'shareFile').single;
      final args = Map<String, Object?>.from(share.arguments as Map);
      expect(args['mime'], 'application/json');
      final path = args['path']! as String;
      expect(path, endsWith('Mother of Learning pronunciations.json'));
      final sent = PronunciationList.decode(File(path).readAsStringSync())!;
      expect(sent.name, 'Mother of Learning');
      expect(_words(sent), {'Zorian=Zor-ee-an', 'Kael Ardent=Kale Ar-dent', 'Zach=Zack'});
      expect(sent.books.map((b) => b.title), ['Mother of Learning', 'Mother of Learning 2']);
    });

    testWidgets('add from a file: for the book it was made from, this phone’s own kept, then what was added',
        (tester) async {
      // This phone says Zorian its own way in every book.
      ReadingRules.instance.say = [const SayRule(from: 'Zorian', to: 'Zorry')];
      final copy = File('${tmp.path}/incoming/slot1/Mother of Learning pronunciations.json')..createSync(recursive: true);
      copy.writeAsStringSync(const PronunciationList(
        name: 'Mother of Learning',
        books: [(id: 'mol1', title: 'Mother of Learning')],
        words: [
          (word: 'Zorian', say: 'Zor-ee-an'),
          (word: 'Kael', say: 'Kale'),
          (word: 'Cyoria', say: 'Kee-or-ee-a'),
        ],
      ).encode());
      picked = [
        {'path': copy.path, 'name': 'Mother of Learning pronunciations.json'},
      ];
      await pump(tester, const RulesScreen(bookTitles: _titles));
      await tester.tap(find.text('Add from a file'));
      await settle(tester, () => find.text('Add pronunciations').evaluate().isNotEmpty);

      expect(find.text('Add pronunciations'), findsOneWidget);
      // The book it was made from is on this phone: it goes there.
      expect(find.widgetWithText(InputChip, 'Mother of Learning'), findsOneWidget);
      expect(find.textContaining('2 words to add'), findsOneWidget);
      expect(find.textContaining('1 kept as you say it'), findsOneWidget);
      await tester.tap(find.text('Add 2 words'));
      await tester.pumpAndSettle();

      Finder said(String text) => find.descendant(of: find.byType(AlertDialog), matching: find.text(text));
      expect(said('Added 2 pronunciations'), findsOneWidget);
      expect(said('For “Mother of Learning”:'), findsOneWidget);
      expect(said('Kael  →  Kale'), findsOneWidget);
      expect(said('Cyoria  →  Kee-or-ee-a'), findsOneWidget);
      expect(said('Zorian  →  Zorry  (the list: Zor-ee-an)'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final say = ReadingRules.instance.say;
      // The file has its words in alphabetical order, and they come in so.
      expect([for (final r in say) '${r.from}=${r.to}@${r.book}'], ['Zorian=Zorry@null', 'Cyoria=Kee-or-ee-a@mol1', 'Kael=Kale@mol1']);
      expect(copy.parent.existsSync(), isFalse, reason: 'the picker’s copy is not left behind');
    });

    testWidgets('a book’s list, from where its title is not known, waits for a name before it goes', (tester) async {
      ReadingRules.instance.say = [..._rules];
      await pump(tester, const RulesScreen(bookTitles: {}, bookId: 'mol1'));
      expect(find.text('THIS BOOK'), findsOneWidget);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      FilledButton share() => tester.widget<FilledButton>(find.ancestor(
            of: find.text('Share 2 words'),
            matching: find.byWidgetPredicate((w) => w is FilledButton),
          ));
      expect(share().onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Mother of Learning');
      await tester.pump();
      expect(share().onPressed, isNotNull);
      await tester.tap(find.text('Share 2 words'));
      await settle(tester, () => calls.any((c) => c.method == 'shareFile'));
      final path = (calls.singleWhere((c) => c.method == 'shareFile').arguments as Map)['path']! as String;
      expect(PronunciationList.decode(File(path).readAsStringSync())!.name, 'Mother of Learning');
    });

    testWidgets('a file with no pronunciations says so and adds nothing', (tester) async {
      final copy = File('${tmp.path}/incoming/slot2/story.txt')..createSync(recursive: true);
      copy.writeAsStringSync('Just a story about a girl and her dog.');
      picked = [
        {'path': copy.path, 'name': 'story.txt'},
      ];
      await pump(tester, const RulesScreen(bookTitles: _titles));
      await tester.tap(find.text('Add from a file'));
      final said = find.textContaining('“story.txt” has no pronunciations in it');
      await settle(tester, () => said.evaluate().isNotEmpty);
      expect(said, findsOneWidget);
      expect(ReadingRules.instance.say, isEmpty);
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
