import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'auto_scroll.dart';
import 'book_tint.dart';
import 'neural_screen.dart';
import 'neural_voices.dart';
import 'page_light.dart';
import 'page_tone.dart';
import 'paged_view.dart' show PageTurn;
import 'prefs.dart';
import 'reading_rules.dart';
import 'rules_screen.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

enum ListenFocus { all, speed, read }

/// When reading should stop on its own.
enum SleepChoice { off, min15, min30, min60, chapterEnd }

/// What the sheet edits, and how the reader hears about it.
class ListenController {
  ListenController({
    required this.prefs,
    required this.language,
    required this.onChanged,
    this.bookId,
    this.bookTitle,
    this.sleep = SleepChoice.off,
    this.onSleep,
    this.onPreview,
    this.isPlaying,
    this.isPdf = false,
    this.narration = false,
    this.light,
    this.autoScroll,
  });

  final ListeningPrefs prefs;

  /// The book's language; voices are offered for this first.
  final String language;

  /// The book whose voice this is, if a book is open.
  final String? bookId;

  /// Its title, where the one who opens the sheet knows it (for its
  /// reading rules).
  final String? bookTitle;

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

  /// The book has its own recorded narration (an EPUB's media overlays),
  /// so it can be read in that instead of a voice.
  final bool narration;

  /// Whether this book is read in its own narration.
  bool get narrated => narration && bookId != null && prefs.narratedBooks.contains(bookId);

  /// Read this book in its own narration; choosing a voice reads it in
  /// that voice again.
  void chooseNarration() {
    final id = bookId;
    if (id == null) return;
    prefs.narratedBooks.add(id);
    prefs.save();
    onChanged(restart: true);
  }
  /// The page's light, moved by the Read tab's sliders as they move, and
  /// auto-scroll, started there: only an open book's page has them.
  final ValueNotifier<PageLight>? light;
  final AutoScroll? autoScroll;

  Timer? _sampleTimer;

  /// The book's own voice, else the one for its language, else the best
  /// installed voice for that language.
  String? get voiceName {
    final catalog = VoiceCatalog.instance;
    final own = bookId == null ? null : prefs.voiceByBook[bookId];
    if (own != null && catalog.byName(own) != null) return own;
    // Only a voice of this language: a Bengali voice chosen for a Bengali
    // novel once taken for English was saved as English's default.
    final usual = catalog.byName(prefs.voiceByLanguage[language]);
    if (usual != null && usual.language == language) return usual.name;
    // None of its own on the phone: the usual voice of the language read
    // in its place (a Ukrainian book in the reader's Russian voice).
    final near = catalog.voiceLanguageFor(language);
    if (near != language) {
      final stand = catalog.byName(prefs.voiceByLanguage[near]);
      if (stand != null && stand.language == near) return stand.name;
    }
    return catalog.bestFor(language)?.name;
  }

