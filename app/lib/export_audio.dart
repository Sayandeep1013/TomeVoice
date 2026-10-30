import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:tomevoice_document/tomevoice_document.dart';

import 'dialogue.dart' show resamplePcm16;
import 'listening_session.dart';
import 'mp4_chapters.dart';
import 'neural_voices.dart';
import 'prefs.dart';
import 'reading_rules.dart';
import 'scheduler.dart';
import 'speech_service.dart';

/// Saving a chapter, or a whole book, as audio: every sentence made as
/// reading aloud makes it (makeSentence in scheduler.dart: the book's voice
/// and dialogue voice, the reader's speed, word gap, pauses, loudness and
/// pronunciations), handed to an AAC encoder instead of the player, and
/// written as an .m4a (a chapter) or an .m4b with chapter marks (a book).
///
/// The platform side (AudioExport.kt) encodes with MediaCodec into an MP4
/// that MediaMuxer writes, in the app's own storage, from a foreground
/// service that keeps working with the screen off; the chapter marks and
/// tags are written into that file here (mp4_chapters.dart), and it is then
/// copied to Audiobooks or to where the reader chose. A save that stops
/// part way leaves no file behind.
///
/// A save is the engine's, as reading aloud is (ReadingCore.kt), not the
/// activity's: swiped away from Recents, TomeVoice goes on saving, its
/// notification's Cancel still stops it, and opened again it shows how far
/// the save is (showRunningExport).
///
/// The phone's speech engine is one, with one progress listener: a save
/// cannot run while a book is read aloud. Reading aloud stops for a save,
/// when the reader agrees, and a book started meanwhile stops the save.

/// The AAC the file holds: mono, at the voice's own rate, 64 kbps.
const exportBitRate = 64000;

/// The rates AAC-LC can be encoded at.
const _aacRates = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000];

/// [rate] if AAC can be encoded at it, else the next one up it can.
int aacRate(int rate) => _aacRates.contains(rate) ? rate : _aacRates.firstWhere((r) => r >= rate, orElse: () => 48000);

/// The longest single file: past about 145 hours an MP4 written with 32-bit
/// offsets runs out of them at 64 kbps.
const maxExportLength = Duration(hours: 120);

/// What a save covers: the sentences from [from] up to [to] of [layout],
/// and the chapters marked in the file.
class ExportPlan {
  ExportPlan._(this.layout, this.from, this.to, this.marks, {required this.wholeBook, required this.chapters});

  /// Chapter [chapter] alone, as an .m4a with no marks.
  factory ExportPlan.chapter(ReadingLayout layout, int chapter) {
    if (layout.chapters.isEmpty) return ExportPlan.book(layout);
    final c = chapter.clamp(0, layout.chapters.length - 1);
    final (first, count) = layout.chapterRange(c);
    return ExportPlan._(layout, first, first + count, const [], wholeBook: false, chapters: 1);
  }

  /// The whole book, as an .m4b with a mark at each chapter. A `chpl` box
  /// holds 255: a book with more is marked at every second, third... one.
  factory ExportPlan.book(ReadingLayout layout) {
    final n = layout.chapters.length;
    if (n == 0) {
      return ExportPlan._(layout, 0, layout.units.length, [(unit: 0, title: layout.book.metadata.title)],
          wholeBook: true, chapters: 1);
    }
    final step = (n + maxChapterMarks - 1) ~/ maxChapterMarks;
    return ExportPlan._(
      layout,
      0,
      layout.units.length,
      [for (var c = 0; c < n; c += step) (unit: layout.chapterFirstUnit[c], title: layout.chapterTitle(c))],
      wholeBook: true,
      chapters: n,
    );
  }

  final ReadingLayout layout;
  final int from;
  final int to;

  /// The chapters marked in the file: the sentence each starts at, and its
  /// title.
  final List<({int unit, String title})> marks;
  final bool wholeBook;

  /// How many chapters the save covers (more than [marks] for a book of
  /// more than 255).
  final int chapters;

  int get _firstChapter => layout.chapterOfUnit(from);

