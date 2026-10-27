import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
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
    // engine) or an unfinished unpacking are not voices: clear them.
    try {
      for (final e in dir.listSync()) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!name.startsWith('piper-') || name.endsWith('.unpacking')) {
          e.deleteSync(recursive: true);
        }
      }
    } on Object {
      // No voices folder yet.
    }
  }

  Directory folder(NeuralVoice v) => Directory('${dir.path}/piper-${v.id}');

  bool installed(NeuralVoice v) => File('${folder(v).path}/${v.id}.onnx').existsSync();

  List<NeuralVoice> get installedVoices => [for (final v in neuralVoices) if (installed(v)) v];

  /// Fetch [v] and unpack it, reporting progress; the archive is not kept.
  Future<void> download(NeuralVoice v) async {
    if (downloading.containsKey(v.id)) return;
    downloading[v.id] = 0;
    notifyListeners();
    final tmp = File('${dir.path}/${v.id}.tar.bz2');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      await dir.create(recursive: true);
      final res = await (await client.getUrl(Uri.parse(v.url))).close();
      if (res.statusCode != 200) throw HttpException('The voice could not be fetched (${res.statusCode})');
      final total = res.contentLength > 0 ? res.contentLength : v.sizeMb * 1024 * 1024;
      final sink = tmp.openWrite();
      var got = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        downloading[v.id] = 0.9 * got / total;
        notifyListeners();
      }
      await sink.close();
      // Unpacking a few hundred files takes a moment: off the screen's isolate.
      // Only the two paths go across: a closure that held this object (and
      // so the screens listening to it) cannot be sent to another isolate.
      final from = tmp.path;
      final into = folder(v).path;
      await Isolate.run(() => _unpack(from, into));
      downloading.remove(v.id);
      notifyListeners();
    } on Object {
      downloading.remove(v.id);
      final f = folder(v);
      if (await f.exists()) await f.delete(recursive: true);
      notifyListeners();
      rethrow;
    } finally {
      client.close(force: true);
      if (await tmp.exists()) await tmp.delete();
    }
  }

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

