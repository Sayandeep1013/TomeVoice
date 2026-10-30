import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// A language Tesseract can read a scan in, and the data it needs for it: one
/// traineddata file from tessdata_fast (Apache-2.0), downloaded when a scan in
/// that language is first read, never shipped in the app.
///
/// The reading itself is done on the phone, page by page, by Ocr.kt;
/// ocr_jobs.dart keeps track of it and ocr_sheet.dart offers it. What
/// Tesseract reads is turned here into the shape a PDF's own text has, so a
/// scan becomes a book the way any PDF does: running heads and page numbers
/// dropped, chapters found, broken words mended (formats/pdf.dart).
class OcrLanguage {
  const OcrLanguage(this.code, this.name, this.bytes, {this.iso, this.native});

  /// Tesseract's name for it, and its file's: "ben", "chi_sim".
  final String code;
  final String name;

  /// The size of its file, to the byte: a download of any other size is not
  /// that file.
  final int bytes;

  /// ISO 639-1, as a book's language is kept ("bn"); null for the few that
  /// have none, or that share one (Serbian in Latin letters).
  final String? iso;

  /// Its name in its own script, shown beside the English one.
  final String? native;

  /// "Bengali · বাংলা", "English".
  String get label => native == null ? name : '$name · $native';

  Uri get url => Uri.parse(
      'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/$tessdataCommit/$code.traineddata');

  @override
  String toString() => code;
}

/// The tessdata_fast commit the data comes from: pinned, so a file is always
/// the one whose size [ocrLanguages] lists. The fast models are a fraction of
/// the size of the best ones (Bengali 0.8 MB rather than 11) and several times
/// quicker, which a phone reading three hundred pages needs.
const tessdataCommit = '87416418657359cb625c412a48b6e1d6d41c29bd';