  /// Use [name] for this book, and as the default for its language when it
  /// speaks that language (another language's voice stays this book's own).
  void chooseVoice(String name) {
    if (bookId != null) {
      prefs.voiceByBook[bookId!] = name;
      prefs.narratedBooks.remove(bookId);
    }
    if (VoiceCatalog.instance.byName(name)?.language == language) prefs.voiceByLanguage[language] = name;
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
      sheetAnimationStyle: sheetMotion(context),
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
  late int _tab = widget.focus == ListenFocus.read ? 1 : 0;
  bool _fineTune = false;

  ListeningPrefs get _prefs => widget.controller.prefs;
  PipelineSettings get _s => _prefs.settings;

  /// Where the voice is heard now, for Highlight timing (each route keeps
  /// its own).
  String _route = SpeechService.routeOther;

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_refresh);
    unawaited(const SpeechService().highlightRoute().then((r) {
      if (mounted) setState(() => _route = r);
    }));
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
            SpeedControl(prefs: _prefs, onChanged: _speedChanged, bookId: widget.controller.bookId),
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
        SpeedControl(prefs: _prefs, onChanged: _speedChanged, bookId: widget.controller.bookId),
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
        const SizedBox(height: Gap.xl),
        const SectionTitle('Skip buttons'),
        const SizedBox(height: Gap.m),
        ChoiceRow<SkipBy>(
          options: [for (final s in SkipBy.values) (s, s.label)],
          value: _prefs.skipBy,
          minSegment: 80,
          onChanged: (s) {
            setState(() => _prefs.skipBy = s);
            _prefs.save();
          },
        ),
        const SizedBox(height: Gap.xs),
        Text(
          'What next and previous do on headphones, the lock screen and the notification. '
          'Previous starts the sentence again once it is under way.',
          style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
        ),
        if (widget.controller.bookId != null) ...[
          const SizedBox(height: Gap.xl),
          const SectionTitle('Reading rules'),
          const SizedBox(height: Gap.m),
          _rulesCard(context),
        ],
      ];

  Widget _voiceCard(BuildContext context) {
    final v = _catalog.byName(widget.controller.voiceName);
    final String title;
    final String detail;
    if (widget.controller.narrated) {
      title = "Book's own narration";
      detail = 'The recording that came with the book';
    } else if (!_catalog.loaded) {
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
              Icon(Icons.record_voice_over_rounded, color: Skin.accentInkOf(context), size: 22),
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
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context))),
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
              Icon(Icons.forum_outlined, color: Skin.accentInkOf(context), size: 22),
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
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context))),
            ],
          ),
        ),
      ),
    );
  }

  /// This book's reading rules: the words it says its own way, and what its
  /// voice skips (notes from an author or translator, rows of symbols).
  Widget _rulesCard(BuildContext context) {
    final c = widget.controller;
    final rules = ReadingRules.instance;
    final skips = [
      for (final p in SkipPreset.values)
        if (p != SkipPreset.links && rules.presetOn(p, book: c.bookId)) p.title.toLowerCase(),
    ];
    final words = rules.say.where((r) => r.book == c.bookId).length;
    return Material(
      color: Skin.raisedOn(context),
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => RulesScreen(bookTitles: const {}, bookId: c.bookId, bookTitle: c.bookTitle),
          ));
          // What it skips now, on the card.
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.rule_rounded, color: Skin.accentInkOf(context), size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      words == 0
                          ? 'Words said your way'
                          : '${words == 1 ? '1 word' : '$words words'} said your way in this book',
                      style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context)),
                    ),
                    Text(
                      skips.isEmpty ? 'The voice skips no notes or symbols' : 'The voice skips ${skips.join(', ')}',
                      style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDialogue(BuildContext context) async {
    final c = widget.controller;
    // A natural narrator on a phone that keeps one natural voice loaded:
    // a second one is loaded again at every quote, a pause of a second or
    // more each time, so the phone's voices come first and it says so.
    final oneAtATime = isNeural(c.voiceName) && !NeuralEngine.instance.holdsTwo;
    final all = [
      for (final v in _catalog.forLanguage(c.language, keep: c.dialogueVoice))
        if (v.name != c.voiceName) v,
    ];
    final voices = oneAtATime
        ? [...all.where((v) => !isNeural(v.name)), ...all.where((v) => isNeural(v.name))]
        : all;
    final picked = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
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
                if (oneAtATime)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
                    child: Text(
                      'This phone keeps one natural voice loaded at a time, so a second natural voice '
                      'pauses at every quote while it loads. A phone voice switches at once.',
                      style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(ctx)),
                    ),
                  ),
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
                    detail: oneAtATime && isNeural(v.name)
                        ? '${v.languageLabel} · pauses at each quote here'
                        : v.languageLabel,
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
          minSegment: 96,
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

  /// The pitch of the voice in use, which is that voice's own. A natural
  /// voice takes no pitch (no pitch shift is built), and says so rather
  /// than leaving a pitch set elsewhere to vanish unexplained.
  Widget? _pitchRow(BuildContext context) {
    final voice = widget.controller.voiceName;
    if (voice == null) return null;
    if (isNeural(voice)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Text(
          'Pitch: a natural voice speaks at its own pitch, which cannot be changed.',
          style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
        ),
      );
    }
    final pitch = _prefs.pitchOf(voice);
    final google = (_prefs.engineId ?? _catalog.engineId) == 'com.google.android.tts';
    void set(double v) => setState(() => _prefs.setPitch(voice, v));
    return LabeledSlider(
      label: 'Pitch',
      value: pitch,
      min: -12,
      max: 12,
      display: '${pitch.toStringAsFixed(1)} st',
      note: pitch != 0 && google
          ? 'For this voice only. Away from 0, Google reads with an older, rougher model of the voice.'
          : 'For this voice only.',
      onChanged: (v) {
        set(v);
        widget.controller.onChanged(restart: false);
      },
      onChangeEnd: (v) {
        set(v);
        _prefs.save();
        widget.controller.changedAudibly();
      },
    );
  }

  /// How much later than the phone says the highlight (and the page) moves
  /// with the voice, for where it is heard now: Bluetooth headphones play a
  /// moment after the phone sends the sound, and not every one tells the
  /// phone how long (docs/05 section 5.9).
  Widget _highlightTiming() {
    final bluetooth = _route == SpeechService.routeBluetooth;
    final ms = _prefs.highlightOffset(_route);
    void set(double v) => setState(() => _prefs.highlightOffsetMs[_route] = (v / 10).round() * 10);
    return LabeledSlider(
      label: 'Highlight timing',
      value: ms.toDouble(),
      min: -200,
      max: 400,
      display: ms == 0 ? 'As heard' : '${ms > 0 ? '+' : ''}$ms ms',
      note: bluetooth
          ? 'For Bluetooth. Move it right if the highlight runs ahead of the voice.'
          : "For the phone's speaker and wired headphones. Move it right if the highlight runs ahead of the voice.",
      onChanged: set,
      onChangeEnd: (v) {
        set(v);
        _prefs.save();
        unawaited(const SpeechService().setHighlightOffsets(
          bluetoothMs: _prefs.highlightOffset(SpeechService.routeBluetooth),
          otherMs: _prefs.highlightOffset(SpeechService.routeOther),
        ));
      },
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
        if (_pitchRow(context) case final pitch?) pitch,
        _highlightTiming(),
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
              final voice = widget.controller.voiceName;
              setState(() {
                _prefs.settings = natural.settings.copyWith(speedScale: _s.speedScale);
                _prefs.presetId = natural.id;
                if (voice != null) _prefs.setPitch(voice, 0);
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
        if (widget.controller.light case final light?) ..._light(context, light),
        ReadingControls(
          prefs: _prefs,
          isPdf: widget.controller.isPdf,
          // The app's light or dark lives in Settings.
          showTheme: false,
          afterLayout: switch (widget.controller.autoScroll) {
            final auto? => _autoScroll(context, auto),
            null => null,
          },
          onChanged: () {
            setState(() {});
            widget.controller.onChanged(restart: false);
          },
        ),
      ];

  /// The page's light: how bright (at the left end, darker than the phone
  /// goes) and how warm, and the phone's own again. The page follows the
  /// sliders as they move; they are kept when let go.
  List<Widget> _light(BuildContext context, ValueNotifier<PageLight> light) {
    final now = PageLight.of(_prefs);
    final brightness = now.brightness;
    void set({double? to, double? warmth, bool keep = false}) {
      setState(() {
        if (to != null) _prefs.pageBrightness = to;
        if (warmth != null) _prefs.pageWarmth = warmth;
      });
      light.value = PageLight.of(_prefs);
      if (keep) _prefs.save();
    }

    String bright(double v) => v < PageLight.below
        ? 'Darker than the phone'
        : '${((v - PageLight.below) / (1 - PageLight.below) * 100).round()}%';
    String warm(double v) => v <= 0 ? 'Off' : '${(v * 100).round()}%';
    return [
      const SectionTitle('Light'),
      const SizedBox(height: Gap.m),
      LabeledSlider(
        label: 'Brightness',
        value: brightness ?? PageLight.resting,
        min: 0,
        max: 1,
        display: brightness == null ? 'As the phone is' : bright(brightness),
        note: 'At its left end, darker than the phone goes.',
        spoken: (v) => brightness == null && v == PageLight.resting ? 'As the phone is' : bright(v),
        onChanged: (v) => set(to: v),
        onChangeEnd: (v) => set(to: v, keep: true),
      ),
      LabeledSlider(
        label: 'Warmth',
        value: now.warmth,
        min: 0,
        max: 1,
        display: warm(now.warmth),
        note: 'Amber over the page, for reading at night.',
        spoken: warm,
        onChanged: (v) => set(warmth: v),
        onChangeEnd: (v) => set(warmth: v, keep: true),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: now.isPhone
              ? null
              : () {
                  setState(() {
                    _prefs.pageBrightness = null;
                    _prefs.pageWarmth = 0;
                  });
                  light.value = PageLight.phone;
                  _prefs.save();
                },
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text('As the phone is'),
        ),
      ),
      const SizedBox(height: Gap.xl),
    ];
  }

  /// Auto-scroll, under the layout it moves: how fast (in pages, how long
  /// on each page), and Start, which closes the sheet onto the page moving;
  /// Stop while it runs.
  Widget _autoScroll(BuildContext context, AutoScroll auto) => ListenableBuilder(
        listenable: auto,
        builder: (context, _) {
          final pages = _prefs.pages;
          // A PDF's real pages scroll as pictures; in pages they turn.
          final can = !(widget.controller.isPdf && _prefs.pdfPages && !pages);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Gap.xl),
              const SectionTitle('Auto-scroll'),
              const SizedBox(height: Gap.m),
              StepperControl(
                value: auto.label(pages: pages),
                minusTooltip: pages ? 'Longer on each page' : 'Scroll slower',
                plusTooltip: pages ? 'Shorter on each page' : 'Scroll faster',
                valueStyle: Skin.ui(size: 17, weight: FontWeight.w700, color: Skin.inkOn(context), tabular: true),
                onMinus: auto.canSlowDown(pages: pages) ? () => auto.slowDown(pages: pages) : null,
                onPlus: auto.canSpeedUp(pages: pages) ? () => auto.speedUp(pages: pages) : null,
              ),
              const SizedBox(height: Gap.s),
              Text(
                !can
                    ? 'The real pages turn by themselves in pages: choose Pages above.'
                    : '${pages ? 'A page turns by itself' : 'The page moves on by itself'} until the chapter ends, '
                        'and a touch holds it a moment. Starting it stops the voice, and Play stops it.',
                style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
              ),
              const SizedBox(height: Gap.m),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: !can
                      ? null
                      : () {
                          if (auto.on) {
                            auto.stop();
                            return;
                          }
                          auto.start();
                          Navigator.of(context).maybePop();
                        },
                  icon: Icon(auto.on ? Icons.stop_rounded : Icons.play_arrow_rounded),
                  label: Text(auto.on ? 'Stop auto-scroll' : 'Start auto-scroll'),
                ),
              ),
            ],
          );
        },
      );
}

