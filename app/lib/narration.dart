import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'scheduler.dart';
import 'speech_service.dart';
import 'zip_entries.dart';

/// The rate a book's own narration is played at: the voices' own, so it
/// shares their stream with the lines a voice reads.
const narrationRate = 24000;

/// Audio as the platform decodes it (NarrationAudio.kt): 16-bit samples,
/// [channels] of them interleaved, at [sampleRate], the first [firstUs] into
/// its file, which runs [durationUs] (-1: the file does not say).
typedef DecodedAudio = ({Uint8List pcm, int channels, int sampleRate, int firstUs, int durationUs});

/// The audio file of [length] bytes at [offset] in the file [path], decoded
/// from a little before [beginUs] to a little after [endUs] (-1: its end).
typedef NarrationDecoder = Future<DecodedAudio> Function({
  required String path,
  required int offset,
  required int length,
  required int beginUs,
  required int endUs,
});

/// The platform's decoder: MediaExtractor and MediaCodec, reading straight
/// from the book's file (NarrationAudio.kt).
Future<DecodedAudio> decodeOnPlatform({
  required String path,
  required int offset,
  required int length,
  required int beginUs,
  required int endUs,
}) async {
  final raw = await const MethodChannel('tomevoice/tts').invokeMapMethod<String, Object?>('narrationClip', {
    'path': path,
    'offset': offset,
    'length': length,
    'beginUs': beginUs,
    'endUs': endUs,
  });
  final pcm = raw?['pcm'];
  if (raw == null || pcm is! Uint8List) {
    throw PlatformException(code: 'NARRATION', message: 'The narration gave no audio');
  }
  int number(String key, int fallback) => (raw[key] as num?)?.toInt() ?? fallback;
  return (
    pcm: pcm,
    channels: number('channels', 1),
    sampleRate: number('sampleRate', narrationRate),
    firstUs: number('firstUs', 0),
    durationUs: number('durationUs', -1),
  );
}

/// A book's own narration read for its scheduler, and for saving the book
/// as audio: each sentence's stretch of the recording, as the book's
/// [NarrationPlan] lays its clips over the sentences, decoded from the
/// book's own EPUB a window of [windowMs] at a time, brought to
/// [narrationRate], sped up or slowed with its pitch kept, and levelled as
/// the voices are.
///
/// Of the pipeline a voice's sentence goes through, only the loudness (and
/// the speed, which an engine applies itself) touch a recording: the word
/// gap, punctuation pauses, trimmed edges and the pause after each sentence
/// would cut into a narrator's own timing. Their pauses stay as they
/// recorded them: the silence between two clips that follow on in a file
/// is played with the first; only where the recording has none to give
/// (the end of a file) does the usual pause follow.
class BookNarrationReader implements BookNarration {
  BookNarrationReader({
    required this.bookId,
    required this.layout,
    required this.chosen,
    this.decode = decodeOnPlatform,
    this.source,
  });

  final String bookId;

  /// The layout read; its plan is made again if it changes.
  final ReadingLayout Function() layout;

  /// Whether the reader chose the book's own narration for it.
  final bool Function() chosen;

  final NarrationDecoder decode;

  /// The book's EPUB; null for the one the library keeps ([files]).
  final String? source;

  /// Book id -> its EPUB, for each book with a narration the library has
  /// opened: where its audio is read from.
  static final files = <String, String>{};

  /// How much of a file is decoded at once: the next few sentences, so the
  /// decoder is not set up again for each.
  static const windowMs = 12000;

  /// The longest silence between two clips that is taken for the
  /// narrator's pause between them, and played.
  static const joinMs = 2000;

  /// How far from where its share of the letters says, a cut through a
  /// clip looks for the pause between its sentences.
  static const reachMs = 1000;

  /// The most two clips that follow on may overlap: an aligner's rounding.
  static const overlapMs = 200;

