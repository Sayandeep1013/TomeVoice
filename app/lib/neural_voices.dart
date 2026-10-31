import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, PlatformException, rootBundle;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Where the models come from: sherpa-onnx's release of speech models, in
/// full precision. The half-size (fp16) ones crash the engine on phones:
/// ONNX Runtime has no fp16 kernel for one of their layers on CPU (found on
/// the phone).
const _release = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

/// How a natural voice is made into speech, all by sherpa-onnx: Piper's
/// models (VITS) hold one voice each; Kokoro's and Kitten's hold many
/// speakers in one download.
enum NeuralKind {
  piper,
  kokoro,
  kitten;

  static NeuralKind parse(String? s) => values.firstWhere((k) => k.name == s, orElse: () => piper);
}

/// What the recordings a voice learned from may be used for, from the most
/// open to the least (docs/18 section 2).
enum LicenceUse {
  /// Public domain or CC0.
  free,

  /// Open, on conditions: credit, share-alike, a notice kept.
  credit,

  /// Personal or research use only.
  noncommercial,

  /// No licence granted ("All rights reserved").
  restricted,

  /// Not stated, or not settled.
  unclear;

  static LicenceUse parse(String? s) => values.firstWhere((u) => u.name == s, orElse: () => unclear);
}

/// The licence of the recordings a voice learned from, as the catalog
/// records it (tools/voice_catalog.py read it from the voice's model card).
class VoiceLicence {
  const VoiceLicence({
    required this.name,
    required this.use,
    this.note = '',
    this.stated = '',
    this.dataset = '',
    this.card = '',
  });

  /// "CC BY 4.0", "Public domain", "Not stated".
  final String name;
  final LicenceUse use;

  /// A plain sentence or two: what it allows, and anything else to know.
  final String note;

  /// The model card's own words, the recordings it names, and where it is.
  final String stated;
  final String dataset;
  final String card;

  static const unknown = VoiceLicence(name: 'Not stated', use: LicenceUse.unclear);

  factory VoiceLicence.fromJson(Object? json) {
    if (json is! Map) return unknown;
    String s(String key) => json[key] as String? ?? '';
    return VoiceLicence(
      name: s('name').isEmpty ? unknown.name : s('name'),
      use: LicenceUse.parse(json['use'] as String?),
      note: s('note'),
      stated: s('stated'),
      dataset: s('dataset'),
      card: s('card'),
    );
  }

  /// What it lets a reader do, in a few words.
  String get summary => switch (use) {
        LicenceUse.free => 'Free for any use',
        LicenceUse.credit => 'Free to use, on conditions',
        LicenceUse.noncommercial => 'Non-commercial use only',
        LicenceUse.restricted => 'No licence granted',
        LicenceUse.unclear => 'Licence unclear',
      };
}

/// One download that holds many voices (Kokoro, Kitten): its speakers share
/// the model, so it is downloaded, tested and removed as one.
class NeuralPack {
  const NeuralPack({
    required this.id,
    required this.kind,
    required this.name,
    required this.file,
    required this.bytes,
    required this.sampleRate,
    this.blurb = '',
    this.minMemoryMb = 0,
    this.mustKeepUp = false,
    this.licence = VoiceLicence.unknown,
  });

  /// The release's name for it, and its folder: "kokoro-multi-lang-v1_0".
  final String id;
  final NeuralKind kind;
  final String name;
  final String blurb;

  /// The model in its folder: "model.onnx".
  final String file;
  final int bytes;
  final int sampleRate;

  /// Not offered on a phone with less memory than this (Kokoro holds about
  /// 850 MB while it reads).
  final int minMemoryMb;

  /// Offered for reading only once this phone's speed test shows it keeps
  /// up: on many phones it cannot.
  final bool mustKeepUp;
  final VoiceLicence licence;

  int get sizeMb => (bytes / 1048576).round();

  String get url => '$_release/$id.tar.bz2';

  factory NeuralPack.fromJson(Map<String, Object?> j) => NeuralPack(
        id: j['id']! as String,
        kind: NeuralKind.parse(j['engine'] as String?),
        name: j['name'] as String? ?? '',
        blurb: j['blurb'] as String? ?? '',
        file: j['file'] as String? ?? 'model.onnx',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        sampleRate: (j['sampleRate'] as num?)?.toInt() ?? 24000,
        minMemoryMb: (j['minMemoryMb'] as num?)?.toInt() ?? 0,
        mustKeepUp: j['mustKeepUp'] == true,
        licence: VoiceLicence.fromJson(j['licence']),
      );
}

