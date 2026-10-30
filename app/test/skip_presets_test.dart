// Skip presets: an author's and a translator's notes, rows of symbols, a
// chapter's title said twice, and links said as their site, each left out of
// what the voice says in chapters as sites and ebooks have them; nothing
// taken off the page; for every book or one book, as the rules are.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/reading_rules.dart';
import 'package:tomevoice_spike/rules_screen.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';

/// A Royal Road chapter: a note before it, one inside a sentence, and one
/// under its own heading after it.
const _royalRoad = '''
<p><strong>A/N:</strong> Sorry this one is a day late, exams ate my whole week. Thank you all for 2,000 followers!</p>
<p>The gate of the Iron Keep opened at dawn, and Rhea was the first through it.</p>
<p>She drew the blade (A/N: yes, the same one from chapter 3) and stepped into the yard.</p>
<p>“Nobody move,” she said.</p>
<p>Author’s Note:</p>
<p>That’s the end of Volume 2! I’m taking a week off to plan Volume 3.</p>
<p>If you enjoyed it, please leave a rating. It really helps the story grow.</p>
''';

/// A translated cultivation novel: notes in brackets, a translator's note,
/// and the translator's notes after the chapter.
const _wuxia = '''
<p>Chapter 87: The Sect Elder</p>
<p>“Senior Brother [TL: shixiong, an older disciple of the same master] has returned!” Lin Feng called out.</p>
<p>The elder’s qi (T/N: the inner energy cultivators refine) pressed down on the courtyard.</p>
<p>Translator’s Note: Next chapter is a long one, so it may come a day late.</p>
<p>Lin Feng bowed low.</p>
<p>TL Notes:</p>
<p>[1] Shixiong: senior brother, a disciple who joined before you.</p>
<p>[2] Dantian: where qi is stored, below the navel.</p>
''';

/// A fan-made ebook's chapter: its title said again under its heading, and
/// scenes parted by rows of symbols.
const _fanfic = '''
<h2>Chapter 12 - The Iron Keep</h2>
<p>Chapter 12: The Iron Keep</p>
<p>The gate opened at dawn, and the yard filled with the sound of boots on stone.</p>
<p>o0o0o0o0o</p>
<p>~~~ Later that night ~~~</p>
<p>Rhea sat by the fire. *** She did not sleep.</p>
<p>◆◆◆</p>
<p>-x-x-x-</p>
<p>In the morning they rode out.</p>
''';

/// Lines that look a little like what the presets leave out, and are the
/// story's.
const _prose = '''
<h2>Chapter 9: Not Again</h2>
<p>Not again.</p>
<p>Author’s notes were found in the margins of every page she turned.</p>
<p>Ed: Are you coming or not?</p>
<p>She wrote A/N in the margin and moved on.</p>
<p>Oooo, the ghost moaned from the attic.</p>
<p>Oooo</p>
<p>He was there—gone—back again, and the score stood at 10—0.</p>
<p>XXX</p>
''';

/// A web novel of [chapters] (title, the HTML its site serves), fetched as
/// TomeVoice fetches one.
Book _novel(List<(String, String)> chapters) => webNovelBook(
      id: 'keep',
      title: 'The Iron Keep',
      sections: [
        for (final (i, (title, html)) in chapters.indexed) webChapterSection(index: i, title: title, html: html),
      ],
    );

/// An ebook of one chapter, [title], from [html].
Book _ebook(String title, String html) => assembleBook(
      id: 'ebook',
      metadata: const BookMetadata(title: 'The Iron Keep'),
      sections: [(title: title, blocks: blocksFromHtml(html))],
      source: SourceKind.epub,
    );

/// What the voice says of [book] with [on], a sentence at a time: those it
/// passes over left out, spaces made one.
List<String> _heard(Book book, Set<SkipPreset> on) {
  final layout = ReadingLayout.build(book, displayOnly: true);
  return [
    for (final u in layout.units)
      if (_said(layout, u, on).text case final t when PlaybackScheduler.sayable(t)) t.replaceAll(RegExp(r'\s+'), ' ').trim(),
  ];
}

