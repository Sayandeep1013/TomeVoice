import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'book_tint.dart';
import 'book_tint.dart';
import 'neural_screen.dart';
import 'neural_voices.dart';
import 'prefs.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

enum ListenFocus { all, speed }

/// When reading should stop on its own.
enum SleepChoice { off, min15, min30, min60, chapterEnd }

/// What the sheet edits, and how the reader hears about it.
class ListenController {
  ListenController({
    required this.prefs,
    required this.language,
    required this.onChanged,
    this.bookId,
    this.sleep = SleepChoice.off,
    this.onSleep,
    this.onPreview,
    this.isPlaying,
    this.isPdf = false,
  });

  final ListeningPrefs prefs;

  /// The book's language; voices are offered for this first.
  final String language;

  /// The book whose voice this is, if a book is open.
  final String? bookId;

  /// Settings changed. [restart] is true when the change should be audible
  /// now (voice, speed, style), false while a slider is still being dragged.
  final void Function({required bool restart}) onChanged;

  /// The sleep timer as it is now, and how to change it.
  final SleepChoice sleep;
  final ValueChanged<SleepChoice>? onSleep;

  /// Say a short sample in the named voice.
  final Future<void> Function(String voiceName)? onPreview;

  /// Whether the book is being read aloud right now. A change is then heard
  /// in the book itself, so no sample is played over it.
  final bool Function()? isPlaying;

  /// The book is a PDF, so the page view can be offered.
  final bool isPdf;

  Timer? _sampleTimer;

  /// The book's own voice, else the one for its language, else the best
  /// installed voice for that language.
  String? get voiceName {
    final catalog = VoiceCatalog.instance;
    for (final chosen in [
      if (bookId != null) prefs.voiceByBook[bookId],
      prefs.voiceByLanguage[language],
    ]) {
      if (chosen != null && catalog.byName(chosen) != null) return chosen;
    }
    return catalog.bestFor(language)?.name;
  }

  /// Use [name] for this book, and as the default for its language.
  void chooseVoice(String name) {
    if (bookId != null) prefs.voiceByBook[bookId!] = name;
    prefs.voiceByLanguage[language] = name;
    prefs.save();
    onChanged(restart: true);
  }

  /// The voice dialogue is read in, when this book has its own for it.
  String? get dialogueVoice {
    final chosen = bookId == null ? null : prefs.dialogueByBook[bookId];
    return chosen != null && VoiceCatalog.instance.byName(chosen) != null && chosen != voiceName ? chosen : null;
  }

  /// Read this book's dialogue in [name], or in the narrator's voice (null).
  void chooseDialogueVoice(String? name) {
    final id = bookId;
    if (id == null) return;
    if (name == null) {
      prefs.dialogueByBook.remove(id);
    } else {
      prefs.dialogueByBook[id] = name;
    }
    prefs.save();
    onChanged(restart: true);
  }

  bool get playing => isPlaying?.call() ?? false;

  /// A setting you can hear changed (speed, style, pitch, pauses). While the
  /// book plays it restarts from the current sentence; otherwise a short
  /// sample is said a moment after the last change, so a slider being dragged
  /// is heard once, where it stopped.
  void changedAudibly() {
    onChanged(restart: true);
    final preview = onPreview;
    final voice = voiceName;
    if (playing || preview == null || voice == null) return;
    _sampleTimer?.cancel();
    _sampleTimer = Timer(const Duration(milliseconds: 650), () => preview(voice));
  }
}