  /// Whether a clip beginning at [next] follows on from one ending at
  /// [end]: after a pause no longer than [joinMs], or overlapping it by no
  /// more than [overlapMs].
  static bool _joined(int end, int next) => next - end <= joinMs && end - next <= overlapMs;

  ReadingLayout? _planned;
  NarrationPlan? _plan;
  final _windows = <_Window>[];
  final _sources = <int, ({String path, int offset, int length})>{};
  final _durationMs = <int, int>{};
  final _cuts = <(int, double), int>{};
  final _failures = <int, int>{};
  bool? _found;

  NarrationPlan? get _current {
    final l = layout();
    if (!identical(l, _planned)) {
      _planned = l;
      _plan = NarrationPlan.of(l);
    }
    return _plan;
  }

  String? get _epub => source ?? files[bookId];

  @override
  NarrationRole at(int unit) {
    if (!chosen()) return NarrationRole.voiced;
    final plan = _current;
    final epub = _epub;
    if (plan == null || epub == null || unit < 0 || unit >= plan.roles.length) return NarrationRole.voiced;
    if (!(_found ??= File(epub).existsSync())) return NarrationRole.voiced;
    final role = plan.roles[unit];
    // A file that would not play twice: its lines go to the voice.
    if (role == NarrationRole.recorded &&
        plan.pieces[unit].any((p) => (_failures[plan.narration.clips[p.clip].audio] ?? 0) >= 2)) {
      return NarrationRole.voiced;
    }
    return role;
  }

  @override
  Future<RenderedSpeech?> make(
    int unit, {
    required PipelineSettings settings,
    required int pauseAfterMs,
    double? levelDb,
    bool Function()? stale,
  }) async {
    final plan = _current;
    if (plan == null || unit < 0 || unit >= plan.pieces.length || plan.pieces[unit].isEmpty) {
      throw StateError('The narration does not say sentence $unit');
    }
    final pieces = plan.pieces[unit];
    final clips = plan.narration.clips;
    bool gone() => stale?.call() ?? false;
    try {
      // The stretches of the recording that say it: pieces of clips that
      // follow on in one file are one stretch, the pause between them kept.
      final spans = <({int file, int from, int to})>[];
      final starts = <int>[];
      for (final p in pieces) {
        final clip = clips[p.clip];
        final from = p.from <= 0 ? clip.beginMs : await _cut(plan, p.clip, p.from, stale);
        final to = p.to >= 1 ? await _endOf(plan, p.clip, stale) : await _cut(plan, p.clip, p.to, stale);
        if (from == null || to == null || gone()) return null;
        starts.add(from);
        final last = spans.isEmpty ? null : spans.last;
        if (last != null && last.file == clip.audio && _joined(last.to, from)) {
          spans[spans.length - 1] = (file: last.file, from: last.from, to: math.max(last.to, to));
        } else {
          spans.add((file: clip.audio, from: from, to: math.max(from, to)));
        }
      }
      // A cut through a clip falls in the pause between its sentences; a
      // clip that the next follows on from keeps the pause between them (or,
      // overlapping it a little, stops where it begins).
      var natural = pieces.last.to < 1;
      final k = pieces.last.clip;
      if (!natural && k + 1 < clips.length) {
        final next = clips[k + 1];
        final end = spans.last.to;
        if (next.audio == clips[k].audio && _joined(end, next.beginMs)) {
          spans[spans.length - 1] = (file: spans.last.file, from: spans.last.from, to: math.max(spans.last.from, next.beginMs));
          natural = true;
        }
      }
      final parts = <Float32List>[];
      for (final s in spans) {
        final audio = await _audio(s.file, s.from, s.to, stale);
        if (audio == null || gone()) return null;
        parts.add(audio);
      }
      // A sentence said in several clips (in phrases, or word by word) has
      // each lit as it is said.
      final timings = <Map<String, Object?>>[];
      if (pieces.length > 1) {
        final total = parts.fold<int>(0, (n, a) => n + a.length);
        final frames = [
          for (var i = 0; i < pieces.length; i++) _frameIn(spans, parts, clips[pieces[i].clip].audio, starts[i]),
        ];
        for (var i = 0; i < pieces.length; i++) {
          timings.add({
            'cs': pieces[i].start,
            'ce': pieces[i].end,
            'fs': frames[i],
            'fe': i + 1 < pieces.length ? math.max(frames[i], frames[i + 1]) : total,
            'src': WordTimingSource.aligned.name,
          });
        }
      }
      _failures.remove(spans.first.file);
      return await _render((parts: parts, settings: settings, levelDb: levelDb, pauseMs: natural ? 0 : pauseAfterMs, timings: timings));
    } on Object {
      if (!gone()) {
        for (final p in pieces) {
          final file = clips[p.clip].audio;
          _failures[file] = (_failures[file] ?? 0) + 1;
        }
      }
      rethrow;
    }
  }

