import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// A natural voice that runs on the phone: a Piper model (VITS), made into
/// speech by sherpa-onnx. Downloaded only when chosen, one at a time; the
/// phone's own voices stay the default and cost nothing.
class NeuralVoice {
  const NeuralVoice(this.id, this.name, this.locale, this.sizeMb, {this.hd = false, this.blurb = ''});

  /// The Piper name: "en_US-kristin-medium".
  final String id;
  final String name;
  final String locale;
  final int sizeMb;

  /// The high-quality model: richer, larger and slower.
  final bool hd;
  final String blurb;

  /// The name voices go by in the app (see [neuralPrefix]).
  String get voiceName => '$neuralPrefix$id';

  /// The full-precision model. The half-size (fp16) ones crash the engine on
  /// phones: ONNX Runtime has no fp16 kernel for one of their layers on CPU
  /// (found on the phone).
  String get url => 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-$id.tar.bz2';

  /// Piper's own recording of this voice (about 100 KB), to hear before
  /// downloading it: en_US-kristin-medium is en/en_US/kristin/medium.
  String get sampleUrl {
    final parts = id.split('-');
    final lang = parts.first.split('_').first;
    return 'https://huggingface.co/rhasspy/piper-voices/resolve/main/$lang/${parts.join('/')}/samples/speaker_0.mp3';
  }
}

/// Voice names that start with this are TomeVoice's own, not the phone's.
const neuralPrefix = 'neural:';

bool isNeural(String? voiceName) => voiceName?.startsWith(neuralPrefix) ?? false;

/// The voices on offer: English for now.
const neuralVoices = [
  NeuralVoice('en_US-kristin-medium', 'Kristin', 'en-US', 64, blurb: 'Warm and clear'),
  NeuralVoice('en_US-norman-medium', 'Norman', 'en-US', 64, blurb: 'Calm, a little deep'),
  NeuralVoice('en_GB-alan-medium', 'Alan', 'en-GB', 64, blurb: 'Steady British reader'),
  NeuralVoice('en_GB-jenny_dioco-medium', 'Jenny', 'en-GB', 64, blurb: 'Bright British voice'),
  NeuralVoice('en_GB-cori-medium', 'Cori', 'en-GB', 64, blurb: 'Soft and expressive'),
  NeuralVoice('en_US-lessac-high', 'Lessac', 'en-US', 110, hd: true, blurb: 'The richest, needs a faster phone'),
  NeuralVoice('en_US-ryan-high', 'Ryan', 'en-US', 110, hd: true, blurb: 'Deep and full, needs a faster phone'),
];

NeuralVoice? neuralVoiceFor(String? voiceName) {
  if (!isNeural(voiceName)) return null;
  final id = voiceName!.substring(neuralPrefix.length);
  return neuralVoices.where((v) => v.id == id).firstOrNull;
}

/// Where voices are kept, and which are here.
class NeuralVoices extends ChangeNotifier {
  NeuralVoices._();

  static final instance = NeuralVoices._();

  Directory? _dir;

  /// Voice id -> download progress (0..1), while downloading.
  final downloading = <String, double>{};

  Directory get dir => _dir ?? Directory.systemTemp;

