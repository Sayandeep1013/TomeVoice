import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'settings_panel.dart';
import 'speech_service.dart';
import 'theme.dart';

const _svc = SpeechService();

const _defaultText =
    'The quick brown fox jumps over the lazy dog. '
    'Pack my box with five dozen liquor jugs.';

/// The reading surface.
///
/// Laid out from the reference design (docs/10 ADR-017): a soft gradient
/// ground, chrome that floats over it as capsules, monospace instrumentation at
/// low contrast, and the text itself as the loudest thing on screen by a wide
/// margin.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController(text: _defaultText);

  List<Map<String, String>> _engines = [];
  String? _engineId;
  List<Map<String, Object?>> _voices = [];
  String? _voiceName;

  PipelineSettings _settings = const PipelineSettings();
  String? _presetId = 'natural';
  bool _speedViaEngine = true;

  bool _busy = false;
  String _status = '';
  _Run? _run;
  int _wordIndex = -1;

  PanelSection? _openPanel;
  late final AnimationController _panel = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _panelCurve =
      CurvedAnimation(parent: _panel, curve: Curves.easeOutCubic);

  static const String _targetLanguage = 'en';

  @override
  void initState() {
    super.initState();
    _loadEngines();
  }

  @override
  void dispose() {
    _panel.dispose();
    _textController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- platform

  Future<void> _loadEngines() async {
    try {
      final list = await _svc.engines();
      if (!mounted) return;
      setState(() {
        _engines = list;
        _engineId = _engines.isNotEmpty ? _engines.first['name'] : null;
      });
      await _loadVoices();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = 'No engines: ${e.message}');
    }
  }

  Future<void> _loadVoices() async {
    try {
      final list = await _svc.voices(_engineId);
      if (!mounted) return;
      setState(() {
        _voices = list;
        _voiceName =
            SpeechService.pickVoice(_voices, _targetLanguage)?['name'] as String?;
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = 'No voices: ${e.message}');
    }
  }

  Future<void> _speak() async {
    setState(() {
      _busy = true;
      _status = 'Synthesising';
      _wordIndex = -1;
    });

    try {
      final native = await _svc.synthesise(
        text: _textController.text,
        engineId: _engineId,
        voiceName: _voiceName,
        rate: _speedViaEngine ? _settings.speedScale : 1.0,
        pitch: SpeechService.semitonesToPitch(_settings.pitchSemitones),
      );

      final run = await _process(native);
      if (!mounted) return;
      setState(() {
        _run = run;
        _status = '';
      });
      await _play(run);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = '${e.code}: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_Run> _process(Map<String, Object?> native) async {
    final settings = _settings.copyWith(
      text: _textController.text,
      // Only one of the two applies the speed change, never both.
      speedScale: _speedViaEngine ? 1.0 : _settings.speedScale,
    );
    final out = await _svc.process(native, settings);
    return _Run(
      audio: out.audio,
      timings: out.timings,
      voice: out.voice,
      engine: out.engine,
    );
  }

  /// Always re-renders before playing.
  ///
  /// An earlier version cached the last exported path, so every play after the
  /// first replayed the same file and every settings change appeared to do
  /// nothing at all.
  Future<void> _play(_Run run) async {
    final dir = await _svc.outputDir();
    if (dir == null) return;
    final path = '$dir/preview.wav';
    await File(path).writeAsBytes(WavCodec.encodePcm16(run.audio));
    await _svc.play(path);
    unawaited(_followAlong(run));
  }

  /// Word highlighting driven by the timings, not by a timer guess.
  Future<void> _followAlong(_Run run) async {
    final rate = run.audio.sampleRate;
    final started = DateTime.now();
    while (mounted) {
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final frame = elapsed * rate ~/ 1000;
      if (frame > run.audio.frameCount) break;
      final i = run.timings.lastIndexWhere((t) => t.frameStart <= frame);
      if (i != _wordIndex) setState(() => _wordIndex = i);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (mounted) setState(() => _wordIndex = -1);
  }

  // ----------------------------------------------------------------- panel

  void _togglePanel(PanelSection s) {
    setState(() {
      if (_openPanel == s) {
        _openPanel = null;
        _panel.reverse();
      } else {
        _openPanel = s;
        _panel.forward();
      }
    });
  }

  void _applyPreset(SpeechPreset p) => setState(() {
        _settings = p.settings.copyWith(text: _textController.text);
        _presetId = p.id;
      });

  void _changeSettings(PipelineSettings s) => setState(() {
        _settings = s;
        _presetId = null; // any manual change means it is no longer a preset
      });

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final panelWidth = (media.size.width * 0.86).clamp(280.0, 420.0);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: Stack(
          children: [
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _topRow(context),
                    const SizedBox(height: 18),
                    _metadata(context),
                    Expanded(child: _stage(context)),
                    _navRow(context),
                    const SizedBox(height: 12),
                    _bottomBar(context),
                  ],
                ),
              ),
            ),
            _edgeTabs(context),
            _panelLayer(context, panelWidth),
          ],
        ),
      ),
    );
  }

  Widget _topRow(BuildContext context) => Row(
        children: [
          Capsule(
            onTap: () {},
            child: Text('Library', style: Skin.label(context)),
          ),
          const Spacer(),
          RoundButton(
              icon: Icons.bookmark_border_rounded,
              tooltip: 'Bookmark',
              onTap: () {}),
          const SizedBox(width: 8),
          RoundButton(
            icon: Icons.graphic_eq_rounded,
            tooltip: 'Voice',
            onTap: () => _togglePanel(PanelSection.voice),
          ),
          const SizedBox(width: 8),
          RoundButton(
            icon: Icons.tune_rounded,
            tooltip: 'Speech',
            onTap: () => _togglePanel(PanelSection.speech),
          ),
        ],
      );

  Widget _metadata(BuildContext context) {
    final v = _run?.voice ?? _voiceName ?? '—';
    final lines = [
      'VOICE: ${v.toUpperCase()}',
      'SPEED: ${_settings.speedScale.toStringAsFixed(2)}X'
          '  ${_speedViaEngine ? 'ENGINE' : 'DSP'}',
      'GAP: ${_settings.wordGapMs}MS'
          '   SENTENCE: ${_settings.sentencePauseMs}MS',
      if (_presetId != null) 'PRESET: ${_presetId!.toUpperCase()}',
      if (_status.isNotEmpty) 'STATUS: ${_status.toUpperCase()}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines) Text(l, style: Skin.meta(context)),
      ],
    );
  }

  /// The text, sized to fill the space and highlighted word by word.
  Widget _stage(BuildContext context) {
    final text = _textController.text;
    final timings = _run?.timings;

    return Center(
      child: LayoutBuilder(
        builder: (context, box) {
          final size = (box.maxHeight * 0.16).clamp(30.0, 58.0);
          if (timings == null || _wordIndex < 0) {
            return SingleChildScrollView(
              child: Text(text, style: Skin.display(context, size)),
            );
          }
          return SingleChildScrollView(
            child: RichText(
              text: TextSpan(
                style: Skin.display(context, size),
                children: [
                  for (var i = 0; i < timings.length; i++) ...[
                    TextSpan(
                      text: text.substring(
                        timings[i].charStart.clamp(0, text.length),
                        timings[i].charEnd.clamp(0, text.length),
                      ),
                      style: i == _wordIndex
                          ? TextStyle(
                              color: Skin.amber,
                              background: Paint()
                                ..color = Skin.amber.withValues(alpha: 0.14),
                            )
                          : null,
                    ),
                    const TextSpan(text: ' '),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _navRow(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RoundButton(
            icon: Icons.chevron_left_rounded,
            size: 44,
            color: Skin.isDark(context) ? null : Skin.cream,
            onTap: () {},
          ),
          const SizedBox(width: 10),
          RoundButton(
            icon: Icons.chevron_right_rounded,
            size: 44,
            color: Skin.isDark(context) ? null : Skin.cream,
            onTap: () {},
          ),
        ],
      );

  Widget _bottomBar(BuildContext context) => Row(
        children: [
          Expanded(
            child: Capsule(
              padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: Material(
                      color: Skin.darkOn(context),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _busy ? null : _speak,
                        child: Icon(
                          _busy
                              ? Icons.hourglass_empty_rounded
                              : Icons.play_arrow_rounded,
                          color: Skin.onDark(context),
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: Skin.label(context, size: 12.5),
                      maxLines: 1,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Text to read',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Capsule(
                    onTap: () => _togglePanel(PanelSection.voice),
                    border: false,
                    color: Skin.darkOn(context),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _shortVoice(),
                          style: Skin.label(context,
                              color: Skin.onDark(context), size: 10.5),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.keyboard_arrow_up_rounded,
                            size: 15, color: Skin.onDark(context)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  String _shortVoice() {
    final n = _voiceName;
    if (n == null || n.isEmpty) return 'voice';
    final parts = n.split('-');
    return parts.length >= 2 ? '${parts[0]}-${parts[1]}' : n;
  }

  /// The tabs the reference design puts on the right edge — half-hidden,
  /// rounded on the left, and the way into the panel.
  Widget _edgeTabs(BuildContext context) => Positioned(
        right: 0,
        top: MediaQuery.of(context).size.height * 0.22,
        child: Column(
          children: [
            _tab(context, Icons.auto_awesome_rounded, PanelSection.voice,
                Skin.darkOn(context), Skin.onDark(context)),
            const SizedBox(height: 8),
            _tab(context, Icons.text_fields_rounded, PanelSection.speech,
                Skin.amber, Skin.dark),
          ],
        ),
      );

  Widget _tab(BuildContext context, IconData icon, PanelSection section,
          Color bg, Color fg) =>
      Material(
        color: bg,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(14),
          bottomLeft: Radius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _togglePanel(section),
          child: SizedBox(
            width: 40,
            height: 46,
            child: Icon(icon, size: 19, color: fg),
          ),
        ),
      );

  Widget _panelLayer(BuildContext context, double width) {
    return AnimatedBuilder(
      animation: _panelCurve,
      builder: (context, _) {
        final t = _panelCurve.value;
        if (t == 0) return const SizedBox.shrink();
        return Stack(
          children: [
            // Scrim: dismiss by tapping the page, as the reference does.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: t < 0.5,
                child: GestureDetector(
                  onTap: () {
                    setState(() => _openPanel = null);
                    _panel.reverse();
                  },
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.28 * t),
                  ),
                ),
              ),
            ),
            Positioned(
              right: -width * (1 - t),
              top: 0,
              bottom: 0,
              width: width,
              child: SettingsPanel(
                section: _openPanel ?? PanelSection.speech,
                settings: _settings,
                onChanged: _changeSettings,
                onPreset: _applyPreset,
                activePresetId: _presetId,
                onClose: () {
                  setState(() => _openPanel = null);
                  _panel.reverse();
                },
                speedViaEngine: _speedViaEngine,
                onSpeedModeChanged: (v) => setState(() => _speedViaEngine = v),
                engines: _engines,
                engineId: _engineId,
                onEngineChanged: (v) {
                  setState(() => _engineId = v);
                  _loadVoices();
                },
                voices: _voices,
                voiceName: _voiceName,
                onVoiceChanged: (v) => setState(() => _voiceName = v),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Run {
  const _Run({
    required this.audio,
    required this.timings,
    required this.voice,
    required this.engine,
  });

  final AudioBuffer audio;
  final List<WordTiming> timings;
  final String voice;
  final String engine;
}

/// Kept so the batch measurement path still has a JSON shape to write.
String encodeReport(Map<String, Object?> m) =>
    const JsonEncoder.withIndent('  ').convert(m);