/// The common speeds: the speed sheet's row, and the steps of the media
/// card's speed button (which has an icon for each).
const speedPresets = [0.75, 1.0, 1.25, 1.5, 2.0];

/// Speed: − value + for fine steps, and one row of common speeds. With a
/// [bookId], the speed that book reads at, and the choice to keep it for
/// that book only (docs/05 section 5.1); without, everyone's.
class SpeedControl extends StatefulWidget {
  const SpeedControl({super.key, required this.prefs, required this.onChanged, this.bookId});

  final ListeningPrefs prefs;
  final void Function({required bool restart}) onChanged;
  final String? bookId;

  @override
  State<SpeedControl> createState() => _SpeedControlState();
}

class _SpeedControlState extends State<SpeedControl> {
  double get _speed => widget.prefs.speedFor(widget.bookId);

  bool get _own => widget.bookId != null && widget.prefs.speedByBook.containsKey(widget.bookId);

  void _setSpeed(double v) {
    final next = ((v * 20).round() / 20).clamp(0.5, 3.0).toDouble(); // Steps of 0.05.
    setState(() => widget.prefs.setSpeed(next, book: widget.bookId));
    widget.prefs.save();
    widget.onChanged(restart: true);
  }

  void _setOwn(bool own) {
    final before = _speed;
    setState(() => widget.prefs.setOwnSpeed(widget.bookId!, own));
    widget.prefs.save();
    // Back to everyone's speed is heard if it differs.
    widget.onChanged(restart: _speed != before);
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
        if (widget.bookId != null)
          SwitchRow(
            title: _own
                ? 'For this book only (others ${trimSpeed(widget.prefs.settings.speedScale)}×)'
                : 'For this book only',
            value: _own,
            padding: EdgeInsets.zero,
            onChanged: _setOwn,
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
    this.afterLayout,
  });

