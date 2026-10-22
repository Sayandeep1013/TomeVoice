import 'package:flutter/material.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'prefs.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'voices.dart';

enum ListenFocus { all, speed }

/// What the sheet edits, and how the reader hears about it.
/// When reading should stop on its own.
enum SleepChoice { off, min15, min30, min60, chapterEnd }

class ListenController {
  ListenController({
    required this.prefs,
    required this.language,
    required this.onChanged,
    this.sleep = SleepChoice.off,
    this.onSleep,
  });

  final ListeningPrefs prefs;

  /// The book's language; voices are offered for this first.
  final String language;

  /// Settings changed. [restart] is true when the change should be audible
  /// now (voice, speed, style), false while a slider is still being dragged.
  final void Function({required bool restart}) onChanged;

  /// The sleep timer as it is now, and how to change it.
  final SleepChoice sleep;
  final ValueChanged<SleepChoice>? onSleep;

  String? get voiceName {
    final chosen = prefs.voiceByLanguage[language];
    final catalog = VoiceCatalog.instance;
    if (chosen != null && catalog.byName(chosen) != null) return chosen;
    return catalog.bestFor(language)?.name;
  }
}

Future<void> showListenSheet(
  BuildContext context,
  ListenController controller, {
  ListenFocus focus = ListenFocus.all,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Skin.darkOn(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _ListenSheet(controller: controller, focus: focus),
    );

class _ListenSheet extends StatefulWidget {
  const _ListenSheet({required this.controller, required this.focus});

  final ListenController controller;
  final ListenFocus focus;

  @override
  State<_ListenSheet> createState() => _ListenSheetState();
}

class _ListenSheetState extends State<_ListenSheet> {
  final _catalog = VoiceCatalog.instance;
  String? _browse;
  late SleepChoice _sleep = widget.controller.sleep;

  ListeningPrefs get _prefs => widget.controller.prefs;
  PipelineSettings get _s => _prefs.settings;

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_refresh);
  }

  @override
  void dispose() {
    _catalog.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _set(PipelineSettings next, {required bool restart, bool custom = true}) {
    setState(() {
      _prefs.settings = next;
      if (custom) _prefs.presetId = null;
    });
    _prefs.save();
    widget.controller.onChanged(restart: restart);
  }

  @override
  Widget build(BuildContext context) {
    final onDark = Skin.onDark(context);
    final speedOnly = widget.focus == ListenFocus.speed;
    final maxHeight = MediaQuery.sizeOf(context).height * (speedOnly ? 0.45 : 0.86);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: onDark.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          ..._speed(context, onDark),
          if (!speedOnly) ...[
            const SizedBox(height: 26),
            ..._sleepTimer(context, onDark),
            const SizedBox(height: 26),
            ..._voice(context, onDark),
            const SizedBox(height: 26),
            ..._style(context, onDark),
            const SizedBox(height: 26),
            ..._display(context, onDark),
            const SizedBox(height: 14),
            _fineTune(context, onDark),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- speed

  List<Widget> _speed(BuildContext context, Color onDark) => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('Speed', style: Skin.title(context, size: 22, color: onDark)),
            const Spacer(),
            Text(
              '${_trim(_s.speedScale)}×',
              style: Skin.label(context, color: Skin.amberSoft, size: 18, weight: FontWeight.w700),
            ),
          ],
        ),
        _slider(
          context,
          onDark,
          value: _s.speedScale,
          min: 0.5,
          max: 3.0,
          divisions: 50,
          semantics: 'Speed',
          onChanged: (v) => _set(_s.copyWith(speedScale: v), restart: false, custom: false),
          onChangeEnd: (v) => _set(_s.copyWith(speedScale: v), restart: true, custom: false),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in const [0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
              _chip(
                context,
                onDark,
                label: '${_trim(v)}×',
                selected: (_s.speedScale - v).abs() < 0.01,
                onTap: () => _set(_s.copyWith(speedScale: v), restart: true, custom: false),
              ),
          ],
        ),
      ];

  // ---------------------------------------------------------- sleep timer

  List<Widget> _sleepTimer(BuildContext context, Color onDark) {
    const labels = {
      SleepChoice.off: 'Off',
      SleepChoice.min15: '15 min',
      SleepChoice.min30: '30 min',
      SleepChoice.min60: '1 hour',
      SleepChoice.chapterEnd: 'End of chapter',
    };
    return [
      Text('Sleep timer', style: Skin.title(context, size: 22, color: onDark)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in labels.entries)
            _chip(
              context,
              onDark,
              label: e.value,
              selected: _sleep == e.key,
              onTap: () {
                setState(() => _sleep = e.key);
                widget.controller.onSleep?.call(e.key);
              },
            ),
        ],
      ),
    ];
  }

  // -------------------------------------------------------------- display

  List<Widget> _display(BuildContext context, Color onDark) => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('Text size', style: Skin.title(context, size: 22, color: onDark)),
            const Spacer(),
            Text('Aa',
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: _prefs.textSize,
                  color: Skin.amberSoft,
                )),
          ],
        ),
        _slider(
          context,
          onDark,
          value: _prefs.textSize,
          min: 14,
          max: 30,
          divisions: 16,
          semantics: 'Text size',
          onChanged: (v) {
            setState(() => _prefs.textSize = v);
            widget.controller.onChanged(restart: false);
          },
          onChangeEnd: (v) {
            _prefs.save();
            widget.controller.onChanged(restart: false);
          },
        ),
      ];

  // ---------------------------------------------------------------- voice

  List<Widget> _voice(BuildContext context, Color onDark) {
    final lang = widget.controller.language;
    final browsing = _browse;
    final showing = browsing == null || browsing.isEmpty ? lang : browsing;
    final selected = widget.controller.voiceName;
    // The voice in use first, so it is on screen when the sheet opens.
    final voices = [..._catalog.forLanguage(showing)]
      ..sort((a, b) => (b.name == selected ? 1 : 0) - (a.name == selected ? 1 : 0));
    return [
      Row(
        children: [
          Text('Voice', style: Skin.title(context, size: 22, color: onDark)),
          const Spacer(),
          Text(
            'BOOK: ${languageName(lang).toUpperCase()}',
            style: Skin.meta(context, color: onDark.withValues(alpha: 0.5), size: 9),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (!_catalog.loaded)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('Loading voices…',
              style: Skin.label(context, color: onDark.withValues(alpha: 0.6))),
        )
      else if (voices.isEmpty)
        _noVoices(context, onDark, showing)
      else
        for (final v in voices)
          _voiceRow(context, onDark, v, selected: v.name == selected),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _chip(
            context,
            onDark,
            label: _browse == null ? 'Other languages' : 'Back to ${languageName(lang)}',
            selected: false,
            onTap: () => setState(() => _browse = _browse == null ? '' : null),
          ),
          if (_browse != null)
            for (final l in _catalog.languages())
              if (l != lang)
                _chip(
                  context,
                  onDark,
                  label: languageName(l),
                  selected: _browse == l,
                  onTap: () => setState(() => _browse = l),
                ),
        ],
      ),
      if (_catalog.engines.length > 1) ...[
        const SizedBox(height: 16),
        Text('ENGINE', style: Skin.meta(context, color: onDark.withValues(alpha: 0.45))),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _catalog.engines)
              _chip(
                context,
                onDark,
                label: (e['label'] ?? '').isEmpty ? e['name']! : e['label']!,
                selected: e['name'] == _catalog.engineId,
                onTap: () async {
                  _prefs.engineId = e['name'];
                  _prefs.save();
                  await _catalog.switchEngine(e['name']!);
                  widget.controller.onChanged(restart: true);
                },
              ),
          ],
        ),
      ],
    ];
  }

  Widget _noVoices(BuildContext context, Color onDark, String lang) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No ${languageName(lang)} voice on this phone yet.',
              style: Skin.label(context, color: onDark, size: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Install one in the speech settings (Speech Services by Google → '
              'Install voice data), then come back.',
              style: Skin.meta(context, color: onDark.withValues(alpha: 0.6), size: 9.5),
            ),
            const SizedBox(height: 10),
            _chip(
              context,
              onDark,
              label: 'Open speech settings',
              selected: true,
              onTap: () => const SpeechService().openTtsSettings(),
            ),
          ],
        ),
      );

  Widget _voiceRow(BuildContext context, Color onDark, VoiceInfo v, {required bool selected}) {
    final badges = [
      if (!v.installed) 'DOWNLOADS ON FIRST USE' else if (v.networkRequired) 'NEEDS INTERNET' else 'WORKS OFFLINE',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? Skin.amber.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() => _prefs.voiceByLanguage[widget.controller.language] = v.name);
            _prefs.save();
            widget.controller.onChanged(restart: true);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  size: 20,
                  color: selected ? Skin.amber : onDark.withValues(alpha: 0.45),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${v.languageLabel} · ${v.variant}',
                        style: Skin.label(context, color: onDark, size: 13),
                      ),
                      Text(
                        badges.join('  ·  '),
                        style: Skin.meta(context, color: onDark.withValues(alpha: 0.5), size: 8.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- style

  List<Widget> _style(BuildContext context, Color onDark) {
    final active = SpeechPreset.all.where((p) => p.id == _prefs.presetId).firstOrNull;
    return [
      Text('Style', style: Skin.title(context, size: 22, color: onDark)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in SpeechPreset.all)
            _chip(
              context,
              onDark,
              label: p.label,
              selected: p.id == _prefs.presetId,
              onTap: () {
                setState(() {
                  // Keep the listener's speed unless the preset is about pace.
                  _prefs.settings = p.settings;
                  _prefs.presetId = p.id;
                });
                _prefs.save();
                widget.controller.onChanged(restart: true);
              },
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        active?.description ?? 'Custom — adjusted below.',
        style: Skin.meta(context, color: onDark.withValues(alpha: 0.55), size: 9.5),
      ),
    ];
  }

  // ------------------------------------------------------------ fine-tune

  Widget _fineTune(BuildContext context, Color onDark) {
    Widget row(String label, double value, double min, double max, String unit,
            PipelineSettings Function(double) apply,
            {int decimals = 0}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label, style: Skin.label(context, color: onDark.withValues(alpha: 0.8))),
                const Spacer(),
                Text(
                  '${value.toStringAsFixed(decimals)}$unit',
                  style: Skin.label(context, color: Skin.amberSoft, weight: FontWeight.w700),
                ),
              ],
            ),
            _slider(
              context,
              onDark,
              value: value,
              min: min,
              max: max,
              semantics: label,
              onChanged: (v) => _set(apply(v), restart: false),
              onChangeEnd: (v) => _set(apply(v), restart: true),
            ),
          ],
        );

    final p = _s.punctuation;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        iconColor: onDark,
        collapsedIconColor: onDark.withValues(alpha: 0.6),
        title: Text('Fine-tune', style: Skin.title(context, size: 22, color: onDark)),
        subtitle: Text(
          'Pitch, word spacing, pauses and loudness',
          style: Skin.meta(context, color: onDark.withValues(alpha: 0.5), size: 9.5),
        ),
        children: [
          row('Pitch', _s.pitchSemitones, -12, 12, ' st',
              (v) => _s.copyWith(pitchSemitones: v), decimals: 1),
          row('Space between words', _s.wordGapMs.toDouble(), 0, 500, ' ms',
              (v) => _s.copyWith(wordGapMs: v.round())),
          row('Pause at commas', p.commaMs.toDouble(), 0, 800, ' ms',
              (v) => _s.copyWith(punctuation: p.copyWith(commaMs: v.round()))),
          row('Pause between sentences', _s.sentencePauseMs.toDouble(), 0, 2000, ' ms',
              (v) => _s.copyWith(sentencePauseMs: v.round())),
          row('Pause between paragraphs', _s.paragraphPauseMs.toDouble(), 0, 3000, ' ms',
              (v) => _s.copyWith(paragraphPauseMs: v.round())),
          row('Volume', _s.volume, 0, 1, '', (v) => _s.copyWith(volume: v), decimals: 2),
          Row(
            children: [
              Expanded(
                child: Text('Even out loudness',
                    style: Skin.label(context, color: onDark.withValues(alpha: 0.8))),
              ),
              Switch(
                value: _s.normaliseLoudness,
                onChanged: (v) => _set(_s.copyWith(normaliseLoudness: v), restart: true),
                thumbColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? Skin.amber
                      : onDark.withValues(alpha: 0.7),
                ),
                trackColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? Skin.amber.withValues(alpha: 0.45)
                      : onDark.withValues(alpha: 0.18),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- pieces

  Widget _chip(
    BuildContext context,
    Color onDark, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Capsule(
        onTap: onTap,
        border: false,
        color: selected ? Skin.amber : Colors.white.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(
          label,
          style: Skin.label(
            context,
            color: selected ? Skin.dark : onDark.withValues(alpha: 0.9),
            weight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      );

  Widget _slider(
    BuildContext context,
    Color onDark, {
    required double value,
    required double min,
    required double max,
    required String semantics,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    int? divisions,
  }) =>
      SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          activeTrackColor: Skin.amber,
          inactiveTrackColor: onDark.withValues(alpha: 0.14),
          thumbColor: Skin.amberSoft,
          overlayColor: Skin.amber.withValues(alpha: 0.12),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
          tickMarkShape: SliderTickMarkShape.noTickMark,
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          semanticFormatterCallback: (v) => '$semantics ${v.toStringAsFixed(2)}',
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      );
}

String _trim(double v) {
  final s = v.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}