/// Every language in tessdata_fast, by English name. Left out: osd (which way
/// up a page is, not a language), equ (equations) and frk (a link in the
/// repository, not a file).
const ocrLanguages = [
  OcrLanguage('afr', 'Afrikaans', 2652786, iso: 'af'),
  OcrLanguage('sqi', 'Albanian', 1874705, iso: 'sq'),
  OcrLanguage('amh', 'Amharic', 5470094, iso: 'am'),
  OcrLanguage('grc', 'Ancient Greek', 2246328),
  OcrLanguage('ara', 'Arabic', 1432056, iso: 'ar', native: 'العربية'),
  OcrLanguage('hye', 'Armenian', 3463717, iso: 'hy'),
  OcrLanguage('asm', 'Assamese', 2045427, iso: 'as', native: 'অসমীয়া'),
  OcrLanguage('aze', 'Azerbaijani', 3524799, iso: 'az'),
  OcrLanguage('aze_cyrl', 'Azerbaijani (Cyrillic)', 1943672),
  OcrLanguage('eus', 'Basque', 5175921, iso: 'eu'),
  OcrLanguage('bel', 'Belarusian', 3692098, iso: 'be'),
  OcrLanguage('ben', 'Bengali', 855841, iso: 'bn', native: 'বাংলা'),
  OcrLanguage('bos', 'Bosnian', 2498242, iso: 'bs'),
  OcrLanguage('bre', 'Breton', 6335007, iso: 'br'),
  OcrLanguage('bul', 'Bulgarian', 1675212, iso: 'bg'),
  OcrLanguage('mya', 'Burmese', 4640561, iso: 'my'),
  OcrLanguage('cat', 'Catalan', 1146012, iso: 'ca'),
  OcrLanguage('ceb', 'Cebuano', 716214),
  OcrLanguage('chr', 'Cherokee', 374944),
  OcrLanguage('chi_sim', 'Chinese (Simplified)', 2469156, iso: 'zh', native: '简体中文'),
  OcrLanguage('chi_sim_vert', 'Chinese (Simplified, vertical)', 1927902),
  OcrLanguage('chi_tra', 'Chinese (Traditional)', 2366642, native: '繁體中文'),
  OcrLanguage('chi_tra_vert', 'Chinese (Traditional, vertical)', 1824756),
  OcrLanguage('cos', 'Corsican', 2299099, iso: 'co'),
  OcrLanguage('hrv', 'Croatian', 4103348, iso: 'hr'),
  OcrLanguage('ces', 'Czech', 3795684, iso: 'cs'),
  OcrLanguage('dan', 'Danish', 2580059, iso: 'da'),
  OcrLanguage('div', 'Dhivehi', 1774535, iso: 'dv'),
  OcrLanguage('nld', 'Dutch', 6050296, iso: 'nl'),
  OcrLanguage('dzo', 'Dzongkha', 449596, iso: 'dz'),
  OcrLanguage('eng', 'English', 4113088, iso: 'en'),
  OcrLanguage('epo', 'Esperanto', 4728393, iso: 'eo'),
  OcrLanguage('est', 'Estonian', 4458101, iso: 'et'),
  OcrLanguage('fao', 'Faroese', 3439772, iso: 'fo'),
  OcrLanguage('fil', 'Filipino', 1841715, iso: 'fil'),
  OcrLanguage('fin', 'Finnish', 7865732, iso: 'fi'),
  OcrLanguage('fra', 'French', 1130365, iso: 'fr'),
  OcrLanguage('glg', 'Galician', 2554555, iso: 'gl'),
  OcrLanguage('kat', 'Georgian', 2524769, iso: 'ka'),
  OcrLanguage('kat_old', 'Georgian (old)', 423167),
  OcrLanguage('deu', 'German', 1525436, iso: 'de'),
  OcrLanguage('deu_latf', 'German (Fraktur)', 6423052),
  OcrLanguage('ell', 'Greek', 1419514, iso: 'el'),
  OcrLanguage('guj', 'Gujarati', 1418394, iso: 'gu', native: 'ગુજરાતી'),
  OcrLanguage('hat', 'Haitian Creole', 1976902, iso: 'ht'),
  OcrLanguage('heb', 'Hebrew', 961404, iso: 'he'),
  OcrLanguage('hin', 'Hindi', 1122751, iso: 'hi', native: 'हिन्दी'),
  OcrLanguage('hun', 'Hungarian', 5296273, iso: 'hu'),
  OcrLanguage('isl', 'Icelandic', 2278973, iso: 'is'),
  OcrLanguage('ind', 'Indonesian', 1122661, iso: 'id'),
  OcrLanguage('iku', 'Inuktitut', 2802266, iso: 'iu'),
  OcrLanguage('gle', 'Irish', 1181824, iso: 'ga'),
  OcrLanguage('ita', 'Italian', 2701314, iso: 'it'),
  OcrLanguage('ita_old', 'Italian (old)', 3286123),
  OcrLanguage('jpn', 'Japanese', 2471260, iso: 'ja', native: '日本語'),
  OcrLanguage('jpn_vert', 'Japanese (vertical)', 3037480),
  OcrLanguage('jav', 'Javanese', 2982741, iso: 'jv'),
  OcrLanguage('kan', 'Kannada', 3608331, iso: 'kn', native: 'ಕನ್ನಡ'),
  OcrLanguage('kaz', 'Kazakh', 4734644, iso: 'kk'),
  OcrLanguage('khm', 'Khmer', 1446926, iso: 'km'),
  OcrLanguage('kor', 'Korean', 1677415, iso: 'ko', native: '한국어'),
  OcrLanguage('kor_vert', 'Korean (vertical)', 1113715),
  OcrLanguage('kmr', 'Kurdish (Kurmanji)', 3568615, iso: 'ku'),
  OcrLanguage('kir', 'Kyrgyz', 9928497, iso: 'ky'),
  OcrLanguage('lao', 'Lao', 6386744, iso: 'lo'),
  OcrLanguage('lat', 'Latin', 3187463, iso: 'la'),
  OcrLanguage('lav', 'Latvian', 2717247, iso: 'lv'),
  OcrLanguage('lit', 'Lithuanian', 3154896, iso: 'lt'),
  OcrLanguage('ltz', 'Luxembourgish', 2606426, iso: 'lb'),
  OcrLanguage('mkd', 'Macedonian', 1600188, iso: 'mk'),
  OcrLanguage('msa', 'Malay', 1747801, iso: 'ms'),
  OcrLanguage('mal', 'Malayalam', 5275996, iso: 'ml', native: 'മലയാളം'),
  OcrLanguage('mlt', 'Maltese', 2308796, iso: 'mt'),
  OcrLanguage('mri', 'Maori', 862973, iso: 'mi'),
  OcrLanguage('mar', 'Marathi', 2118233, iso: 'mr', native: 'मराठी'),
  OcrLanguage('enm', 'Middle English', 3101551),
  OcrLanguage('frm', 'Middle French', 2024948),
  OcrLanguage('mon', 'Mongolian', 2137042, iso: 'mn'),
  OcrLanguage('nep', 'Nepali', 1002911, iso: 'ne', native: 'नेपाली'),
  OcrLanguage('nor', 'Norwegian', 3610079, iso: 'no'),
  OcrLanguage('oci', 'Occitan', 6322087, iso: 'oc'),
  OcrLanguage('ori', 'Odia', 1480066, iso: 'or', native: 'ଓଡ଼ିଆ'),
  OcrLanguage('pus', 'Pashto', 1772087, iso: 'ps'),
  OcrLanguage('fas', 'Persian', 431500, iso: 'fa'),
  OcrLanguage('pol', 'Polish', 4765518, iso: 'pl'),
  OcrLanguage('por', 'Portuguese', 1982756, iso: 'pt'),
  OcrLanguage('pan', 'Punjabi', 497721, iso: 'pa', native: 'ਪੰਜਾਬੀ'),
  OcrLanguage('que', 'Quechua', 5026336, iso: 'qu'),
  OcrLanguage('ron', 'Romanian', 2376323, iso: 'ro'),
  OcrLanguage('rus', 'Russian', 3861738, iso: 'ru', native: 'Русский'),
  OcrLanguage('san', 'Sanskrit', 12404677, iso: 'sa', native: 'संस्कृतम्'),
  OcrLanguage('gla', 'Scottish Gaelic', 3068307, iso: 'gd'),
  OcrLanguage('srp', 'Serbian', 2149931, iso: 'sr'),
  OcrLanguage('srp_latn', 'Serbian (Latin)', 3281787),
  OcrLanguage('snd', 'Sindhi', 1694035, iso: 'sd'),
  OcrLanguage('sin', 'Sinhala', 1727413, iso: 'si'),
  OcrLanguage('slk', 'Slovak', 4427661, iso: 'sk'),
  OcrLanguage('slv', 'Slovenian', 3003829, iso: 'sl'),
  OcrLanguage('spa', 'Spanish', 2294433, iso: 'es'),
  OcrLanguage('spa_old', 'Spanish (old)', 2894755),
  OcrLanguage('sun', 'Sundanese', 1369500, iso: 'su'),
  OcrLanguage('swa', 'Swahili', 2167651, iso: 'sw'),
  OcrLanguage('swe', 'Swedish', 4167034, iso: 'sv'),
  OcrLanguage('syr', 'Syriac', 2207208),
  OcrLanguage('tgk', 'Tajik', 2602685, iso: 'tg'),
  OcrLanguage('tam', 'Tamil', 3237963, iso: 'ta', native: 'தமிழ்'),
  OcrLanguage('tat', 'Tatar', 1072896, iso: 'tt'),
  OcrLanguage('tel', 'Telugu', 2769654, iso: 'te', native: 'తెలుగు'),
  OcrLanguage('tha', 'Thai', 1072600, iso: 'th'),
  OcrLanguage('bod', 'Tibetan', 1966440, iso: 'bo'),
  OcrLanguage('tir', 'Tigrinya', 378822, iso: 'ti'),
  OcrLanguage('ton', 'Tongan', 947249, iso: 'to'),
  OcrLanguage('tur', 'Turkish', 4550554, iso: 'tr'),
  OcrLanguage('ukr', 'Ukrainian', 3825102, iso: 'uk'),
  OcrLanguage('urd', 'Urdu', 1398718, iso: 'ur', native: 'اردو'),
  OcrLanguage('uig', 'Uyghur', 2794272, iso: 'ug'),
  OcrLanguage('uzb', 'Uzbek', 6470703, iso: 'uz'),
  OcrLanguage('uzb_cyrl', 'Uzbek (Cyrillic)', 1563501),
  OcrLanguage('vie', 'Vietnamese', 531275, iso: 'vi'),
  OcrLanguage('cym', 'Welsh', 2208919, iso: 'cy'),
  OcrLanguage('fry', 'Western Frisian', 1906018, iso: 'fy'),
  OcrLanguage('yid', 'Yiddish', 545606, iso: 'yi'),
  OcrLanguage('yor', 'Yoruba', 963400, iso: 'yo'),
];