/// A natural voice that runs on the phone, made into speech by sherpa-onnx:
/// a Piper model, or one speaker of a model that holds many (Kokoro,
/// Kitten). Downloaded only when chosen; the phone's own voices stay the
/// default and cost nothing.
class NeuralVoice {
  const NeuralVoice(
    this.id,
    this.name,
    this.locale,
    this.bytes, {
    this.quality = 'medium',
    this.sampleRate = 22050,
    this.speakers = 1,
    this.blurb = '',
    this.sample = '',
    this.licence = VoiceLicence.unknown,
    this.kind = NeuralKind.piper,
    this.pack,
    this.sid = 0,
    this.lang = '',
    this.lexicon = false,
    this.grade = '',
    this.gender = '',
  });

  /// Piper's name for it, "en_US-kristin-medium"; a speaker of a shared
  /// model is "kokoro-multi-lang-v1_0:hf_alpha".
  final String id;
  final String name;

  /// "en-US", "hi-IN".
  final String locale;

  /// The download: this voice's own, or the model it shares.
  final int bytes;

  /// Piper's grades: x_low, low, medium, high.
  final String quality;

  /// Samples a second its model makes: 16,000 for Piper's low voices,
  /// 22,050 for most, 24,000 for Kokoro and Kitten, 44,100 for a few.
  final int sampleRate;
  final int speakers;
  final String blurb;

  /// A recording of it, to hear before downloading.
  final String sample;
  final VoiceLicence licence;
  final NeuralKind kind;

  /// The model this speaker shares (Kokoro, Kitten), and its number there.
  final NeuralPack? pack;
  final int sid;

  /// The language its text is read in (Kokoro's speakers: espeak-ng's
  /// "hi", "en-gb"); empty for a model that knows its own.
  final String lang;

  /// Read through a lexicon and rules rather than espeak-ng (two Chinese
  /// Piper voices).
  final bool lexicon;

  /// Its makers' grade (Kokoro), and whose voice it is, where they say.
  final String grade;
  final String gender;

  /// The name voices go by in the app (see [neuralPrefix]).
  String get voiceName => '$neuralPrefix$id';

  /// What its download, folder and loaded model go by: its own id, or the
  /// model it shares.
  String get modelId => pack?.id ?? id;

  int get sizeMb => (bytes / 1048576).round();

  /// The high-quality models: richer, larger and slower.
  bool get hd => quality == 'high';

  String get url => pack?.url ?? '$_release/vits-piper-$id.tar.bz2';

  /// Its model in its folder.
  String get modelFile => pack?.file ?? '$id.onnx';

  /// A recording of it (about 100 KB) to hear before downloading; empty for
  /// the one voice nobody has recorded a sample of.
  String get sampleUrl => sample;

  /// Piper's own recording of one of its voices: en_US-kristin-medium is
  /// en/en_US/kristin/medium.
  static String piperSample(String id) {
    final parts = id.split('-');
    final lang = parts.first.split('_').first;
    return 'https://huggingface.co/rhasspy/piper-voices/resolve/main/$lang/${parts.join('/')}/samples/speaker_0.mp3';
  }

  /// "en", "hi".
  String get language => locale.split(RegExp('[-_]')).first.toLowerCase();

  /// "US", "IN"; empty when it names none.
  String get region {
    final parts = locale.split(RegExp('[-_]'));
    return parts.length > 1 ? parts[1].toUpperCase() : '';
  }

  /// The catalog's entry; a speaker names its model, which must be in [packs].
  static NeuralVoice? fromJson(Map<String, Object?> j, Map<String, NeuralPack> packs) {
    final packId = j['pack'] as String?;
    final pack = packId == null ? null : packs[packId];
    if (packId != null && pack == null) return null;
    return NeuralVoice(
      j['id']! as String,
      j['name'] as String? ?? '',
      j['locale'] as String? ?? '',
      (j['bytes'] as num?)?.toInt() ?? pack?.bytes ?? 0,
      quality: j['quality'] as String? ?? 'medium',
      sampleRate: (j['sampleRate'] as num?)?.toInt() ?? pack?.sampleRate ?? 22050,
      speakers: (j['speakers'] as num?)?.toInt() ?? 1,
      blurb: j['blurb'] as String? ?? '',
      sample: j['sample'] as String? ?? '',
      licence: VoiceLicence.fromJson(j['licence']),
      kind: NeuralKind.parse(j['engine'] as String?),
      pack: pack,
      sid: (j['sid'] as num?)?.toInt() ?? 0,
      lang: j['lang'] as String? ?? '',
      lexicon: j['frontend'] == 'lexicon',
      grade: j['grade'] as String? ?? '',
      gender: j['gender'] as String? ?? '',
    );
  }
}

/// The natural voices on offer, as tools/voice_catalog.py wrote them into
/// the app (assets/voices/catalog.json): every voice in sherpa-onnx's release
/// in full precision, with its language, size and sample rate, and the
/// licence of the recordings it learned from. Nothing is listed from
/// upstream at run time (docs/06 section 6.4).
class NeuralCatalog {
  NeuralCatalog(this.voices, this.packs) : _byId = {for (final v in voices) v.id: v};