  /// [renderNarrated] on another isolate. Apart from [make], so all it takes
  /// there is the job: a closure made in [make] would take its `stale`, and
  /// with it the scheduler, which cannot cross.
  static Future<RenderedSpeech> _render(
    ({
      List<Float32List> parts,
      PipelineSettings settings,
      double? levelDb,
      int pauseMs,
      List<Map<String, Object?>> timings,
    }) job,
  ) =>
      Isolate.run(() => renderNarrated(job));

  /// Where in [spans] (heard as [parts], one after another) [ms] of [file] is.
  static int _frameIn(List<({int file, int from, int to})> spans, List<Float32List> parts, int file, int ms) {
    var before = 0;
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      if (s.file == file && ms >= s.from && ms <= s.to) {
        return before + ((ms - s.from) * narrationRate / 1000).round().clamp(0, parts[i].length);
      }
      before += parts[i].length;
    }
    return before;
  }

  /// Where clip [k] ends: its own end, or its file's (known once any of the
  /// file has been decoded).
  Future<int?> _endOf(NarrationPlan plan, int k, bool Function()? stale) async {
    final clip = plan.narration.clips[k];
    final end = clip.endMs;
    if (end != null) return end;
    var known = _durationMs[clip.audio];
    if (known == null) {
      final audio = await _audio(clip.audio, clip.beginMs, clip.beginMs + windowMs, stale);
      if (audio == null) return null;
      known = _durationMs[clip.audio] ?? clip.beginMs + audio.length * 1000 ~/ narrationRate;
    }
    return math.max(clip.beginMs, known);
  }

  /// Where in clip [k] the share [share] of its text is said: the pause
  /// nearest that share of its audio, no nearer the cuts either side of it
  /// than half way.
  Future<int?> _cut(NarrationPlan plan, int k, double share, bool Function()? stale) async {
    final had = _cuts[(k, share)];
    if (had != null) return had;
    final clip = plan.narration.clips[k];
    final end = await _endOf(plan, k, stale);
    if (end == null) return null;
    final cuts = plan.cuts[k] ?? [share];
    final i = cuts.indexWhere((c) => (c - share).abs() < 1e-9);
    final before = i > 0 ? cuts[i - 1] : 0.0;
    final after = i >= 0 && i + 1 < cuts.length ? cuts[i + 1] : 1.0;
    final length = end - clip.beginMs;
    final guess = clip.beginMs + share * length;
    final lo = math.max(clip.beginMs + (before + share) / 2 * length, guess - reachMs).floor();
    final hi = math.min(clip.beginMs + (share + after) / 2 * length, guess + reachMs).ceil();
    // From the clip's start when that is near: the sentence before the cut
    // is wanted next, from the same window.
    final from = lo - clip.beginMs <= windowMs ~/ 2 ? clip.beginMs : lo;
    final audio = await _audio(clip.audio, from, hi, stale);
    if (audio == null) return null;
    int frame(num ms) => ((ms - from) * narrationRate / 1000).round();
    final at = AudioAnalysis.quietestNear(audio, narrationRate, near: frame(guess), from: frame(lo), to: audio.length);
    return _cuts[(k, share)] = from + (at * 1000 / narrationRate).round();
  }

  /// The audio of [file] from [fromMs] to [toMs] at [narrationRate], from a
  /// window decoded for it or for the sentences before it.
  Future<Float32List?> _audio(int file, int fromMs, int toMs, bool Function()? stale) async {
    final known = _durationMs[file];
    final to = known == null ? toMs : math.min(toMs, known);
    if (to <= fromMs) return Float32List(0);
    var w = _windows.where((w) => w.holds(file, fromMs, to)).firstOrNull;
    if (w == null) {
      w = await _decodeWindow(file, fromMs, math.max(to, fromMs + windowMs));
      if (stale?.call() ?? false) return null;
      _windows.add(w);
      if (_windows.length > 3) _windows.removeAt(0);
    }
    final a = ((fromMs - w.fromMs) * narrationRate / 1000).round().clamp(0, w.samples.length);
    final b = ((to - w.fromMs) * narrationRate / 1000).round().clamp(a, w.samples.length);
    return Float32List.fromList(Float32List.sublistView(w.samples, a, b));
  }

  Future<_Window> _decodeWindow(int file, int fromMs, int toMs) async {
    final src = await _sourceOf(file);
    final known = _durationMs[file];
    final end = known == null ? toMs : math.min(toMs, known);
    final d = await decode(path: src.path, offset: src.offset, length: src.length, beginUs: fromMs * 1000, endUs: end * 1000);
    if (d.durationUs > 0) _durationMs[file] = d.durationUs ~/ 1000;
    final samples = await Isolate.run(() => monoAt(d, fromMs * 1000, end * 1000, narrationRate));
    final held = fromMs + samples.length * 1000 ~/ narrationRate;
    // Less than was asked for: the file ends there.
    if (held < end - 50 && known == null) _durationMs[file] = held;
    return _Window(file, fromMs, held < end - 50 ? held : end, samples);
  }

  Future<({String path, int offset, int length})> _sourceOf(int file) async {
    final had = _sources[file];
    if (had != null) return had;
    final epub = _epub;
    final plan = _current;
    if (epub == null || plan == null) throw const FileSystemException("The book's file is not on the phone");
    final name = plan.narration.audio[file];
    final cache = '${Directory.systemTemp.path}/narration';
    final keep = '$bookId-$file';
    final found = await Isolate.run(() => narrationSource(epub, name, cache, keep));
    return _sources[file] = found;
  }
}

