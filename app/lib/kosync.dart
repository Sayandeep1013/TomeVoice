import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:xml/xml.dart';

import 'library_store.dart';
import 'sync.dart';

// KOReader's progress sync ("kosync"): the place in a book, shared through
// a server KOReader also talks to (KOReader's own, or one of the reader's).
// As KOReader does it (plugins/kosync.koplugin): a book is known by a
// partial MD5 of its file, the user by a name and the MD5 of the password,
// and the place by a share of the book and KOReader's own pointer to it.

/// KOReader's id for a book file (util.partialMD5, the "binary" checksum):
/// the MD5 of 1 KB samples at 0 and at 1, 4, 16, 64, 256 KB, 1, 4, 16, 64,
/// 256 MB and 1 GB (1 KB times 4 to the i), stopping at the file's end.
/// KOReader writes the first offset as lshift(1024, -2), which LuaJIT's
/// 32-bit shift turns into 0: the file's start.
Future<String> koreaderPartialMd5(File file) async {
  final raf = await file.open();
  try {
    final length = await raf.length();
    final samples = BytesBuilder(copy: false);
    for (var i = -1; i <= 10; i++) {
      final offset = i < 0 ? 0 : 1024 << (2 * i);
      if (offset >= length) break;
      await raf.setPosition(offset);
      samples.add(await raf.read(1024));
    }
    return md5.convert(samples.takeBytes()).toString();
  } finally {
    await raf.close();
  }
}

/// [koreaderPartialMd5] of bytes already read.
String koreaderPartialMd5Of(Uint8List bytes) {
  final samples = BytesBuilder(copy: false);
  for (var i = -1; i <= 10; i++) {
    final offset = i < 0 ? 0 : 1024 << (2 * i);
    if (offset >= bytes.length) break;
    samples.add(Uint8List.sublistView(bytes, offset, offset + 1024 > bytes.length ? bytes.length : offset + 1024));
  }
  return md5.convert(samples.takeBytes()).toString();
}

/// KOReader's key for a password: its MD5, which is all the server sees.
String koreaderKey(String password) => md5.convert(utf8.encode(password)).toString();

/// KOReader keeps four places of a share (Math.roundPercent).
double _round(double p) => (p.clamp(0.0, 1.0) * 10000).floorToDouble() / 10000;

int? _pageOf(Block b) => b.anchor is PageAnchor ? (b.anchor as PageAnchor).page : null;

/// A PDF's pages, as far as its text reaches.
int _pages(Book book) {
  var last = -1;
  for (final s in book.sections) {
    for (final b in s.blocks) {
      final p = _pageOf(b);
      if (p != null && p > last) last = p;
    }
  }
  return last + 1;
}

/// How far through [book] the sentence at [c] is, as KOReader measures a
/// place: for a PDF its page of the pages (1-based, as KOReader counts);
/// for any other book the share of all its text before the sentence, the
/// front matter and the notes included, as KOReader lays them all out.
double percentOf(Book book, ReadingCursor c) {
  if (book.source == SourceKind.pdf) {
    final pages = _pages(book);
    final page = _blockAt(book, c) == null ? null : _pageOf(_blockAt(book, c)!);
    if (pages > 0 && page != null) return _round((page + 1) / pages);
  }
  var total = 0, before = 0;
  for (final s in book.sections) {
    for (var bi = 0; bi < s.blocks.length; bi++) {
      final b = s.blocks[bi];
      if (b.isImage) continue;
      final here = s.index < c.sectionIndex || (s.index == c.sectionIndex && bi < c.blockIndex);
      if (here) before += b.text.length;
      if (s.index == c.sectionIndex && bi == c.blockIndex && c.sentenceIndex < b.sentences.length) {
        before += b.sentences[c.sentenceIndex].startOffset;
      }
      total += b.text.length;
    }
  }
  return total == 0 ? 0 : _round(before / total);
}

Block? _blockAt(Book book, ReadingCursor c) {
  for (final s in book.sections) {
    if (s.index == c.sectionIndex) return c.blockIndex < s.blocks.length ? s.blocks[c.blockIndex] : null;
  }
  return null;
}