  final ListeningPrefs prefs;
  final VoidCallback onChanged;
  final bool isPdf;
  final bool showTheme;

  /// Under the layout's choice, where a book's page is open: its auto-scroll.
  final Widget? afterLayout;

  void _apply(void Function() change) {
    change();
    prefs.save();
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('Page'),
          const SizedBox(height: Gap.m),
          _PageTones(
            selected: PageTone.byId(prefs.pageTone),
            font: prefs.bookFont,
            onPick: (t) => _apply(() => prefs.pageTone = t.id),
          ),
          const SizedBox(height: Gap.xl),
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
          const SizedBox(height: Gap.xl),
          const SectionTitle('Paragraphs'),
          const SizedBox(height: Gap.m),
          ChoiceRow<bool>(
            options: const [(false, 'Spaced'), (true, 'Indented')],
            value: prefs.indent,
            onChanged: (v) => _apply(() => prefs.indent = v),
          ),
          const SizedBox(height: Gap.xl),
          const SectionTitle('Layout'),
          const SizedBox(height: Gap.m),
          ChoiceRow<bool>(
            options: const [(false, 'Scroll'), (true, 'Pages')],
            value: prefs.pages,
            onChanged: (v) => _apply(() => prefs.pages = v),
          ),
          // Only pages are turned: their settings open in under the choice.
          growIn(
            context,
            !prefs.pages
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: Gap.l),
                      ChoiceRow<PageTurn>(
                        options: [for (final t in PageTurn.values) (t, t.label)],
                        value: PageTurn.byName(prefs.pageTurn),
                        onChanged: (t) => _apply(() => prefs.pageTurn = t.name),
                      ),
                      const SizedBox(height: Gap.s),
                      SwitchRow(
                        title: 'Tap the sides to turn',
                        subtitle: 'Left for back, right for on; the middle shows the controls',
                        value: prefs.tapToTurn,
                        padding: EdgeInsets.zero,
                        onChanged: (v) => _apply(() => prefs.tapToTurn = v),
                      ),
                      const SizedBox(height: Gap.s),
                      SwitchRow(
                        title: 'Volume keys turn pages',
                        subtitle: 'Down for on, up for back. While a book is read aloud they change the volume',
                        value: prefs.volumeKeys,
                        padding: EdgeInsets.zero,
                        onChanged: (v) => _apply(() => prefs.volumeKeys = v),
                      ),
                    ],
                  ),
          ),
          if (afterLayout case final after?) after,
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
            title: 'Full screen',
            subtitle: "Hide the phone's status and navigation bars while reading",
            value: prefs.fullScreen,
            padding: EdgeInsets.zero,
            onChanged: (v) => _apply(() => prefs.fullScreen = v),
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
            // Only the real pages have margins to cut: it opens in under them.
            growIn(
              context,
              !prefs.pdfPages
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: Gap.s),
                      child: SwitchRow(
                        title: 'Crop margins',
                        subtitle: 'The white edges cut away, so the print is larger. Pictures stay whole',
                        value: prefs.pdfCrop,
                        padding: EdgeInsets.zero,
                        onChanged: (v) => _apply(() => prefs.pdfCrop = v),
                      ),
                    ),
            ),
          ],
        ],
      );
}

