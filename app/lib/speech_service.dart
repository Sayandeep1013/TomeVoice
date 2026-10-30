import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show wordSpans;

import 'neural_voices.dart';
import 'scheduler.dart';

/// The phone a problem report names: Android's version and API level, and
/// its maker and model (see [SpeechService.deviceInfo]).
typedef DeviceInfo = ({String android, int sdk, String maker, String model});

/// Everything that talks to the platform, plus the decoding that has to happen
/// before the pure-Dart pipeline can be handed anything.
///
/// Shared by the reading screen and the measurement batch so the two cannot
/// drift apart — the batch is only useful if it exercises the same code the
/// user hears.
class SpeechService {
  const SpeechService();

  static const _channel = MethodChannel('tomevoice/tts');

  static final _events = StreamController<Map<String, Object?>>.broadcast();
  static bool _handlerSet = false;

  /// Platform events: audio focus, headphones unplugged, notification and
  /// lock-screen buttons, "Open with TomeVoice", PDF import progress.
  static Stream<Map<String, Object?>> get events {
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'platformEvent' && call.arguments is Map) {
          _events.add(Map<String, Object?>.from(call.arguments as Map));
        }
        return null;
      });
    }
    return _events.stream;
  }

  Future<Map<String, String>> launchArgs() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('launchArgs');
      return {
        for (final e in (raw ?? const {}).entries)
          e.key: e.value?.toString() ?? '',
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  Future<List<Map<String, String>>> engines() async {
    final raw =
        await _channel.invokeListMethod<Map<Object?, Object?>>('listEngines');
    return [
      for (final e in raw ?? const [])
        {
          'name': e['name'] as String? ?? '',
          'label': e['label'] as String? ?? '',
        },
    ];
  }

  Future<List<Map<String, Object?>>> voices(String? engineId) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listVoices',
      {'engineId': engineId},
    );
    return [
      for (final v in raw ?? const [])
        {
          'name': v['name'] as String? ?? '',
          'locale': v['locale'] as String? ?? '',
          'quality': v['quality'] as int? ?? 0,
          'networkRequired': v['networkRequired'] == true,
          'installed': v['installed'] != false,
        },
    ];
  }

  /// Android TTS is a single engine with one progress listener. Overlapping
  /// synthesise calls steal the listener and the first utterance never
  /// continues the scheduler, so this is strictly one at a time.
  static Future<void> _synthBusy = Future<void>.value();

  /// Forget a synthesis still holding the queue (between widget tests).
  @visibleForTesting
  static void resetQueue() => _synthBusy = Future<void>.value();

  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async {
    final previous = _synthBusy;
    final gate = Completer<void>();
    _synthBusy = gate.future;
    // Never wait on a call that will not come back (an engine that hung, a
    // test that ended mid-call): one stuck sentence must not silence every
    // later one.
    await previous.timeout(const Duration(seconds: 20), onTimeout: () {});
    try {
      // A natural voice is made here, not by the phone's speech engine.
      final natural = neuralVoiceFor(voiceName);
      if (natural != null) {
        return await NeuralEngine.instance.synthesise(
          voice: natural,
          text: text,
          speed: rate,
          outDir: synthTempDir().path,
          urgent: urgent,
        );
      }
      final raw = await _channel.invokeMapMethod<String, Object?>('synthesise', {
        'text': text,
        'engineId': engineId,
        'voiceName': voiceName,
        'rate': rate,
        'pitch': pitch,
      });
      if (raw == null) throw Exception('synthesise returned nothing');
      return raw;
    } finally {
      gate.complete();
    }
  }

  /// Abandon the sentence being synthesised (after a seek): the phone's
  /// engine stops at once; a natural voice stops after the piece it is on.
  Future<void> cancelSynthesis() {
    NeuralEngine.instance.cancel();
    return _quiet('cancelSynthesis');
  }

  Future<String?> outputDir() => _channel.invokeMethod<String>('outputDir');

  // ---------------------------------------------------------------- player

  /// Answers of [requestFocus].
  static const focusGranted = 'granted';

  /// Not now (a call is on): a `focusGain` event comes when it ends.
  static const focusDelayed = 'delayed';
  static const focusFailed = 'failed';

  /// Ask for the phone's audio before playing. A platform that cannot
  /// answer (widget tests) grants it.
  Future<String> requestFocus() async {
    try {
      return await _channel.invokeMethod<String>('requestFocus') ?? focusGranted;
    } on Object {
      return focusGranted;
    }
  }

  /// Queue PCM16 mono audio; returns the stream frame it will start at.
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
    final start = await _channel.invokeMethod<int>(
      'playerEnqueue',
      {'pcm': pcm, 'sampleRate': sampleRate},
    );
    return start ?? 0;
  }

  /// Frames of the current stream the listener has heard: the hardware head
  /// less what is still on its way out (the output's own delay, Bluetooth's
  /// above all, and the reader's Highlight timing). [raw] is the head
  /// itself. Negative when the player failed and needs starting again.
  Future<int> position({bool raw = false}) async =>
      await _channel.invokeMethod<int>('playerPosition', {'raw': raw}) ?? 0;

  Future<void> pausePlayback() => _quiet('playerPause');
  Future<void> resumePlayback() => _quiet('playerResume');
  Future<void> stopPlayback() => _quiet('playerStop');

  /// The player's volume, 0 to 1, on top of the phone's (the sleep fade).
  Future<void> setVolume(double volume) => _quiet('playerVolume', {'volume': volume});

  /// How much later than the platform says the highlight should move, in ms:
  /// on Bluetooth, and on everything else (see [highlightRoute]).
  Future<void> setHighlightOffsets({required int bluetoothMs, required int otherMs}) =>
      _quiet('playerLatency', {'bluetoothMs': bluetoothMs, 'otherMs': otherMs});

  /// Where the voice is heard now: [routeBluetooth] or [routeOther].
  Future<String> highlightRoute() async {
    try {
      return await _channel.invokeMethod<String>('playerRoute') ?? routeOther;
    } on Object {
      return routeOther;
    }
  }

  static const routeBluetooth = 'bluetooth';
  static const routeOther = 'other';

  /// The "reading aloud" foreground service that keeps speech going with the
  /// screen off. Inactive ends it.
  ///
  /// It also feeds the shade's media card: [cover] (an image file) is its
  /// picture, [positionMs] of [durationMs] its seek bar through the chapter,
  /// and [speed] its speed button. [book], when given, is the book's id: a
  /// Play from outside the app for that book then carries on with this one.
  Future<void> session({
    required bool active,
    String title = '',
    String subtitle = '',
    bool playing = false,
    String? cover,
    int positionMs = 0,
    int durationMs = 0,
    double speed = 1.0,
    String? book,
  }) =>
      _quiet('session', {
        'active': active,
        'title': title,
        'subtitle': subtitle,
        'playing': playing,
        'cover': cover,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'speed': speed,
        'book': book,
      });

  // ------------------------------------------------------ outside the app

  /// A book asked for from outside the app (the system's resume card, a
  /// headset's Play, Android Auto), taken once: its id, and whether a
  /// reading had the card when it was asked. Null when none is waiting.
  Future<({String book, bool reading})?> takeMediaPlay() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('takeMediaPlay');
      final book = raw?['book'];
      return book is String ? (book: book, reading: raw?['reading'] == true) : null;
    } on Object {
      return null;
    }
  }

  /// The book asked for from outside the app cannot be read: the card put
  /// up for it goes.
  Future<void> mediaPlayFailed() => _quiet('mediaPlayFailed');

  /// Whether an activity shows this engine: the app runs with no screen when
  /// a book was started from outside it.
  Future<bool> activityAttached() async {
    try {
      return await _channel.invokeMethod<bool>('activityAttached') ?? false;
    } on Object {
      return false;
    }
  }

  /// Whether Android's battery optimisation leaves TomeVoice alone, and the
  /// phone's maker and brand; null where the platform cannot say.
  Future<({bool exempt, String maker, String brand})?> batteryStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('batteryStatus');
      if (raw == null) return null;
      return (
        exempt: raw['exempt'] == true,
        maker: raw['maker'] as String? ?? '',
        brand: raw['brand'] as String? ?? '',
      );
    } on Object {
      return null;
    }
  }

  /// Android's setting that lets TomeVoice read on with the screen off.
  /// False when the phone has none to open.
  Future<bool> openBatterySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } on Object {
      return false;
    }
  }

  /// Whether the phone has a lock (a PIN, pattern or password) to ask for.
  Future<bool> deviceSecure() async {
    try {
      return await _channel.invokeMethod<bool>('deviceSecure') ?? false;
    } on Object {
      return false;
    }
  }

  /// Ask for the phone's own lock (a fingerprint or face, or its PIN): true
  /// once the owner has shown it is them, false if they cancel, null if
  /// the phone could not ask.
  Future<bool?> confirmUser({required String title, String? subtitle}) async {
    try {
      return await _channel.invokeMethod<bool>('confirmUser', {'title': title, 'subtitle': subtitle}) ?? false;
    } on Object catch (e) {
      debugPrint('TomeVoice: could not ask for the phone lock: $e');
      return null;
    }
  }

  /// A blank card for TomeVoice in Recents, instead of what is on screen.
  Future<void> hideRecents(bool on) => _quiet('hideRecents', {'on': on});

  /// Android's security settings, where a screen lock is set.
  Future<bool> openSecuritySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSecuritySettings') ?? false;
    } on Object {
      return false;
    }
  }

  Future<bool> openTtsSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openTtsSettings') ?? false;
    } on Object {
      return false;
    }
  }

  /// Open a web page in the browser.
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } on Object {
      return false;
    }
  }

  /// [word] to the phone's dictionary apps; false when it has none.
  Future<bool> lookUp(String word) => _textTo('lookUp', word);

  /// [text] to the phone's translate app; false when it has none.
  Future<bool> translate(String text) => _textTo('translate', text);

  Future<bool> _textTo(String method, String text) async {
    try {
      return await _channel.invokeMethod<bool>(method, {'text': text}) ?? false;
    } on Object {
      return false;
    }
  }

  /// Read a NovelDokusha backup zip; the path of the JSON it was turned into.
  Future<String> readNovelDokushaBackup(String path) async {
    final out = await _channel.invokeMethod<String>('readNovelDokushaBackup', {'path': path});
    if (out == null) throw Exception('The backup could not be read');
    return out;
  }

  /// The phone's own browser User-Agent, so a site's browser check, passed
  /// in a web view, also holds for the app's requests. Null without one.
  Future<String?> webUserAgent() async {
    try {
      return await _channel.invokeMethod<String>('webUserAgent');
    } on Object {
      return null;
    }
  }

  /// Show [url]'s browser check in a web view; the site's cookies once it
  /// lets the reader in ("a=1; cf_clearance=…"), or null if it did not.
  Future<String?> browserCheck(String url, String userAgent) async {
    try {
      return await _channel.invokeMethod<String>('browserCheck', {'url': url, 'userAgent': userAgent});
    } on Object {
      return null;
    }
  }

  /// Keep the display awake while a book is open (a reader setting).
  Future<void> keepScreenOn(bool on) => _quiet('keepScreenOn', {'on': on});

  /// While on, the volume keys turn pages (a `pageKey` event with `delta`)
  /// instead of changing the volume.
  Future<void> volumeKeysTurnPages(bool on) => _quiet('volumeKeysTurnPages', {'on': on});

  /// The installed version name, "0.3.0".
  Future<String?> appVersion() async {
    try {
      return await _channel.invokeMethod<String>('appVersion');
    } on Object {
      return null;
    }
  }

  /// The phone, for a problem report: Android's version ("14") and API
  /// level, its maker and its model. Null where the platform cannot say.
  Future<DeviceInfo?> deviceInfo() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('deviceInfo');
      if (raw == null) return null;
      return (
        android: raw['android'] as String? ?? '',
        sdk: (raw['sdk'] as num?)?.toInt() ?? 0,
        maker: raw['maker'] as String? ?? '',
        model: raw['model'] as String? ?? '',
      );
    } on Object {
      return null;
    }
  }

  Future<void> _quiet(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on Object {
      // Platform may not be ready in widget tests.
    }
  }

  // ---------------------------------------------------------------- backup

  /// Bytes a backup would hold before compression; -1 if unknown.
  Future<int> backupSize({required bool includeChapters}) async {
    try {
      return (await _channel.invokeMethod<num>('backupSize', {'includeChapters': includeChapters}))?.toInt() ?? -1;
    } on Object {
      return -1;
    }
  }

  /// Ask where to save, then zip the library there. Null if the save dialog
  /// was closed; otherwise `files` and `bytes`. Progress arrives on [events]
  /// as `backupProgress` with `done` and `total`.
  Future<Map<String, Object?>?> backupLibrary({
    required String manifest,
    required bool includeChapters,
    required String fileName,
  }) =>
      _channel.invokeMapMethod<String, Object?>('backupLibrary', {
        'manifest': manifest,
        'includeChapters': includeChapters,
        'fileName': fileName,
      });

  /// Ask for a backup and unpack it into [staging]. Its manifest's text, or
  /// null if the picker was closed. Progress: `restoreProgress` with `done`.
  Future<String?> pickBackup(String staging) =>
      _channel.invokeMethod<String>('pickBackup', {'staging': staging});

  /// Where pictures to share are written (served to other apps from there).
  Future<String?> shareDir() => _channel.invokeMethod<String>('shareDir');

  /// Play the recording at [url] (a voice's sample) as it streams; an event
  /// `urlSampleDone` or `urlSampleFailed` follows.
  Future<void> playUrl(String url) => _channel.invokeMethod<void>('playUrl', {'url': url});

  Future<void> stopUrl() => _channel.invokeMethod<void>('stopUrl');

  /// Whether this app runs as 64-bit code (so wants the 64-bit APK).
  Future<bool> is64Bit() async => await _channel.invokeMethod<bool>('is64Bit') ?? true;

  /// Open Android's installer for the APK at [path] (in [shareDir]):
  /// "started", or "permission" when Android first has to be told TomeVoice
  /// may install apps (its setting is opened instead).
  Future<String?> installApk(String path) => _channel.invokeMethod<String>('installApk', {'path': path});

  /// Android's share sheet for the picture at [path], with [text] beside it.
  Future<void> shareImage(String path, {String? text}) =>
      _channel.invokeMethod<void>('shareImage', {'path': path, 'text': text});

  /// What a tapped widget asked for (`book`, `play`, `page`), once.
  Future<Map<String, Object?>?> widgetLaunch() async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('widgetLaunch');
    } on Object {
      return null;
    }
  }

  /// Ask the launcher to add a widget: player, playerStamp, playerWide,
  /// streak or streakWide. False when the launcher cannot.
  Future<bool> pinWidget(String kind) async {
    try {
      return await _channel.invokeMethod<bool>('pinWidget', {'kind': kind}) ?? false;
    } on Object {
      return false;
    }
  }

  /// Redraw the home-screen widgets (the library or stats changed).
  Future<void> refreshWidgets() => _quiet('refreshWidgets');

  /// Start the app again in a fresh process (after a restore).
  Future<void> restartApp() => _quiet('restartApp');

  // ---------------------------------------------------------------- import

  /// SAF picker, several files at once. Empty if the user cancelled.
  Future<List<PickedFile>> pickDocuments() async {
    final raw = await _channel.invokeListMethod<Object?>('pickDocuments');
    return [
      for (final m in raw ?? const [])
        if (m is Map) PickedFile.fromMap(m),
    ];
  }

  /// One picture from the phone (for a book cover). Null if cancelled.
  Future<PickedFile?> pickImage() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pickImage');
    return raw == null ? null : PickedFile.fromMap(raw);
  }

  /// A file handed to us by "Open with" / "Share" before Dart was listening.
  Future<PickedFile?> pendingOpen() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('pendingOpen');
      return raw == null ? null : PickedFile.fromMap(raw);
    } on Object {
      return null;
    }
  }

  /// PDF text via PdfBox on the device.
  Future<Map<String, Object?>> extractPdf(String path) async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'extractPdf',
      {'path': path},
    );
    if (raw == null) throw Exception('PDF extraction returned nothing');
    return raw;
  }

  // ----------------------------------------------------------- page view

  /// Page count and page sizes (in points) of a PDF, for the page view.
  Future<({int pages, List<double> aspects})> pdfInfo(String path) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pdfInfo', {'path': path});
    final sizes = [for (final v in (raw?['sizes'] as List? ?? const [])) (v as num).toDouble()];
    final pages = raw?['pages'] as int? ?? 0;
    return (
      pages: pages,
      aspects: [
        for (var i = 0; i + 1 < sizes.length; i += 2)
          sizes[i + 1] <= 0 ? 1.414 : sizes[i] / sizes[i + 1],
      ],
    );
  }

  /// A rendered page as an image file, [width] pixels wide.
  Future<String> pdfRender(String path, int page, int width) async {
    final file = await _channel.invokeMethod<String>(
      'pdfRender',
      {'path': path, 'page': page, 'width': width},
    );
    if (file == null) throw Exception('Page $page could not be drawn');
    return file;
  }

  // ------------------------------------------------------------- pipeline

  /// Reads the WAV the engine wrote and runs it through the pipeline. Used by
  /// the measurement batch; playback uses [renderInBackground].
  Future<ProcessedSpeech> process(
    Map<String, Object?> native,
    PipelineSettings settings,
  ) async {
    final raw = WavCodec.decode(
      await File(native['wavPath'] as String).readAsBytes(),
    );
    final decoded = decodeTimings(native, raw.frameCount, settings.text.length);

    final traced = buildStandardPipeline(settings).runTraced(
      SynthesisResult(
        audio: raw,
        wordTimings: wordTimingsFor(native, raw, settings.text),
        engineId: native['engineId'] as String? ?? 'unknown',
      ),
    );

    return ProcessedSpeech(
      result: traced.result,
      trace: traced.trace,
      rawFrames: raw.frameCount,
      layout: decoded.layout,
      voice: native['voiceName'] as String? ?? 'unknown',
      engine: native['engineId'] as String? ?? 'unknown',
      native: native,
    );
  }

  /// Detects which `onRangeStart` parameter carries the frame position instead
  /// of trusting the documented order.
  ///
  /// The platform documents `(utteranceId, start, end, frame)`, but Google TTS
  /// delivers `(frame, charStart, charEnd)` — matching the engine-side
  /// `SynthesisCallback#rangeStart(markerInFrames, start, end)` it forwards
  /// from. Character offsets are bounded by the text length and frame positions
  /// at 24 kHz are not, so whichever column runs past the text length is the
  /// frame.
  ///
  /// Getting this wrong is not subtle: it put every word at frames 3, 9, 15,
  /// which sent all the injected silence to the front of the buffer where edge
  /// trimming removed it.
  static ({List<WordTiming> timings, String layout}) decodeTimings(
    Map<String, Object?> native,
    int totalFrames,
    int textLength,
  ) {
    final events = [
      for (final e in (native['rangeEvents'] as List? ?? const []))
        (a: (e as Map)['start'] as int, b: e['end'] as int, c: e['frame'] as int),
    ];
    if (events.isEmpty) return (timings: const [], layout: 'none');

    int maxOf(int Function(({int a, int b, int c})) pick) =>
        events.map(pick).reduce((x, y) => x > y ? x : y);

    final overA = maxOf((e) => e.a) > textLength;
    final overB = maxOf((e) => e.b) > textLength;
    final overC = maxOf((e) => e.c) > textLength;

    final String layout;
    int Function(({int a, int b, int c})) frameOf, startOf, endOf;

    if (overA && !overB && !overC) {
      layout = 'frameFirst';
      frameOf = (e) => e.a;
      startOf = (e) => e.b;
      endOf = (e) => e.c;
    } else if (overC && !overA && !overB) {
      layout = 'documented';
      frameOf = (e) => e.c;
      startOf = (e) => e.a;
      endOf = (e) => e.b;
    } else {
      layout = 'ambiguous';
      frameOf = (e) => e.c;
      startOf = (e) => e.a;
      endOf = (e) => e.b;
    }

    return (
      timings: [
        for (var i = 0; i < events.length; i++)
          WordTiming(
            charStart: startOf(events[i]),
            charEnd: endOf(events[i]),
            frameStart: frameOf(events[i]).clamp(0, totalFrames),
            frameEnd:
                (i + 1 < events.length ? frameOf(events[i + 1]) : totalFrames)
                    .clamp(0, totalFrames),
            source: layout == 'ambiguous'
                ? WordTimingSource.estimated
                : WordTimingSource.engineReported,
          ),
      ],
      layout: layout,
    );
  }

  /// The word timings of [raw], the audio [native] describes, for [text]:
  /// already worked out (a dialogue line, joined from its parts), reported
  /// by the engine, or, from a voice that reports none, matched to the
  /// pauses in the audio (see [PauseAligner]; its `anchors` are where pieces
  /// made apart were joined).
  static List<WordTiming> wordTimingsFor(Map<String, Object?> native, AudioBuffer raw, String text) {
    final given = native['wordTimings'];
    if (given is List) return timingsFromMaps(given, raw.frameCount);
    final decoded = decodeTimings(native, raw.frameCount, text.length);
    if (decoded.timings.isNotEmpty) return decoded.timings;
    return PauseAligner.align(
      raw,
      text,
      known: [
        for (final a in (native['anchors'] as List? ?? const []))
          if (a is Map) (char: (a['char'] as num).toInt(), frame: (a['frame'] as num).toInt()),
      ],
      // The document's own word units: Chinese and Japanese, which have no
      // spaces, are a unit a character there, not a sentence a word.
      spans: [for (final w in wordSpans(text, 0, text.length)) (start: w.start, end: w.end)],
    );
  }

  /// Word timings as plain maps, to cross to another isolate or platform.
  static List<Map<String, Object?>> timingsToMaps(List<WordTiming> timings) => [
        for (final t in timings)
          {'cs': t.charStart, 'ce': t.charEnd, 'fs': t.frameStart, 'fe': t.frameEnd, 'src': t.source.name},
      ];

  static List<WordTiming> timingsFromMaps(List<Object?> maps, int totalFrames) => [
        for (final m in maps)
          if (m is Map)
            WordTiming(
              charStart: (m['cs'] as num).toInt(),
              charEnd: (m['ce'] as num).toInt(),
              frameStart: (m['fs'] as num).toInt().clamp(0, totalFrames),
              frameEnd: (m['fe'] as num).toInt().clamp(0, totalFrames),
              source: WordTimingSource.values.firstWhere((s) => s.name == m['src'],
                  orElse: () => WordTimingSource.estimated),
            ),
      ];

  /// Language first, then installed and offline, then quality.
  ///
  /// Ranking by quality alone once selected an Arabic voice for English text,
  /// so language match is the primary key rather than a tiebreaker.
  static Map<String, Object?>? pickVoice(
    List<Map<String, Object?>> voices,
    String language, {
    String? preferRegion,
  }) {
    if (voices.isEmpty) return null;
    bool matches(Map<String, Object?> v) =>
        (v['locale'] as String? ?? '').toLowerCase().startsWith(language);
    final matching = voices.where(matches).toList();
    final pool = matching.isNotEmpty ? matching : voices;
    final region = preferRegion?.toUpperCase();
    bool local(Map<String, Object?> v) =>
        region != null &&
        (v['locale'] as String? ?? '').toUpperCase().endsWith(region);
    // Installed, then offline, then the phone's own region (an Indian
    // phone gets the Indian Bengali voice), then the engine's quality.
    int score(Map<String, Object?> v) =>
        (v['installed'] == false ? 0 : 8000) +
        (v['networkRequired'] == true ? 0 : 4000) +
        (local(v) ? 2000 : 0) +
        ((v['quality'] as int?) ?? 0);
    final ranked = [...pool]..sort((a, b) => score(b).compareTo(score(a)));
    return ranked.first;
  }

  /// Android's `setPitch` is a linear multiplier around 1.0. Semitones are the
  /// perceptually even unit, so the UI speaks semitones and this converts.
  static double semitonesToPitch(double semitones) {
    if (semitones == 0) return 1.0;
    var r = 1.0;
    final x = semitones / 12;
    final whole = x.truncate();
    for (var i = 0; i < whole.abs(); i++) {
      r = whole > 0 ? r * 2 : r / 2;
    }
    return (r * (1 + (x - whole) * 0.6931471805599453)).clamp(0.5, 2.0);
  }
}