/// The reader's settings: a Listen tab (speed, sleep timer, voice, style,
/// fine-tune) and a Read tab (how the page looks).
Future<void> showListenSheet(
  BuildContext context,
  ListenController controller, {
  ListenFocus focus = ListenFocus.all,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => carryTint(context, _ReaderSettingsSheet(controller: controller, focus: focus)),
    );

class _ReaderSettingsSheet extends StatefulWidget {
  const _ReaderSettingsSheet({required this.controller, required this.focus});

  final ListenController controller;
  final ListenFocus focus;

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  final _catalog = VoiceCatalog.instance;
  late SleepChoice _sleep = widget.controller.sleep;
  int _tab = 0;
  bool _fineTune = false;

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
    if (restart) {
      widget.controller.changedAudibly();
    } else {
      widget.controller.onChanged(restart: false);
    }
  }

  void _speedChanged({required bool restart}) =>
      restart ? widget.controller.changedAudibly() : widget.controller.onChanged(restart: false);

  @override
  Widget build(BuildContext context) {
    final speedOnly = widget.focus == ListenFocus.speed;
    final height = MediaQuery.sizeOf(context).height;
    final children = speedOnly
        ? [
            const SectionTitle('Speed'),
            const SizedBox(height: Gap.m),
            SpeedControl(prefs: _prefs, onChanged: _speedChanged),
          ]
        : [
            ChoiceRow<int>(
              options: const [(0, 'Listen'), (1, 'Read')],
              value: _tab,
              onChanged: (t) => setState(() => _tab = t),
            ),
            const SizedBox(height: Gap.xl),
            // A fade-through: one tab's settings fade away, then the other's
            // fade in, drifting from the side of the tab that was tapped.
            AnimatedSwitcher(
              duration: Motion.of(context, Motion.page),
              switchInCurve: const Interval(0.35, 1, curve: Curves.easeOutCubic),
              switchOutCurve: const Interval(0.6, 1),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, if (current != null) current],
              ),
              transitionBuilder: (child, animation) {
                final arriving = child.key == ValueKey(_tab);
                final side = _tab == 1 ? 1.0 : -1.0;
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: animation.drive(
                      Tween(begin: Offset((arriving ? side : -side) * 0.06, 0), end: Offset.zero),
                    ),
                    child: child,
                  ),
                );
              },
              child: Column(
                key: ValueKey(_tab),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _tab == 0 ? _listen(context) : _read(context),
              ),
            ),
          ];
    final list = ListView(
      key: const Key('reader-settings'),
      shrinkWrap: speedOnly,
      padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xxl),
      children: children,
    );
    // The full sheet keeps one height, so switching between Listen and Read
    // does not make it jump.
    return speedOnly
        ? ConstrainedBox(constraints: BoxConstraints(maxHeight: height * 0.45), child: list)
        : SizedBox(height: height * 0.8, child: list);
  }

  // ---------------------------------------------------------------- listen

  List<Widget> _listen(BuildContext context) => [
        const SectionTitle('Speed'),
        const SizedBox(height: Gap.m),
        SpeedControl(prefs: _prefs, onChanged: _speedChanged),
        const SizedBox(height: Gap.xl),
        const SectionTitle('Sleep timer'),
        const SizedBox(height: Gap.m),
        ChoiceRow<SleepChoice>(
          options: const [
            (SleepChoice.off, 'Off'),
            (SleepChoice.min15, '15 min'),
            (SleepChoice.min30, '30 min'),
            (SleepChoice.min60, '1 hour'),
            (SleepChoice.chapterEnd, 'Chapter'),
          ],
          value: _sleep,
          minSegment: 60,
          onChanged: (c) {
            setState(() => _sleep = c);
            widget.controller.onSleep?.call(c);
          },
        ),
        const SizedBox(height: Gap.xl),
        SectionTitle('Voice', note: 'Book: ${languageName(widget.controller.language)}'),
        const SizedBox(height: Gap.m),
        _voiceCard(context),
        if (widget.controller.bookId != null) ...[
          const SizedBox(height: Gap.s),
          _dialogueCard(context),
        ],
        const SizedBox(height: Gap.xl),
        const SectionTitle('Style'),
        const SizedBox(height: Gap.m),
        _style(context),
        const SizedBox(height: Gap.l),
        _fineTuneSection(context),
      ];

  Widget _voiceCard(BuildContext context) {
    final v = _catalog.byName(widget.controller.voiceName);
    final String title;
    final String detail;
    if (!_catalog.loaded) {
      title = 'Loading voices…';
      detail = '';
    } else if (v == null) {
      title = 'No ${languageName(widget.controller.language)} voice';
      detail = 'Tap to choose one or install one';
    } else {
      title = '${v.languageLabel} · ${_catalog.friendlyName(v)}';
      detail = _availability(v);
    }
    return Material(
      color: Skin.raisedOn(context),
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () => showVoicePicker(context, widget.controller),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded, color: Skin.accentOf(context), size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                    if (detail.isNotEmpty)
                      Text(detail,
                          style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                  ],
                ),
              ),
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentSoftOf(context))),
            ],
          ),
        ),
      ),
    );
  }

  /// Dialogue in a second voice: what is in quotation marks, read by another.
  Widget _dialogueCard(BuildContext context) {
    final c = widget.controller;
    final v = _catalog.byName(c.dialogueVoice);
    return Material(
      color: Skin.raisedOn(context),
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () => _pickDialogue(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.forum_outlined, color: Skin.accentOf(context), size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dialogue', style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                    Text(
                      v == null ? 'In the same voice' : 'Words in quotation marks: ${_catalog.friendlyName(v)}',
                      style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                  ],
                ),
              ),
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentSoftOf(context))),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDialogue(BuildContext context) async {
    final c = widget.controller;
    final voices = [
      for (final v in _catalog.forLanguage(c.language))
        if (v.name != c.voiceName) v,
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => carryTint(
        context,
        SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: ListView(
              shrinkWrap: true,
              children: [
                const SheetHeader('Dialogue voice', subtitle: 'Who reads the words in quotation marks'),
                SheetAction(
                  icon: Icons.person_outline_rounded,
                  label: 'The same voice',
                  detail: 'Everything in the narrator\'s voice',
                  onTap: () => Navigator.pop(ctx, ''),
                ),
                for (final v in voices)
                  SheetAction(
                    icon: isNeural(v.name) ? Icons.auto_awesome_rounded : Icons.record_voice_over_outlined,
                    label: _catalog.friendlyName(v),
                    detail: v.languageLabel,
                    onTap: () => Navigator.pop(ctx, v.name),
                  ),
                const SizedBox(height: Gap.s),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    c.chooseDialogueVoice(picked.isEmpty ? null : picked);
    setState(() {});
  }

  Widget _style(BuildContext context) {
    final active = SpeechPreset.all.where((p) => p.id == _prefs.presetId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChoiceRow<String?>(
          options: [for (final p in SpeechPreset.all) (p.id, p.label)],
          value: _prefs.presetId,
          minSegment: 200,
          onChanged: (id) {
            final p = SpeechPreset.all.firstWhere((x) => x.id == id);
            setState(() {
              _prefs.settings = p.settings;
              _prefs.presetId = p.id;
            });
            _prefs.save();
            widget.controller.changedAudibly();
          },
        ),
        const SizedBox(height: Gap.s),
        Text(
          active?.description ?? 'Custom: adjusted in Fine-tune.',
          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
        ),
      ],
    );
  }

  Widget _fineTuneSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(Radii.row),
          onTap: () => setState(() => _fineTune = !_fineTune),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.s),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Fine-tune', style: Skin.title(context, size: 21)),
                      Text('Pitch, word spacing, pauses and loudness',
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _fineTune ? 0.5 : 0,
                  duration: Motion.of(context, Motion.standard),
                  curve: Motion.emphasized,
                  child: Icon(Icons.expand_more_rounded, color: Skin.inkSoftOn(context)),
                ),
              ],
            ),
          ),
        ),
        // Unfolds below its heading, and folds back with its sliders still
        // drawn rather than vanishing first.
        AnimatedSwitcher(
          duration: Motion.of(context, Motion.page),
          switchInCurve: Motion.emphasized,
          switchOutCurve: Motion.emphasized,
          transitionBuilder: revealDown,
          child: _fineTune ? _fineTuneBody(context) : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _fineTuneBody(BuildContext context) {
    final p = _s.punctuation;
    Widget row(String label, double value, double min, double max, String unit,
            PipelineSettings Function(double) apply,
            {int decimals = 0}) =>
        LabeledSlider(
          label: label,
          value: value,
          min: min,
          max: max,
          display: '${value.toStringAsFixed(decimals)}$unit',
          onChanged: (v) => _set(apply(v), restart: false),
          onChangeEnd: (v) => _set(apply(v), restart: true),
        );

    return Column(
      key: const ValueKey('fine-tune'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Gap.s),
        row('Pitch', _s.pitchSemitones, -12, 12, ' st', (v) => _s.copyWith(pitchSemitones: v), decimals: 1),
        row('Space between words', _s.wordGapMs.toDouble(), 0, 500, ' ms',
            (v) => _s.copyWith(wordGapMs: v.round())),
        row('Pause at commas', p.commaMs.toDouble(), 0, 800, ' ms',
            (v) => _s.copyWith(punctuation: p.copyWith(commaMs: v.round()))),
        row('Pause between sentences', _s.sentencePauseMs.toDouble(), 0, 2000, ' ms',
            (v) => _s.copyWith(sentencePauseMs: v.round())),
        row('Pause between paragraphs', _s.paragraphPauseMs.toDouble(), 0, 3000, ' ms',
            (v) => _s.copyWith(paragraphPauseMs: v.round())),
        row('Volume', _s.volume, 0, 1, '', (v) => _s.copyWith(volume: v), decimals: 2),
        SwitchRow(
          title: 'Even out loudness',
          value: _s.normaliseLoudness,
          padding: EdgeInsets.zero,
          onChanged: (v) => _set(_s.copyWith(normaliseLoudness: v), restart: true),
        ),
        const SizedBox(height: Gap.s),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              final natural = SpeechPreset.all.first;
              setState(() {
                _prefs.settings = natural.settings.copyWith(speedScale: _s.speedScale);
                _prefs.presetId = natural.id;
              });
              _prefs.save();
              widget.controller.changedAudibly();
            },
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset to Natural'),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ read

  List<Widget> _read(BuildContext context) => [
        ReadingControls(
          prefs: _prefs,
          isPdf: widget.controller.isPdf,
          // The app's light or dark lives in Settings.
          showTheme: false,
          onChanged: () {
            setState(() {});
            widget.controller.onChanged(restart: false);
          },
        ),
      ];
}

/// The common speeds: the speed sheet's row, and the steps of the media
/// card's speed button (which has an icon for each).
const speedPresets = [0.75, 1.0, 1.25, 1.5, 2.0];

/// Speed: − value + for fine steps, and one row of common speeds.
class SpeedControl extends StatefulWidget {
  const SpeedControl({super.key, required this.prefs, required this.onChanged});

  final ListeningPrefs prefs;
  final void Function({required bool restart}) onChanged;

  @override
  State<SpeedControl> createState() => _SpeedControlState();
}

class _SpeedControlState extends State<SpeedControl> {
  double get _speed => widget.prefs.settings.speedScale;

  void _setSpeed(double v) {
    final next = (v * 20).round() / 20; // Steps of 0.05.
    setState(() => widget.prefs.settings = widget.prefs.settings.copyWith(speedScale: next.clamp(0.5, 3.0)));
    widget.prefs.save();
    widget.onChanged(restart: true);
  }

  @override
  Widget build(BuildContext context) {
    final preset = speedPresets.where((p) => (p - _speed).abs() < 0.001).firstOrNull;
    return Column(
      children: [
        StepperControl(
          value: '${trimSpeed(_speed)}×',
          minusTooltip: 'Slower',
          plusTooltip: 'Faster',
          onMinus: _speed > 0.5 ? () => _setSpeed(_speed - 0.05) : null,
          onPlus: _speed < 3.0 ? () => _setSpeed(_speed + 0.05) : null,
        ),
        const SizedBox(height: Gap.m),
        ChoiceRow<double?>(
          options: [for (final p in speedPresets) (p, '${trimSpeed(p)}×')],
          value: preset,
          minSegment: 54,
          onChanged: (v) => _setSpeed(v!),
        ),
      ],
    );
  }
}

/// How the page looks: size, font, spacing, margins, alignment, theme.
/// Used by the reader's sheet and by Settings, so the two never disagree.
class ReadingControls extends StatelessWidget {
  const ReadingControls({
    super.key,
    required this.prefs,
    required this.onChanged,
    this.isPdf = false,
    this.showTheme = true,
  });

  final ListeningPrefs prefs;
  final VoidCallback onChanged;
  final bool isPdf;
  final bool showTheme;

  void _apply(void Function() change) {
    change();
    prefs.save();
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('Text size'),
          const SizedBox(height: Gap.m),
          StepperControl(
            value: 'Aa',
            minusTooltip: 'Smaller text',
            plusTooltip: 'Larger text',
            valueStyle: Skin.page(context, size: prefs.textSize, font: prefs.bookFont, height: 1.2),
            onMinus: prefs.textSize > 14 ? () => _apply(() => prefs.textSize -= 1) : null,
            onPlus: prefs.textSize < 30 ? () => _apply(() => prefs.textSize += 1) : null,
          ),
          const SizedBox(height: Gap.xl),
          const SectionTitle('Font'),
          const SizedBox(height: Gap.m),
          ChoiceRow<BookFont>(
            options: [for (final f in BookFont.values) (f, f.label)],
            value: prefs.bookFont,
            minSegment: 72,
            onChanged: (f) => _apply(() => prefs.bookFont = f),
          ),
          const SizedBox(height: Gap.s),
          Text(
            'The quick brown fox jumps over the lazy dog.',
            style: Skin.page(context, size: 17, font: prefs.bookFont, height: 1.4)
                .copyWith(color: Skin.inkSoftOn(context)),
          ),
          const SizedBox(height: Gap.xl),
          const SectionTitle('Line spacing'),
          const SizedBox(height: Gap.m),
          ChoiceRow<double>(
            options: const [(1.45, 'Compact'), (1.6, 'Normal'), (1.8, 'Relaxed')],
            value: prefs.lineHeight,
            onChanged: (v) => _apply(() => prefs.lineHeight = v),
          ),
          const SizedBox(height: Gap.xl),
          const SectionTitle('Margins'),
          const SizedBox(height: Gap.m),
          ChoiceRow<double>(
            options: const [(14, 'Narrow'), (22, 'Normal'), (34, 'Wide')],
            value: prefs.margin,
            onChanged: (v) => _apply(() => prefs.margin = v),
          ),
          if (showTheme) ...[
            const SizedBox(height: Gap.xl),
            const SectionTitle('Theme'),
            const SizedBox(height: Gap.m),
            ChoiceRow<ThemeMode>(
              options: const [(ThemeMode.system, 'Phone'), (ThemeMode.light, 'Light'), (ThemeMode.dark, 'Dark')],
              value: prefs.themeMode,
              onChanged: (m) => _apply(() => prefs.themeMode = m),
            ),
          ],
          const SizedBox(height: Gap.l),
          SwitchRow(
            title: 'Justify text',
            subtitle: 'Straight right edge, like a printed book',
            value: prefs.justify,
            padding: EdgeInsets.zero,
            onChanged: (v) => _apply(() => prefs.justify = v),
          ),
          const SizedBox(height: Gap.s),
          SwitchRow(
            title: 'Keep screen on',
            subtitle: 'While a book is open',
            value: prefs.keepScreenOn,
            padding: EdgeInsets.zero,
            onChanged: (v) => _apply(() => prefs.keepScreenOn = v),
          ),
          if (isPdf) ...[
            const SizedBox(height: Gap.s),
            SwitchRow(
              title: 'Show the real pages',
              subtitle: 'The PDF as printed, instead of text that reflows',
              value: prefs.pdfPages,
              padding: EdgeInsets.zero,
              onChanged: (v) => _apply(() => prefs.pdfPages = v),
            ),
          ],
        ],
      );
}