/// A stretch of a decoded file, kept for the sentences after the one it
/// was decoded for.
class _Window {
  _Window(this.file, this.fromMs, this.toMs, this.samples);

  final int file;
  final int fromMs;
  final int toMs;

  /// At [narrationRate], the first at [fromMs].
  final Float32List samples;

  bool holds(int file, int from, int to) => this.file == file && from >= fromMs && to <= toMs + 2;
}

/// Where the audio file [name] of the EPUB at [epub] is read from: a
/// stretch of the EPUB itself where it is stored there whole (as audio in
/// an EPUB nearly always is, so nothing is unpacked), else a copy unpacked
/// once into the folder [cache] as [keep] (with its extension), where only
/// the copies of the book being read are kept.
({String path, int offset, int length}) narrationSource(String epub, String name, String cache, String keep) {
  final entry = zipEntries(epub)[name];
  if (entry == null) throw FileSystemException('The narration names a file the book does not have', name);
  if (entry.stored) {
    final f = File(epub).openSync();
    try {
      return (path: epub, offset: zipDataOffset(f, entry), length: entry.size);
    } finally {
      f.closeSync();
    }
  }
  final dir = Directory(cache)..createSync(recursive: true);
  final dot = name.lastIndexOf('.');
  final out = File('${dir.path}/$keep${dot > name.lastIndexOf('/') ? name.substring(dot) : ''}');
  if (!out.existsSync() || out.lengthSync() != entry.size) {
    final book = keep.substring(0, keep.lastIndexOf('-') + 1);
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.uri.pathSegments.last.startsWith(book)) {
        try {
          f.deleteSync();
        } on FileSystemException {
          // Another reading may have it open; swept another time.
        }
      }
    }
    final part = File('${out.path}.part');
    zipUnpack(epub, entry, part.path);
    part.renameSync(out.path);
  }
  return (path: out.path, offset: 0, length: entry.size);
}