/// Unpack the archive at [archive] into [into], dropping its top folder.
/// Streamed through files (the bz2 to a plain tar beside it, then each file
/// out of that), so memory stays small however large the voice: reading it
/// whole took about four times its size.
void _unpack(String archive, String into) {
  final tarPath = '$archive.tar';
  final work = Directory('$into.unpacking');
  try {
    final input = InputFileStream(archive);
    final plain = OutputFileStream(tarPath);
    BZip2Decoder().decodeStream(input, plain);
    input.closeSync();
    plain.closeSync();
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
class NeuralEngine {
  NeuralEngine._();

  static final instance = NeuralEngine._();

  SendPort? _worker;
  Future<SendPort>? _starting;
  int _next = 0;
  final _waiting = <int, Completer<Map<String, Object?>>>{};

  Future<SendPort> _port() => _starting ??= () async {
        final inbox = ReceivePort();
        final ready = Completer<SendPort>();
        inbox.listen((msg) {
          if (msg is SendPort) {
            ready.complete(msg);
          } else if (msg is Map) {
            _waiting.remove(msg['id'])?.complete(Map<String, Object?>.from(msg));
          }
        });
        await Isolate.spawn(_workerMain, inbox.sendPort, debugName: 'neural-voice');
        return _worker = await ready.future;
      }();

  /// Say [text] in [voice] at [speed]; a WAV in [outDir], as the phone's
  /// voices return (`wavPath`, no word timings: they are estimated).
  ///
  /// [urgent]: someone is waiting to hear it (the first sentence, or the
  /// voice about to run out), so it is made at the screen's own priority.
  /// Otherwise it is made at a low one, seconds ahead of the voice.
  Future<Map<String, Object?>> synthesise({
    required NeuralVoice voice,
    required String text,
    required double speed,
    required String outDir,
    bool urgent = true,
  }) async {
    final port = await _port();
    final id = _next++;
    final done = Completer<Map<String, Object?>>();
    _waiting[id] = done;
    port.send({
      'id': id,
      'op': 'say',
      'dir': NeuralVoices.instance.folder(voice).path,
      'model': voice.id,
      'text': text,
      'speed': speed,
      'urgent': urgent,
      'out': '$outDir/neural-$id.wav',
    });
    final r = await done.future;
    if (r['error'] != null) throw Exception(r['error']);
    final loadMs = r['loadMs'] as int? ?? 0;
    if (loadMs > 0) debugPrint('Natural voice ${voice.id}: loaded in $loadMs ms');
    return {'wavPath': r['wav'], 'engineId': 'tomevoice.neural', 'rangeEvents': const []};
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
    // The first call loads the voice; time the second.
    final warm = await synthesise(voice: voice, text: 'Hello.', speed: 1, outDir: outDir);
    await File(warm['wavPath']! as String).delete().catchError((Object _) => File(''));
    final watch = Stopwatch()..start();
    final r = await synthesise(voice: voice, text: text, speed: 1, outDir: outDir);
    watch.stop();
    final wav = File(r['wavPath']! as String);
    final seconds = (await wav.length() - 44) / 2 / 22050;
    await wav.delete();
    return seconds / (watch.elapsedMilliseconds / 1000);
  }

  Future<void> unload(NeuralVoice voice) async {
    final w = _worker;
    if (w == null) return;
    final id = _next++;
    final done = Completer<Map<String, Object?>>();
    _waiting[id] = done;
    w.send({'id': id, 'op': 'unload', 'model': voice.id});
    await done.future;
  }
}

/// The worker: one loaded voice at a time, kept until another is asked for.
Future<void> _workerMain(SendPort out) async {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  sherpa.initBindings();
  sherpa.OfflineTts? tts;
  String? loaded;

  /// The engine's own threads (ONNX Runtime's), found when it was made.
  var engineThreads = const <int>[];
  await for (final msg in inbox) {
    final m = msg as Map;
    final id = m['id'];
    try {
      if (m['op'] == 'unload') {
        if (loaded == m['model']) {
          tts?.free();
          tts = null;
          loaded = null;
          engineThreads = const [];
        }
        out.send({'id': id});
        continue;
      }
      final model = m['model'] as String;
      final urgent = m['urgent'] != false;
      final tid = _tid();
      var loadMs = 0;
      if (loaded != model) {
        // Forget the old engine before making the new one: if making it
        // fails, nothing is left pointing at freed memory.
        tts?.free();
        tts = null;
        loaded = null;
        engineThreads = const [];
        final dir = m['dir'] as String;
        final watch = Stopwatch()..start();
        // Its threads start at this thread's priority; they are set for
        // each sentence below.
        _setNice(tid, 0);
        final before = _threads();
        tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
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
        engineThreads = [for (final t in _threads()) if (!before.contains(t)) t];
        loaded = model;
        loadMs = watch.elapsedMilliseconds;
      }
      // The engine's threads and this one share the work of each sentence,
      // so they all take the same priority: one left behind holds up the
      // others at every step.
      final nice = urgent ? 0 : 10;
      for (final t in [tid, ...engineThreads]) {
        _setNice(t, nice);
      }
      final sherpa.GeneratedAudio audio;
      try {
        audio = tts!.generate(text: m['text'] as String, sid: 0, speed: (m['speed'] as num).toDouble());
      } finally {
        // This thread is the VM's, shared with other isolates (the render
        // after each sentence, the collector): it goes back as it came.
        if (!urgent) _setNice(tid, 0);
      }
      final path = m['out'] as String;
      File(path).writeAsBytesSync(wavBytes(audio.samples, audio.sampleRate));
      out.send({'id': id, 'wav': path, 'loadMs': loadMs});
    } on Object catch (e) {
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