  /// The chapter [unit] is in, counted from 1 within the save.
  int chapterOf(int unit) => layout.chapterOfUnit(unit) - _firstChapter + 1;

  /// The first chapter's title: "this chapter" names it.
  String get firstTitle => layout.chapterTitle(_firstChapter);

  /// How often a chapter is marked: 1 for every chapter.
  int get markEvery => marks.length < 2 ? 1 : (chapters / marks.length).ceil();

  int get words => layout.wordsBefore[to] - layout.wordsBefore[from];

  /// Characters of text before sentence [unit], counted from [from].
  late final Int32List _charsBefore = () {
    final out = Int32List(to - from + 1);
    for (var i = from; i < to; i++) {
      out[i - from + 1] = out[i - from] + layout.units[i].text.length;
    }
    return out;
  }();

  int charsBefore(int unit) => _charsBefore[(unit - from).clamp(0, to - from)];

  int get chars => _charsBefore.last;

  String get extension => wholeBook ? 'm4b' : 'm4a';
}

/// About how long [plan] runs read at [speed] with [wordGapMs] between
/// words: the app's 165 words a minute, plus the gaps.
Duration roughLength(ExportPlan plan, double speed, int wordGapMs) =>
    Duration(milliseconds: (plan.words / (165 * speed) * 60000 + plan.words * wordGapMs).round());

/// About how large a file of [length] is: its audio at [exportBitRate],
/// and a little for the boxes around it (sizes of samples, chapters).
int fileBytes(Duration length) => (length.inMilliseconds * exportBitRate / 8000 * 1.02).round() + 64 * 1024;

/// Space wanted to save a file of about [bytes]: the file as it is made,
/// its copy where it goes, and some to spare.
int spaceWanted(int bytes) => bytes * 2 + 50 * 1024 * 1024;

/// How this phone makes speech in [voice]: milliseconds of work, and of
/// audio, per character of text, from one sentence of [plan] made as a
/// save makes it. Null when there is nothing to time or the voice failed.
Future<({double workMs, double audioMs})?> measureSpeech(PlaybackScheduler voice, ExportPlan plan) async {
  final units = plan.layout.units;
  int? pick;
  var longest = 0;
  for (var i = plan.from; i < plan.to && i < plan.from + 400; i++) {
    final n = units[i].text.length;
    if (n >= 60 && n <= 240) {
      pick = i;
      break;
    }
    if (n > longest) {
      longest = n;
      pick = i;
    }
  }
  final at = pick;
  if (at == null) return null;
  final text = (voice.respell?.call(units[at]) ?? Respelled.same(units[at].text)).text;
  if (!PlaybackScheduler.sayable(text) || text.length < 10) return null;
  final narrator = voice.voiceNameOf();
  try {
    // A natural voice is loaded first (a second or two): not its speed.
    final natural = neuralVoiceFor(narrator);
    if (natural != null) await NeuralEngine.instance.warm(natural);
    final watch = Stopwatch()..start();
    final r = await makeSentence(
      service: voice.service,
      text: text,
      settings: voice.settingsFor(text),
      engineId: voice.engineIdOf(),
      narrator: narrator,
      dialogue: null,
      pauseAfterMs: () => voice.pauseAfter(at),
    );
    watch.stop();
    if (r == null) return null;
    return (workMs: watch.elapsedMilliseconds / text.length, audioMs: r.totalFrames * 1000 / r.sampleRate / text.length);
  } on Object catch (e) {
    debugPrint('TomeVoice: could not time the voice: $e');
    return null;
  }
}

/// The voice and settings [layout] of book [bookId] is read with, as they
/// are now: what the save is made with from start to end, even if they are
/// changed meanwhile. The same set-up as reading aloud (readingScheduler).
PlaybackScheduler exportVoice({
  required ReadingLayout layout,
  required String bookId,
  required String language,
  SpeechService service = const SpeechService(),
}) {
  final now = ListeningPrefs.loaded ?? ListeningPrefs.memory;
  final frozen = ListeningPrefs.fromJson(now.toJson());
  return readingScheduler(layout: layout, prefs: () => frozen, language: language, bookId: bookId, service: service);
}