  final List<NeuralVoice> voices;
  final Map<String, NeuralPack> packs;
  final Map<String, NeuralVoice> _byId;

  static const asset = 'assets/voices/catalog.json';

  NeuralVoice? byId(String id) => _byId[id];

  /// [language]'s voices, in the catalog's order.
  List<NeuralVoice> forLanguage(String language) => [
        for (final v in voices)
          if (v.language == language) v,
      ];

  /// Every language with a voice.
  Set<String> get languages => {for (final v in voices) v.language};

  /// The speakers [pack] holds.
  List<NeuralVoice> speakersOf(NeuralPack pack) => [
        for (final v in voices)
          if (v.pack?.id == pack.id) v,
      ];

  static NeuralCatalog parse(String text) {
    final json = jsonDecode(text) as Map<String, Object?>;
    final packs = <String, NeuralPack>{
      for (final p in (json['packs'] as List? ?? const []).cast<Map<String, Object?>>())
        p['id']! as String: NeuralPack.fromJson(p),
    };
    return NeuralCatalog([
      for (final v in (json['voices'] as List? ?? const []).cast<Map<String, Object?>>())
        if (NeuralVoice.fromJson(v, packs) case final voice?) voice,
    ], packs);
  }

  /// Read from the app's files. As bytes, decoded here: loadString hands a
  /// file this size to another isolate, and tests never see that finish.
  static Future<NeuralCatalog> load([AssetBundle? bundle]) async {
    final data = await (bundle ?? rootBundle).load(asset);
    return parse(utf8.decode(Uint8List.sublistView(data)));
  }
}

/// The first natural voices, known before the catalog is read (a moment
/// after start): a book set to one finds it from the first moment, and so
/// would an app whose catalog could not be read.
final firstNeuralVoices = [
  for (final (id, name, locale, bytes, blurb) in const [
    ('en_US-kristin-medium', 'Kristin', 'en-US', 67259230, 'Warm and clear'),
    ('en_US-norman-medium', 'Norman', 'en-US', 67203672, 'Calm, a little deep'),
    ('en_GB-alan-medium', 'Alan', 'en-GB', 67220121, 'Steady British reader'),
    ('en_GB-jenny_dioco-medium', 'Jenny (Dioco)', 'en-GB', 67225842, 'Bright British voice'),
    ('en_GB-cori-medium', 'Cori', 'en-GB', 67257412, 'Soft and expressive'),
    ('en_US-lessac-high', 'Lessac', 'en-US', 115545841, 'The richest, needs a faster phone'),
    ('en_US-ryan-high', 'Ryan', 'en-US', 115630708, 'Deep and full, needs a faster phone'),
  ])
    NeuralVoice(id, name, locale, bytes,
        quality: id.endsWith('-high') ? 'high' : 'medium', blurb: blurb, sample: NeuralVoice.piperSample(id)),
];

/// Voice names that start with this are TomeVoice's own, not the phone's.
const neuralPrefix = 'neural:';

bool isNeural(String? voiceName) => voiceName?.startsWith(neuralPrefix) ?? false;

/// The voices on offer: the catalog's, or the first ones until it is read.
List<NeuralVoice> get neuralVoices => NeuralVoices.instance.catalog?.voices ?? firstNeuralVoices;

NeuralVoice? neuralVoiceFor(String? voiceName) {
  if (!isNeural(voiceName)) return null;
  return NeuralVoices.instance.byId(voiceName!.substring(neuralPrefix.length));
}

/// Where voices are kept, which are here, and what this phone measured
/// each to manage.
class NeuralVoices extends ChangeNotifier {
  NeuralVoices._();

  static final instance = NeuralVoices._();

  Directory? _dir;

  /// Download (a voice's own, or a shared model's: [NeuralVoice.modelId]) ->
  /// progress (0..1), while downloading.
  final downloading = <String, double>{};

  Directory get dir => _dir ?? Directory.systemTemp;

  NeuralCatalog? _catalog;
  Future<NeuralCatalog>? _loading;

  /// The catalog, once read; null for the moment before.
  NeuralCatalog? get catalog => _catalog;

  /// The catalog, read once from the app's files.
  Future<NeuralCatalog> get ready => _loading ??= _readCatalog();

  Future<NeuralCatalog> _readCatalog() async {
    NeuralCatalog read;
    try {
      read = await NeuralCatalog.load();
    } on Object catch (e) {
      debugPrint('Natural voices: the catalog could not be read ($e)');
      read = NeuralCatalog(firstNeuralVoices, const {});
    }
    // One given meanwhile (a test's) stands.
    final given = _catalog;
    if (given != null) return given;
    _catalog = read;
    notifyListeners();
    return read;
  }