/// The languages the sheet always shows first, as well as any it proposes:
/// the ones TomeVoice is most read in.
const featuredOcrLanguages = ['ben', 'hin', 'eng'];

OcrLanguage? ocrLanguageByCode(String code) => ocrLanguages.where((l) => l.code == code).firstOrNull;

/// The language Tesseract reads [tag] in ("bn", "bn-IN", "zh-Hant"), or null
/// when it reads no such language.
OcrLanguage? ocrLanguageForIso(String? tag) {
  if (tag == null || tag.trim().isEmpty) return null;
  final parts = tag.trim().toLowerCase().split(RegExp('[-_]'));
  if (parts.first == 'zh' && parts.skip(1).any(const {'hant', 'tw', 'hk', 'mo'}.contains)) {
    return ocrLanguageByCode('chi_tra');
  }
  // Older and wider codes for the same languages.
  const same = {'nb': 'no', 'nn': 'no', 'iw': 'he', 'in': 'id', 'tl': 'fil', 'ji': 'yi', 'mo': 'ro'};
  final iso = same[parts.first] ?? parts.first;
  return ocrLanguages.where((l) => l.iso == iso).firstOrNull;
}

/// The languages a scan is first offered in: the book's own and the app's.
/// A scan rarely says what language it is in, so for one that does not, the
/// languages picked last time stand in for the book's.
List<OcrLanguage> defaultOcrLanguages({String? book, String? app, List<String> last = const []}) {
  final out = <OcrLanguage>[];
  void add(OcrLanguage? l) {
    if (l != null && !out.contains(l)) out.add(l);
  }

  final own = ocrLanguageForIso(book);
  if (own != null) {
    add(own);
  } else {
    last.map(ocrLanguageByCode).forEach(add);
  }
  add(ocrLanguageForIso(app));
  if (out.isEmpty) add(ocrLanguageByCode('eng'));
  return out;
}