/// [text] as a file name: no characters a file system refuses, not too long.
String safeFileName(String text) {
  final cleaned = text.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = String.fromCharCodes(cleaned.runes.take(100)).trim().replaceAll(RegExp(r'[. ]+$'), '');
  return short.isEmpty ? 'TomeVoice' : short;
}

/// A save stopped part way, by the reader or by a book read aloud.
class ExportCancelled implements Exception {
  const ExportCancelled();
}

/// A save that could not be made: [message] says why, to show.
class ExportFailed implements Exception {
  const ExportFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where the encoder's audio goes: opened at the rate of the first
/// sentence, then given each sentence's PCM16.
abstract class PcmSink {
  Future<void> open(int sampleRate);

  /// Completes once there is room for more (the encoder has caught up).
  Future<void> add(Uint8List pcm);

  /// Completes when everything given has been taken.
  Future<void> flush();
}

/// PCM to the platform's encoder over [channel], in pieces of at most
/// [chunkBytes], with no more than [inFlight] pieces unanswered: the next
/// waits for the encoder to take one, so a book of twelve hours never sits
/// in memory, only a sentence and a few pieces.
class ChannelPcmSink implements PcmSink {
  ChannelPcmSink(this.channel, {this.chunkBytes = 64 * 1024, this.inFlight = 2});

  final MethodChannel channel;
  final int chunkBytes;
  final int inFlight;

  /// The file the encoder writes, once open.
  String? path;

  final _waiting = <Future<void>>{};
  Object? _error;

  @override
  Future<void> open(int sampleRate) async {
    path = await channel.invokeMethod<String>('begin', {'sampleRate': sampleRate, 'bitRate': exportBitRate});
  }

  @override
  Future<void> add(Uint8List pcm) async {
    for (var at = 0; at < pcm.length; at += chunkBytes) {
      while (_waiting.length >= inFlight) {
        await Future.any(_waiting);
      }
      final error = _error;
      if (error != null) throw error;
      final piece = Uint8List.sublistView(pcm, at, math.min(at + chunkBytes, pcm.length));
      late final Future<void> sent;
      sent = channel
          .invokeMethod<void>('write', {'pcm': piece})
          .then<void>((_) {}, onError: (Object e) {
            _error ??= e;
          })
          .whenComplete(() => _waiting.remove(sent));
      _waiting.add(sent);
    }
  }

  @override
  Future<void> flush() async {
    await Future.wait([..._waiting]);
    final error = _error;
    if (error != null) throw error;
  }
}

/// How far a save has got.
@immutable
class RenderProgress {
  const RenderProgress({required this.done, required this.total, required this.chapter, required this.chapters});

  /// Characters of text made, of [total].
  final int done;
  final int total;

  /// The chapter being made, from 1, of [chapters].
  final int chapter;
  final int chapters;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// What the renderer made: how much audio, at what rate, with the chapters
/// where they start in it, and how many lines the voice could not say.
@immutable
class RenderResult {
  const RenderResult({required this.frames, required this.sampleRate, required this.marks, required this.unsaid});

  final int frames;
  final int sampleRate;
  final List<ChapterMark> marks;
  final int unsaid;

  Duration get length => Duration(microseconds: frames * 1000000 ~/ sampleRate);
}

/// A sentence the voice would not say (after asking again where that is
/// worth it): left out, as reading aloud leaves it out.
class _Unsaid implements Exception {
  const _Unsaid(this.message);
  final String message;
}

/// Makes [plan]'s sentences one after another, as reading aloud makes them
/// ([makeSentence], with [voice]'s voices and settings), and hands their
/// PCM to [sink] instead of the player. One sentence at a time, as the
/// engine allows; a sentence the rest of the app stopped is made again.
class AudioRenderer {
  AudioRenderer({required this.plan, required this.voice, required this.sink, this.onProgress});

  final ExportPlan plan;