  /// Use [c] as the catalog.
  @visibleForTesting
  void useCatalog(NeuralCatalog c) {
    _catalog = c;
    _loading = Future.value(c);
    notifyListeners();
  }

  static final _first = {for (final v in firstNeuralVoices) v.id: v};

  NeuralVoice? byId(String id) {
    final known = _catalog?.byId(id) ?? _first[id];
    if (known != null) return known;
    // On the phone but not in this catalog (a later one left it out): a
    // Piper voice is all in its folder, so it still reads.
    if (_installedFolders.contains('piper-$id')) return _inferred(id);
    return null;
  }

  /// A Piper voice known only by its id: "de_DE-thorsten-high".
  static NeuralVoice _inferred(String id) {
    final m = RegExp(r'^([a-z]{2,3})_([A-Z]{2})-(.+)-(x_low|low|medium|high)$').firstMatch(id);
    if (m == null) return NeuralVoice(id, id, 'und', 0);
    final name = m.group(3)!.replaceAll('_', ' ');
    return NeuralVoice(id, name[0].toUpperCase() + name.substring(1), '${m.group(1)}-${m.group(2)}', 0,
        quality: m.group(4)!, sample: NeuralVoice.piperSample(id));
  }

  void attach(Directory root) {
    _dir = Directory('${root.path}/voices');
    _here = null;
    _speeds.clear();
    // Folders from an earlier format (the fp16 models, which crash the
    // engine) or an unfinished unpacking are not voices: clear them, and a
    // voice folder left without its model (removed while the engine still
    // read through it, see [remove]). A download cut short is kept, to go
    // on from where it stopped.
    try {
      for (final e in dir.listSync()) {
        final name = _nameOf(e);
        if (e is Directory && _isVoiceFolder(name)) {
          if (!_hasModel(e)) e.deleteSync(recursive: true);
        } else if (!name.endsWith(_partial)) {
          e.deleteSync(recursive: true);
        }
      }
    } on Object {
      // No voices folder yet.
    }
    unawaited(ready);
  }

  static const _partial = '.tar.bz2.part';

  /// No data for this long and a download has stalled: it stops, and can
  /// go on from there (it once sat at "Downloading n%" for good).
  static const stallAfter = Duration(seconds: 30);

