import 'package:flutter/material.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'theme.dart';

/// The pop-out panel, driven by the tabs on the right edge.
///
/// It slides over the reading surface rather than pushing it aside, which is
/// what the reference design does: the page stays put and the panel arrives on
/// top of it. Every control here is wired to something that changes the audio —
/// a slider that does nothing is worse than no slider.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onPreset,
    required this.onClose,
    required this.speedViaEngine,
    required this.onSpeedModeChanged,
    required this.engines,
    required this.engineId,
    required this.onEngineChanged,
    required this.voices,
    required this.voiceName,
    required this.onVoiceChanged,
    required this.activePresetId,
    required this.section,
  });

  final PipelineSettings settings;
  final ValueChanged<PipelineSettings> onChanged;
  final ValueChanged<SpeechPreset> onPreset;
  final VoidCallback onClose;

  final bool speedViaEngine;
  final ValueChanged<bool> onSpeedModeChanged;

  final List<Map<String, String>> engines;
  final String? engineId;
  final ValueChanged<String?> onEngineChanged;

  final List<Map<String, Object?>> voices;
  final String? voiceName;
  final ValueChanged<String?> onVoiceChanged;

  final String? activePresetId;

  /// Which tab opened the panel, so it lands on the right section.
  final PanelSection section;

  @override
  Widget build(BuildContext context) {
    final onDark = Skin.onDark(context);

    return Material(
      color: Skin.darkOn(context),
      borderRadius: Skin.panelRadius,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, onDark),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 40),
                children: switch (section) {
                  PanelSection.voice => _voiceSection(context, onDark),
                  PanelSection.speech => _speechSection(context, onDark),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, Color onDark) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 14, 10),
        child: Row(
          children: [
            Text(
              section == PanelSection.voice ? 'VOICE' : 'SPEECH',
              style: Skin.meta(context,
                  color: onDark.withValues(alpha: 0.55), size: 11),
            ),
            const Spacer(),
            RoundButton(
              icon: Icons.close_rounded,
              size: 34,
              onTap: onClose,
              color: Colors.white.withValues(alpha: 0.08),
              iconColor: onDark,
              tooltip: 'Close',
            ),
          ],
        ),
      );

  // ---------------------------------------------------------------- voice

  List<Widget> _voiceSection(BuildContext context, Color onDark) => [
        _groupLabel(context, 'ENGINE', onDark),
        _picker<String>(
          context,
          onDark,
          value: engineId,
          items: [
            for (final e in engines)
              (
                value: e['name']!,
                label: (e['label'] ?? '').isEmpty ? e['name']! : e['label']!,
              ),
          ],
          onChanged: onEngineChanged,
        ),
        const SizedBox(height: 22),
        _groupLabel(context, 'VOICE  (${voices.length} AVAILABLE)', onDark),
        _picker<String>(
          context,
          onDark,
          value: voiceName,
          items: [
            for (final v in voices)
              (
                value: v['name'] as String,
                label: '${v['locale']}   q${v['quality']}'
                    '${v['networkRequired'] == true ? '   net' : ''}',
              ),
          ],
          onChanged: onVoiceChanged,
        ),
        const SizedBox(height: 10),
        Text(
          'Sorted best first, offline preferred. A voice in the wrong language '
          'beats nothing, but not by much — check the locale.',
          style: Skin.meta(context,
              color: onDark.withValues(alpha: 0.4), size: 9.5),
        ),
        const SizedBox(height: 26),
        _groupLabel(context, 'PITCH', onDark),
        _slider(
          context,
          onDark,
          label: 'Pitch',
          value: settings.pitchSemitones,
          min: -12,
          max: 12,
          unit: 'st',
          decimals: 1,
          onChanged: (v) => onChanged(settings.copyWith(pitchSemitones: v)),
        ),
        Text(
          'Applied by the engine. Neural voices expose no pitch control at all, '
          'so this will grey out for them until the DSP shifter lands.',
          style: Skin.meta(context,
              color: onDark.withValues(alpha: 0.4), size: 9.5),
        ),
      ];

  // --------------------------------------------------------------- speech

  List<Widget> _speechSection(BuildContext context, Color onDark) => [
        _groupLabel(context, 'PRESET', onDark),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in SpeechPreset.all)
              _presetChip(context, onDark, p),
          ],
        ),
        const SizedBox(height: 26),

        _groupLabel(context, 'PACE', onDark),
        _slider(
          context,
          onDark,
          label: 'Speed',
          value: settings.speedScale,
          min: 0.5,
          max: 3.0,
          unit: 'x',
          decimals: 2,
          onChanged: (v) => onChanged(settings.copyWith(speedScale: v)),
        ),
        _toggle(
          context,
          onDark,
          label: speedViaEngine ? 'via engine' : 'via DSP stub',
          detail: speedViaEngine
              ? 'Real duration change. Natural.'
              : 'Naive resampler — doubles pitch at 2x. Measurement only.',
          value: speedViaEngine,
          danger: !speedViaEngine,
          onChanged: onSpeedModeChanged,
        ),
        const SizedBox(height: 22),

        _groupLabel(context, 'SPACING', onDark),
        _slider(
          context,
          onDark,
          label: 'Word gap',
          value: settings.wordGapMs.toDouble(),
          min: 0,
          max: 500,
          unit: 'ms',
          onChanged: (v) => onChanged(settings.copyWith(wordGapMs: v.round())),
        ),
        Text(
          'Silence inserted between every word. No TTS engine offers this; it '
          'is why the audio pipeline exists.',
          style: Skin.meta(context,
              color: onDark.withValues(alpha: 0.4), size: 9.5),
        ),
        const SizedBox(height: 22),

        _groupLabel(context, 'PAUSES', onDark),
        _slider(context, onDark,
            label: 'Comma',
            value: settings.punctuation.commaMs.toDouble(),
            min: 0,
            max: 800,
            unit: 'ms',
            onChanged: (v) => onChanged(settings.copyWith(
                punctuation:
                    settings.punctuation.copyWith(commaMs: v.round())))),
        _slider(context, onDark,
            label: 'Clause  ;',
            value: settings.punctuation.clauseMs.toDouble(),
            min: 0,
            max: 800,
            unit: 'ms',
            onChanged: (v) => onChanged(settings.copyWith(
                punctuation:
                    settings.punctuation.copyWith(clauseMs: v.round())))),
        _slider(context, onDark,
            label: 'Colon  :',
            value: settings.punctuation.colonMs.toDouble(),
            min: 0,
            max: 800,
            unit: 'ms',
            onChanged: (v) => onChanged(settings.copyWith(
                punctuation:
                    settings.punctuation.copyWith(colonMs: v.round())))),
        _slider(context, onDark,
            label: 'Dash  —',
            value: settings.punctuation.dashMs.toDouble(),
            min: 0,
            max: 800,
            unit: 'ms',
            onChanged: (v) => onChanged(settings.copyWith(
                punctuation:
                    settings.punctuation.copyWith(dashMs: v.round())))),
        _slider(context, onDark,
            label: 'Ellipsis  …',
            value: settings.punctuation.ellipsisMs.toDouble(),
            min: 0,
            max: 1200,
            unit: 'ms',
            onChanged: (v) => onChanged(settings.copyWith(
                punctuation:
                    settings.punctuation.copyWith(ellipsisMs: v.round())))),
        _slider(context, onDark,
            label: 'Sentence',
            value: settings.sentencePauseMs.toDouble(),
            min: 0,
            max: 2000,
            unit: 'ms',
            onChanged: (v) =>
                onChanged(settings.copyWith(sentencePauseMs: v.round()))),
        _slider(context, onDark,
            label: 'Paragraph',
            value: settings.paragraphPauseMs.toDouble(),
            min: 0,
            max: 3000,
            unit: 'ms',
            onChanged: (v) =>
                onChanged(settings.copyWith(paragraphPauseMs: v.round()))),
        const SizedBox(height: 22),

        _groupLabel(context, 'SOUND', onDark),
        _slider(context, onDark,
            label: 'Volume',
            value: settings.volume,
            min: 0,
            max: 1,
            unit: '',
            decimals: 2,
            onChanged: (v) => onChanged(settings.copyWith(volume: v))),
        _slider(context, onDark,
            label: 'Voice trim',
            value: settings.trimDb,
            min: -12,
            max: 12,
            unit: 'dB',
            decimals: 1,
            onChanged: (v) => onChanged(settings.copyWith(trimDb: v))),
        _toggle(
          context,
          onDark,
          label: 'Level voices',
          detail: 'Open voices differ by over 10 dB. Keeps them comparable.',
          value: settings.normaliseLoudness,
          onChanged: (v) => onChanged(settings.copyWith(normaliseLoudness: v)),
        ),
        const SizedBox(height: 6),
        _segmented(
          context,
          onDark,
          label: 'Compression',
          options: const ['off', 'light', 'strong'],
          index: settings.compression.index,
          onChanged: (i) =>
              onChanged(settings.copyWith(compression: Compression.values[i])),
        ),
      ];

  // --------------------------------------------------------------- pieces

  Widget _groupLabel(BuildContext context, String text, Color onDark) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: Skin.meta(context,
              color: onDark.withValues(alpha: 0.38), size: 9.5),
        ),
      );

  Widget _presetChip(BuildContext context, Color onDark, SpeechPreset p) {
    final active = p.id == activePresetId;
    return Capsule(
      onTap: () => onPreset(p),
      border: false,
      color: active ? Skin.amber : Colors.white.withValues(alpha: 0.07),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Text(
        p.label,
        style: Skin.label(
          context,
          color: active ? Skin.dark : onDark.withValues(alpha: 0.85),
          weight: active ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
  }

  Widget _slider(
    BuildContext context,
    Color onDark, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String unit,
    required ValueChanged<double> onChanged,
    int decimals = 0,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label,
                    style: Skin.label(context,
                        color: onDark.withValues(alpha: 0.75))),
                Text(
                  '${value.toStringAsFixed(decimals)}$unit',
                  style: Skin.label(context,
                      color: Skin.amberSoft, weight: FontWeight.w700),
                ),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                activeTrackColor: Skin.amber,
                inactiveTrackColor: onDark.withValues(alpha: 0.14),
                thumbColor: Skin.amberSoft,
                overlayColor: Skin.amber.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      );

  Widget _toggle(
    BuildContext context,
    Color onDark, {
    required String label,
    required String detail,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool danger = false,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: Skin.label(context,
                          color: danger
                              ? Skin.amber
                              : onDark.withValues(alpha: 0.75))),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: Skin.meta(context,
                          color: onDark.withValues(alpha: 0.38), size: 9)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Skin.amber,
            ),
          ],
        ),
      );

  Widget _segmented(
    BuildContext context,
    Color onDark, {
    required String label,
    required List<String> options,
    required int index,
    required ValueChanged<int> onChanged,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  Skin.label(context, color: onDark.withValues(alpha: 0.75))),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                Capsule(
                  onTap: () => onChanged(i),
                  border: false,
                  color: i == index
                      ? Skin.amber
                      : Colors.white.withValues(alpha: 0.07),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                    options[i],
                    style: Skin.label(
                      context,
                      color: i == index
                          ? Skin.dark
                          : onDark.withValues(alpha: 0.8),
                      weight:
                          i == index ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      );

  Widget _picker<T>(
    BuildContext context,
    Color onDark, {
    required T? value,
    required List<({T value, String label})> items,
    required ValueChanged<T?> onChanged,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            dropdownColor: Skin.darkSoft,
            iconEnabledColor: onDark.withValues(alpha: 0.6),
            style: Skin.label(context, color: onDark),
            items: [
              for (final i in items)
                DropdownMenuItem<T>(
                  value: i.value,
                  child: Text(i.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged,
          ),
        ),
      );
}

enum PanelSection { voice, speech }