class PickedFile {
  const PickedFile({required this.path, required this.name, this.mime});

  final String path;
  final String name;
  final String? mime;

  static PickedFile fromMap(Map<Object?, Object?> m) => PickedFile(
        path: m['path']?.toString() ?? '',
        name: m['name']?.toString() ?? 'document',
        mime: m['mime']?.toString(),
      );
}

/// One sentence, ready for the player: raw PCM16 with the pause after it
/// already appended, plus word timings in the same frame space.
class RenderedSpeech {
  const RenderedSpeech({
    required this.pcm,
    required this.sampleRate,
    required this.speechFrames,
    required this.totalFrames,
    required this.timings,
    required this.levels,
    this.gainDb,
  });

  final Uint8List pcm;
  final int sampleRate;

  /// Frames of voice; the rest of [totalFrames] is the pause after it.
  final int speechFrames;
  final int totalFrames;
  final List<WordTiming> timings;

  /// How loud the voice is, every [speechLevelMs]: see [speechLevels].
  final Uint8List levels;

  /// The levelling gain this sentence was given (null with levelling off),
  /// for the next to move on from.
  final double? gainDb;
}

/// The step of [RenderedSpeech.levels].
const speechLevelMs = 20;

/// How loud [samples] are, 0 to 255 for each [speechLevelMs]: on a decibel
/// scale, as the ear hears it, from -50 dB (nothing) to -10 dB (full voice).
/// What the glow behind the player rises and falls with.
Uint8List speechLevels(List<double> samples, int sampleRate) {
  final step = math.max(1, sampleRate * speechLevelMs ~/ 1000);
  final out = Uint8List((samples.length + step - 1) ~/ step);
  for (var k = 0; k < out.length; k++) {
    final from = k * step;
    final to = math.min(samples.length, from + step);
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += samples[i] * samples[i];
    }
    if (sum <= 0) continue;
    final db = 10 * math.log(sum / (to - from)) / math.ln10;
    out[k] = ((db + 50) / 40 * 255).clamp(0, 255).round();
  }
  return out;
}

