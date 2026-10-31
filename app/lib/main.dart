import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'brand.dart';
import 'error_log.dart';
import 'home_shell.dart';
import 'listening_session.dart';
import 'own_colours.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'secret_shelf.dart';
import 'sources/bridge.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'wallpaper_colours.dart';

// Both ways in run in a guarded zone, with Flutter's errors and those
// nothing caught going to the error log on the phone (error_log.dart) as
// well as where they went before. Nothing is sent anywhere.

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    catchErrors();
    unawaited(openErrorLog());
    _registerFontLicences();
    _listen();
    _show();
  }, zoneError);
}

/// Where Android starts the app for a book read with no screen: Play on the
/// system's resume card after TomeVoice was closed, a headset's Play, a
/// book picked in Android Auto (ReadAloudService, through ReadingCore). The
/// library is opened and the book read; nothing is built until TomeVoice is
/// opened onto this engine, when the app is built here as main() builds it.
@pragma('vm:entry-point')
void backgroundMain() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    catchErrors();
    unawaited(openErrorLog());
    _registerFontLicences();
    _listen();
    // Opened before this was listening: shown now.
    unawaited(const SpeechService().activityAttached().then((on) {
      if (on) _show();
    }));
  }, zoneError);
}

/// What both ways in listen for: books asked for from outside the app, and
/// a new activity showing this engine (it outlives the activity while a
/// book is read).
void _listen() {
  MediaRequests.listen(() async => (await openLibrary()).store);
  SpeechService.events.where((e) => e['type'] == 'shown').listen((_) => _show());
  // The closed-app check's worker, finding this engine up, asks it to check.
  SourcesBridge.answerChecks(checkInApp);
}

var _built = false;

/// One list for every build of the app, so the navigator keeps its observer.
final _observers = <NavigatorObserver>[placeSettler];

/// The app on screen: built once for the engine, and drawn edge to edge in
/// each new activity's window (Android gives each its own, and the mode was
/// sent to the first).
void _show() {
  // Draw under the status bar and the gesture bar, and ask Android not to
  // lay its contrast scrim over the gesture area: that scrim was a darker
  // band with a hard edge just above the home bar, cutting the gradient.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  ));
  if (_built) return;
  _built = true;
  runApp(const SpikeApp());
  // The wallpaper's colours, for its theme: read now, and again each time
  // the app comes back, since a new wallpaper brings new ones.
  unawaited(WallpaperColours.refresh());
  _wallpaper ??= AppLifecycleListener(onResume: () => unawaited(WallpaperColours.refresh()));
}

AppLifecycleListener? _wallpaper;

/// The fonts ship inside the app, so their licences are listed on the About
/// screen with everything else.
void _registerFontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in const [
      ('Bodoni Moda', 'BodoniModa'),
      ('Figtree', 'Figtree'),
      ('Newsreader', 'Newsreader'),
      ('Literata', 'Literata'),
      ('Doto', 'Doto'),
    ]) {
      yield LicenseEntryWithLineBreaks(
        [family],
        await rootBundle.loadString('assets/fonts/OFL-$file.txt'),
      );
    }
    // The engine and libraries web-novel sources run on.
    yield LicenseEntryWithLineBreaks(
      const ['QuickJS', 'cheerio', 'htmlparser2', 'parse5', 'dayjs', 'core-js', 'LNReader plugins'],
      await rootBundle.loadString('assets/licenses/third_party.txt'),
    );
  });
}

/// Entry point.
///
/// Two modes. Normally this is the library. Launched with `--es batch true` it
/// runs the measurement sweep instead, so a device run is one adb command
/// rather than a person tapping sliders into the same positions twice:
///
///     adb shell am start -n app.tomevoice.tomevoice_spike/.MainActivity \
///         --es batch true
class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([ListeningPrefs.revision, WallpaperColours.current]),
        builder: (context, _) {
          final prefs = ListeningPrefs.loaded;
          final follow = (prefs?.bookColours ?? true) ? Skin.followTint : null;
          final base = chosenPalette(prefs);
          // With book colours on, the accent is the cover colour of the book
          // being read; the grounds stay the palette's.
          final palette = follow == null ? base : base.withTint(follow);
          // Every colour in Skin reads the palette, so set it before the
          // tree below is built.
          Skin.palette = palette;
          return _app(palette, palette.modeFor(prefs?.themeMode ?? ThemeMode.system));
        },
      );

  Widget _app(Palette palette, ThemeMode mode) => MaterialApp(
          title: 'TomeVoice',
          navigatorKey: SecretShelf.navigator,
          // Leaving a book writes its place at once (see PlaceSettler).
          navigatorObservers: _observers,
          debugShowCheckedModeBanner: false,
          theme: Skin.themeFor(palette, Brightness.light),
          darkTheme: Skin.themeFor(palette, Brightness.dark),
          themeMode: mode,
          // Palette and light/dark changes ease across rather than snap
          // (Settings also cross-fades its whole screen when you pick one).
          themeAnimationDuration: Motion.page,
          themeAnimationCurve: Motion.emphasized,
          // Status bar icons dark on the light ground, light on the dark one.
          // Every field is set: one left out falls back to Android's default,
          // which for the divider is the separator line above the home bar.
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: Skin.isDark(context)
                ? const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    statusBarIconBrightness: Brightness.light,
                    systemNavigationBarColor: Colors.transparent,
                    systemNavigationBarDividerColor: Colors.transparent,
                    systemNavigationBarIconBrightness: Brightness.light,
                    systemNavigationBarContrastEnforced: false,
                    systemStatusBarContrastEnforced: false,
                  )
                : const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    statusBarIconBrightness: Brightness.dark,
                    systemNavigationBarColor: Colors.transparent,
                    systemNavigationBarDividerColor: Colors.transparent,
                    systemNavigationBarIconBrightness: Brightness.dark,
                    systemNavigationBarContrastEnforced: false,
                    systemStatusBarContrastEnforced: false,
                  ),
            child: child!,
          ),
          home: const _ModeGate(),
        );
}