  /// The book's voice and settings (see [exportVoice]); never played.
  final PlaybackScheduler voice;
  final PcmSink sink;
  final void Function(RenderProgress progress)? onProgress;

  bool _cancelled = false;
  bool get cancelled => _cancelled;

  /// Stop: the sentence being made is called off (nothing else is using
  /// the voice while a save runs), and [run] ends with [ExportCancelled].
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    unawaited(voice.service.cancelSynthesis());
  }

  void _check() {
    if (_cancelled) throw const ExportCancelled();
  }

  Future<RenderResult> run() async {
    final units = plan.layout.units;
    final marks = <({int frame, String title})>[];
    var frames = 0;
    int? rate;
    double? level;
    var unsaid = 0;
    var failures = 0;
    var opened = false;
    var m = 0;
    for (var i = plan.from; i < plan.to; i++) {
      _check();
      while (m < plan.marks.length && plan.marks[m].unit <= i) {
        // A chapter with nothing said: the next one's mark takes its place.
        if (marks.isNotEmpty && marks.last.frame == frames) marks.removeLast();
        marks.add((frame: frames, title: plan.marks[m].title));
        m++;
      }
      final text = (voice.respell?.call(units[i]) ?? Respelled.same(units[i].text)).text;
      if (!PlaybackScheduler.sayable(text)) continue;
      RenderedSpeech? r;
      try {
        r = await _make(i, text, level);
        failures = 0;
      } on _Unsaid catch (e) {
        unsaid++;
        // One unspeakable line should not end the save; three in a row do.
        if (++failures >= 3) throw ExportFailed(e.message);
        continue;
      }
      if (r == null) continue;
      final to = rate ??= aacRate(r.sampleRate);
      final pcm = to == r.sampleRate ? r.pcm : resamplePcm16(r.pcm, r.sampleRate, to);
      if (!opened) {
        await sink.open(to);
        opened = true;
      }
      _check();
      await sink.add(pcm);
      frames += pcm.length ~/ 2;
      level = r.gainDb;
      onProgress?.call(RenderProgress(
        done: plan.charsBefore(i + 1),
        total: plan.chars,
        chapter: plan.chapterOf(i),
        chapters: plan.chapters,
      ));
    }
    _check();
    if (frames == 0 || rate == null) throw const ExportFailed('There was nothing in it the voice could say.');
    await sink.flush();
    return RenderResult(
      frames: frames,
      sampleRate: rate,
      marks: [for (final k in marks) ChapterMark(Duration(microseconds: k.frame * 1000000 ~/ rate), k.title)],
      unsaid: unsaid,
    );
  }

  /// Sentence [i], said as [text], made as reading makes it; null when the
  /// engine says there is nothing in it to say.
  Future<RenderedSpeech?> _make(int i, String text, double? level) async {
    var stopped = 0;
    var offline = 0;
    var broken = 0;
    while (true) {
      _check();
      final narrator = voice.voiceNameOf();
      var dialogue = voice.dialogueVoiceOf?.call();
      if (dialogue == narrator) dialogue = null;
      try {
        final r = await makeSentence(
          service: voice.service,
          text: text,
          settings: voice.settingsFor(text),
          open: dialogue == null ? null : voice.quoteOpenAt?.call(i),
          engineId: voice.engineIdOf(),
          narrator: narrator,
          dialogue: dialogue,
          pitchOf: voice.pitchOf,
          pauseAfterMs: () => voice.pauseAfter(i),
          levelDb: level,
          // Nobody is waiting to hear it: a natural voice works below the
          // screen's priority, so the phone stays smooth meanwhile.
          urgent: false,
          stale: () => _cancelled,
        );
        _check();
        return r;
      } on PlatformException catch (e) {
        _check();
        if (e.code == 'EMPTY_TEXT') return null;
        // Stopped by something else (a voice's sample): the same sentence
        // again, a moment later.
        if (e.code == 'TTS_STOPPED' && stopped++ < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        // An online voice out of reach: again, after a breath, twice.
        final away = PlaybackScheduler.offline(e);
        if (away && offline++ < 2) {
          await Future<void>.delayed(Duration(milliseconds: 700 * offline));
          continue;
        }
        throw _Unsaid(away ? PlaybackScheduler.offlineHint : e.message ?? e.code);
      } on ExportCancelled {
        rethrow;
      } on Object catch (e) {
        _check();
        // A natural voice that stopped (its worker gone, too little
        // memory): once more, in a fresh worker. Unlike reading aloud, it
        // is not read on in the phone's voice: a book would change voice
        // half way through.
        if (broken++ < 1) continue;
        final name = neuralVoiceFor(narrator)?.name ?? 'The voice';
        throw ExportFailed('$name could not speak on this phone ($e).');
      }
    }
  }
}

/// Where a save is.
enum ExportPhase { starting, making, finishing, saved, cancelled, failed }

@immutable
class ExportStatus {
  const ExportStatus(
    this.phase, {
    this.progress,
    this.left,
    this.message,
    this.uri,
    this.where,
    this.unsaid = 0,
    this.waiting = false,
  });