/// Say [text] once in [voiceName], through the same pipeline as reading, so
/// a voice sounds in the preview exactly as it will in the book. Completes
/// when the sample has about finished playing.
Future<void> speakSample({
  required String voiceName,
  required String text,
  required PipelineSettings settings,
  String? engineId,
}) async {
  const svc = SpeechService();
  // A book reading in the background stops for the sample.
  PlaybackScheduler.beforePlay?.call(null);
  // Speed and pitch as the scheduler gives them: to the engine. The DSP
  // stretch resamples, so a 1.5x sample came out squeaky and too fast.
  final native = await svc.synthesise(
    text: text,
    engineId: engineId,
    voiceName: voiceName,
    rate: settings.speedScale,
    pitch: SpeechService.semitonesToPitch(settings.pitchSemitones),
  );
  final r = await renderInBackground(
    native: native,
    settings: settings.copyWith(speedScale: 1.0, sentencePauseMs: 0, text: text),
    pauseAfterMs: 0,
  );
  await svc.stopPlayback();
  await svc.enqueue(r.pcm, r.sampleRate);
  await Future<void>.delayed(Duration(milliseconds: r.totalFrames * 1000 ~/ r.sampleRate));
}

/// Decode, run the pipeline and encode for the player on a background
/// isolate. On the UI isolate this work was a dropped frame per sentence.
///
/// [levelDb] is the levelling gain the sentence before was given: this one
/// moves half way from it to its own, so the level drifts with the voice
/// rather than jumping with each sentence's measure (null: start afresh).
Future<RenderedSpeech> renderInBackground({
  required Map<String, Object?> native,
  required PipelineSettings settings,
  required int pauseAfterMs,
  double? levelDb,
}) {
  final job = (native: native, settings: settings, pauseAfterMs: pauseAfterMs, levelDb: levelDb);
  return Isolate.run(() => _render(job));
}