  void attach(Directory root) {
    _dir = Directory('${root.path}/voices');
    // Folders from an earlier format (the fp16 models, which crash the
    // engine) or an unfinished unpacking are not voices: clear them. A
    // download cut short is kept, to go on from where it stopped.
    try {
      for (final e in dir.listSync()) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if ((!name.startsWith('piper-') && !name.endsWith(_partial)) || name.endsWith('.unpacking')) {
          e.deleteSync(recursive: true);
        }
      }
    } on Object {
      // No voices folder yet.
    }
  }

  static const _partial = '.tar.bz2.part';

  /// No data for this long and a download has stalled: it stops, and can
  /// go on from there (it once sat at "Downloading n%" for good).
  static const stallAfter = Duration(seconds: 30);

  Directory folder(NeuralVoice v) => Directory('${dir.path}/piper-${v.id}');

  bool installed(NeuralVoice v) => File('${folder(v).path}/${v.id}.onnx').existsSync();

  List<NeuralVoice> get installedVoices => [for (final v in neuralVoices) if (installed(v)) v];

  /// Downloads called off from the screen, and the connections they use.
  final _cancelled = <String>{};
  final _clients = <String, HttpClient>{};

  /// Stop downloading [v] (at once, data coming or not); what came is deleted.
  void cancel(NeuralVoice v) {
    if (!downloading.containsKey(v.id)) return;
    _cancelled.add(v.id);
    _clients[v.id]?.close(force: true);
  }

  /// Fetch [v] and unpack it, reporting progress; the archive is not kept.
  ///
  /// A download cut short (a lost connection, a stall) keeps what came, and
  /// the next one asks the server only for the rest. Before unpacking, the
  /// size is checked against what the server said; unpacking checks the
  /// archive's own checksums and that the voice's files are all there.
  /// Throws [DownloadCancelled] when called off with [cancel]. [source] and
  /// [stall] stand in for the voice's address and [stallAfter] in tests.
  Future<void> download(NeuralVoice v, {@visibleForTesting Uri? source, Duration stall = stallAfter}) async {
    if (downloading.containsKey(v.id)) return;
    _cancelled.remove(v.id);
    downloading[v.id] = 0;
    notifyListeners();
    final part = File('${dir.path}/${v.id}$_partial');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _clients[v.id] = client;
    var keepPart = true;
    try {
      await dir.create(recursive: true);
      for (var attempt = 0;; attempt++) {
        final have = await part.exists() ? await part.length() : 0;
        final req = await client.getUrl(source ?? Uri.parse(v.url));
        if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final res = await req.close();
        // The part on the phone is the whole file, or not this one: start over.
        if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable && attempt == 0) {
          await res.drain<void>();
          await part.delete();
          continue;
        }
        final resumed = res.statusCode == HttpStatus.partialContent && have > 0;
        if (res.statusCode != HttpStatus.ok && !resumed) {
          throw HttpException('The voice could not be fetched (${res.statusCode})');
        }
        final from = resumed ? have : 0;
        final total = resumed ? _totalOf(res.headers.value(HttpHeaders.contentRangeHeader)) : res.contentLength;
        final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        var got = from;
        final expected = total > 0 ? total : v.sizeMb * 1024 * 1024;
        try {
          await for (final chunk in res.timeout(stall)) {
            if (_cancelled.contains(v.id)) throw const DownloadCancelled();
            sink.add(chunk);
            got += chunk.length;
            downloading[v.id] = 0.9 * (got / expected).clamp(0.0, 1.0);
            notifyListeners();
          }
        } finally {
          await sink.close();
        }
        if (total > 0 && got != total) throw const HttpException('The download was cut short');
        break;
      }
      // Unpacking a few hundred files takes a moment: off the screen's isolate.
      // Only the two paths go across: a closure that held this object (and
      // so the screens listening to it) cannot be sent to another isolate.
      final from = part.path;
      final into = folder(v).path;
      final model = '${v.id}.onnx';
      // A broken archive is not worth resuming: it starts over next time.
      keepPart = false;
      await Isolate.run(() => _unpack(from, into, model));
      downloading.remove(v.id);
      notifyListeners();
    } on Object {
      // Called off: whatever the closed connection threw, it is that.
      final cancelled = _cancelled.remove(v.id);
      if (cancelled) keepPart = false;
      downloading.remove(v.id);
      final f = folder(v);
      if (!installed(v) && await f.exists()) await f.delete(recursive: true);
      notifyListeners();
      if (cancelled) throw const DownloadCancelled();
      rethrow;
    } finally {
      _clients.remove(v.id);
      client.close(force: true);
      if (!keepPart && await part.exists()) await part.delete();
    }
  }

  /// The whole size from "bytes 100-199/2000"; 0 when it is not said.
  static int _totalOf(String? range) => int.tryParse(range?.split('/').last.trim() ?? '') ?? 0;

  /// Space the natural voices take, in bytes.
  int get bytesUsed {
    if (!dir.existsSync()) return 0;
    var n = 0;
    for (final f in dir.listSync(recursive: true)) {
      if (f is File) n += f.lengthSync();
    }
    return n;
  }

  /// Every voice off the phone, and the folder with them.
  Future<void> removeAll() async {
    for (final v in installedVoices) {
      await NeuralEngine.instance.unload(v);
    }
    if (await dir.exists()) await dir.delete(recursive: true);
    notifyListeners();
  }

  Future<void> remove(NeuralVoice v) async {
    await NeuralEngine.instance.unload(v);
    final f = folder(v);
    if (await f.exists()) await f.delete(recursive: true);
    notifyListeners();
  }
}