/// The sentence at [percent] of [book]: the other way from [percentOf].
/// A PDF's [page] (1-based, KOReader's progress there) is used when given.
ReadingCursor placeAt(Book book, double percent, {int? page}) {
  if (book.source == SourceKind.pdf) {
    final pages = _pages(book);
    // KOReader's share of a PDF is its page over the pages, cut to four
    // places: the nearest page back.
    final want = page != null ? page - 1 : (percent.clamp(0.0, 1.0) * pages).round() - 1;
    if (pages > 0) {
      for (final s in book.sections) {
        for (var bi = 0; bi < s.blocks.length; bi++) {
          final b = s.blocks[bi];
          final p = _pageOf(b);
          if (p != null && p >= want && b.sentences.isNotEmpty && !b.isImage) {
            return ReadingCursor(sectionIndex: s.index, blockIndex: bi);
          }
        }
      }
    }
  }
  var total = 0;
  for (final s in book.sections) {
    for (final b in s.blocks) {
      if (!b.isImage) total += b.text.length;
    }
  }
  // The nearest character: a share kept to four places falls a little
  // short of where it was taken.
  final target = (percent.clamp(0.0, 1.0) * total).round();
  var at = 0;
  ReadingCursor? last;
  for (final s in book.sections) {
    for (var bi = 0; bi < s.blocks.length; bi++) {
      final b = s.blocks[bi];
      if (b.isImage) continue;
      if (b.sentences.isNotEmpty) {
        last = ReadingCursor(sectionIndex: s.index, blockIndex: bi, sentenceIndex: b.sentences.length - 1);
      }
      if (target < at + b.text.length && b.sentences.isNotEmpty) {
        final within = target - at;
        var si = 0;
        for (var k = 0; k < b.sentences.length; k++) {
          if (b.sentences[k].startOffset <= within) si = k;
        }
        return ReadingCursor(sectionIndex: s.index, blockIndex: bi, sentenceIndex: si);
      }
      at += b.text.length;
    }
  }
  return last ?? ReadingCursor.zero;
}

/// An EPUB's chapter files in KOReader's order: the XHTML documents of its
/// spine, which KOReader numbers as DocFragment 1, 2, 3...
List<String> epubSpine(Uint8List epub) {
  try {
    final zip = ZipDecoder().decodeBytes(epub);
    String? read(String name) {
      final f = zip.findFile(name);
      return f == null ? null : utf8.decode(f.content as List<int>, allowMalformed: true);
    }

    final container = read('META-INF/container.xml');
    if (container == null) return const [];
    final opfPath = XmlDocument.parse(container)
        .descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    final opfText = opfPath == null ? null : read(opfPath);
    if (opfPath == null || opfText == null) return const [];
    final dir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/')) : '';
    final opf = XmlDocument.parse(opfText);
    final items = <String, (String, String)>{
      for (final item in opf.descendants.whereType<XmlElement>().where((e) => e.name.local == 'item'))
        if (item.getAttribute('id') case final id?)
          id: (item.getAttribute('href') ?? '', item.getAttribute('media-type') ?? ''),
    };
    return [
      for (final ref in opf.descendants.whereType<XmlElement>().where((e) => e.name.local == 'itemref'))
        if (items[ref.getAttribute('idref')] case (final href, final type)
            when type.contains('xhtml') || type.contains('html'))
          zipJoin(dir, Uri.decodeFull(href)),
    ];
  } on Object {
    return const [];
  }
}

/// What KOReader keeps as the place itself for the sentence at [c]: a
/// PDF's page number, or for an EPUB a pointer to the start of the chapter
/// file holding it (KOReader opens there; the share says how far in).
/// Null where TomeVoice cannot say it in KOReader's terms: KOReader would
/// take an unknown pointer for the start of the book, so none is sent.
String? progressOf(Book book, ReadingCursor c, {List<String> spine = const []}) {
  if (book.source == SourceKind.pdf) {
    final b = _blockAt(book, c);
    final page = b == null ? null : _pageOf(b);
    return page == null ? null : '${page + 1}';
  }
  if (book.source != SourceKind.epub || spine.isEmpty) return null;
  final section = book.sections.where((s) => s.index == c.sectionIndex).firstOrNull;
  final href = section?.href?.split('#').first;
  if (href == null) return null;
  final n = spine.indexOf(href);
  return n < 0 ? null : '/body/DocFragment[${n + 1}]';
}

/// The server took no such user, or no such password.
class KosyncAuthException implements Exception {
  const KosyncAuthException([this.message = 'The KOReader sync server did not take that user name and password.']);
  final String message;
  @override
  String toString() => message;
}

/// A place another device sent.
typedef KosyncProgress = ({double percentage, String progress, String device, String deviceId, int timestamp});