/// Tesseract's language string for [languages]: "ben+eng".
String ocrLanguageString(List<OcrLanguage> languages) => languages.map((l) => l.code).join('+');

/// The languages of a language string, those the catalogue knows.
List<OcrLanguage> ocrLanguagesOf(String languages) => [
      for (final c in languages.split('+'))
        if (ocrLanguageByCode(c.trim()) case final l?) l,
    ];

/// Whether [head], the start of a file of [size] bytes, is a Tesseract
/// traineddata file: a count of entries, then where each one starts (-1 for
/// none), in order and inside the file. A web page, or a file cut short, is
/// not one; Tesseract fed either could fail in ways no message explains.
bool looksLikeTraineddata(Uint8List head, int size) {
  if (head.length < 4) return false;
  final data = ByteData.sublistView(head);
  final n = data.getInt32(0, Endian.little);
  if (n < 1 || n > 64 || head.length < 4 + 8 * n) return false;
  var from = 4 + 8 * n;
  var any = false;
  for (var i = 0; i < n; i++) {
    final at = data.getInt64(4 + 8 * i, Endian.little);
    if (at == -1) continue;
    if (at < from || at > size) return false;
    from = at;
    any = true;
  }
  return any;
}

/// A language's data downloaded on purpose and called off.
class OcrDownloadCancelled implements Exception {
  const OcrDownloadCancelled();
}

