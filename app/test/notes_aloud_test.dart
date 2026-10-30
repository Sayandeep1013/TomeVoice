// "Read notes aloud": off by default, kept with the settings, honoured by
// the layouts the library builds, and a book reading on goes on with its
// notes at the sentence it was at.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/relayout.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

const _book = '<html><head><title>Notes Book</title></head><body>'
    '<h1>Chapter One</h1>'
    '<p>It was a house.<a id="r1" href="#n1">[1]</a> The next day came, and the rain went on falling on the old roof for hours.</p>'
    '<p>Then the rain stopped and everyone went outside to look at the washed sky for a long while.</p>'
    '<ol><li id="n1"><a href="#r1">[1]</a> A note about the house and who built it.</li></ol>'
    '<p>Evening came at last, and with it a quiet that nobody in the village could remember.</p>'
    '</body></html>';

const _note = '[1] A note about the house and who built it.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    tmp = Directory.systemTemp.createTempSync('tomevoice_notes');
    var n = 0;
    // Speech with sound: every sentence a short silent WAV, the playback
    // head never moving, so a book stays in mid-reading.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'synthesise' => () {
            final f = File('${tmp.path}/s${n++}.wav')..writeAsBytesSync(wavBytes(Float32List(2400), 24000));
            return <String, Object?>{'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
          }(),
        'outputDir' => tmp.path,
        'playerPosition' => 0,
        'playerEnqueue' => 0,
        'listEngines' => const [],
        'listVoices' => const [],
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

  Future<(LibraryStore, LibraryEntry)> imported() async {
    final store = LibraryStore(tmp);
    final f = File('${tmp.path}/incoming/notes.html')
      ..createSync(recursive: true)
      ..writeAsStringSync(_book);
    final e = await store.importFile(PickedFile(path: f.path, name: 'notes.html'));
    return (store, e);
  }

  test('off unless turned on, and kept with the settings', () {
    expect(ListeningPrefs().notesAloud, isFalse);
    expect(ListeningPrefs.fromJson(const {}).notesAloud, isFalse, reason: 'prefs saved before it');
    expect(ListeningPrefs().toJson().containsKey('notesAloud'), isFalse);
    final on = ListeningPrefs()..notesAloud = true;
    expect(ListeningPrefs.fromJson(on.toJson()).notesAloud, isTrue);
  });

  test('the library lays books out with their notes read only when asked', () async {
    final (store, e) = await imported();
    ListeningPrefs.memory.notesAloud = false;
    final quiet = await store.loadLayout(e.id);
    expect(quiet.units.map((u) => u.text), isNot(contains(_note)));
    expect(quiet.items.where((i) => i.displayOnly).map((i) => i.block!.text), contains(_note));

    ListeningPrefs.memory.notesAloud = true;
    final read = await store.loadLayout(e.id);
    final texts = read.units.map((u) => u.text).toList();
    expect(texts, contains(_note));
    // Where it stands: after the paragraph before it.
    expect(texts.indexOf(_note), texts.indexWhere((t) => t.startsWith('Then the rain stopped')) + 1);
    // Its marker is still silent.
    final marked = read.units.firstWhere((u) => u.text.startsWith('It was a house.'));
    expect(spokenText(marked.text, marked.silent).text, 'It was a house.');
  });

  testWidgets('a book reading on goes on in the new layout, at the same sentence', (tester) async {
    late LibraryStore store;
    late LibraryEntry entry;
    await tester.runAsync(() async {
      (store, entry) = await imported();
      ListeningPrefs.memory.notesAloud = false;
      final before = await store.loadLayout(entry.id);
      final at = before.units.indexWhere((u) => u.text.startsWith('Evening came'));
      await store.saveCursor(entry.id, cursorOf(before.units[at]), 0.8);
      await BackgroundReading.startFrom(store, entry);
    });
    final bg = BackgroundReading.current.value!;
    expect(bg.playing, isTrue);
    expect(bg.layout.units.map((u) => u.text), isNot(contains(_note)));
    final sentence = bg.layout.units[bg.unit].text;
    expect(sentence, startsWith('Evening came'));

    ListeningPrefs.memory.notesAloud = true;
    await tester.runAsync(relayReadingBook);
    final next = BackgroundReading.current.value!;
    expect(identical(next, bg), isFalse);
    expect(next.layout.units.map((u) => u.text), contains(_note));
    expect(next.layout.units[next.unit].text, sentence, reason: 'the place is kept');
    expect(next.playing, isTrue);
    await tester.runAsync(next.stop);
  });

  test('nothing reading: nothing to do', () async {
    expect(BackgroundReading.current.value, isNull);
    await relayReadingBook();
    expect(BackgroundReading.current.value, isNull);
  });
}