/// [d] cut to [beginUs]..[endUs] of its file (an [endUs] below 0: to the
/// end of what was decoded), its channels mixed into one, at [rate].
Float32List monoAt(DecodedAudio d, int beginUs, int endUs, int rate) {
  final channels = math.max(1, d.channels);
  // A view needs an even offset; a copy has one.
  final bytes = d.pcm.offsetInBytes.isEven ? d.pcm : Uint8List.fromList(d.pcm);
  final ints = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
  final frames = ints.length ~/ channels;
  int frameAt(int us) => ((us - d.firstUs) * d.sampleRate / 1000000).round();
  final a = frameAt(beginUs).clamp(0, frames);
  final b = endUs < 0 ? frames : frameAt(endUs).clamp(a, frames);
  final mono = Float32List(b - a);
  for (var i = a; i < b; i++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += ints[i * channels + c];
    }
    mono[i - a] = sum / (channels * 32768);
  }
  return d.sampleRate == rate ? mono : resampleBandLimited(mono, d.sampleRate, rate);
}

/// One sentence of a narration made ready for the player: [job]'s parts of
/// the recording joined, at the reader's speed with the pitch kept, and
/// levelled (moving on from the sentence before's gain, as a voice's do),
/// with [job]'s pause after it. Its timings are where each clip of it
/// starts, when it has more than one.
RenderedSpeech renderNarrated(
  ({
    List<Float32List> parts,
    PipelineSettings settings,
    double? levelDb,
    int pauseMs,
    List<Map<String, Object?>> timings,
  }) job,
) {
  final total = job.parts.fold<int>(0, (n, p) => n + p.length);
  if (total == 0) {
    return RenderedSpeech(pcm: Uint8List(0), sampleRate: narrationRate, speechFrames: 0, totalFrames: 0, timings: const [], levels: Uint8List(0));
  }
  final joined = Float32List(total);
  var at = 0;
  for (final p in job.parts) {
    joined.setRange(at, at + p.length, p);
    at += p.length;
  }
  final s = job.settings;
  final gainDb = s.normaliseLoudness
      ? GainStage.smoothedGainDb(job.levelDb, GainStage.levelGainDb(joined, narrationRate))
      : null;
  final result = Pipeline([
    TimeStretchStage(s.speedScale),
    GainStage(
      volume: s.volume,
      trimDb: s.trimDb,
      normalise: s.normaliseLoudness,
      compression: s.compression,
      gainDb: gainDb,
    ),
  ]).run(SynthesisResult(
    audio: AudioBuffer(joined, narrationRate),
    wordTimings: SpeechService.timingsFromMaps(job.timings, total),
    engineId: 'tomevoice.narration',
  ));
  final audio = result.audio;
  final pause = audio.msToFrames(job.pauseMs);
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

/// Whether the EPUB at [path] has its own narration (media overlays named
/// in its manifest): read from its package document alone. False for one
/// that cannot be read.
bool epubHasNarration(String path) {
  try {
    final entries = zipEntries(path);
    final container = entries['META-INF/container.xml'];
    if (container == null) return false;
    final xml = utf8.decode(zipRead(path, container), allowMalformed: true);
    final opf = RegExp(r'''full-path\s*=\s*["']([^"']+)["']''').firstMatch(xml)?.group(1);
    final package = opf == null ? null : entries[opf] ?? entries[Uri.decodeFull(opf)];
    if (package == null) return false;
    return RegExp(r'media-overlay\s*=').hasMatch(utf8.decode(zipRead(path, package), allowMalformed: true));
  } on Object {
    return false;
  }
}