Respelled _said(ReadingLayout layout, Speakable u, Set<SkipPreset> on) =>
    respellUnit(u, const [], presets: on, quiet: quietStretches(layout.book, u, on, skipped: layout.skipped));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(ReadingRules.instance.reset);

  group('authors’ notes', () {
    final book = _novel([('Chapter 41: The Gate', _royalRoad)]);

    test('read as ever until switched on', () {
      expect(_heard(book, defaultPresets), [
        'A/N: Sorry this one is a day late, exams ate my whole week.',
        'Thank you all for 2,000 followers!',
        'The gate of the Iron Keep opened at dawn, and Rhea was the first through it.',
        'She drew the blade (A/N: yes, the same one from chapter 3) and stepped into the yard.',
        '“Nobody move,” she said.',
        'Author’s Note:',
        'That’s the end of Volume 2!',
        'I’m taking a week off to plan Volume 3.',
        'If you enjoyed it, please leave a rating.',
        'It really helps the story grow.',
      ]);
    });

    test('the note before the chapter, the one in a sentence, and the one under its heading are passed over', () {
      expect(_heard(book, {SkipPreset.authorNotes}), [
        'The gate of the Iron Keep opened at dawn, and Rhea was the first through it.',
        'She drew the blade and stepped into the yard.',
        '“Nobody move,” she said.',
      ]);
    });

    test('a heading of a note with the story going on after it leaves the story alone', () {
      final story = [for (var i = 1; i <= 14; i++) '<p>Rhea walked on through the hall, and the torches burned low, step $i.</p>'];
      final html = '<p>Author’s Note:</p>${story.join()}';
      final heard = _heard(_novel([('Chapter 2: The Hall', html)]), {SkipPreset.authorNotes});
      expect(heard, hasLength(14), reason: 'only the heading goes, not the chapter under it');
      expect(heard.first, startsWith('Rhea walked on'));
    });

    test('other ways authors write them', () {
      List<String> said(String p) => _heard(
            _novel([('Chapter 3: Rain', '<p>$p</p><p>The rain kept falling on the roofs of the city all night long.</p>')]),
            {SkipPreset.authorNotes},
          );
      for (final note in [
        'A/N - short chapter today, sorry!',
        'A/N sorry for the wait everyone',
        '**Author’s Note:** this arc is nearly done.',
        '(A/N: I know, I know.)',
        '[Author’s note: edited on 3 May.]',
        'AN: Thanks for 500 favourites!',
        'Note from the author: the next part is darker.',
        'Author’s Thoughts',
      ]) {
        expect(said(note), ['The rain kept falling on the roofs of the city all night long.'], reason: note);
      }
    });
  });

  group('translators’ notes', () {
    final book = _novel([('Chapter 87: The Sect Elder', _wuxia)]);

    test('in brackets, as a line, and the notes after the chapter are passed over', () {
      expect(_heard(book, {SkipPreset.translatorNotes}), [
        'Chapter 87: The Sect Elder',
        '“Senior Brother has returned!”',
        'Lin Feng called out.',
        'The elder’s qi pressed down on the courtyard.',
        'Lin Feng bowed low.',
      ]);
    });

    test('authors’ notes alone leave the translator’s', () {
      expect(_heard(book, {SkipPreset.authorNotes}), contains(startsWith('Translator’s Note:')));
    });

    test('other ways translators write them', () {
      // In an ebook of the translation: a site's own "TL:" lines are left
      // out as it is fetched, an ebook keeps them.
      List<String> said(String p) => _heard(
            _ebook('Chapter 5: Snow', '<p>$p</p><p>Snow covered the peaks of the northern range by morning.</p>'),
            {SkipPreset.translatorNotes},
          );
      for (final note in [
        'TL Note: the name means “white crane”.',
        'T/N: a pun in the raw.',
        'TL: edited by Moon.',
        '(TL: this chapter was long!)',
        '（TL：this chapter was long!）',
        'Editor’s Note: fixed typos.',
        'Translators’ Notes:',
      ]) {
        expect(said(note), ['Snow covered the peaks of the northern range by morning.'], reason: note);
      }
    });
  });

  group('symbols and separators', () {
    final book = _ebook('Chapter 12 - The Iron Keep', _fanfic);

    test('a row of o and x, runs of marks, and lines of symbols are passed over', () {
      expect(_heard(book, {SkipPreset.symbols}), [
        'Chapter 12 - The Iron Keep',
        'Chapter 12: The Iron Keep',
        'The gate opened at dawn, and the yard filled with the sound of boots on stone.',
        'Later that night',
        'Rhea sat by the fire.',
        'She did not sleep.',
        'In the morning they rode out.',
      ]);
    });

    test('marks at a word’s edge go; between letters or digits they stay', () {
      final book = _ebook(
        'Chapter 2: Snow',
        '<p>“Senpai~,” she called. *Sigh.* Hehe~~</p>'
            '<p>Her handle was xX_Slayer_Xx, and 5*3 is 15; C++ and snake_case stay.</p>',
      );
      expect(_heard(book, {SkipPreset.symbols}).join(' '),
          '“Senpai,” she called. Sigh. Hehe Her handle was xX_Slayer_Xx, and 5*3 is 15; C++ and snake_case stay.');
    });

    test('without it, the rows with letters in them are read', () {
      final heard = _heard(book, defaultPresets);
      expect(heard, containsAll(['o0o0o0o0o', '-x-x-x-', '~~~ Later that night ~~~', '*** She did not sleep.']));
      expect(heard, isNot(contains('◆◆◆')), reason: 'a line with nothing to say was always passed over');
    });
  });

  group('chapter titles said twice', () {
    test('the title the text repeats under its heading is said once', () {
      expect(_heard(_ebook('Chapter 12 - The Iron Keep', _fanfic), {SkipPreset.chapterTitles}).take(3), [
        'Chapter 12 - The Iron Keep',
        'The gate opened at dawn, and the yard filled with the sound of boots on stone.',
        'o0o0o0o0o',
      ]);
    });

    test('a fuller title after a short one keeps only what it adds', () {
      final book = _ebook('Chapter 3', '<h2>Chapter 3</h2><p>Chapter 3: Night Falls</p>'
          '<p>Night fell over the valley, and the wolves came down from the hills.</p>');
      expect(_heard(book, {SkipPreset.chapterTitles}),
          ['Chapter 3', 'Night Falls', 'Night fell over the valley, and the wolves came down from the hills.']);
    });

    test('a web novel whose page repeats its title once more', () {
      const html = '<p>Chapter 44 - A Show of Trust</p><p>Chapter 44</p><p>A Show of Trust</p>'
          '<p>Klein waited by the door until the bell rang twice in the hall below.</p>';
      expect(_heard(_novel([('44. A Show of Trust', html)]), {SkipPreset.chapterTitles}),
          ['Chapter 44 - A Show of Trust', 'Klein waited by the door until the bell rang twice in the hall below.']);
    });
  });

  test('lines that only look like those are the story’s, and are read with every preset on', () {
    final heard = _heard(_ebook('Chapter 9: Not Again', _prose), SkipPreset.values.toSet());
    expect(heard, [
      'Chapter 9: Not Again',
      'Not again.',
      'Author’s notes were found in the margins of every page she turned.',
      'Ed: Are you coming or not?',
      'She wrote A/N in the margin and moved on.',
      'Oooo, the ghost moaned from the attic.',
      'Oooo',
      'He was there—gone—back again, and the score stood at 10—0.',
      'XXX',
    ]);
  });

  group('links said as their site', () {
    final book = _novel([
      (
        'Chapter 1: The Road',
        '<p>Support the story at https://www.patreon.com/ironkeep?ref=ch12 if you can.</p>'
            '<p>The road ran north through the pines for three days and three nights.</p>',
      ),
    ]);

    test('on as it always was, and switched off a link is read as written', () {
      expect(SkipPreset.links.byDefault, isTrue);
      expect(_heard(book, defaultPresets).first, 'Support the story at patreon.com if you can.');
      expect(_heard(book, const {}).first, 'Support the story at https://www.patreon.com/ironkeep?ref=ch12 if you can.');
    });

    test('the marks in a link are the link’s, with symbols passed over too', () {
      final marked = _novel([
        (
          'Chapter 2: The Map',
          '<p>The map is at https://example.com/~ann/maps_v2 now.</p>'
              '<p>The road ran north through the pines for three days and three nights.</p>',
        ),
      ]);
      expect(_heard(marked, {SkipPreset.links, SkipPreset.symbols}).first, 'The map is at example.com now.');
      expect(_heard(marked, {SkipPreset.symbols}).first, 'The map is at https://example.com/~ann/maps_v2 now.');
    });
  });

  test('nothing is taken off the page: the notes are shown, and what is said maps back onto it', () {
    final book = _novel([('Chapter 41: The Gate', _royalRoad), ('Chapter 87: The Sect Elder', _wuxia)]);
    final all = SkipPreset.values.toSet();
    final layout = ReadingLayout.build(book, displayOnly: true);
    final page = [for (final i in layout.items) i.block?.text ?? i.title ?? ''].join('\n');
    for (final shown in [
      'A/N: Sorry this one is a day late',
      '(A/N: yes, the same one from chapter 3)',
      'Author’s Note:',
      '[TL: shixiong, an older disciple of the same master]',
      'Translator’s Note: Next chapter',
      '[2] Dantian: where qi is stored',
    ]) {
      expect(page, contains(shown));
    }
    // Every sentence is still on the page to be highlighted, whatever is said.
    for (final u in layout.units) {
      final block = layout.items[layout.unitItem[layout.units.indexOf(u)]].block!;
      expect(block.text, contains(u.text));
    }
    // What the voice says of a sentence with a note in it maps back to its words.
    final blade = layout.units.firstWhere((u) => u.text.startsWith('She drew the blade'));
    final said = _said(layout, blade, all);
    expect(said.text, 'She drew the blade and stepped into the yard.');
    final and = said.text.indexOf('and stepped');
    expect(said.toOriginal(and), blade.text.indexOf('and stepped'));
    expect(said.toOriginal(said.text.length, end: true), blade.text.length);
    // A sentence that is all note is said as nothing: the voice goes past it.
    final note = layout.units.firstWhere((u) => u.text.startsWith('A/N:'));
    expect(PlaybackScheduler.sayable(_said(layout, note, all).text), isFalse);
    expect(PlaybackScheduler.sayable(_said(layout, note, defaultPresets).text), isTrue);
  });

  test('a book parsed again since its place was found leaves nothing out rather than the wrong words', () {
    final book = _novel([('Chapter 41: The Gate', _royalRoad)]);
    final layout = ReadingLayout.build(book, displayOnly: true);
    final u = layout.units.first;
    final moved = Speakable(
      sectionIndex: u.sectionIndex,
      blockIndex: u.blockIndex,
      sentenceIndex: u.sentenceIndex,
      text: 'Something else entirely, said at this place now.',
      role: u.role,
      blockId: u.blockId,
    );
    expect(quietStretches(book, moved, {SkipPreset.authorNotes}), isEmpty);
  });

  group('each preset’s example', () {
    test('shows what that preset leaves out, worked out as a book is read', () {
      String heard(SkipPreset p) => [
            for (final para in presetExample(p))
              () {
                var at = 0;
                final out = StringBuffer();
                for (final c in para.changes) {
                  out
                    ..write(para.text.substring(at, c.start))
                    ..write(c.said);
                  at = c.end;
                }
                return (out..write(para.text.substring(at))).toString().replaceAll(RegExp(r'\s+'), ' ').trim();
              }(),
          ].where((t) => t.isNotEmpty).join(' | ');
      expect(heard(SkipPreset.authorNotes), 'The gate of the Iron Keep opened at dawn.');
      expect(heard(SkipPreset.translatorNotes), '“Senior Brother is back!”');
      expect(heard(SkipPreset.symbols), 'Part Two | “Senpai,” she called. Sigh. Then she ran.');
      expect(heard(SkipPreset.chapterTitles), 'Chapter 12: The Iron Keep | The gate opened at dawn.');
      expect(heard(SkipPreset.links), 'Art by Mira: artstation.com');
      for (final p in SkipPreset.values) {
        expect(presetExample(p).expand((x) => x.changes), isNotEmpty, reason: '${p.name} shows nothing left out');
      }
    });
  });

  group('for every book or one book', () {
    test('off until chosen, links on; a book can have its own, and go back to every book’s', () async {
      final rules = ReadingRules.instance;
      expect(rules.presetsFor('keep'), {SkipPreset.links});
      await rules.setPreset(SkipPreset.authorNotes, true);
      expect(rules.presetsFor('keep'), {SkipPreset.authorNotes, SkipPreset.links});
      expect(rules.presetsFor(null), {SkipPreset.authorNotes, SkipPreset.links});

      // Its own: from every book's, then changed for it alone.
      await rules.setOwnPresets('keep', true);
      await rules.setPreset(SkipPreset.symbols, true, book: 'keep');
      await rules.setPreset(SkipPreset.links, false, book: 'keep');
      expect(rules.presetsFor('keep'), {SkipPreset.authorNotes, SkipPreset.symbols});
      expect(rules.presetsFor('other'), {SkipPreset.authorNotes, SkipPreset.links});

      // Back to every book's.
      await rules.setOwnPresets('keep', false);
      expect(rules.presetsFor('keep'), {SkipPreset.authorNotes, SkipPreset.links});
    });

    test('kept in rules.json beside the rules, and a backup’s rules added keep them', () async {
      final dir = Directory.systemTemp.createTempSync('tomevoice_presets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final rules = ReadingRules.instance;
      await rules.attach(dir);
      await rules.addSay(const SayRule(from: 'Zorian', to: 'Zor-ee-an'));
      await rules.setPreset(SkipPreset.translatorNotes, true);
      await rules.setOwnPresets('keep', true);
      await rules.setPreset(SkipPreset.links, false, book: 'keep');
      // Written in the background: read once it has landed.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      rules.reset();
      await rules.attach(dir);
      expect(rules.say.single.to, 'Zor-ee-an');
      expect(rules.presetsFor(null), {SkipPreset.translatorNotes, SkipPreset.links});
      expect(rules.presetsFor('keep'), {SkipPreset.translatorNotes});
      expect(ReadingRules.skipTextsSync(dir.path, null), isEmpty);

      // A rules.json from before presets: all as they come.
      File('${dir.path}/rules.json').writeAsStringSync('{"say":[{"from":"Kael","to":"Kale"}],"skip":[]}');
      rules.reset();
      await rules.attach(dir);
      expect(rules.say.single.from, 'Kael');
      expect(rules.presetsFor('keep'), defaultPresets);
    });

    testWidgets('the book read aloud passes over what its presets leave out; the page shows it all', (tester) async {
      final book = _novel([('Chapter 41: The Gate', _royalRoad)]);
      final layout = ReadingLayout.build(book, displayOnly: true);
      final dir = Directory.systemTemp.createTempSync('tomevoice_skip_read');
      addTearDown(() => dir.deleteSync(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), (call) async {
        return switch (call.method) {
          'launchArgs' => <String, Object?>{},
          'outputDir' => dir.path,
          'playerPosition' => 0,
          'playerEnqueue' => 0,
          'listEngines' || 'listVoices' => const [],
          _ => null,
        };
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), null));
      ListeningPrefs.reset();
      // For this book only: every other book reads its notes.
      final rules = ReadingRules.instance;
      await rules.setOwnPresets('keep', true);
      await rules.setPreset(SkipPreset.authorNotes, true, book: 'keep');

      final voice = _Voice(dir);
      await tester.runAsync(() async {
        final player = readingScheduler(
            layout: layout, prefs: () => ListeningPrefs.memory, language: 'en', bookId: 'keep', service: voice);
        await player.play(0);
        for (var i = 0; i < 400 && player.state.value != PlayState.idle; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        player.dispose();
      });
      expect(voice.asked, [
        'The gate of the Iron Keep opened at dawn, and Rhea was the first through it.',
        'She drew the blade and stepped into the yard.',
        '“Nobody move,” she said.',
      ]);

      // Another book, with every book's presets: its note is read.
      final other = _Voice(dir);
      await tester.runAsync(() async {
        final player = readingScheduler(
            layout: layout, prefs: () => ListeningPrefs.memory, language: 'en', bookId: 'other', service: other);
        await player.play(0);
        for (var i = 0; i < 400 && player.state.value != PlayState.idle; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        player.dispose();
      });
      expect(other.asked.first, startsWith('A/N: Sorry'));

      // The page: every note is there to be read with the eyes.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(layout: layout)));
      await tester.pumpAndSettle();
      expect(find.textContaining('A/N: Sorry this one is a day late', findRichText: true), findsOneWidget);
      expect(find.textContaining('(A/N: yes, the same one from chapter 3)', findRichText: true), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('from the reader, the listening sheet opens the book’s own rules', (tester) async {
      final layout = ReadingLayout.build(_novel([('Chapter 41: The Gate', _royalRoad)]), displayOnly: true);
      final dir = Directory.systemTemp.createTempSync('tomevoice_skip_sheet');
      addTearDown(() => dir.deleteSync(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), (call) async {
        return switch (call.method) {
          'launchArgs' => <String, Object?>{},
          'outputDir' => dir.path,
          'playerPosition' => 0,
          'playerEnqueue' => 0,
          'listEngines' || 'listVoices' => const [],
          _ => null,
        };
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), null));
      ListeningPrefs.reset();
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(layout: layout)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Voice'));
      await tester.pumpAndSettle();
      final card = find.text('Words said your way');
      await tester.scrollUntilVisible(card, 200,
          scrollable: find.descendant(of: find.byKey(const Key('reader-settings')), matching: find.byType(Scrollable)).first);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      // Named by its title, which the reader passes on.
      expect(find.text('THE IRON KEEP'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('For this book only'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('For this book only'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(SkipPreset.authorNotes.title), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text(SkipPreset.authorNotes.title));
      await tester.pumpAndSettle();
      final rules = ReadingRules.instance;
      expect(rules.presetsFor(layout.book.id), {SkipPreset.authorNotes, SkipPreset.links});
      expect(rules.presetsFor('another book'), defaultPresets);

      // Back on the sheet, its card says what the book's voice skips.
      Navigator.of(tester.element(find.byType(RulesScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.text('The voice skips authors’ notes'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}

/// A phone voice that says each sentence as a short tone, and a player that
/// has heard whatever it was given; what it was asked to say is kept.
class _Voice extends SpeechService {
  _Voice(this.dir);

  final Directory dir;
  final asked = <String>[];
  var _n = 0;
  var _frames = 0;

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async {
    asked.add(text);
    const rate = 24000;
    final samples = Float32List(rate ~/ 10);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = 0.3 * math.sin(2 * math.pi * 220 * i / rate);
    }
    final f = File('${dir.path}/v${_n++}.wav')..writeAsBytesSync(wavBytes(samples, rate));
    return {'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
  }

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
    final start = _frames;
    _frames += pcm.length ~/ 2;
    return start;
  }

  @override
  Future<int> position({bool raw = false}) async => _frames;

  @override
  Future<String> requestFocus() async => SpeechService.focusGranted;

  @override
  Future<void> stopPlayback() async {}

  @override
  Future<void> pausePlayback() async {}

  @override
  Future<void> resumePlayback() async {}

  @override
  Future<void> cancelSynthesis() async {}

  @override
  Future<void> setVolume(double volume) async {}
}
