// Natural voices in many languages: the catalog the app reads, voices by
// language with their licences, the bigger models (Kokoro, Kitten) and the
// memory and speed they must have, and what stays on the phone as voices
// come and go.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/listen_sheet.dart';
import 'package:tomevoice_spike/neural_screen.dart';
import 'package:tomevoice_spike/neural_voices.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/voices.dart';

NeuralCatalog readCatalog() => NeuralCatalog.parse(File('assets/voices/catalog.json').readAsStringSync());

/// A voice's folder as a download leaves it.
void install(Directory root, NeuralVoice v, {bool espeak = true}) {
  final folder = Directory('${root.path}/voices/${NeuralVoices.instance.folderName(v)}')..createSync(recursive: true);
  File('${folder.path}/${v.modelFile}').writeAsBytesSync(Uint8List(16));
  File('${folder.path}/tokens.txt').writeAsStringSync('a 1\n');
  if (v.pack != null) File('${folder.path}/voices.bin').writeAsBytesSync(Uint8List(16));
  if (espeak) {
    Directory('${folder.path}/espeak-ng-data').createSync();
    File('${folder.path}/espeak-ng-data/phontab').writeAsStringSync('x');
  }
}

void main() {
  final catalog = readCatalog();
  NeuralVoice voice(String id) => catalog.byId(id)!;

  group('the catalog', () {
    test('every voice says its language, quality, size, sample rate, sample and licence', () {
      expect(catalog.voices.length, greaterThan(150));
      expect({for (final v in catalog.voices) v.id}.length, catalog.voices.length, reason: 'ids are unique');
      for (final v in catalog.voices) {
        expect(v.language, matches(RegExp(r'^[a-z]{2,3}$')), reason: v.id);
        expect(['x_low', 'low', 'medium', 'high'], contains(v.quality), reason: v.id);
        expect(v.bytes, greaterThan(10 * 1024 * 1024), reason: '${v.id} has its download size');
        expect([16000, 22050, 24000, 44100], contains(v.sampleRate), reason: v.id);
        // Nobody has recorded a sample of one voice: none is made up for it.
        if (v.id != 'fa_en-rezahedayatfar-ibrahimwalk-medium') {
          expect(v.sampleUrl, startsWith('https://huggingface.co/'), reason: v.id);
        }
        expect(v.licence.name, isNotEmpty, reason: v.id);
        expect(v.licence.note, isNotEmpty, reason: '${v.id} says what its licence allows');
        // Full precision only: the fp16 models crash ONNX Runtime on the phone.
        expect(v.url, isNot(contains('fp16')), reason: v.id);
        expect(v.url, isNot(contains('int8')), reason: v.id);
      }
      expect(voice('fa_en-rezahedayatfar-ibrahimwalk-medium').sampleUrl, isEmpty);
      // Not every voice speaks at 22,050 a second.
      expect(voice('fr_FR-tom-medium').sampleRate, 44100);
      expect(voice('ca_ES-upc_ona-x_low').sampleRate, 16000);
      expect(voice('kokoro-multi-lang-v1_0:hf_alpha').sampleRate, 24000);
    });

    test('the first natural voices keep their ids, files and names', () {
      for (final first in firstNeuralVoices) {
        final v = voice(first.id);
        expect(v.name, first.name);
        expect(v.locale, first.locale);
        expect(v.quality, first.quality);
        expect(v.url, 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-${first.id}.tar.bz2');
        expect(v.modelFile, '${first.id}.onnx');
        expect(v.sizeMb, first.hd ? 110 : 64);
        expect(v.sampleUrl, endsWith('/samples/speaker_0.mp3'));
      }
      // Its dataset asks for the voice to be called this where practical.
      expect(voice('en_GB-jenny_dioco-medium').name, 'Jenny (Dioco)');
    });

    test('each licence is the one its model card states (docs/18 section 2)', () {
      for (final id in ['en_US-kristin-medium', 'en_US-norman-medium', 'en_GB-cori-medium']) {
        expect(voice(id).licence.use, LicenceUse.free, reason: id);
      }
      expect(voice('en_GB-jenny_dioco-medium').licence.use, LicenceUse.credit);
      expect(voice('en_GB-jenny_dioco-medium').licence.note, contains('Jenny (Dioco)'));
      expect(voice('en_GB-alan-medium').licence.use, LicenceUse.restricted);
      expect(voice('en_US-lessac-high').licence.use, LicenceUse.noncommercial);
      expect(voice('en_US-ryan-high').licence.use, LicenceUse.noncommercial);
      expect(voice('en_US-ryan-high').licence.name, 'CC BY-NC-SA 4.0');
      // A voice that started from Lessac says so.
      expect(voice('en_GB-alba-medium').licence.note, contains('Lessac'));
      expect(voice('en_US-kristin-medium').licence.card, contains('MODEL_CARD'));
    });

    test('voices come by language: Hindi has its own, Bengali none yet', () {
      final hindi = catalog.forLanguage('hi');
      expect([for (final v in hindi) if (v.pack == null) v.id],
          containsAll(['hi_IN-pratham-medium', 'hi_IN-priyamvada-medium', 'hi_IN-rohan-medium']));
      expect([for (final v in hindi) if (v.kind == NeuralKind.kokoro) v.name], ['Alpha', 'Beta', 'Omega', 'Psi']);
      expect(catalog.forLanguage('bn'), isEmpty);
      expect(catalog.languages.length, greaterThan(35));
      // Two Chinese voices read through a lexicon, not espeak-ng.
      expect(voice('zh_CN-xiao_ya-medium').lexicon, isTrue);
      expect(voice('zh_CN-huayan-medium').lexicon, isFalse);
    });

    test("Kokoro's speakers share one download and name their language", () {
      final kokoro = catalog.packs['kokoro-multi-lang-v1_0']!;
      expect(kokoro.kind, NeuralKind.kokoro);
      expect(kokoro.mustKeepUp, isTrue);
      expect(kokoro.minMemoryMb, greaterThanOrEqualTo(5200));
      expect(kokoro.file, 'model.onnx');
      expect(kokoro.url, endsWith('/kokoro-multi-lang-v1_0.tar.bz2'));
      final alpha = voice('kokoro-multi-lang-v1_0:hf_alpha');
      expect(alpha.pack, same(kokoro));
      expect(alpha.sid, 31, reason: "its place in sherpa-onnx's voices.bin");
      expect(alpha.lang, 'hi');
      expect(alpha.modelId, kokoro.id);
      expect(alpha.bytes, kokoro.bytes);
      expect(voice('kokoro-multi-lang-v1_0:bf_emma').lang, 'en-gb');
      expect(voice('kokoro-multi-lang-v1_0:pf_dora').locale, 'pt-BR');
      final kitten = catalog.packs['kitten-nano-en-v0_8-fp32']!;
      expect(kitten.mustKeepUp, isFalse);
      expect([for (final v in catalog.speakersOf(kitten)) v.name], hasLength(8));
      expect(naturalName(alpha), 'Alpha · Kokoro');
      expect(naturalName(voice('en_US-lessac-high')), 'Lessac · natural HD');
      expect(naturalName(voice('en_US-kristin-medium')), 'Kristin · natural');
    });
  });

  group('how each kind of model is loaded', () {
    test('Piper through espeak-ng, two Chinese voices through a lexicon, Kokoro and Kitten with their speakers',
        () {
      final dir = Directory.systemTemp.createTempSync('tomevoice_config');
      addTearDown(() => dir.deleteSync(recursive: true));
      Map<String, Object?> say(NeuralVoice v, String folder) =>
          {'dir': folder, 'model': v.modelId, 'kind': v.kind.name, 'file': v.modelFile};

      final piper = modelConfigFor(say(voice('en_US-kristin-medium'), '/v/piper-k'));
      expect(piper.model.vits.model, '/v/piper-k/en_US-kristin-medium.onnx');
      expect(piper.model.vits.dataDir, '/v/piper-k/espeak-ng-data');
      expect(piper.model.kokoro.model, isEmpty);

      final zh = Directory('${dir.path}/piper-zh')..createSync();
      File('${zh.path}/lexicon.txt').writeAsStringSync('');
      File('${zh.path}/phone.fst').writeAsStringSync('');
      final lexicon = modelConfigFor(say(voice('zh_CN-xiao_ya-medium'), zh.path));
      expect(lexicon.model.vits.lexicon, '${zh.path}/lexicon.txt');
      expect(lexicon.model.vits.dataDir, isEmpty);
      expect(lexicon.ruleFsts, '${zh.path}/phone.fst');

      final kokoro = modelConfigFor(say(voice('kokoro-multi-lang-v1_0:hf_alpha'), '/v/kokoro'));
      expect(kokoro.model.kokoro.model, '/v/kokoro/model.onnx');
      expect(kokoro.model.kokoro.voices, '/v/kokoro/voices.bin');
      expect(kokoro.model.kokoro.dataDir, '/v/kokoro/espeak-ng-data');
      expect(kokoro.model.kokoro.lang, isNotEmpty, reason: 'Kokoro 1.0 exits the process without one');
      expect(kokoro.model.vits.model, isEmpty);

      final kitten = modelConfigFor(say(voice('kitten-nano-en-v0_8-fp32:expr-voice-2-f'), '/v/kitten'));
      expect(kitten.model.kitten.model, '/v/kitten/model.fp32.onnx');
      expect(kitten.model.kitten.voices, '/v/kitten/voices.bin');
    });

    test("a WAV's length is read at its own sample rate", () {
      for (final rate in [16000, 22050, 24000, 44100]) {
        final wav = wavBytes(Float32List(rate * 2), rate);
        expect(wavSeconds(wav), closeTo(2, 1e-9), reason: '$rate Hz');
      }
      expect(wavSeconds(Uint8List(10)), isNull);
    });
  });

  group('on the phone', () {
    late Directory root;
    final natural = NeuralVoices.instance;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tomevoice_natural');
      natural.useCatalog(catalog);
      natural.attach(root);
      ListeningPrefs.reset();
    });

    tearDown(() {
      NeuralEngine.instance.memoryForTests = null;
      NeuralEngine.instance.espeakHomeForTests = null;
      VoiceCatalog.instance.voices = const [];
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test('voices already on the phone are found where they were, and odd leftovers cleared', () {
      final kristin = voice('en_US-kristin-medium');
      install(root, kristin);
      // A voice this catalog does not list (a later one dropped it) still reads.
      final gone = Directory('${root.path}/voices/piper-de_DE-retired-high')..createSync();
      File('${gone.path}/de_DE-retired-high.onnx').writeAsBytesSync(Uint8List(16));
      // A folder left without its model, an old format, and a download cut short.
      Directory('${root.path}/voices/piper-en_US-ryan-high/espeak-ng-data').createSync(recursive: true);
      Directory('${root.path}/voices/vits-piper-en_US-amy-low-fp16').createSync();
      File('${root.path}/voices/hi_IN-rohan-medium.tar.bz2.part').writeAsBytesSync(Uint8List(8));
      natural.attach(root);

      expect(natural.installed(kristin), isTrue);
      expect(Directory('${root.path}/voices/piper-en_US-ryan-high').existsSync(), isFalse);
      expect(Directory('${root.path}/voices/vits-piper-en_US-amy-low-fp16').existsSync(), isFalse);
      expect(File('${root.path}/voices/hi_IN-rohan-medium.tar.bz2.part').existsSync(), isTrue,
          reason: 'a download goes on from where it stopped');
      final retired = neuralVoiceFor('neural:de_DE-retired-high');
      expect(retired?.locale, 'de-DE');
      expect(retired?.quality, 'high');
      expect([for (final v in natural.installedVoices) v.id], ['en_US-kristin-medium', 'de_DE-retired-high']);
    });

    test("removing the voice the engine reads pronunciation through keeps that data until the next start",
        () async {
      final kristin = voice('en_US-kristin-medium');
      final norman = voice('en_US-norman-medium');
      install(root, kristin);
      install(root, norman);
      natural.attach(root);
      NeuralEngine.instance.espeakHomeForTests = natural.folder(kristin).path;

      await natural.remove(kristin);
      expect(natural.installed(kristin), isFalse);
      expect(Directory('${natural.folder(kristin).path}/espeak-ng-data').existsSync(), isTrue,
          reason: 'Norman would fall silent without it');
      await natural.remove(norman);
      expect(natural.folder(norman).existsSync(), isFalse);

      NeuralEngine.instance.espeakHomeForTests = null;
      natural.attach(root);
      expect(natural.folder(kristin).existsSync(), isFalse, reason: 'cleared once the app starts again');
    });

    test('Kokoro is offered only with the memory for it, and read with only once it keeps up', () async {
      final alpha = voice('kokoro-multi-lang-v1_0:hf_alpha');
      NeuralEngine.instance.memoryForTests = 3700; // a 4 GB phone
      expect(natural.offeredFor('hi').where((v) => v.pack != null), isEmpty);
      expect(natural.offeredFor('hi'), hasLength(3), reason: "Piper's Hindi voices are offered all the same");
      NeuralEngine.instance.memoryForTests = 7600; // an 8 GB phone
      expect(natural.offeredFor('hi').where((v) => v.pack != null), hasLength(4));

      install(root, alpha);
      natural.attach(root);
      VoiceCatalog.instance.voices = const [];
      bool offered() => VoiceCatalog.instance.byName(alpha.voiceName) != null;
      expect(natural.installed(alpha), isTrue);
      expect(natural.installed(voice('kokoro-multi-lang-v1_0:hm_psi')), isTrue, reason: 'one download, every speaker');
      expect(natural.readable(alpha), isFalse, reason: 'not tested yet');
      expect(offered(), isFalse);

      await natural.rememberSpeed(alpha, 0.7);
      expect(natural.readable(alpha), isFalse, reason: 'it would fall behind');
      expect(offered(), isFalse);

      await natural.rememberSpeed(alpha, 1.4);
      expect(natural.readable(alpha), isTrue);
      expect(offered(), isTrue);
      expect(VoiceCatalog.instance.forLanguage('hi').map((v) => v.name), contains(alpha.voiceName));

      // What was measured is kept with it, and known after a restart.
      natural.attach(root);
      expect(natural.speedOf(voice('kokoro-multi-lang-v1_0:hm_omega')), 1.4);
      // A Piper voice needs no test to be offered.
      final rohan = voice('hi_IN-rohan-medium');
      install(root, rohan);
      natural.attach(root);
      expect(natural.readable(rohan), isTrue);
    });
  });

  group('the voice screen', () {
    late Directory root;

    setUp(() {
      ListeningPrefs.reset();
      ListeningPrefs.memory.naturalVoices = true;
      // No voices on this phone yet, and a 4 GB one.
      root = Directory.systemTemp.createTempSync('tomevoice_screen');
      NeuralVoices.instance.useCatalog(catalog);
      NeuralVoices.instance.attach(root);
      NeuralEngine.instance.memoryForTests = 3700;
    });

    tearDown(() {
      NeuralEngine.instance.memoryForTests = null;
      root.deleteSync(recursive: true);
    });

    Future<void> open(WidgetTester tester, String language) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: NeuralVoicesScreen(language: language)));
      await tester.pumpAndSettle();
    }

    testWidgets("a language with none says the phone's voice is used", (tester) async {
      await open(tester, 'bn');
      expect(find.text('Natural voices for Bengali'), findsOneWidget);
      expect(find.text("None yet for Bengali; your phone's voice is used."), findsOneWidget);
      // Every other language is there, folded.
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('German'), 400, scrollable: list);
      expect(find.text('Thorsten (emotional)', skipOffstage: false), findsNothing);
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Thorsten (emotional)'), 300, scrollable: list);
      expect(find.text('Thorsten (emotional)'), findsOneWidget);
    });

    testWidgets("the book's language comes first, each voice with its size, quality and licence", (tester) async {
      await open(tester, 'hi');
      expect(find.text('Natural voices for Hindi'), findsOneWidget);
      expect(find.text('Rohan'), findsOneWidget);
      expect(find.text('HINDI (INDIA) · MEDIUM · 64 MB'), findsWidgets);
      expect(find.text('IIT Madras licence · Free to use, on conditions'), findsOneWidget);
      expect(find.text('CC BY-NC-SA 4.0 · Non-commercial use only'), findsNWidgets(2));
      expect(find.byTooltip('Hear Pratham'), findsOneWidget);
      expect(find.byTooltip('Download Pratham'), findsOneWidget);

      await tester.tap(find.text('IIT Madras licence · Free to use, on conditions'));
      await tester.pumpAndSettle();
      expect(find.textContaining("keep IIT Madras's copyright notice"), findsOneWidget);
      expect(find.text('Model card'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // Kokoro, which this 4 GB phone cannot hold, says so and offers nothing.
      final list = find.byType(Scrollable).first;
      const tooLittle = 'Needs a phone with 6 GB of memory or more; this one has 4 GB.';
      await tester.scrollUntilVisible(find.text(tooLittle), 300, scrollable: list);
      expect(find.text(tooLittle), findsOneWidget);
      expect(find.byTooltip('Download Kokoro', skipOffstage: false), findsNothing);
      // Its voices can still be heard.
      await tester.scrollUntilVisible(find.byTooltip('Hear Alpha'), 200, scrollable: list);
      expect(find.byTooltip('Hear Alpha'), findsOneWidget);
    });

    testWidgets("the reader's voice picker leads to its language's natural voices", (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final catalog = VoiceCatalog.instance;
      catalog.voices = const [
        VoiceInfo(name: 'hi-in-x-hia-local', locale: 'hi-IN', quality: 400, networkRequired: false, installed: true),
      ];
      catalog.loaded = true;
      addTearDown(() => catalog.voices = const []);
      ListenController controller(String language) => ListenController(
            prefs: ListeningPrefs.memory,
            language: language,
            onChanged: ({required bool restart}) {},
          );
      Future<void> pick(String language) async {
        await tester.pumpWidget(MaterialApp(
          key: ValueKey(language),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVoicePicker(context, controller(language)),
              child: const Text('Open the picker'),
            ),
          ),
        ));
        await tester.tap(find.text('Open the picker'));
        await tester.pumpAndSettle();
      }

      await pick('bn');
      expect(find.text('No Bengali voice on this phone yet.'), findsOneWidget);
      expect(find.textContaining('Natural voices for'), findsNothing);

      await pick('hi');
      expect(find.text('Natural voices for Hindi'), findsOneWidget);
      expect(find.text('3 to download: voices that sound like people, made on your phone'), findsOneWidget,
          reason: "Piper's three; Kokoro's need more memory than this phone has");
      await tester.tap(find.text('Natural voices for Hindi'));
      await tester.pumpAndSettle();
      expect(find.byType(NeuralVoicesScreen), findsOneWidget);
      expect(find.text('Rohan'), findsOneWidget);
    });
  });
}