/// A download called off from the screen.
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Unpack the archive at [archive] into [into], dropping its top folder.
/// Streamed through files (the bz2 to a plain tar beside it, then each file
/// out of that), so memory stays small however large the voice: reading it
/// whole took about four times its size. The bz2's own checksums are
/// checked, and the voice must have its [model], its tokens and its
/// pronunciation data, or nothing is kept (a half voice crashed the engine).
void _unpack(String archive, String into, String model) {
  final tarPath = '$archive.tar';
  final work = Directory('$into.unpacking');
  try {
    final input = InputFileStream(archive);
    final plain = OutputFileStream(tarPath);
    final whole = BZip2Decoder().decodeStream(input, plain, verify: true);
    input.closeSync();
    plain.closeSync();
    if (!whole) throw const FormatException('The voice arrived damaged. Download it again.');
    if (work.existsSync()) work.deleteSync(recursive: true);
    final tarIn = InputFileStream(tarPath);
    try {
      for (final f in TarDecoder().decodeStream(tarIn)) {
        final parts = f.name.split('/');
        final rel = parts.skip(1).join('/');
        if (!f.isFile || rel.isEmpty || parts.contains('..')) continue;
        final path = '${work.path}/$rel';
        File(path).parent.createSync(recursive: true);
        final out = OutputFileStream(path);
        f.writeContent(out);
        out.closeSync();
      }
    } finally {
      tarIn.closeSync();
    }
    final onnx = File('${work.path}/$model');
    if (!onnx.existsSync() ||
        onnx.lengthSync() < 1024 * 1024 ||
        !File('${work.path}/tokens.txt').existsSync() ||
        !Directory('${work.path}/espeak-ng-data').existsSync()) {
      throw const FormatException('The voice arrived incomplete. Download it again.');
    }
    final out = Directory(into);
    if (out.existsSync()) out.deleteSync(recursive: true);
    work.renameSync(out.path);
  } finally {
    if (File(tarPath).existsSync()) File(tarPath).deleteSync();
    if (work.existsSync()) work.deleteSync(recursive: true);
  }
}

/// Speech from a natural voice, made on a worker isolate that keeps the
/// voice loaded (loading takes a second or two; a sentence then takes a
/// fraction of its own length).
///
/// A long sentence is made in pieces cut where it pauses anyway
/// ([clausePieces]), and a sentence called off ([cancel], a jump) stops at
/// the next piece: a jump used to wait for the whole sentence being made,
/// seconds of it at low priority. The worker is watched: one that dies or
/// stops answering fails the sentence it had (so reading falls back to the
/// phone's voice) and a fresh one starts with the next.
class NeuralEngine {
  NeuralEngine._();

  static final instance = NeuralEngine._();

  SendPort? _worker;
  Isolate? _isolate;
  ReceivePort? _inbox;
  Future<SendPort>? _starting;
  int _next = 0;
  final _waiting = <int, Completer<Map<String, Object?>>>{};

  /// The worker's thread and its engine's threads, as it last said: raised
  /// to the screen's priority when a sentence is called off, so the piece
  /// under way finishes fast.
  List<int> _busyThreads = const [];

  /// Bumped by [cancel]: a sentence being made stops before its next piece.
  int _cancels = 0;

  /// Loaded voices are let go after this long unused: a model holds a
  /// hundred MB or more, kept after the reader switched voice or stopped.
  static const idleUnload = Duration(minutes: 3);
  Timer? _idle;