/// The language data on the phone, under files/ocr/tessdata: Tesseract's data
/// path is files/ocr. Never backed up (LibraryBackup.kt): it is a download
/// away, and a restore keeps the phone's own (backup.dart, keptOnPhone).
class OcrData extends ChangeNotifier {
  OcrData._();

  static final instance = OcrData._();

  Directory? _dir;

  /// Tesseract's data path: the folder that holds tessdata/.
  Directory get dataDir => _dir ?? Directory('${Directory.systemTemp.path}/ocr');

  Directory get tessdata => Directory('${dataDir.path}/tessdata');

  void attach(Directory root) => _dir = Directory('${root.path}/ocr');

  File fileOf(OcrLanguage l) => File('${tessdata.path}/${l.code}.traineddata');

  File _partOf(OcrLanguage l) => File('${fileOf(l).path}.part');

  bool installed(OcrLanguage l) {
    final f = fileOf(l);
    return f.existsSync() && f.lengthSync() == l.bytes;
  }

  /// Language code -> download progress (0..1), while downloading.
  final downloading = <String, double>{};

  final _going = <String, Future<void>>{};
  final _cancelled = <String>{};
  final _clients = <String, HttpClient>{};

  /// No data for this long and a download has stalled: it stops, and goes on
  /// from there next time.
  static const stallAfter = Duration(seconds: 30);

  /// Stop downloading [l] at once; what came is deleted.
  void cancel(OcrLanguage l) {
    if (!downloading.containsKey(l.code)) return;
    _cancelled.add(l.code);
    _clients[l.code]?.close(force: true);
  }

  /// Fetch [l]'s data, reporting progress in [downloading].
  ///
  /// As a natural voice's download (neural_voices.dart): one cut short keeps
  /// what came, and the next asks only for the rest. The file must come to
  /// exactly the size the catalogue lists, as the server must say it is, and
  /// be a traineddata file by its own table of contents, or it is not kept.
  /// Throws [OcrDownloadCancelled] when called off with [cancel]. [source]
  /// and [stall] stand in for the file's address and [stallAfter] in tests.
  Future<void> download(OcrLanguage l, {@visibleForTesting Uri? source, Duration stall = stallAfter}) {
    if (installed(l)) return Future.value();
    // A block, not an arrow: the arrow would hand whenComplete the future it
    // took out of the map, this very one, and it would wait on itself.
    return _going[l.code] ??= _download(l, source, stall).whenComplete(() {
      _going.remove(l.code);
    });
  }