RenderedSpeech _render(
  ({
    Map<String, Object?> native,
    PipelineSettings settings,
    int pauseAfterMs,
    double? levelDb,
  }) job,
) {
  final file = File(job.native['wavPath'] as String);
  final bytes = file.readAsBytesSync();
  try {
    file.deleteSync();
  } on FileSystemException {
    // Cache directory; the platform sweeps it on next launch anyway.
  }
  final raw = WavCodec.decode(bytes);
  final text = job.settings.text;
  final gainDb = job.settings.normaliseLoudness
      ? GainStage.smoothedGainDb(job.levelDb, GainStage.levelGainDb(raw.samples, raw.sampleRate))
      : null;
  final result = buildStandardPipeline(job.settings.copyWith(levelGainDb: gainDb)).run(
    SynthesisResult(
      audio: raw,
      wordTimings: SpeechService.wordTimingsFor(job.native, raw, text),
      engineId: job.native['engineId'] as String? ?? 'unknown',
    ),
  );
  final audio = result.audio;
  final pause = audio.msToFrames(job.pauseAfterMs);
  return RenderedSpeech(
    pcm: WavCodec.pcm16Bytes(audio, silenceFrames: pause),
    sampleRate: audio.sampleRate,
    speechFrames: audio.frameCount,
    totalFrames: audio.frameCount + pause,
    timings: result.wordTimings,
    levels: speechLevels(audio.samples, audio.sampleRate),
    gainDb: gainDb,
  );
}