/// A labelled slider whose track lines up with its label.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: Skin.ui(size: 14.5, weight: FontWeight.w500, color: Skin.inkSoftOn(context))),
                ),
                Text(display,
                    style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentSoftOf(context), tabular: true)),
              ],
            ),
            // No side padding on the slider, so the track starts and ends
            // where the label does.
            SliderTheme(
              data: SliderTheme.of(context).copyWith(padding: const EdgeInsets.symmetric(vertical: 10)),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                semanticFormatterCallback: (v) => '$label ${v.toStringAsFixed(2)}',
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ],
        ),
      );
}

/// Voices for the book's language (or any other), grouped by region, each
/// with a sample to listen to.
Future<void> showVoicePicker(BuildContext context, ListenController controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => carryTint(context, _VoicePicker(controller: controller)),
    );

class _VoicePicker extends StatefulWidget {
  const _VoicePicker({required this.controller});

  final ListenController controller;

  @override
  State<_VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<_VoicePicker> {
  final _catalog = VoiceCatalog.instance;
  late String _language = widget.controller.language;
  String? _previewing;

  ListeningPrefs get _prefs => widget.controller.prefs;

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

  Future<void> _preview(VoiceInfo v) async {
    final preview = widget.controller.onPreview;
    if (preview == null) return;
    setState(() => _previewing = v.name);
    try {
      await preview(v.name);
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  /// Use [v]. While the book plays, the change is heard in the book; when
  /// it is quiet, the voice introduces itself.
  void _choose(VoiceInfo v) {
    setState(() => widget.controller.chooseVoice(v.name));
    if (!widget.controller.playing) unawaited(_preview(v));
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.controller.voiceName;
    final current = _catalog.byName(selected);
    final voices = _catalog.forLanguage(_language);
    final byRegion = <String, List<VoiceInfo>>{};
    for (final v in voices) {
      byRegion.putIfAbsent(v.region.isEmpty ? '' : regionLabel(v.region), () => []).add(v);
    }
    final languages = [
      widget.controller.language,
      for (final l in _catalog.languages())
        if (l != widget.controller.language) l,
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Voices', subtitle: 'Play to hear one, tap a name to use it'),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              children: [
                for (final l in languages) ...[
                  _LanguagePill(
                    label: languageName(l),
                    selected: l == _language,
                    onTap: () => setState(() => _language = l),
                  ),
                  const SizedBox(width: Gap.s),
                ],
              ],
            ),
          ),
          const SizedBox(height: Gap.s),
          Flexible(
            child: !_catalog.loaded
                ? const Padding(
                    padding: EdgeInsets.all(Gap.xl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : voices.isEmpty
                    ? _noVoices(context)
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: Gap.xl),
                        children: [
                          // The voice in use, on its own; the list below keeps
                          // its order and marks it where it stands.
                          if (current != null) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, Gap.s),
                              child: Eyebrow('In use'),
                            ),
                            _selectedCard(context, current),
                            const SizedBox(height: Gap.s),
                          ],
                          if (_language == 'en' && ListeningPrefs.loaded?.naturalVoices != false)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
                              child: SheetAction(
                                icon: Icons.auto_awesome_rounded,
                                label: 'Natural voices',
                                detail: 'Voices that sound like people, downloaded once, made on your phone',
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(builder: (_) => const NeuralVoicesScreen()),
                                ),
                              ),
                            ),
                          for (final group in byRegion.entries) ...[
                            if (byRegion.length > 1 || group.key.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.xs),
                                child: Eyebrow(group.key.isEmpty ? languageName(_language) : group.key),
                              ),
                            for (final v in group.value) _voiceRow(context, v, selected: v.name == selected),
                          ],
                          if (_catalog.engines.length > 1) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, Gap.s),
                              child: Eyebrow('Speech engine'),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                              child: ChoiceRow<String?>(
                                options: [
                                  for (final e in _catalog.engines)
                                    (e['name'], (e['label'] ?? '').isEmpty ? e['name']! : e['label']!),
                                ],
                                value: _catalog.engineId,
                                minSegment: 120,
                                onChanged: (id) async {
                                  _prefs.engineId = id;
                                  _prefs.save();
                                  await _catalog.switchEngine(id!);
                                  widget.controller.onChanged(restart: true);
                                },
                              ),
                            ),
                          ],
                          Padding(
                            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, 0),
                            child: TextButton.icon(
                              onPressed: () => const SpeechService().openTtsSettings(),
                              icon: const Icon(Icons.download_rounded, size: 18),
                              label: const Text('Get more voices in phone settings'),
                            ),
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _selectedCard(BuildContext context, VoiceInfo v) {
    final busy = _previewing == v.name;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
      child: Material(
        color: Skin.accentOf(context).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.row),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded, color: Skin.accentOf(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${v.languageLabel} · ${_catalog.friendlyName(v)}',
                        style: Skin.ui(size: 16, weight: FontWeight.w700, color: Skin.inkOn(context))),
                    Text(
                      '${_availability(v)} · ${trimSpeed(_prefs.settings.speedScale)}×',
                      style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                  ],
                ),
              ),
              if (widget.controller.onPreview != null)
                TextButton.icon(
                  onPressed: busy ? null : () => _preview(v),
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.volume_up_rounded, size: 20),
                  label: const Text('Hear it'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _voiceRow(BuildContext context, VoiceInfo v, {required bool selected}) {
    final note = _availability(v);
    final busy = _previewing == v.name;
    final duration = Motion.of(context, Motion.standard);
    return InkWell(
      onTap: () => _choose(v),
      // The wash moves from the old voice to the new one rather than jumping.
      child: AnimatedContainer(
        duration: duration,
        curve: Motion.out,
        color: Skin.accentOf(context).withValues(alpha: selected ? 0.12 : 0),
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.m, Gap.s),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: duration,
              switchInCurve: Motion.out,
              switchOutCurve: Motion.out,
              child: Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                key: ValueKey(selected),
                size: 22,
                color: selected ? Skin.accentOf(context) : Skin.inkFaintOn(context),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_catalog.friendlyName(v),
                      style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                  if (note != 'Works offline')
                    Text(note, style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                ],
              ),
            ),
            if (widget.controller.onPreview != null)
              IconButton(
                tooltip: 'Hear ${_catalog.friendlyName(v)}',
                onPressed: busy ? null : () => _preview(v),
                icon: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.play_circle_outline_rounded, color: Skin.accentSoftOf(context), size: 28),
              ),
          ],
        ),
      ),
    );
  }

  Widget _noVoices(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No ${languageName(_language)} voice on this phone yet.',
                style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
            const SizedBox(height: Gap.xs),
            Text(
              'Install one in the speech settings (Speech Services by Google, then Install voice data), '
              'then come back.',
              style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
            ),
            const SizedBox(height: Gap.l),
            FilledButton(
              onPressed: () => const SpeechService().openTtsSettings(),
              child: const Text('Open speech settings'),
            ),
          ],
        ),
      );
}

class _LanguagePill extends StatelessWidget {
  const _LanguagePill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final duration = Motion.of(context, Motion.standard);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: selected ? Skin.accentOf(context) : Skin.raisedOn(context)),
      duration: duration,
      curve: Motion.out,
      builder: (context, fill, child) => Material(
        color: fill,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: child,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: AnimatedDefaultTextStyle(
            duration: duration,
            curve: Motion.out,
            style: Skin.ui(
              size: 14,
              weight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Skin.onAccentOf(context) : Skin.inkOn(context),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

String _availability(VoiceInfo v) {
  if (!v.installed) return 'Downloads on first use';
  if (v.networkRequired) return 'Needs internet';
  return 'Works offline';
}

/// "1.25", "1.5", "2" for speeds.
String trimSpeed(double v) {
  var s = v.toStringAsFixed(2);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return s;
}
