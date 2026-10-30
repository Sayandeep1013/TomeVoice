import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'backup_flow.dart' show sizeLabel;
import 'book_tint.dart';
import 'export_audio.dart';
import 'listen_sheet.dart' show trimSpeed;
import 'listening_session.dart';
import 'neural_voices.dart';
import 'scheduler.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

/// "Save as audio…", from a book's page or the reader's menu: [chapter] (the
/// one being read) or the whole book, as an M4B (M4A for a chapter) or an
/// MP3, in the voice and with the settings the book is read with, with how
/// long and how large it will be, and how long it takes to make on this
/// phone (timed on one of its sentences).
///
/// [reading] is the reader's own player, when asked from the reader: it and
/// a book read in the background stop for the save, once the reader agrees.
/// [wholeBook] false offers the chapter only (a web novel's reader holds
/// only the chapters fetched). A save already running is shown instead.
Future<void> showSaveAsAudio(
  BuildContext context, {
  required ReadingLayout layout,
  required String bookId,
  required String title,
  String? author,
  String? cover,
  required int chapter,
  PlaybackScheduler? reading,
  bool wholeBook = true,
  bool preferBook = false,
}) async {
  final running = AudioExport.current.value;
  if (running != null) return showExportProgress(context, running);
  if (layout.isEmpty) {
    showSnack(context, 'This book has nothing to read aloud.');
    return;
  }
  final job = await showModalBottomSheet<AudioExport>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => carryTint(
      context,
      _SaveSheet(
        layout: layout,
        bookId: bookId,
        title: title,
        author: author,
        cover: cover,
        chapter: chapter,
        reading: reading,
        wholeBook: wholeBook && layout.chapters.length > 1,
        preferBook: preferBook,
      ),
    ),
  );
  if (job != null && context.mounted) await showExportProgress(context, job);
}

/// How a save is going, with Stop; Share once it is saved. Hidden, it goes
/// on (the notification shows it). One at a time: asked again while it is
/// open, it stays the one.
Future<void> showExportProgress(BuildContext context, AudioExport job) async {
  if (_progressShown != null) return;
  final mine = Object();
  _progressShown = mine;
  try {
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      builder: (_) => carryTint(context, _ProgressSheet(job: job, shown: mine)),
    );
  } finally {
    if (identical(_progressShown, mine)) _progressShown = null;
  }
}

/// The save's progress sheet on screen now, if any: from the moment it is
/// asked for until it closes, or goes with the screen under it.
Object? _progressShown;

/// The save going on now, shown again: when TomeVoice is opened onto it
/// (swiped away from Recents, the save went on with no window) and from its
/// notification. Nothing when no save is going on, or its progress shows.
Future<void> showRunningExport(BuildContext context) async {
  final job = AudioExport.current.value;
  if (job == null || !job.status.value.running || !context.mounted) return;
  await showExportProgress(context, job);
}

class _SaveSheet extends StatefulWidget {
  const _SaveSheet({
    required this.layout,
    required this.bookId,
    required this.title,
    required this.author,
    required this.cover,
    required this.chapter,
    required this.reading,
    required this.wholeBook,
    required this.preferBook,
  });

  final ReadingLayout layout;
  final String bookId;
  final String title;
  final String? author;
  final String? cover;
  final int chapter;
  final PlaybackScheduler? reading;
  final bool wholeBook;
  final bool preferBook;

  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  late bool _whole = widget.wholeBook && widget.preferBook;
  late final _chapterPlan = ExportPlan.chapter(widget.layout, widget.chapter);
  late final _bookPlan = ExportPlan.book(widget.layout);

  /// M4B (or M4A for a chapter) unless MP3 is asked for.
  ExportFormat _format = ExportFormat.aac;

  /// The book's voice and settings as they are now, frozen for the save.
  late final PlaybackScheduler _voice = exportVoice(
    layout: widget.layout,
    bookId: widget.bookId,
    language: primaryLanguage(widget.layout.book.metadata.language),
  );
  bool _handedOver = false;

  ({double workMs, double audioMs})? _speed;
  bool _timing = false;
  int _free = -1;
  bool? _folder;
  bool _choose = false;
  bool _busy = false;
  String? _problem;

  ExportPlan get _plan => _whole ? _bookPlan : _chapterPlan;

  bool get _reading => (widget.reading?.active ?? false) || BackgroundReading.current.value != null;

  @override
  void initState() {
    super.initState();
    unawaited(AudioExport.freeSpace().then((v) => _set(() => _free = v)));
    unawaited(AudioExport.hasAudiobooksFolder().then((v) => _set(() => _folder = v)));
    // Timed on one of its sentences, unless a book is being read aloud:
    // the two would take turns with the one voice.
    if (!_reading) {
      _timing = true;
      unawaited(measureSpeech(_voice, _chapterPlan).then((v) => _set(() {
            _speed = v;
            _timing = false;
          })));
    }
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
    if (!_handedOver) _voice.dispose();
    super.dispose();
  }