  /// How many voices stay loaded at once: two on a phone with the memory
  /// for it (about 6 GB), so a natural narrator and a natural dialogue voice
  /// do not take turns reloading at every quote (a second or two each, more
  /// for HD); one elsewhere.
  late final int slots = slotsFor(_memTotalKb());

  /// Whether two natural voices (a narrator and a dialogue voice) can stay
  /// loaded together on this phone.
  bool get holdsTwo => slots >= 2;

  @visibleForTesting
  static int slotsFor(int? memTotalKb) => (memTotalKb ?? 0) >= 5200 * 1024 ? 2 : 1;

  static int? _memTotalKb() {
    try {
      final line = File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal:'));
      return int.tryParse(RegExp(r'\d+').firstMatch(line)?.group(0) ?? '');
    } on Object {
      return null;
    }
  }

  Future<SendPort> _port() => _starting ??= _spawn();

  Future<SendPort> _spawn() async {
    final inbox = ReceivePort();
    _inbox = inbox;
    final ready = Completer<SendPort>();
    inbox.listen((msg) {
      if (!identical(_inbox, inbox)) return;
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
      } else if (msg is Map) {
        final fatal = msg['fatal'];
        if (fatal != null) {
          _died('$fatal', ready);
          return;
        }
        final threads = msg['threads'];
        if (threads is List) _busyThreads = [for (final t in threads) if (t is int) t];
        _waiting.remove(msg['id'])?.complete(Map<String, Object?>.from(msg));
      } else if (msg is List) {
        // An error the worker did not catch: it is ending.
        _died(msg.isEmpty ? 'an error' : '${msg.first}', ready);
      } else if (msg == null) {
        _died('it exited', ready);
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        inbox.sendPort,
        debugName: 'neural-voice',
        onError: inbox.sendPort,
        onExit: inbox.sendPort,
      );
    } on Object catch (e) {
      _died('it could not start: $e', ready);
    }
    return _worker = await ready.future;
  }

  /// The worker is gone: every sentence waiting on it fails (and is read in
  /// the phone's voice), and the next one starts a fresh worker.
  void _died(String why, [Completer<SendPort>? ready]) {
    debugPrint('Natural voices: the worker stopped ($why)');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _inbox?.close();
    _inbox = null;
    _worker = null;
    _starting = null;
    _busyThreads = const [];
    final waiting = Map.of(_waiting);
    _waiting.clear();
    for (final done in waiting.values) {
      done.complete({'error': 'The natural voice stopped working ($why)'});
    }
    if (ready != null && !ready.isCompleted) {
      ready.completeError(Exception('The natural voice stopped working ($why)'));
    }
  }