/// The page tones side by side, each a little page of its own paper and
/// ink, the chosen one ringed.
class _PageTones extends StatelessWidget {
  const _PageTones({required this.selected, required this.font, required this.onPick});

  final PageTone selected;
  final BookFont font;
  final ValueChanged<PageTone> onPick;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (final t in PageTone.all) ...[
            if (t != PageTone.all.first) const SizedBox(width: Gap.s),
            Expanded(
              child: Semantics(
                button: true,
                selected: t == selected,
                label: 'Page: ${t.label}',
                child: GestureDetector(
                  onTap: () => onPick(t),
                  child: AnimatedContainer(
                    duration: Motion.of(context, Motion.quick),
                    height: 72,
                    decoration: t.paperOf(context).copyWith(
                          borderRadius: BorderRadius.circular(Radii.chip),
                          border: Border.all(
                            color: t == selected ? Skin.accentMarkOf(context) : Skin.outlineOn(context),
                            width: t == selected ? 2.5 : 1,
                          ),
                        ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Aa', style: Skin.page(context, size: 22, font: font, height: 1.1).copyWith(color: t.inkOf(context))),
                        const SizedBox(height: 2),
                        Text(t.label.toUpperCase(),
                            style: Skin.meta(context, size: 9.5, color: t.ink ?? Skin.inkSoftOn(context))),
                      ],
                    ),
                  ),
                ),
              ),
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
    this.note,
    this.spoken,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// A line under the slider about what it does.
  final String? note;

  /// The value as a screen reader says it ("40%"), where the number alone
  /// would not say it.
  final String Function(double value)? spoken;

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
                    style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context), tabular: true)),
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
                semanticFormatterCallback: (v) => '$label ${spoken?.call(v) ?? v.toStringAsFixed(2)}',
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
            if (note != null)
              Text(note!, style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
          ],
        ),
      );
}