class ProcessedSpeech {
  const ProcessedSpeech({
    required this.result,
    required this.trace,
    required this.rawFrames,
    required this.layout,
    required this.voice,
    required this.engine,
    required this.native,
  });

  final SynthesisResult result;
  final List<StageTrace> trace;
  final int rawFrames;
  final String layout;
  final String voice;
  final String engine;
  final Map<String, Object?> native;

  AudioBuffer get audio => result.audio;
  List<WordTiming> get timings => result.wordTimings;

  Map<String, Object?> toJson(String text, PipelineSettings s) => {
        'engineId': engine,
        'voiceName': voice,
        'deviceModel': native['deviceModel'],
        'androidVersion': native['androidVersion'],
        'text': text,
        'settings': {
          'gapMs': s.wordGapMs,
          'speedScale': s.speedScale,
          'sentencePauseMs': s.sentencePauseMs,
          'commaMs': s.punctuation.commaMs,
          'clauseMs': s.punctuation.clauseMs,
          'pitchSemitones': s.pitchSemitones,
        },
        'rangeStartFired': native['rangeStartFired'],
        'granularity': native['granularity'],
        'rangeEvents': native['rangeEvents'],
        'timingSource':
            timings.isEmpty ? 'none' : timings.first.source.name,
        'eventLayout': layout,
        'sampleRate': audio.sampleRate,
        'rawFrameCount': rawFrames,
        'processedFrameCount': audio.frameCount,
        'stages': [
          for (final t in trace)
            {'name': t.stageName, 'in': t.framesIn, 'out': t.framesOut},
        ],
        'reportedTimings': [
          for (final t in timings)
            {
              'charStart': t.charStart,
              'charEnd': t.charEnd,
              'frameStart': t.frameStart,
              'frameEnd': t.frameEnd,
            },
        ],
      };
}

/// Where speech made in Dart (natural voices, joined dialogue) is written:
/// cache/tts, the folder the app empties on every start.
Directory synthTempDir() => Directory('${Directory.systemTemp.path}/tts')..createSync(recursive: true);
