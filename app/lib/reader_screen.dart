import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'brand.dart';
import 'scheduler.dart';
import 'settings_panel.dart';
import 'speech_service.dart';
import 'theme.dart';

const _svc = SpeechService();

/// The reading surface.
///
/// Laid out from the reference design (docs/10 ADR-017): a soft gradient
/// ground, chrome that floats over it as capsules, monospace instrumentation at
/// low contrast, and the text itself as the loudest thing on screen by a wide
/// margin. The text is the current sentence of a real [Book], not a pasted blob.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    this.store,
    this.initialCursor = ReadingCursor.zero,
  });

  final Book book;
  final LibraryStore? store;
  final ReadingCursor initialCursor;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with SingleTickerProviderStateMixin {
  late final List<Speakable> _units = flattenSpeakable(widget.book);
  late int _unitIndex;

  List<Map<String, String>> _engines = [];
  String? _engineId;
  List<Map<String, Object?>> _voices = [];
  String? _voiceName;

  PipelineSettings _settings = const PipelineSettings();
  String? _presetId = 'natural';
  bool _speedViaEngine = true;

  String _status = '';
  List<WordTiming> _timings = const [];
  int _wordIndex = -1;

  PlaybackScheduler? _scheduler;
  int _playEpoch = 0;

  PanelSection? _openPanel;
  late final AnimationController _panel = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _panelCurve =
      CurvedAnimation(parent: _panel, curve: Curves.easeOutCubic);

  String get _targetLanguage {
    final lang = widget.book.metadata.language ?? 'en';
    return lang.length >= 2 ? lang.substring(0, 2).toLowerCase() : 'en';
  }

  Speakable? get _current =>
      _units.isEmpty ? null : _units[_unitIndex.clamp(0, _units.length - 1)];

  @override
  void initState() {
    super.initState();
    _unitIndex = _units.isEmpty
        ? 0
        : indexOfCursor(_units, widget.initialCursor);
    _loadEngines();
  }

  @override
  void dispose() {
    _playEpoch++;
    unawaited(_scheduler?.stop());
    _panel.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    final store = widget.store;
    final unit = _current;
    if (store == null || unit == null) return;
    await store.saveCursor(
      widget.book.id,
      cursorOf(unit),
      progressFraction(_units, _unitIndex),
    );
  }

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
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final list = await _svc.voices(_engineId);
        if (!mounted) return;
        if (list.isEmpty && attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          continue;
        }
        setState(() {
          _voices = list;
          _voiceName =
              SpeechService.pickVoice(_voices, _targetLanguage)?['name']
                  as String?;
        });
        return;
      } on PlatformException catch (e) {
        if (attempt == 1 && mounted) {
          setState(() => _status = 'No voices: ${e.message}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
  }

  PipelineSettings _settingsFor(String text) => _settings.copyWith(
        text: text,
        speedScale: _speedViaEngine ? 1.0 : _settings.speedScale,
      );

  Future<void> _togglePlay() async {
    if (_scheduler?.running == true) {
      await _scheduler?.stop();
      if (mounted) setState(() {});
      return;
    }
    if (_units.isEmpty) return;
    final epoch = ++_playEpoch;
    bool live() => mounted && epoch == _playEpoch;
    final scheduler = PlaybackScheduler(
      service: _svc,
      units: _units,
      settingsFor: _settingsFor,
      engineIdOf: () => _engineId,
      voiceNameOf: () => _voiceName,
      speedViaEngineOf: () => _speedViaEngine,
      onUnit: (i, _) {
        if (!live()) return;
        setState(() {
          _unitIndex = i;
          _wordIndex = -1;
          _timings = const [];
        });
        unawaited(_persist());
      },
      onTimings: (t) {
        if (live()) setState(() => _timings = t);
      },
      onWord: (w) {
        if (live()) setState(() => _wordIndex = w);
      },
      onStatus: (s) {
        if (live()) setState(() => _status = s);
      },
      onFinished: () {
        if (live()) setState(() {});
      },
    );
    _scheduler = scheduler;
    try {
      await scheduler.start(_unitIndex);
    } on PlatformException catch (e) {
      if (live()) setState(() => _status = '${e.code}: ${e.message}');
    } catch (e) {
      if (live()) setState(() => _status = '$e');
    } finally {
      if (live()) setState(() {});
    }
  }

  void _goUnit(int delta) {
    if (_units.isEmpty) return;
    final next = (_unitIndex + delta).clamp(0, _units.length - 1);
    if (next == _unitIndex) return;
    setState(() {
      _unitIndex = next;
      _wordIndex = -1;
      _timings = const [];
    });
    unawaited(_persist());
    if (_scheduler?.running == true) {
      unawaited(_restartFromHere());
    }
  }

  void _goSection(int sectionIndex) {
    if (_units.isEmpty) return;
    final i = _units.indexWhere((u) => u.sectionIndex == sectionIndex);
    if (i < 0) return;
    setState(() {
      _unitIndex = i;
      _wordIndex = -1;
      _timings = const [];
    });
    unawaited(_persist());
    if (_scheduler?.running == true) {
      unawaited(_restartFromHere());
    }
  }

  void _openToc() {
    final speakable = {for (final u in _units) u.sectionIndex};
    final toc = [
      for (final t in widget.book.toc.isNotEmpty
          ? widget.book.toc
          : [
              for (final s in widget.book.sections)
                TocEntry(title: s.displayTitle, sectionIndex: s.index),
            ])
        if (speakable.contains(t.sectionIndex)) t,
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Skin.darkOn(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final onDark = Skin.onDark(context);
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
            children: [
              Text('SECTIONS',
                  style: Skin.meta(context,
                      color: onDark.withValues(alpha: 0.55), size: 11)),
              const SizedBox(height: 12),
              if (toc.isEmpty)
                Text(
                  'No speakable sections in this file.',
                  style: Skin.label(context,
                      color: onDark.withValues(alpha: 0.7), size: 13),
                ),
              for (final t in toc)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Capsule(
                    onTap: () {
                      Navigator.pop(ctx);
                      _goSection(t.sectionIndex);
                    },
                    color: Colors.white.withValues(alpha: 0.07),
                    border: false,
                    radius: const BorderRadius.all(Radius.circular(16)),
                    child: Text(
                      t.title,
                      style: Skin.label(context, color: onDark, size: 13),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _restartFromHere() async {
    await _scheduler?.stop();
    await _togglePlay();
  }

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
        _settings = p.settings.copyWith(text: _current?.text ?? '');
        _presetId = p.id;
        _scheduler?.invalidateLookahead();
      });

  void _changeSettings(PipelineSettings s) => setState(() {
        _settings = s;
        _presetId = null;
        _scheduler?.invalidateLookahead();
      });

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
                padding: const EdgeInsets.fromLTRB(18, 10, 52, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _topRow(context),
                    const SizedBox(height: 12),
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
          const BrandMark(size: 22),
          const SizedBox(width: 8),
          Capsule(
            onTap: () => Navigator.of(context).maybePop(),
            child: Text('Library', style: Skin.label(context)),
          ),
          const Spacer(),
          RoundButton(
            icon: Icons.list_rounded,
            tooltip: 'Sections',
            onTap: _openToc,
          ),
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
    final v = _voiceName ?? '—';
    final section = widget.book.sections.isEmpty
        ? ''
        : widget.book.sections[
                (_current?.sectionIndex ?? 0)
                    .clamp(0, widget.book.sections.length - 1)]
            .displayTitle;
    final pct = (progressFraction(_units, _unitIndex) * 100).round();
    final lines = [
      [
        widget.book.metadata.title.toUpperCase(),
        if (section.isNotEmpty) section.toUpperCase(),
        '$pct%',
      ].join('  ·  '),
      [
        'VOICE: ${v.toUpperCase()}',
        'SPEED: ${_settings.speedScale.toStringAsFixed(2)}X',
        _speedViaEngine ? 'ENGINE' : 'DSP',
        'GAP: ${_settings.wordGapMs}MS',
        if (_presetId != null) 'PRESET: ${_presetId!.toUpperCase()}',
      ].join('  ·  '),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Text(
            l,
            style: Skin.meta(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Widget _stage(BuildContext context) {
    final unit = _current;
    final text = unit?.text ?? 'This file has no speakable text.';
    final timings = _timings;

    return Center(
      child: LayoutBuilder(
        builder: (context, box) {
          final size = (box.maxHeight * 0.18).clamp(28.0, 52.0);
          final style = Skin.display(context, size);
          return SingleChildScrollView(
            child: timings.isEmpty || _wordIndex < 0
                ? Text(text, style: style)
                : _highlighted(text, timings, _wordIndex, style),
          );
        },
      ),
    );
  }

  /// Keep characters the engine didn't mark, so a missed range doesn't
  /// swallow the rest of the sentence.
  Widget _highlighted(
    String text,
    List<WordTiming> timings,
    int wordIndex,
    TextStyle base,
  ) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < timings.length; i++) {
      final start = timings[i].charStart.clamp(0, text.length);
      final end = timings[i].charEnd.clamp(0, text.length);
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      if (end > start) {
        spans.add(TextSpan(
          text: text.substring(start, end),
          style: i == wordIndex
              ? TextStyle(
                  color: Skin.amber,
                  background: Paint()
                    ..color = Skin.amber.withValues(alpha: 0.14),
                )
              : null,
        ));
      }
      if (end > cursor) cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return RichText(text: TextSpan(style: base, children: spans));
  }

  Widget _navRow(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RoundButton(
            icon: Icons.chevron_left_rounded,
            size: 44,
            color: Skin.disc(context),
            tooltip: 'Previous sentence',
            onTap: () => _goUnit(-1),
          ),
          const SizedBox(width: 10),
          RoundButton(
            icon: Icons.chevron_right_rounded,
            size: 44,
            color: Skin.disc(context),
            tooltip: 'Next sentence',
            onTap: () => _goUnit(1),
          ),
        ],
      );

  Widget _bottomBar(BuildContext context) {
    final playing = _scheduler?.running == true;
    final empty = _units.isEmpty;
    final pos = empty ? '0 / 0' : '${_unitIndex + 1} / ${_units.length}';
    final status = _status.trim();
    return Row(
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
                    color: Skin.darkOn(context)
                        .withValues(alpha: empty ? 0.45 : 1),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: empty ? null : _togglePlay,
                      child: Tooltip(
                        message: playing ? 'Stop' : 'Play',
                        child: Icon(
                          playing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          color: Skin.onDark(context),
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        pos,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.label(context, size: 12.5),
                      ),
                      Text(
                        status.isEmpty ? ' ' : status.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.meta(context, color: Skin.amber, size: 8),
                      ),
                    ],
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
  }

  String _shortVoice() {
    final n = _voiceName;
    if (n == null || n.isEmpty) return 'voice';
    final parts = n.split('-');
    return parts.length >= 2 ? '${parts[0]}-${parts[1]}' : n;
  }

  Widget _edgeTabs(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      right: 0,
      top: media.padding.top + 56,
      bottom: media.padding.bottom + 96,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tab(context, Icons.auto_awesome_rounded, PanelSection.voice,
                Skin.darkOn(context), Skin.onDark(context)),
            const SizedBox(height: 8),
            _tab(context, Icons.text_fields_rounded, PanelSection.speech,
                Skin.amber, Skin.dark),
          ],
        ),
      ),
    );
  }

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
            width: 34,
            height: 40,
            child: Icon(icon, size: 17, color: fg),
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
                onSpeedModeChanged: (v) {
                  setState(() => _speedViaEngine = v);
                  _scheduler?.invalidateLookahead();
                },
                engines: _engines,
                engineId: _engineId,
                onEngineChanged: (v) {
                  setState(() => _engineId = v);
                  _scheduler?.invalidateLookahead();
                  _loadVoices();
                },
                voices: _voices,
                voiceName: _voiceName,
                onVoiceChanged: (v) {
                  setState(() => _voiceName = v);
                  _scheduler?.invalidateLookahead();
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Kept so the batch measurement path still has a JSON shape to write.
String encodeReport(Map<String, Object?> m) =>
    const JsonEncoder.withIndent('  ').convert(m);