/// Voices for the book's language (or any other), grouped by region, each
/// with a sample to listen to.
Future<void> showVoicePicker(BuildContext context, ListenController controller) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
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

  /// Words typed to find a language or a voice, lower case.
  String _query = '';
  final _find = TextEditingController();

  ListeningPrefs get _prefs => widget.controller.prefs;

  /// Whether [v] answers [_query]: its language, country, name, or "online"
  /// or "offline", every word somewhere.
  bool _matches(VoiceInfo v) {
    final hay = [
      languageName(v.language),
      v.language,
      v.locale,
      regionLabel(v.region),
      _catalog.friendlyName(v),
      v.networkRequired ? 'online network internet' : 'offline',
    ].join(' ').toLowerCase();
    return _query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_refresh);
  }

  @override
  void dispose() {
    _catalog.removeListener(_refresh);
    _find.dispose();
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
    final narrated = widget.controller.narrated;
    final selected = widget.controller.voiceName;
    final current = _catalog.byName(selected);
    final voices = _catalog.forLanguage(_language, keep: selected);
    final byRegion = <String, List<VoiceInfo>>{};
    for (final v in voices) {
      byRegion.putIfAbsent(v.region.isEmpty ? '' : regionLabel(v.region), () => []).add(v);
    }
    final finding = _query.isNotEmpty;
    final languages = [
      for (final l in [
        widget.controller.language,
        for (final l in _catalog.languages())
          if (l != widget.controller.language) l,
      ])
        if (!finding || '${languageName(l)} $l'.toLowerCase().contains(_query.trim())) l,
    ];
    // While finding: every language's voices that answer, by language.
    final found = <String, List<VoiceInfo>>{};
    if (finding) {
      for (final l in _catalog.languages()) {
        for (final v in _catalog.forLanguage(l, keep: selected)) {
          if (_matches(v)) found.putIfAbsent(v.languageLabel, () => []).add(v);
        }
      }
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Voices', subtitle: 'Play to hear one, tap a name to use it'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
            child: SearchField(
              controller: _find,
              hint: 'Find a language or voice',
              onChanged: (q) => setState(() => _query = q.trim().toLowerCase()),
              onClear: _query.isEmpty
                  ? null
                  : () {
                      _find.clear();
                      setState(() => _query = '');
                    },
            ),
          ),
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
            // Another language's voices (or the list after loading) fade in.
            child: FadeIn(
              trigger: '${_catalog.loaded}/$_language/$finding',
              child: finding
                  ? _found(context, found, selected)
                  : !_catalog.loaded
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
                            if (widget.controller.narration) _narrationRow(context, selected: narrated),
                            // The voice in use, on its own; the list below keeps
                            // its order and marks it where it stands.
                            if (current != null) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, Gap.s),
                                child: Eyebrow(narrated ? 'Reads what the narration leaves out' : 'In use'),
                              ),
                              _selectedCard(context, current),
                              const SizedBox(height: Gap.s),
                            ],
                            if (ListeningPrefs.loaded?.naturalVoices != false) _naturalVoices(context),
                            for (final group in byRegion.entries) ...[
                              if (byRegion.length > 1 || group.key.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.xs),
                                  child: Eyebrow(group.key.isEmpty ? languageName(_language) : group.key),
                                ),
                              for (final v in group.value) _voiceRow(context, v, selected: !narrated && v.name == selected),
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
          ),
        ],
      ),
    );
  }

  /// The voices found, by language; a word that finds nothing says so.
  Widget _found(BuildContext context, Map<String, List<VoiceInfo>> found, String? selected) {
    if (found.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(
          'No voice or language goes by "$_query". Try a language ("Bengali"), a country ("India") '
          'or "offline".',
          textAlign: TextAlign.center,
          style: Skin.label(context, size: 14),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: Gap.xl),
      children: [
        for (final group in found.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.xs),
            child: Eyebrow(group.key),
          ),
          for (final v in group.value) _voiceRow(context, v, selected: v.name == selected),
        ],
      ],
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
              Icon(Icons.record_voice_over_rounded, color: Skin.accentInkOf(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${v.languageLabel} · ${_catalog.friendlyName(v)}',
                        style: Skin.ui(size: 16, weight: FontWeight.w700, color: Skin.inkOn(context))),
                    Text(
                      '${_availability(v)} · ${trimSpeed(_prefs.speedFor(widget.controller.bookId))}×',
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

  /// The book's own narration, above its voices: the recording it came
  /// with, read instead of a voice.
  Widget _narrationRow(BuildContext context, {required bool selected}) => InkWell(
        onTap: () => setState(widget.controller.chooseNarration),
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.standard),
          curve: Motion.out,
          color: Skin.accentOf(context).withValues(alpha: selected ? 0.12 : 0),
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.m, Gap.m),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                size: 22,
                color: selected ? Skin.accentInkOf(context) : Skin.inkFaintOn(context),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Book's own narration",
                        style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                    Text('The recording that came with the book, lit as it is read',
                        style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                  ],
                ),
              ),
              Icon(Icons.headphones_rounded, color: Skin.accentInkOf(context), size: 24),
            ],
          ),
        ),
      );

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
              switchOutCurve: const Interval(0.5, 1),
              child: Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                key: ValueKey(selected),
                size: 22,
                color: selected ? Skin.accentInkOf(context) : Skin.inkFaintOn(context),
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
                    : Icon(Icons.play_circle_outline_rounded, color: Skin.accentInkOf(context), size: 28),
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
            // Or a natural voice of this language, where there is one.
            if (ListeningPrefs.loaded?.naturalVoices != false &&
                NeuralVoices.instance.offeredFor(_language).isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              _naturalVoices(context, inset: false),
            ],
          ],
        ),
      );

  /// The way to natural voices of the language shown, saying how many there
  /// are to have; where there are none, that the phone's voice reads it.
  Widget _naturalVoices(BuildContext context, {bool inset = true}) {
    final name = languageName(_language);
    final offered = NeuralVoices.instance.offeredFor(_language);
    final padding = inset ? const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0) : EdgeInsets.zero;
    if (offered.isEmpty) {
      // The catalog is read a moment after start: nothing said until then.
      if (NeuralVoices.instance.catalog == null) return const SizedBox.shrink();
      return Padding(
        padding: inset ? const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, 0) : EdgeInsets.zero,
        child: Text(
          'No natural voices for $name yet; your phone\'s voice is used.',
          style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
        ),
      );
    }
    final natural = NeuralVoices.instance;
    final here = offered.where(natural.readable).length;
    // Not "to download" if it is here already (a Kokoro too slow to read with).
    final toGet = offered.where((v) => !natural.installed(v)).length;
    return Padding(
      padding: padding,
      child: SheetAction(
        icon: Icons.auto_awesome_rounded,
        label: 'Natural voices for $name',
        detail: here == 0
            ? '$toGet to download: voices that sound like people, made on your phone'
            : '$here on this phone${toGet == 0 ? '' : ', $toGet more to download'}',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => NeuralVoicesScreen(language: _language)),
        ),
      ),
    );
  }
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