  static String _nameOf(FileSystemEntity e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last;

  /// A voice's folder: "piper-<id>", or a shared model's own name.
  static bool _isVoiceFolder(String name) =>
      !name.endsWith('.unpacking') &&
      (name.startsWith('piper-') || name.startsWith('kokoro-') || name.startsWith('kitten-'));

  /// Whether [folder] holds its model: a Piper voice's "<id>.onnx", or a
  /// shared model's.
  static bool _hasModel(Directory folder) {
    final name = _nameOf(folder);
    if (name.startsWith('piper-')) return File('${folder.path}/${name.substring(6)}.onnx').existsSync();
    try {
      return folder.listSync().any((f) => f is File && f.path.endsWith('.onnx'));
    } on Object {
      return false;
    }
  }

  /// The folders that hold a voice, read once and again after each change:
  /// the screens ask on every frame.
  Set<String>? _here;

  /// Not yet told where voices are kept ([attach]): none, rather than
  /// whatever is in the system's temporary folder, and nothing remembered.
  Set<String> get _installedFolders => _dir == null ? const {} : _here ??= _scan();

  Set<String> _scan() {
    try {
      return {
        for (final e in dir.listSync())
          if (e is Directory && _isVoiceFolder(_nameOf(e)) && _hasModel(e)) _nameOf(e),
      };
    } on Object {
      return {};
    }
  }

  String folderName(NeuralVoice v) => v.pack?.id ?? 'piper-${v.id}';

  Directory folder(NeuralVoice v) => Directory('${dir.path}/${folderName(v)}');

  bool installed(NeuralVoice v) => _installedFolders.contains(folderName(v));

  /// Every voice on the phone: the catalog's, then any it no longer lists.
  List<NeuralVoice> get installedVoices {
    final here = _installedFolders;
    final known = neuralVoices;
    final ids = {for (final v in known) v.id};
    return [
      for (final v in known)
        if (here.contains(folderName(v))) v,
      for (final f in here)
        if (f.startsWith('piper-') && !ids.contains(f.substring(6))) _inferred(f.substring(6)),
    ];
  }

  /// Whether [v] may read: on the phone, and, for a model that must keep up
  /// (Kokoro), shown by this phone's speed test to keep up. One that does
  /// not is not offered: it would leave pauses between sentences.
  bool readable(NeuralVoice v) {
    if (!installed(v)) return false;
    final pack = v.pack;
    return pack == null || !pack.mustKeepUp || keepsUp(speedOf(v));
  }

  /// The voices the voice picker offers.
  List<NeuralVoice> get readableVoices => [
        for (final v in installedVoices)
          if (readable(v)) v,
      ];

  /// Whether [speed] (seconds of speech made per second of work) keeps up
  /// with reading aloud, with a little to spare.
  static bool keepsUp(double? speed) => speed != null && speed >= 1.05;

  /// What the speed test measured for each model on this phone: kept in the
  /// model's folder, so it is known next time and goes with the voice.
  final _speeds = <String, double?>{};
  static const _speedFile = 'speed-test.txt';

  double? speedOf(NeuralVoice v) {
    final key = v.modelId;
    if (_speeds.containsKey(key)) return _speeds[key];
    double? s;
    try {
      final f = File('${folder(v).path}/$_speedFile');
      if (f.existsSync()) s = double.tryParse(f.readAsStringSync().trim());
    } on Object {
      // Not measured, as far as anyone can tell.
    }
    return _speeds[key] = s;
  }

  Future<void> rememberSpeed(NeuralVoice v, double speed) async {
    _speeds[v.modelId] = speed;
    notifyListeners();
    try {
      await File('${folder(v).path}/$_speedFile').writeAsString(speed.toStringAsFixed(3));
    } on Object {
      // Measured again next time.
    }
  }

  /// Whether this phone has the memory [pack] needs.
  bool fits(NeuralPack pack) =>
      pack.minMemoryMb <= 0 || (NeuralEngine.instance.memoryMb ?? 0) >= pack.minMemoryMb;

  /// [language]'s voices this phone can have: all of Piper's, and a bigger
  /// model's only where the phone has the memory for it.
  List<NeuralVoice> offeredFor(String language) => [
        for (final v in _catalog?.forLanguage(language) ?? const <NeuralVoice>[])
          if (v.pack == null || fits(v.pack!)) v,
      ];

  /// Downloads called off from the screen, and the connections they use.
  final _cancelled = <String>{};
  final _clients = <String, HttpClient>{};

  /// Stop downloading [v] (at once, data coming or not); what came is deleted.
  void cancel(NeuralVoice v) {
    final key = v.modelId;
    if (!downloading.containsKey(key)) return;
    _cancelled.add(key);
    _clients[key]?.close(force: true);
  }

  /// Fetch [v] (a shared model's speaker: the whole model) and unpack it,
  /// reporting progress; the archive is not kept.
  ///
  /// A download cut short (a lost connection, a stall) keeps what came, and
  /// the next one asks the server only for the rest. Before unpacking, the
  /// size is checked against what the server said; unpacking checks the
  /// archive's own checksums and that the voice's files are all there.
  /// Throws [DownloadCancelled] when called off with [cancel]. [source] and
  /// [stall] stand in for the voice's address and [stallAfter] in tests.
  Future<void> download(NeuralVoice v, {@visibleForTesting Uri? source, Duration stall = stallAfter}) async {
    final key = v.modelId;
    if (downloading.containsKey(key)) return;
    _cancelled.remove(key);
    downloading[key] = 0;
    notifyListeners();
    final part = File('${dir.path}/$key$_partial');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _clients[key] = client;
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
        final expected = total > 0 ? total : math.max(1, v.bytes);
        try {
          await for (final chunk in res.timeout(stall)) {
            if (_cancelled.contains(key)) throw const DownloadCancelled();
            sink.add(chunk);
            got += chunk.length;
            downloading[key] = 0.9 * (got / expected).clamp(0.0, 1.0);
            notifyListeners();
          }
        } finally {
          await sink.close();
        }
        if (total > 0 && got != total) throw const HttpException('The download was cut short');
        break;
      }
      // Unpacking a few hundred files takes a moment: off the screen's isolate.
      // Only plain values go across: a closure that held this object (and
      // so the screens listening to it) cannot be sent to another isolate.
      final from = part.path;
      final into = folder(v).path;
      final model = v.modelFile;
      final shared = v.pack != null;
      // A broken archive is not worth resuming: it starts over next time.
      keepPart = false;
      await Isolate.run(() => _unpack(from, into, model, shared: shared));
      _here = null;
      _speeds.remove(key);
      downloading.remove(key);
      notifyListeners();
    } on Object {
      // Called off: whatever the closed connection threw, it is that.
      final cancelled = _cancelled.remove(key);
      if (cancelled) keepPart = false;
      downloading.remove(key);
      _here = null;
      final f = folder(v);
      if (!installed(v) && !NeuralEngine.instance.readsThrough(f) && await f.exists()) {
        await f.delete(recursive: true);
      }
      notifyListeners();
      if (cancelled) throw const DownloadCancelled();
      rethrow;
    } finally {
      _clients.remove(key);
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

  /// Every voice off the phone.
  Future<void> removeAll() async {
    for (final v in installedVoices) {
      await NeuralEngine.instance.unload(v);
    }
    if (await dir.exists()) {
      for (final e in await dir.list().toList()) {
        if (e is Directory) {
          await _clear(e);
        } else {
          await e.delete();
        }
      }
    }
    _here = null;
    _speeds.clear();
    notifyListeners();
  }

  Future<void> remove(NeuralVoice v) async {
    await NeuralEngine.instance.unload(v);
    await _clear(folder(v));
    _here = null;
    _speeds.remove(v.modelId);
    notifyListeners();
  }

  /// Delete [f]. The engine reads every voice's pronunciation through the
  /// data of the first voice it loaded this run (espeak-ng starts once), so
  /// that voice's espeak-ng-data stays until the app next starts ([attach]
  /// clears it), or every other voice would fall silent until then.
  static Future<void> _clear(Directory f) async {
    if (!await f.exists()) return;
    if (!NeuralEngine.instance.readsThrough(f)) {
      await f.delete(recursive: true);
      return;
    }
    for (final e in await f.list().toList()) {
      if (_nameOf(e) != 'espeak-ng-data') await e.delete(recursive: true);
    }
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
/// pronunciation data (espeak-ng's, or a lexicon), and a [shared] model its
/// speakers, or nothing is kept (a half voice crashed the engine).
void _unpack(String archive, String into, String model, {bool shared = false}) {
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
    final espeak = Directory('${work.path}/espeak-ng-data').existsSync();
    final lexicon = File('${work.path}/lexicon.txt').existsSync();
    if (!onnx.existsSync() ||
        onnx.lengthSync() < 1024 * 1024 ||
        !File('${work.path}/tokens.txt').existsSync() ||
        !(espeak || (lexicon && !shared)) ||
        (shared && !File('${work.path}/voices.bin').existsSync())) {
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
  /// hundred MB or more, kept after the reader stopped or paused.
  static const idleUnload = Duration(minutes: 3);
  Timer? _idle;

  /// [idleUnload], or less in a test.
  @visibleForTesting
  Duration idleAfter = idleUnload;

  /// The models the worker may be holding: asked for since it last let go
  /// of them all.
  final _asked = <String>{};

  /// Run in place of the worker isolate, on this one (tests): handed the
  /// port the engine hears on, it answers as the worker does.
  @visibleForTesting
  static void Function(SendPort out)? workerForTests;

  /// How many voices stay loaded at once: two on a phone with the memory
  /// for it (about 6 GB), so a natural narrator and a natural dialogue voice
  /// do not take turns reloading at every quote (a second or two each, more
  /// for HD); one elsewhere.
  int get slots => slotsForTests ?? _slots;
  late final int _slots = slotsFor(_memTotalKb());

  /// [slots] for a test's phone.
  @visibleForTesting
  int? slotsForTests;

  /// Whether two natural voices (a narrator and a dialogue voice) can stay
  /// loaded together on this phone.
  bool get holdsTwo => slots >= 2;

  @visibleForTesting
  static int slotsFor(int? memTotalKb) => (memTotalKb ?? 0) >= 5200 * 1024 ? 2 : 1;

  /// The phone's memory in MB as Linux counts it (a 6 GB phone says about
  /// 5,600); null where it cannot be read.
  int? get memoryMb => memoryForTests ?? _memoryMb;
  late final int? _memoryMb = switch (_memTotalKb()) { final kb? => kb ~/ 1024, null => null };

  @visibleForTesting
  int? memoryForTests;

  static int? _memTotalKb() {
    try {
      final line = File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal:'));
      return int.tryParse(RegExp(r'\d+').firstMatch(line)?.group(0) ?? '');
    } on Object {
      return null;
    }
  }

  /// The folder whose espeak-ng-data the engine reads every voice's
  /// pronunciation through: the first one loaded this run (sherpa-onnx
  /// starts espeak-ng once a process).
  String? _espeakHome;

  /// Whether the engine reads through [folder]'s espeak-ng-data, which must
  /// then stay until the app next starts.
  bool readsThrough(Directory folder) => _espeakHome != null && _same(folder.path, _espeakHome!);

  @visibleForTesting
  set espeakHomeForTests(String? path) => _espeakHome = path;

  static bool _same(String a, String b) => a.replaceAll(r'\', '/') == b.replaceAll(r'\', '/');

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
      final stand = workerForTests;
      if (stand != null) {
        stand(inbox.sendPort);
      } else {
        _isolate = await Isolate.spawn(
          _workerMain,
          inbox.sendPort,
          debugName: 'neural-voice',
          onError: inbox.sendPort,
          onExit: inbox.sendPort,
        );
      }
    } on Object catch (e) {
      _died('it could not start: $e', ready);
    }
    return _worker = await ready.future;
  }

  /// Let the worker go (tests): the next sentence starts another.
  @visibleForTesting
  void forgetWorkerForTests() {
    _idle?.cancel();
    _died('let go by a test');
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
    _asked.clear();
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

  /// Long enough for a model to load (longer for HD or Kokoro on a slow
  /// phone) and a piece to be made at no faster than real time.
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
    _idle = Timer(idleAfter, () {
      _asked.clear();
      _worker?.send({'id': -1, 'op': 'unload', 'model': null});
    });
  }

  /// The natural voices reading uses now, [voices] (its narrator, and a
  /// dialogue voice): any other the worker holds is let go at once, before
  /// the next one loads. A voice switched away from stayed until it had gone
  /// unused for [idleUnload], which on a phone that holds two voices was
  /// never, as long as reading went on.
  void keepOnly(Iterable<NeuralVoice> voices) {
    final keep = {for (final v in voices) v.modelId};
    final worker = _worker;
    if (worker == null || _asked.every(keep.contains)) return;
    _asked.retainAll(keep);
    worker.send({'id': -1, 'op': 'unload', 'keep': [...keep]});
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
    final dir = NeuralVoices.instance.folder(voice).path;
    _asked.add(voice.modelId);
    try {
      for (var k = 0; k < parts.length; k++) {
        if (_cancels != cancels) throw PlatformException(code: 'TTS_STOPPED', message: 'Synthesis cancelled');
        final last = k == parts.length - 1;
        final r = await _ask({
          'op': 'say',
          'job': job,
          'last': last,
          'dir': dir,
          'model': voice.modelId,
          'kind': voice.kind.name,
          'file': voice.modelFile,
          'sid': voice.sid,
          'lang': voice.lang,
          'text': parts[k].text,
          'speed': speed,
          'urgent': urgent,
          'slots': slots,
          'out': '$outDir/neural-$job.wav',
        }, _timeoutFor(parts[k].text));
        if (r['error'] != null) throw Exception(r['error']);
        // The first voice to load and speak this run is the one espeak-ng
        // reads every voice's pronunciation through ([readsThrough]).
        if (!voice.lexicon) _espeakHome ??= dir;
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
    if (!NeuralVoices.instance.readable(voice)) return;
    try {
      final r = await synthesise(
        voice: voice,
        text: voice.language == 'zh' ? _helloZh : 'Hi.',
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
  /// from one long sentence: above 1 it keeps up with reading aloud. The
  /// length is read at the voice's own sample rate (16,000 to 44,100 a
  /// second), from the WAV it made.
  Future<double> measure(NeuralVoice voice, String outDir) async {
    // A shared model does the same work in any of its voices: measured in an
    // English one, as the sentence is English.
    final pack = voice.pack;
    if (pack != null && voice.language != 'en') {
      voice = NeuralVoices.instance.catalog?.speakersOf(pack).where((v) => v.language == 'en').firstOrNull ?? voice;
    }
    // A Chinese voice reads through a Chinese lexicon: English is lost on it.
    final zh = voice.language == 'zh';
    final text = zh
        ? _storyZh
        : 'It was a bright cold day in April, and the clocks were striking thirteen, '
            'while the wind swept little eddies of dust and torn paper into spirals along the street.';
    // The first call loads the voice; time the second, made in one go.
    final warm = await synthesise(voice: voice, text: zh ? _helloZh : 'Hello.', speed: 1, outDir: outDir);
    await File(warm['wavPath']! as String).delete().catchError((Object _) => File(''));
    final watch = Stopwatch()..start();
    final r = await synthesise(voice: voice, text: text, speed: 1, outDir: outDir, pieces: false);
    watch.stop();
    final wav = File(r['wavPath']! as String);
    final bytes = await wav.readAsBytes();
    await wav.delete();
    final seconds = wavSeconds(bytes) ?? 0;
    if (seconds <= 0) throw StateError('The voice made no sound');
    return seconds / (watch.elapsedMilliseconds / 1000);
  }

  Future<void> unload(NeuralVoice voice) async {
    if (_worker == null) return;
    _asked.remove(voice.modelId);
    try {
      await _ask({'op': 'unload', 'model': voice.modelId}, const Duration(seconds: 20));
    } on Object {
      // A worker that cannot answer holds nothing worth keeping.
    }
  }
}

/// "Hello." and a sentence of a children's story, in Chinese, for a Chinese
/// voice's warming and speed test.
final _helloZh = String.fromCharCodes(const [0x4F60, 0x597D, 0x3002]);
final _storyZh = String.fromCharCodes(const [
  0x4ECE, 0x524D, 0x6709, 0x5EA7, 0x5C71, 0xFF0C, 0x5C71, 0x91CC, 0x6709, 0x5EA7, 0x5E99, 0xFF0C, //
  0x5E99, 0x91CC, 0x6709, 0x4E2A, 0x8001, 0x548C, 0x5C1A, 0x5728, 0x7ED9, 0x5C0F, 0x548C, 0x5C1A, //
  0x8BB2, 0x6545, 0x4E8B, 0xFF0C, 0x8BB2, 0x5F97, 0x5F88, 0x6162, 0x5F88, 0x6162, 0x3002,
]);

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

/// How to load the model a `say` message [m] asks for, from what is in its
/// folder.
@visibleForTesting
sherpa.OfflineTtsConfig modelConfigFor(Map<Object?, Object?> m) {
  final dir = m['dir']! as String;
  final model = '$dir/${m['file'] ?? '${m['model']}.onnx'}';
  final tokens = '$dir/tokens.txt';
  final espeak = '$dir/espeak-ng-data';
  final threads = Platform.numberOfProcessors >= 8 ? 4 : 2;
  switch (m['kind']) {
    case 'kokoro':
      return sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: model,
            voices: '$dir/voices.bin',
            tokens: tokens,
            dataDir: espeak,
            // Each speaker's own language goes with each piece; Kokoro 1.0
            // will not load without one (the process exits).
            lang: 'en-us',
          ),
          numThreads: threads,
          debug: false,
        ),
        maxNumSenetences: 1,
      );
    case 'kitten':
      return sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kitten: sherpa.OfflineTtsKittenModelConfig(
            model: model,
            voices: '$dir/voices.bin',
            tokens: tokens,
            dataDir: espeak,
          ),
          numThreads: threads,
          debug: false,
        ),
        maxNumSenetences: 1,
      );
    default:
      // Two Chinese voices read through a lexicon and rules for numbers and
      // dates, where the rest use espeak-ng.
      final lexicon = !Directory(espeak).existsSync() && File('$dir/lexicon.txt').existsSync();
      return sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: model,
            tokens: tokens,
            dataDir: lexicon ? '' : espeak,
            lexicon: lexicon ? '$dir/lexicon.txt' : '',
          ),
          numThreads: threads,
          debug: false,
        ),
        ruleFsts: lexicon
            ? [
                for (final f in const ['phone.fst', 'date.fst', 'number.fst'])
                  if (File('$dir/$f').existsSync()) '$dir/$f',
              ].join(',')
            : '',
        maxNumSenetences: 1,
      );
  }
}