/// A KOReader sync server (koreader-sync-server's API, v1).
class KosyncClient {
  KosyncClient(Uri base, {required this.user, required this.key})
      : base = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/') {
    _http
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'TomeVoice (kosync)';
  }

  final Uri base;
  final String user;

  /// MD5 of the password ([koreaderKey]).
  final String key;
  final _http = HttpClient();

  void close() => _http.close(force: true);

  Future<({int status, Object? body})> _call(String method, String path, {Object? json, bool signed = true}) async {
    final req = await _http.openUrl(method, base.resolve(path)).timeout(const Duration(seconds: 30));
    req.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.koreader.v1+json')
      ..set(HttpHeaders.contentTypeHeader, 'application/json');
    if (signed) {
      req.headers
        ..set('x-auth-user', user)
        ..set('x-auth-key', key);
    }
    if (json != null) {
      final bytes = utf8.encode(jsonEncode(json));
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = null;
    }
    return (status: res.statusCode, body: body);
  }

  /// Make the user (true), or find it is taken (false).
  Future<bool> register() async {
    final r = await _call('POST', 'users/create', json: {'username': user, 'password': key}, signed: false);
    if (r.status == 201) return true;
    if (r.status == 402) return false;
    throw KosyncAuthException(_message(r.body) ?? 'The server would not make that user (HTTP ${r.status}).');
  }

  /// Check the user name and key.
  Future<void> authorize() async {
    final r = await _call('GET', 'users/auth');
    if (r.status == 200) return;
    if (r.status == 401) throw const KosyncAuthException();
    throw HttpException('The KOReader sync server answered HTTP ${r.status}.');
  }

  /// Send the place in [document]. The server's time for it.
  Future<int?> push(String document, {required double percentage, required String progress, required String device, required String deviceId}) async {
    final r = await _call('PUT', 'syncs/progress', json: {
      'document': document,
      'progress': progress,
      'percentage': percentage,
      'device': device,
      'device_id': deviceId,
    });
    if (r.status == 401) throw const KosyncAuthException();
    if (r.status != 200 && r.status != 202) throw HttpException('The KOReader sync server answered HTTP ${r.status}.');
    final b = r.body;
    return b is Map ? (b['timestamp'] as num?)?.toInt() : null;
  }

  /// The place last sent for [document], by any device; null if none.
  Future<KosyncProgress?> pull(String document) async {
    final r = await _call('GET', 'syncs/progress/${Uri.encodeComponent(document)}');
    if (r.status == 401) throw const KosyncAuthException();
    if (r.status != 200) throw HttpException('The KOReader sync server answered HTTP ${r.status}.');
    final b = r.body;
    if (b is! Map || b['percentage'] is! num) return null;
    return (
      percentage: (b['percentage'] as num).toDouble(),
      progress: '${b['progress'] ?? ''}',
      device: '${b['device'] ?? ''}',
      deviceId: '${b['device_id'] ?? ''}',
      timestamp: (b['timestamp'] as num?)?.toInt() ?? 0,
    );
  }

  static String? _message(Object? body) => body is Map ? body['message'] as String? : null;
}

/// What TomeVoice calls itself to KOReader ("Sync to 42% from TomeVoice?").
const kosyncDevice = 'TomeVoice';

/// Sync [books]' places with the KOReader sync server at [url]: a place
/// sent from another device, newer than this phone's, is moved to; this
/// phone's, when it moved since it was last sent, is sent. Books read in
/// the last two months only, and books KOReader can open (not web novels).
Future<({int sent, int taken})> syncKosync(
  LibraryStore store,
  List<LibraryEntry> books,
  SyncState state, {
  required String url,
  required String user,
  required String key,
  required String device,
}) async {
  final client = KosyncClient(Uri.parse(url), user: user, key: key);
  try {
    final st = state.of('kosync', '$url $user');
    final known = Map<String, Object?>.from(st['books'] as Map? ?? const {});
    final since = DateTime.now().subtract(const Duration(days: 60));
    var sent = 0, taken = 0;
    for (final e in books) {
      final opened = e.openedAt;
      if (e.isWeb || opened == null || opened.isBefore(since)) continue;
      final file = File(e.sourcePath);
      if (!await file.exists()) continue;
      final mine = Map<String, Object?>.from(known[e.id] as Map? ?? const {});
      final doc = mine['doc'] as String? ?? await koreaderPartialMd5(file);
      mine['doc'] = doc;
      final here = jsonEncode(e.cursor.toJson());
      ReadingLayout? layout;
      Future<ReadingLayout> book() async => layout ??= await store.loadLayout(e.id);

      final remote = await client.pull(doc);
      var moved = false;
      if (remote != null &&
          remote.deviceId != device &&
          remote.timestamp * 1000 > opened.millisecondsSinceEpoch &&
          remote.timestamp != mine['taken']) {
        final l = await book();
        final page = e.source == SourceKind.pdf ? int.tryParse(remote.progress) : null;
        final to = placeAt(l.book, remote.percentage, page: page);
        final unit = l.unitForCursor(to, saved: true);
        if (!l.isEmpty) {
          final cursor = cursorOf(l.units[unit]);
          if (jsonEncode(cursor.toJson()) != here) {
            // At the time KOReader saved it (see LibraryStore.saveCursor).
            await store.saveCursor(e.id, cursor, progressFraction(l.units, unit),
                where: l.chapterTitle(l.unitChapter[unit]),
                at: DateTime.fromMillisecondsSinceEpoch(remote.timestamp * 1000));
            taken++;
            moved = true;
            mine['sentAt'] = jsonEncode(cursor.toJson());
          }
        }
        mine['taken'] = remote.timestamp;
      }
      if (!moved && mine['sentAt'] != here) {
        final l = await book();
        final spine = e.source == SourceKind.epub ? epubSpine(await file.readAsBytes()) : const <String>[];
        final progress = progressOf(l.book, e.cursor, spine: spine);
        if (progress != null) {
          await client.push(doc,
              percentage: percentOf(l.book, e.cursor), progress: progress, device: kosyncDevice, deviceId: device);
          sent++;
        }
        mine['sentAt'] = here;
      }
      known[e.id] = mine;
    }
    st['books'] = known;
    return (sent: sent, taken: taken);
  } finally {
    client.close();
  }
}