  Duration _length(ExportPlan p) {
    final s = _speed;
    if (s != null) return Duration(milliseconds: (p.chars * s.audioMs).round());
    final settings = _voice.settingsFor('');
    return roughLength(p, settings.speedScale, settings.wordGapMs);
  }

  Duration? _work(ExportPlan p) {
    final s = _speed;
    return s == null ? null : Duration(milliseconds: (p.chars * s.workMs).round());
  }

  String _voiceLabel(String? name) {
    final natural = neuralVoiceFor(name);
    if (natural != null) return '${natural.name}, a natural voice';
    final v = VoiceCatalog.instance.byName(name);
    if (v == null) return "the phone's voice";
    return '${VoiceCatalog.instance.friendlyName(v)} (${v.languageLabel})';
  }

  Future<void> _save() async {
    final plan = _plan;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      if (_reading) {
        await BackgroundReading.current.value?.stop();
        await widget.reading?.stop();
      }
      final bytes = fileBytes(_length(plan));
      final free = await AudioExport.freeSpace();
      if (free >= 0 && free < spaceWanted(bytes)) {
        _set(() {
          _free = free;
          _busy = false;
        });
        return;
      }
      String? where;
      if (_choose || _folder == false) {
        where = await AudioExport.chooseWhere(AudioExport.nameFor(plan, widget.title, format: _format));
        if (where == null) {
          _set(() => _busy = false);
          return;
        }
      }
      final job = AudioExport.start(
        plan: plan,
        voice: _voice,
        bookTitle: widget.title,
        author: widget.author,
        cover: await _coverBytes(widget.cover),
        destination: where,
        format: _format,
      );
      _handedOver = true;
      if (mounted) Navigator.pop(context, job);
    } on Object catch (e) {
      _set(() {
        _problem = 'It could not start: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final length = _length(plan);
    final bytes = fileBytes(length);
    final work = _work(plan);
    final settings = _voice.settingsFor('');
    final narrator = _voice.voiceNameOf();
    final dialogue = _voice.dialogueVoiceOf?.call();
    final natural = isNeural(narrator) || isNeural(dialogue);
    final short = _free >= 0 && _free < spaceWanted(bytes);
    final tooLong = length > maxExportLength;
    final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)).copyWith(height: 1.4);
    final soft = Skin.ui(size: 14.5, weight: FontWeight.w500, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);

    Widget note(IconData icon, String text, {Color? color}) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color ?? Skin.inkFaintOn(context)),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(text, style: color == null ? faint : faint.copyWith(color: color))),
            ],
          ),
        );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader('Save as audio', subtitle: widget.title),
            if (widget.wholeBook)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                child: ChoiceRow<bool>(
                  options: const [(false, 'This chapter'), (true, 'Whole book')],
                  value: _whole,
                  onChanged: (v) => setState(() => _whole = v),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    !plan.wholeBook
                        ? plan.firstTitle
                        : plan.markEvery == 1
                            ? '${plan.chapters} chapters, each marked in the file'
                            : '${plan.chapters} chapters, every ${plan.markEvery}th marked (players show up to 255)',
                    style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context)),
                  ),
                  const SizedBox(height: Gap.xs),
                  Text(
                    'About ${durationLabel(length)} of audio · ${sizeLabel(bytes)} · '
                    '${_format.extensionOf(plan).toUpperCase()}',
                    style: soft,
                  ),
                  Text(
                    _timing
                        ? 'Timing this phone…'
                        : work == null
                            ? 'How long it takes to make shows once it starts.'
                            : 'Takes about ${durationLabel(work)} to make on this phone.',
                    style: soft,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.s),
            note(
              Icons.record_voice_over_outlined,
              'Read by ${_voiceLabel(narrator)}'
              '${dialogue == null || dialogue == narrator ? '' : ', the dialogue by ${_voiceLabel(dialogue)}'}'
              ' at ${trimSpeed(settings.speedScale)}×, with your word gap, pauses and pronunciations: '
              'the current voice and settings, as you hear them.',
            ),
            if (natural)
              note(
                Icons.thermostat_rounded,
                'Natural voices keep the processor busy: a whole book can take hours, use a lot of battery '
                'and warm the phone. Best plugged in.',
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, 0),
              child: ChoiceRow<ExportFormat>(
                options: [(ExportFormat.aac, plan.extension.toUpperCase()), (ExportFormat.mp3, 'MP3')],
                value: _format,
                onChanged: (v) => setState(() => _format = v),
              ),
            ),
            if (_format == ExportFormat.mp3)
              note(
                Icons.audio_file_outlined,
                'MP3 plays on nearly anything, car stereos too${plan.wholeBook ? ', with the chapters marked' : ''}. '
                '${plan.extension.toUpperCase()} sounds a little better at the same size.',
              ),
            if (_folder == true)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, Gap.m, Gap.page, 0),
                child: ChoiceRow<bool>(
                  options: const [(false, 'Audiobooks folder'), (true, 'Choose where…')],
                  value: _choose,
                  onChanged: (v) => setState(() => _choose = v),
                ),
              ),
            if (_folder == false) note(Icons.folder_open_rounded, 'You choose where it goes next.'),
            if (_reading)
              note(
                Icons.pause_circle_outline_rounded,
                'A book is being read aloud. The voice cannot read and save at once, so the reading stops.',
                color: Skin.accentOf(context),
              ),
            if (short)
              note(
                Icons.sd_card_alert_outlined,
                'Not enough space: this needs about ${sizeLabel(spaceWanted(bytes))} free while it is made '
                '(the file, and its copy where it goes), and the phone has ${sizeLabel(_free)}.',
                color: const Color(0xFFE5674D),
              ),
            if (tooLong)
              note(
                Icons.timer_off_outlined,
                'Too long for one file. Save it a chapter at a time.',
                color: const Color(0xFFE5674D),
              ),
            if (_problem != null) note(Icons.error_outline_rounded, _problem!, color: const Color(0xFFE5674D)),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, 0),
              child: FilledButton.icon(
                onPressed: _busy || short || tooLong ? null : _save,
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(_reading ? 'Stop reading and save' : 'Save'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, Gap.m),
              child: Text(
                'It goes on with the screen off, the notification showing how far it is. '
                'Reading a book aloud meanwhile stops it.',
                style: faint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cover at [path], to go in the file, if it is a picture of a sensible
/// size.
Future<Uint8List?> _coverBytes(String? path) async {
  if (path == null) return null;
  try {
    final f = File(path);
    if (!await f.exists() || await f.length() > 2 * 1024 * 1024) return null;
    return await f.readAsBytes();
  } on Object {
    return null;
  }
}

class _ProgressSheet extends StatefulWidget {
  const _ProgressSheet({required this.job, required this.shown});

  final AudioExport job;

  /// Which showing of the sheet this is (see [_progressShown]).
  final Object shown;

  @override
  State<_ProgressSheet> createState() => _ProgressSheetState();
}

class _ProgressSheetState extends State<_ProgressSheet> {
  AudioExport get job => widget.job;

  @override
  void dispose() {
    // Gone with its route, or with the screen under it (whose route then
    // never says it closed): another may show.
    if (identical(_progressShown, widget.shown)) _progressShown = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ExportStatus>(
        valueListenable: job.status,
        builder: (context, s, _) {
          final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)).copyWith(height: 1.4);
          final soft = Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);
          final (heading, body) = switch (s.phase) {
            ExportPhase.starting => ('Saving as audio', 'Starting…'),
            ExportPhase.making => ('Saving as audio', progressLabel(s)),
            ExportPhase.finishing => ('Saving as audio', 'Finishing the file…'),
            ExportPhase.saved => ('Saved', 'In ${s.where ?? job.fileName}.${s.message == null || s.message!.isEmpty ? '' : ' ${s.message}'}'),
            ExportPhase.cancelled => ('Not saved', s.message ?? 'Stopped. Nothing was kept.'),
            ExportPhase.failed => ('Could not save', '${s.message ?? 'Something went wrong.'} Nothing was kept.'),
          };
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(heading, subtitle: job.fileName),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (s.running) ...[
                        Progress(s.progress?.fraction ?? 0, height: 5),
                        const SizedBox(height: Gap.s),
                      ],
                      Text(body, style: soft),
                      if (s.waiting) ...[
                        const SizedBox(height: Gap.s),
                        Text(
                          'Android paused it after six hours in the background. It goes on while TomeVoice is open.',
                          style: faint,
                        ),
                      ],
                      if (s.running) ...[
                        const SizedBox(height: Gap.s),
                        Text('It goes on with the screen off; the notification shows how far it is.', style: faint),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.m),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (s.running && s.phase != ExportPhase.finishing)
                        TextButton(
                          onPressed: job.cancel,
                          style: TextButton.styleFrom(foregroundColor: const Color(0xFFE5674D)),
                          child: const Text('Stop saving'),
                        ),
                      if (s.phase == ExportPhase.saved && s.uri != null)
                        TextButton.icon(
                          onPressed: () => unawaited(AudioExport.share(s.uri!, mime: job.format.mime)),
                          icon: const Icon(Icons.ios_share_rounded, size: 20),
                          label: const Text('Share'),
                        ),
                      const SizedBox(width: Gap.s),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(s.running ? 'Hide' : 'Done'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
}