  /// Send [message] and wait for the answer, no longer than [timeout]: a
  /// worker stuck in the engine is replaced rather than waited on for ever
  /// (Play once spun for good when the worker died).
  Future<Map<String, Object?>> _ask(Map<String, Object?> message, Duration timeout) async {
    final port = await _port();
    final id = _next++;
    final done = Completer<Map<String, Object?>>();
    _waiting[id] = done;
    port.send({...message, 'id': id});
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      _waiting.remove(id);
      _died('no answer in ${timeout.inSeconds} s');
      throw Exception('The natural voice took too long and was restarted.');
    }
  }

  /// Long enough for a model to load (longer for HD on a slow phone) and a
  /// piece to be made at no faster than real time.
  static Duration _timeoutFor(String text) => Duration(seconds: 45, milliseconds: 150 * text.length);

  /// Call off the sentence being made: it stops before its next piece, and
  /// the piece under way finishes at the screen's priority.
  void cancel() {
    _cancels++;
    for (final t in _busyThreads) {
      _setNice(t, 0);
    }
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(idleUnload, () {
      _worker?.send({'id': -1, 'op': 'unload', 'model': null});
    });
  }

  /// Say [text] in [voice] at [speed]; a WAV in [outDir], as the phone's
  /// voices return (`wavPath`, no word timings: they are worked out from its
  /// pauses, and from `anchors`, the frames where its pieces were joined).
  ///
  /// [urgent]: someone is waiting to hear it (the first sentence, or the
  /// voice about to run out), so it is made at the screen's own priority.
  /// Otherwise it is made at a low one, seconds ahead of the voice.
  /// [pieces] false makes it in one go (the speed test). Throws a
  /// `TTS_STOPPED` [PlatformException] when called off with [cancel].
  Future<Map<String, Object?>> synthesise({
    required NeuralVoice voice,
    required String text,
    required double speed,
    required String outDir,
    bool urgent = true,
    bool pieces = true,
  }) async {
    final cancels = _cancels;
    _idle?.cancel();
    final parts = pieces ? clausePieces(text) : [(start: 0, text: text)];
    final job = _next++;
    try {
      for (var k = 0; k < parts.length; k++) {
        if (_cancels != cancels) throw PlatformException(code: 'TTS_STOPPED', message: 'Synthesis cancelled');
        final last = k == parts.length - 1;
        final r = await _ask({
          'op': 'say',
          'job': job,
          'last': last,
          'dir': NeuralVoices.instance.folder(voice).path,
          'model': voice.id,
          'text': parts[k].text,
          'speed': speed,
          'urgent': urgent,
          'slots': slots,
          'out': '$outDir/neural-$job.wav',
        }, _timeoutFor(parts[k].text));
        if (r['error'] != null) throw Exception(r['error']);
        final loadMs = r['loadMs'] as int? ?? 0;
        if (loadMs > 0) debugPrint('Natural voice ${voice.id}: loaded in $loadMs ms');
        if (!last) continue;
        final joins = r['joins'] as List? ?? const [];
        return {
          'wavPath': r['wav'],
          'engineId': 'tomevoice.neural',
          'rangeEvents': const [],
          'anchors': [
            for (var j = 0; j < joins.length && j + 1 < parts.length; j++)
              {'char': parts[j + 1].start, 'frame': joins[j]},
          ],
        };
      }
      throw StateError('nothing to say');
    } on Object {
      // What the worker kept of this sentence is not wanted now.
      if (parts.length > 1) _worker?.send({'id': -1, 'op': 'drop', 'job': job});
      rethrow;
    } finally {
      _armIdle();
    }
  }

  /// Load [voice] and say one word with it, unheard, so the first sentence
  /// read aloud does not wait for the model (a second or two, longer for
  /// HD) or for the engine's slower first run. Done at low priority.
  Future<void> warm(NeuralVoice voice) async {
    if (!NeuralVoices.instance.installed(voice)) return;
    try {
      final r = await synthesise(
        voice: voice,
        text: 'Hi.',
        speed: 1,
        outDir: Directory.systemTemp.path,
        urgent: false,
      );
      await File(r['wavPath']! as String).delete();
    } on Object {
      // Reading will load it, and say why if it cannot.
    }
  }

  /// Seconds of speech made per second of work for [voice] on this phone,
  /// from one long sentence: above 1 it keeps up with reading aloud.
  Future<double> measure(NeuralVoice voice, String outDir) async {
    const text = 'It was a bright cold day in April, and the clocks were striking thirteen, '
        'while the wind swept little eddies of dust and torn paper into spirals along the street.';
    // The first call loads the voice; time the second, made in one go.
    final warm = await synthesise(voice: voice, text: 'Hello.', speed: 1, outDir: outDir);
    await File(warm['wavPath']! as String).delete().catchError((Object _) => File(''));
    final watch = Stopwatch()..start();
    final r = await synthesise(voice: voice, text: text, speed: 1, outDir: outDir, pieces: false);
    watch.stop();
    final wav = File(r['wavPath']! as String);
    final seconds = (await wav.length() - 44) / 2 / 22050;
    await wav.delete();
    return seconds / (watch.elapsedMilliseconds / 1000);
  }

  Future<void> unload(NeuralVoice voice) async {
    if (_worker == null) return;
    try {
      await _ask({'op': 'unload', 'model': voice.id}, const Duration(seconds: 20));
    } on Object {
      // A worker that cannot answer holds nothing worth keeping.
    }
  }
}