  final ExportPhase phase;
  final RenderProgress? progress;

  /// About how long the rest takes, once that can be told.
  final Duration? left;

  /// Why it stopped or failed, or what happened to it meanwhile.
  final String? message;

  /// The saved file, to share: a content:// address.
  final String? uri;

  /// Where it was saved, to say ("Audiobooks/Emma/Emma.m4b").
  final String? where;

  /// Lines the voice could not say, left out.
  final int unsaid;

  /// Android paused it (a foreground job's time used up): it goes on when
  /// TomeVoice is opened.
  final bool waiting;

  bool get running => phase == ExportPhase.starting || phase == ExportPhase.making || phase == ExportPhase.finishing;
}

/// "2 h 5 min", "12 min", "under a minute".
String durationLabel(Duration d) {
  final minutes = (d.inSeconds / 60).round();
  if (minutes < 1) return 'under a minute';
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// "Chapter 3 of 12 · 42% · about 10 min left".
String progressLabel(ExportStatus s) {
  final p = s.progress;
  return [
    if (p != null && p.chapters > 1) 'Chapter ${p.chapter} of ${p.chapters}',
    '${((p?.fraction ?? 0) * 100).floor()}%',
    if (s.left != null) 'about ${durationLabel(s.left!)} left',
  ].join(' · ');
}

/// One save as audio, from the first sentence to the file where it goes.
/// [current] is the one running; there is one at a time.
class AudioExport {
  AudioExport._({
    required this.plan,
    required this.voice,
    required this.bookTitle,
    required this.fileName,
    required this.folder,
    required this.tags,
    required this.destination,
  });

  /// The save running now, if any.
  static final current = ValueNotifier<AudioExport?>(null);

  static const channel = MethodChannel('tomevoice/export');

  final ExportPlan plan;
  final PlaybackScheduler voice;
  final String bookTitle;

  /// The file's name ("Emma.m4b") and its folder under Audiobooks.
  final String fileName;
  final String folder;
  final AudioTags tags;

  /// Where the reader chose (a document's address), or null for the
  /// Audiobooks folder.
  final String? destination;

  final status = ValueNotifier(const ExportStatus(ExportPhase.starting));

  late final AudioRenderer _renderer;
  late final ChannelPcmSink _sink;
  String? _stoppedBecause;
  bool _serviceStopped = false;
  final _watch = Stopwatch();
  DateTime _lastNotice = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastChapter = 0;

  /// Start saving [plan], read by [voice], as [bookTitle] by [author]. Its
  /// result is in [status]; it ends by itself.
  static AudioExport start({
    required ExportPlan plan,
    required PlaybackScheduler voice,
    required String bookTitle,
    String? author,
    Uint8List? cover,
    String? destination,
  }) {
    final running = current.value;
    if (running != null) return running;
    final chapter = plan.wholeBook ? null : plan.firstTitle;
    final job = AudioExport._(
      plan: plan,
      voice: voice,
      bookTitle: bookTitle,
      fileName: '${safeFileName(chapter == null ? bookTitle : '$bookTitle - $chapter')}.${plan.extension}',
      folder: safeFileName(bookTitle),
      tags: AudioTags(
        title: chapter ?? bookTitle,
        artist: author == null || author.trim().isEmpty ? null : author,
        album: bookTitle,
        genre: 'Audiobook',
        cover: cover,
        audiobook: true,
      ),
      destination: destination,
    );
    current.value = job;
    _listen();
    unawaited(job._run());
    return job;
  }

  /// Stop it; [because] is said (in the notification, and to [status])
  /// when it is not the reader who stopped it.
  void cancel({String? because}) {
    if (!status.value.running || status.value.phase == ExportPhase.finishing) return;
    _stoppedBecause ??= because;
    _renderer.cancel();
  }

  /// Bytes free where files are made; -1 if unknown.
  static Future<int> freeSpace() async {
    try {
      return (await channel.invokeMethod<num>('space'))?.toInt() ?? -1;
    } on Object {
      return -1;
    }
  }

  /// Whether the phone has an Audiobooks folder to save into (Android 10
  /// and later); before, the reader chooses where.
  static Future<bool> hasAudiobooksFolder() async {
    try {
      return await channel.invokeMethod<bool>('audiobooksFolder') ?? false;
    } on Object {
      return false;
    }
  }

  /// Android's save dialog, for a file named [name]; its address, or null
  /// if it was closed.
  static Future<String?> chooseWhere(String name) => channel.invokeMethod<String>('pick', {'name': name});

  /// Android's share sheet for the saved file at [uri].
  static Future<void> share(String uri) => channel.invokeMethod<void>('share', {'uri': uri});

  /// The name a save of [plan] from [bookTitle] is given.
  static String nameFor(ExportPlan plan, String bookTitle) =>
      '${safeFileName(plan.wholeBook ? bookTitle : '$bookTitle - ${plan.firstTitle}')}.${plan.extension}';

  static bool _listening = false;

  /// The notification's Cancel, and Android stopping the job's service.
  static void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'exportEvent' || call.arguments is! Map) return null;
      final type = (call.arguments as Map)['type'];
      final job = current.value;
      if (job == null) return null;
      if (type == 'cancel') job.cancel();
      if (type == 'timeout') job._onTimeout();
      return null;
    });
  }

  Future<void> _run() async {
    _sink = ChannelPcmSink(channel);
    _renderer = AudioRenderer(plan: plan, voice: voice, sink: _sink, onProgress: _onProgress);
    _hook();
    final lifecycle = AppLifecycleListener(onResume: _onResume);
    _watch.start();
    try {
      await _service('start', 'Starting…', -1);
      status.value = const ExportStatus(ExportPhase.making);
      final made = await _renderer.run();
      status.value = ExportStatus(ExportPhase.finishing, progress: status.value.progress);
      await _service('progress', 'Finishing the file…', -1);
      final out = await channel.invokeMapMethod<String, Object?>('finish');
      final path = out?['path'] as String?;
      if (path == null) throw const ExportFailed('The audio could not be finished.');
      await writeChaptersAndTags(path, marks: plan.wholeBook ? made.marks : const [], tags: tags);
      final saved = await channel.invokeMapMethod<String, Object?>('publish', {
        'path': path,
        'name': fileName,
        'folder': folder,
        'uri': destination,
      });
      final uri = saved?['uri'] as String?;
      final where = saved?['where'] as String? ?? fileName;
      final note = made.unsaid == 0 ? '' : ' ${made.unsaid} ${made.unsaid == 1 ? 'line' : 'lines'} the voice could not say '
          '${made.unsaid == 1 ? 'was' : 'were'} left out.';
      await _quiet('done', {
        'title': 'Saved as audio: $bookTitle',
        'text': '$where · ${durationLabel(made.length)}.$note',
        'uri': uri,
      });
      status.value = ExportStatus(ExportPhase.saved, uri: uri, where: where, unsaid: made.unsaid, message: note.trim());
    } on ExportCancelled {
      final why = _stoppedBecause;
      await _abort(why);
      status.value = ExportStatus(ExportPhase.cancelled, message: why);
    } on Object catch (e) {
      final why = _reason(e);
      debugPrint('TomeVoice: saving as audio failed: $e');
      await _abort('It could not be saved: $why');
      status.value = ExportStatus(ExportPhase.failed, message: why);
    } finally {
      _unhook();
      lifecycle.dispose();
      voice.dispose();
      if (identical(current.value, this)) current.value = null;
    }
  }

  /// Everything made so far deleted, the service stopped; [notice] said in
  /// a notification when the reader did not stop it themselves.
  Future<void> _abort(String? notice) async {
    await _quiet('abort', {'title': 'Not saved: $bookTitle', 'notice': notice});
    final chosen = destination;
    if (chosen != null) await _quiet('discard', {'uri': chosen});
  }

  void _onProgress(RenderProgress p) {
    final elapsed = _watch.elapsed;
    final left = p.fraction < 0.02 || p.done == 0
        ? null
        : Duration(microseconds: (elapsed.inMicroseconds * (p.total - p.done) / p.done).round());
    status.value = ExportStatus(ExportPhase.making, progress: p, left: left, waiting: _serviceStopped);
    // The notification at most once a second, and at every new chapter.
    final now = DateTime.now();
    if (now.difference(_lastNotice) < const Duration(seconds: 1) && p.chapter == _lastChapter) return;
    _lastNotice = now;
    _lastChapter = p.chapter;
    unawaited(_service('progress', progressLabel(status.value), (p.fraction * 100).floor()));
  }

  /// The service's notification: [text] under the book's name, [percent]
  /// done (-1: not known yet).
  Future<void> _service(String method, String text, int percent) async {
    if (_serviceStopped && method == 'progress') return;
    await _quiet(method, {'title': 'Saving $bookTitle as audio', 'text': text, 'percent': percent});
  }

  /// Android 15 lets a job like this run six hours a day in the background,
  /// and stopped its service: it goes on once TomeVoice is opened.
  void _onTimeout() {
    _serviceStopped = true;
    status.value = ExportStatus(status.value.phase, progress: status.value.progress, left: status.value.left, waiting: true);
  }

  void _onResume() {
    if (!_serviceStopped || !status.value.running) return;
    _serviceStopped = false;
    status.value = ExportStatus(status.value.phase, progress: status.value.progress, left: status.value.left);
    unawaited(_service('start', progressLabel(status.value), ((status.value.progress?.fraction ?? 0) * 100).floor()));
  }

  // ------------------------------------------------- one voice, one job

  void Function(PlaybackScheduler? next)? _before;
  late final void Function(PlaybackScheduler? next) _onPlay = _beforePlay;

  static const readingBegan = 'A book began reading aloud, and the voice cannot read and save at once.';

  /// Told before anything reads aloud: whatever the app did before still
  /// happens (a book read in the background stops), and the save stops
  /// too. A voice's sample (null) is short and let through.
  void _hook() {
    _before = PlaybackScheduler.beforePlay;
    PlaybackScheduler.beforePlay = _onPlay;
  }

  void _beforePlay(PlaybackScheduler? next) {
    (_before ?? BackgroundReading.claim)(next);
    if (next != null && !identical(next, voice)) cancel(because: readingBegan);
  }

  void _unhook() {
    if (identical(PlaybackScheduler.beforePlay, _onPlay)) {
      // (What a book read on in the background sets, had it been asked.)
      PlaybackScheduler.beforePlay = _before ?? BackgroundReading.claim;
    }
  }

  static Future<void> _quiet(String method, Map<String, Object?> args) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } on Object catch (e) {
      debugPrint('TomeVoice: $method: $e');
    }
  }

  static String _reason(Object e) => switch (e) {
        ExportFailed(:final message) => message,
        PlatformException(code: 'SPACE') => 'the phone ran out of space. Free some and try again.',
        PlatformException(:final message, :final code) => message ?? code,
        FileSystemException(:final message) => message,
        FormatException(:final message) => message,
        _ => '$e',
      };
}