/// The worker: up to `slots` loaded voices, the one used longest ago let go
/// first when another is needed. The speakers of one model (Kokoro's, say)
/// share it, loaded once.
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
          // One voice, every voice, or every voice but those still read with.
          final model = m['model'] as String?;
          final keep = m['keep'];
          for (final key in [...loaded.keys]) {
            final go = keep is List ? !keep.contains(key) : model == null || key == model;
            if (go) loaded.remove(key)!.tts.free();
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
            final watch = Stopwatch()..start();
            // Its threads start at this thread's priority; they are set for
            // each piece below.
            _setNice(tid, 0);
            final before = _threads();
            final tts = sherpa.OfflineTts(modelConfigFor(m));
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
          final lang = m['lang'] as String? ?? '';
          final sherpa.GeneratedAudio audio;
          try {
            audio = engine.tts.generateWithConfig(
              text: m['text'] as String,
              config: sherpa.OfflineTtsGenerationConfig(
                sid: m['sid'] as int? ?? 0,
                speed: (m['speed'] as num).toDouble(),
                // A Kokoro speaker's language: one model reads several.
                extra: lang.isEmpty ? const {} : {'lang': lang},
              ),
            );
          } finally {
            // This thread is the VM's, shared with other isolates (the render
            // after each sentence, the collector): it goes back as it came.
            if (!urgent) _setNice(tid, 0);
          }
          // A piece that made no sound says no rate either: the model's own.
          final rate = audio.sampleRate > 0 ? audio.sampleRate : engine.tts.sampleRate;
          final key = m['job'] as int;
          final job = jobs.putIfAbsent(key, () => _Job(rate))..pieces.add(audio.samples);
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

/// How long the speech in a WAV that [wavBytes] wrote lasts, in seconds, at
/// the sample rate its header gives; null when it is not such a WAV.
double? wavSeconds(Uint8List wav) {
  if (wav.length < 44 || String.fromCharCodes(wav.sublist(0, 4)) != 'RIFF') return null;
  final head = ByteData.sublistView(wav);
  final rate = head.getUint32(24, Endian.little);
  final channels = head.getUint16(22, Endian.little);
  final bits = head.getUint16(34, Endian.little);
  if (rate <= 0 || channels <= 0 || bits <= 0) return null;
  return (wav.length - 44) / (channels * bits ~/ 8) / rate;
}