  Future<void> _download(OcrLanguage l, Uri? source, Duration stall) async {
    _cancelled.remove(l.code);
    downloading[l.code] = 0;
    notifyListeners();
    final part = _partOf(l);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      // Sizes and ranges count the file's own bytes: nothing compressed on
      // the way.
      ..autoUncompress = false;
    _clients[l.code] = client;
    var keepPart = true;
    try {
      await tessdata.create(recursive: true);
      for (var attempt = 0;; attempt++) {
        var have = await part.exists() ? await part.length() : 0;
        if (have >= l.bytes) {
          // Already whole (stopped before it was checked), or too long to be
          // this file: checked below, or fetched again.
          if (have == l.bytes) break;
          await part.delete();
          have = 0;
        }
        final req = await client.getUrl(source ?? l.url);
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final res = await req.close();
        // The part on the phone is not of this file: start over.
        if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable && attempt == 0) {
          await res.drain<void>();
          await part.delete();
          continue;
        }
        final resumed = res.statusCode == HttpStatus.partialContent && have > 0;
        if (res.statusCode != HttpStatus.ok && !resumed) {
          await res.drain<void>().catchError((Object _) {});
          throw HttpException('The ${l.name} language data could not be fetched (${res.statusCode})');
        }
        final from = resumed ? have : 0;
        final total = resumed ? _totalOf(res.headers.value(HttpHeaders.contentRangeHeader)) : res.contentLength;
        if (total > 0 && total != l.bytes) {
          keepPart = false;
          throw FormatException('The ${l.name} language data is not the size it should be ($total bytes).');
        }
        final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        var got = from;
        try {
          await for (final chunk in res.timeout(stall)) {
            if (_cancelled.contains(l.code)) throw const OcrDownloadCancelled();
            if (got + chunk.length > l.bytes) {
              keepPart = false;
              throw FormatException('The ${l.name} language data is longer than it should be.');
            }
            sink.add(chunk);
            got += chunk.length;
            downloading[l.code] = got / l.bytes;
            notifyListeners();
          }
        } finally {
          await sink.close();
        }
        if (got != l.bytes) throw const HttpException('The download was cut short');
        break;
      }
      // Whole: a damaged file is not worth going on from.
      keepPart = false;
      if (!await _isTraineddata(part, l.bytes)) {
        throw FormatException('The ${l.name} language data arrived damaged. Try again.');
      }
      await part.rename(fileOf(l).path);
      downloading.remove(l.code);
      notifyListeners();
    } on Object {
      // Called off: whatever the closed connection threw, it is that.
      final cancelled = _cancelled.remove(l.code);
      if (cancelled) keepPart = false;
      downloading.remove(l.code);
      notifyListeners();
      if (cancelled) throw const OcrDownloadCancelled();
      rethrow;
    } finally {
      _clients.remove(l.code);
      client.close(force: true);
      if (!keepPart && await part.exists()) await part.delete();
    }
  }

  static Future<bool> _isTraineddata(File f, int size) async {
    final raf = await f.open();
    try {
      return looksLikeTraineddata(await raf.read(4 + 8 * 64), size);
    } finally {
      await raf.close();
    }
  }

  /// The whole size from "bytes 100-199/2000"; 0 when it is not said.
  static int _totalOf(String? range) => int.tryParse(range?.split('/').last.trim() ?? '') ?? 0;

  /// The data of [languages] that is not on the phone yet, fetched one after
  /// another; [onProgress] has how far, 0 to 1, by bytes. [source] stands in
  /// for the files' addresses in tests.
  Future<void> ensure(
    List<OcrLanguage> languages, {
    void Function(double done)? onProgress,
    @visibleForTesting Uri Function(OcrLanguage l)? source,
  }) async {
    final missing = [for (final l in languages) if (!installed(l)) l];
    final all = missing.fold<int>(0, (n, l) => n + l.bytes);
    var before = 0;
    for (final l in missing) {
      void report() {
        final p = downloading[l.code];
        if (p != null) onProgress?.call((before + p * l.bytes) / all);
      }

      addListener(report);
      try {
        await download(l, source: source?.call(l));
      } finally {
        removeListener(report);
      }
      before += l.bytes;
      onProgress?.call(before / all);
    }
    if (missing.isEmpty) onProgress?.call(1);
  }

  /// Take [languages]' data off the phone (it failed to load: fetched again
  /// when next wanted).
  Future<void> remove(List<OcrLanguage> languages) async {
    for (final l in languages) {
      try {
        await fileOf(l).delete();
      } on FileSystemException {
        // Not there.
      }
    }
    notifyListeners();
  }

  File get _picked => File('${dataDir.path}/languages.json');

  /// The languages picked for the last scan, for a scan that does not say.
  List<String> lastPicked() {
    try {
      final raw = jsonDecode(_picked.readAsStringSync());
      return [for (final c in raw is List ? raw : const []) if (c is String) c];
    } on Object {
      return const [];
    }
  }

  Future<void> remember(List<OcrLanguage> languages) async {
    try {
      await _picked.parent.create(recursive: true);
      await _picked.writeAsString(jsonEncode([for (final l in languages) l.code]));
    } on FileSystemException {
      // Only a default for next time.
    }
  }
}

/// A PDF that could be read with OCR: one refused because its pages are
/// pictures, or one imported with only a few pages of text.
class OcrOffer {
  const OcrOffer({required this.path, required this.name, required this.pdf, this.bookId, this.language});

  /// The PDF: the picker's copy, when the scan was refused (kept for this,
  /// and gone when it is declined), or the book's own.
  final String path;

  /// The file's name, as it was picked.
  final String name;

  /// The platform's text of the PDF (PdfText.kt): the pages that have text
  /// keep it, and its bookmarks are its chapters.
  final Map<String, Object?> pdf;