/// [text] cut where a voice pauses anyway (after a comma, a semicolon, a
/// colon, a dash, a question or an exclamation) into pieces of at least
/// [min] characters, when it is longer than [over]. Each piece keeps its
/// mark, so the voice still says it as a clause; [start] is where it begins
/// in [text].
List<({int start, String text})> clausePieces(String text, {int over = 90, int min = 40}) {
  if (text.length <= over) return [(start: 0, text: text)];
  final out = <({int start, String text})>[];
  var from = 0;
  for (final m in _clauseEnd.allMatches(text)) {
    if (m.end - from < min) continue;
    if (text.length - m.end < min) break;
    out.add((start: from, text: text.substring(from, m.end).trimRight()));
    from = m.end;
  }
  out.add((start: from, text: text.substring(from)));
  return out;
}

final _clauseEnd = RegExp('[,;:—–!?…]["”’)\\]]*\\s+');

/// One loaded voice in the worker, and the engine's own threads (ONNX
/// Runtime's), found when it was made.
class _Engine {
  _Engine(this.tts, this.threads);
  final sherpa.OfflineTts tts;
  final List<int> threads;
}

/// A sentence being made in pieces: joined when its last piece is done.
class _Job {
  _Job(this.rate);
  final int rate;
  final pieces = <Float32List>[];

  /// The pieces as one: the silence between two kept to a natural pause
  /// (the first piece's tail no longer than 180 ms, the next one's lead-in
  /// 15 ms, and at least 80 ms in all, as a clause mark asks), with the frame
  /// each piece after the first begins at.
  ({Float32List samples, List<int> joins}) joined() {
    final keepTail = rate * 180 ~/ 1000;
    final keepLead = rate * 15 ~/ 1000;
    final atLeast = rate * 80 ~/ 1000;
    final out = <double>[];
    final joins = <int>[];
    for (var k = 0; k < pieces.length; k++) {
      final p = pieces[k];
      var a = 0;
      var b = p.length;
      if (k > 0) {
        final lead = _quietRun(p, forward: true);
        a = math.max(0, lead - keepLead);
        final gap = (lead - a) + _trailingQuiet(out);
        for (var i = gap; i < atLeast; i++) {
          out.add(0);
        }
        joins.add(out.length);
      }
      if (k < pieces.length - 1) b = math.min(p.length, p.length - _quietRun(p, forward: false) + keepTail);
      for (var i = a; i < b; i++) {
        out.add(p[i]);
      }
    }
    return (samples: Float32List.fromList(out), joins: joins);
  }

  static const _quiet = 0.003; // about -50 dBFS

  static int _quietRun(Float32List p, {required bool forward}) {
    var n = 0;
    while (n < p.length && p[forward ? n : p.length - 1 - n].abs() < _quiet) {
      n++;
    }
    return n;
  }

  static int _trailingQuiet(List<double> out) {
    var n = 0;
    while (n < out.length && out[out.length - 1 - n].abs() < _quiet) {
      n++;
    }
    return n;
  }
}