class _ModeGate extends StatefulWidget {
  const _ModeGate();

  @override
  State<_ModeGate> createState() => _ModeGateState();
}

class _ModeGateState extends State<_ModeGate> {
  bool? _batch;

  @override
  void initState() {
    super.initState();
    const SpeechService().launchArgs().then((args) {
      // A development tool: a release build ignores it (any app can send
      // the extra).
      if (mounted) setState(() => _batch = !kReleaseMode && args['batch'] == 'true');
    });
  }

  @override
  Widget build(BuildContext context) => switch (_batch) {
        true => const BatchScreen(),
        false => const HomeShell(),
        // Same chrome as the library so launchArgs does not flash a blank
        // scaffold and then a different product.
        null => Scaffold(
            body: Container(
              decoration: BoxDecoration(gradient: Skin.ground(context)),
              child: const SafeArea(
                child: Center(child: BrandLockup()),
              ),
            ),
          ),
      };
}

/// The measurement sweep.
///
/// Synthesises once per (engine, speed-mode) and processes that audio through
/// every gap setting, so configurations differ only in our own pipeline
/// settings. Writes a WAV plus JSON pair per configuration and a
/// BATCH-COMPLETE.txt sentinel, which is what `adb pull` and
/// `tools/measure.dart` consume.
class BatchScreen extends StatefulWidget {
  const BatchScreen({super.key});

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  static const _text =
      'The quick brown fox jumps over the lazy dog. '
      'Pack my box with five dozen liquor jugs.';

  static const _configs = <({int gap, double speed, bool viaEngine})>[
    (gap: 0, speed: 1.0, viaEngine: false),
    (gap: 120, speed: 1.0, viaEngine: false),
    (gap: 250, speed: 1.0, viaEngine: false),
    (gap: 120, speed: 2.0, viaEngine: false),
    (gap: 120, speed: 2.0, viaEngine: true),
  ];

  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    const svc = SpeechService();
    void note(String s) {
      if (mounted) setState(() => _log.add(s));
    }

    final engines = await svc.engines();
    final voices = await svc.voices(engines.firstOrNull?['name']);
    final voice = SpeechService.pickVoice(voices, 'en');
    final voiceName = voice?['name'] as String?;

    final matching = voices
        .where((v) =>
            (v['locale'] as String? ?? '').toLowerCase().startsWith('en'))
        .length;
    note('voices: ${voices.length} total, $matching match "en", '
        'chosen="$voiceName"');

    final dir = await svc.outputDir();

    for (final engine in engines) {
      final id = engine['name']!;
      final short = id.split('.').last;

      for (final c in _configs) {
        try {
          final native = await svc.synthesise(
            text: _text,
            engineId: id,
            voiceName: voiceName,
            rate: c.viaEngine ? c.speed : 1.0,
          );

          if (c == _configs.first) {
            note('$short: onRangeStart=${native['rangeStartFired']} '
                'events=${(native['rangeEvents'] as List?)?.length ?? 0} '
                'granularity=${native['granularity']}');
          }

          final settings = PipelineSettings(
            wordGapMs: c.gap,
            speedScale: c.viaEngine ? 1.0 : c.speed,
            sentencePauseMs: 350,
            text: _text,
          );
          final out = await svc.process(native, settings);

          final tag = '${c.viaEngine ? 'eng' : 'dsp'}'
              '${c.speed.toStringAsFixed(1).replaceAll('.', '_')}';
          final label = '$short-gap${c.gap}-$tag';

          if (dir != null) {
            await File('$dir/tomevoice-spike-$label.wav')
                .writeAsBytes(WavCodec.encodePcm16(out.audio));
            await File('$dir/tomevoice-spike-$label.json')
                .writeAsString(encodeReport(out.toJson(_text, settings)));
          }
          note('  gap=${c.gap} speed=${c.speed}x ${c.viaEngine ? 'eng' : 'dsp'}'
              ' -> $label');
        } catch (e) {
          note('  gap=${c.gap} speed=${c.speed}x FAILED: $e');
        }
      }
    }

    if (dir != null) {
      await File('$dir/BATCH-COMPLETE.txt').writeAsString(_log.join('\n'));
    }
    note('BATCH COMPLETE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Skin.dark,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: ListView(
              children: [
                Text('BATCH',
                    style: Skin.meta(context, color: Skin.amber, size: 12)),
                const SizedBox(height: 12),
                for (final l in _log)
                  Text(l,
                      style: Skin.meta(context,
                          color: Skin.cream.withValues(alpha: 0.85),
                          size: 10.5)),
              ],
            ),
          ),
        ),
      );
}