  /// The book, when it is in the library already (a few pages of text).
  final String? bookId;

  /// The book's language when known (ISO 639-1).
  final String? language;

  bool get imported => bookId != null;

  int get pageCount => pdf['pages'] as int? ?? 0;

  /// The name without ".pdf": "Sonar Tori".
  String get title => name.toLowerCase().endsWith('.pdf') ? name.substring(0, name.length - 4) : name;
}

/// A PDF refused because its pages are pictures, with what OCR needs to read
/// it. Still an [UnsupportedDocumentException]: anything that does not offer
/// OCR says why the PDF was refused, as before.
class ScannedPdf extends UnsupportedDocumentException {
  const ScannedPdf(super.message, this.offer);

  final OcrOffer offer;
}

/// The pages of [pdf] (the platform's text of a PDF) with nothing to read:
/// the ones OCR reads. The pages with text keep their own.
List<int> ocrPagesToRead(Map<String, Object?> pdf) {
  final pages = (pdf['text'] as String? ?? '').split(String.fromCharCode(0x0C));
  final withText = pdfPagesWithText(pages, layout: pdfLayoutFromPlatform(pdf['layout']));
  final count = math.max(pdf['pages'] as int? ?? 0, withText.length);
  return [
    for (var p = 0; p < count; p++)
      if (p >= withText.length || !withText[p]) p,
  ];
}

/// A page as Tesseract reads it (its lines, and a blank line after each
/// paragraph) in the platform's PDF form: each paragraph opened by U+2029,
/// its lines kept. A paragraph stays a paragraph, a heading stays a line of
/// its own, and a word broken at a line's end is mended as in any PDF.
String ocrPageText(String raw) {
  final mark = String.fromCharCode(0x2029);
  final text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll(String.fromCharCode(0x0C), '\n')
      .replaceAll(mark, '\n');
  return [
    for (final para in text.split(RegExp(r'\n[ \t]*\n')))
      if (para.trim().isNotEmpty)
        mark +
            [
              for (final line in para.split('\n'))
                if (line.trim().isNotEmpty) line.trimRight(),
            ].join('\n'),
  ].join('\n');
}

/// A scan's text in the platform's PDF form: its own text for the pages that
/// had some ([pdf], as PdfText.kt gives it), Tesseract's for those it read
/// ([read], page to text). With the bookmarks, and the line layout and
/// raised runs of the pages that kept their own text (an OCR'd page has
/// neither, so it is read as it comes), and which [languages] read it.
Map<String, Object?> ocrPdfText(Map<String, Object?> pdf, Map<int, String> read, {required String languages}) {
  final ff = String.fromCharCode(0x0C);
  final own = (pdf['text'] as String? ?? '').split(ff);
  final ownCount = own.isNotEmpty && own.last.isEmpty ? own.length - 1 : own.length;
  final layout = pdfLayoutFromPlatform(pdf['layout']);
  final raised = pdfRaisedFromPlatform(pdf['raised']);
  final last = read.keys.fold<int>(-1, math.max);
  final count = math.max(math.max(pdf['pages'] as int? ?? 0, ownCount), last + 1);
  final pages = <String>[];
  final lines = <List<int>>[];
  final runs = <List<int>>[];
  for (var p = 0; p < count; p++) {
    final ocr = read[p];
    if (ocr != null) {
      pages.add(ocrPageText(ocr));
      lines.add(const []);
      runs.add(const []);
    } else {
      pages.add(p < ownCount ? own[p] : '');
      lines.add(layout != null && p < layout.length ? layout[p] : const []);
      runs.add(raised != null && p < raised.length ? raised[p] : const []);
    }
  }
  return {
    // Every page ends with a page break, as the platform's text does.
    'text': pages.map((p) => '$p$ff').join(),
    'pages': count,
    'layout': lines,
    'raised': runs,
    'outline': pdf['outline'] ?? const [],
    'title': pdf['title'],
    'author': pdf['author'],
    'ocr': languages,
    'ocrPages': [...read.keys]..sort(),
  };
}