/// The worker: up to `slots` loaded voices, the one used longest ago let go
/// first when another is needed.
Future<void> _workerMain(SendPort out) async {
  final inbox = ReceivePort();
  try {
    sherpa.initBindings();
  } on Object catch (e) {
    // Said, not thrown: the app falls back to the phone's voice and says why.
    out.send({'fatal': 'the engine could not start: $e'});
    inbox.close();
    return;
  }
  out.send(inbox.sendPort);
  // Most recently used last.
  final loaded = <String, _Engine>{};
  final jobs = <int, _Job>{};
  await for (final msg in inbox) {
    final m = msg as Map;
    final id = m['id'];
    try {
      switch (m['op']) {
        case 'unload':
          final model = m['model'] as String?;
          for (final key in [...loaded.keys]) {
            if (model == null || key == model) loaded.remove(key)!.tts.free();
          }
          out.send({'id': id});
        case 'drop':
          jobs.remove(m['job']);
        default:
          final model = m['model'] as String;
          final urgent = m['urgent'] != false;
          final slots = (m['slots'] as int? ?? 1).clamp(1, 2);
          final tid = _tid();
          var loadMs = 0;
          var engine = loaded.remove(model);
          if (engine == null) {
            // Room for it: the voice used longest ago goes, and goes first,
            // so if making the new one fails nothing points at freed memory.
            while (loaded.length >= slots) {
              loaded.remove(loaded.keys.first)!.tts.free();
            }
            final dir = m['dir'] as String;
            final watch = Stopwatch()..start();
            // Its threads start at this thread's priority; they are set for
            // each piece below.
            _setNice(tid, 0);
            final before = _threads();
            final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                vits: sherpa.OfflineTtsVitsModelConfig(
                  model: '$dir/$model.onnx',
                  tokens: '$dir/tokens.txt',
                  dataDir: '$dir/espeak-ng-data',
                ),
                numThreads: Platform.numberOfProcessors >= 8 ? 4 : 2,
                debug: false,
              ),
              maxNumSenetences: 1,
            ));
            engine = _Engine(tts, [for (final t in _threads()) if (!before.contains(t)) t]);
            loadMs = watch.elapsedMilliseconds;
          }
          loaded[model] = engine;
          // The engine's threads and this one share the work of each piece,
          // so they all take the same priority: one left behind holds up the
          // others at every step.
          final nice = urgent ? 0 : 10;
          for (final t in [tid, ...engine.threads]) {
            _setNice(t, nice);
          }
          final sherpa.GeneratedAudio audio;
          try {
            audio = engine.tts.generate(text: m['text'] as String, sid: 0, speed: (m['speed'] as num).toDouble());
          } finally {
            // This thread is the VM's, shared with other isolates (the render
            // after each sentence, the collector): it goes back as it came.
            if (!urgent) _setNice(tid, 0);
          }
          final key = m['job'] as int;
          final job = jobs.putIfAbsent(key, () => _Job(audio.sampleRate))..pieces.add(audio.samples);
          final threads = [tid, ...engine.threads];
          if (m['last'] != true) {
            out.send({'id': id, 'loadMs': loadMs, 'threads': threads});
            continue;
          }
          jobs.remove(key);
          final whole = job.joined();
          final path = m['out'] as String;
          File(path).writeAsBytesSync(wavBytes(whole.samples, job.rate));
          out.send({'id': id, 'wav': path, 'loadMs': loadMs, 'joins': whole.joins, 'threads': threads});
      }
    } on Object catch (e) {
      jobs.remove(m['job']);
      out.send({'id': id, 'error': '$e'});
    }
  }
}

/// Ids of this process's threads.
Set<int> _threads() {
  try {
    return {
      for (final e in Directory('/proc/self/task').listSync())
        if (int.tryParse(e.uri.pathSegments.where((s) => s.isNotEmpty).last) case final t?) t,
    };
  } on Object {
    return const {};
  }
}

int _tid() {
  if (!Platform.isAndroid) return 0;
  try {
    return _gettid();
  } on Object {
    return 0;
  }
}

/// Whether a thread's priority can be raised again once lowered. Android
/// allows it; on a phone that does not, nothing is lowered from then on,
/// so speech is never left slow.
bool _canRestore = true;

/// Set thread [tid]'s Linux nice value: 0 is the screen's own priority, 10
/// is below it. Speech made seconds ahead can wait a moment while the
/// screen moves (at the UI's priority its four threads took the fast cores
/// in bursts, and scrolling dropped frames whenever a natural voice read),
/// but speech someone is waiting for must not wait behind the screen. In
/// 1.0.7 every sentence was made low, the first after Play too.
void _setNice(int tid, int nice) {
  if (!Platform.isAndroid || tid <= 0) return;
  if (nice > 0 && !_canRestore) return;
  try {
    final r = _setpriority(0 /* PRIO_PROCESS: one thread, by its id */, tid, nice);
    if (r != 0 && nice == 0) _canRestore = false;
  } on Object {
    // Nothing worse than before.
  }
}

final _libc = DynamicLibrary.open('libc.so');
final _gettid = _libc.lookupFunction<Int32 Function(), int Function()>('gettid');
final _setpriority =
    _libc.lookupFunction<Int32 Function(Int32, Uint32, Int32), int Function(int, int, int)>('setpriority');

/// Float samples as a 16-bit mono WAV.
Uint8List wavBytes(Float32List samples, int sampleRate) {
  final data = ByteData(44 + samples.length * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}
