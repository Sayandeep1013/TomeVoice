import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:xml/xml.dart';

import 'error_log.dart' show ErrorLog;
import 'kosync.dart';
import 'library_store.dart';
import 'marks.dart';
import 'prefs.dart';
import 'safe_file.dart';
import 'secrets.dart';
import 'stats.dart';

// Sync keeps each book's place, quotes and bookmarks and reading time the
// same on the reader's phones, through a WebDAV folder of their own (and a
// book's place with KOReader, see kosync.dart). Off unless set up: nothing
// leaves the phone until the reader names a server. The books themselves
// never go, nor anything of a book on a shut secret shelf.

/// A reading place as synced: where, how far, and when it was saved.
class SyncedPlace {
  const SyncedPlace({required this.cursor, required this.progress, required this.at, this.where});

  final ReadingCursor cursor;
  final double progress;
  final String? where;
  final DateTime at;

  bool samePlace(SyncedPlace o) =>
      o.cursor.sectionIndex == cursor.sectionIndex &&
      o.cursor.blockIndex == cursor.blockIndex &&
      o.cursor.sentenceIndex == cursor.sentenceIndex;

  Map<String, Object?> toJson() => {
        'cursor': cursor.toJson(),
        'progress': progress,
        if (where != null) 'where': where,
        'at': at.toUtc().toIso8601String(),
      };

  static SyncedPlace? fromJson(Object? j) {
    if (j is! Map || j['cursor'] is! Map) return null;
    return SyncedPlace(
      cursor: ReadingCursor.fromJson(Map<String, Object?>.from(j['cursor'] as Map)),
      progress: (j['progress'] as num?)?.toDouble() ?? 0,
      where: j['where'] as String?,
      at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// What is synced of one book, in `TomeVoice/books/<id>.json`: its place,
/// its quotes and bookmarks, those removed (and when), and the time spent
/// in it each day.
class BookRecord {
  BookRecord({
    required this.id,
    this.title = '',
    this.place,
    List<Mark>? marks,
    Map<String, DateTime>? removed,
    Map<String, int>? days,
  })  : marks = marks ?? [],
        removed = removed ?? {},
        days = days ?? {};

  final String id;
  final String title;
  final SyncedPlace? place;
  final List<Mark> marks;

  /// Mark id -> when it was removed: a removal is not undone by a copy of
  /// the mark saved before it.
  final Map<String, DateTime> removed;

  /// Day ("2026-10-30") -> milliseconds spent in the book.
  final Map<String, int> days;

  /// The same record always written the same way, so two copies with the
  /// same things in them compare equal.
  Map<String, Object?> toJson() {
    final ms = [...marks]..sort((a, b) => a.id.compareTo(b.id));
    final gone = removed.keys.toList()..sort();
    final ds = days.keys.toList()..sort();
    return {
      'app': 'TomeVoice',
      'v': 1,
      'id': id,
      if (title.isNotEmpty) 'title': title,
      if (place != null) 'place': place!.toJson(),
      'marks': [for (final m in ms) m.toJson()],
      if (gone.isNotEmpty) 'removed': {for (final k in gone) k: removed[k]!.toUtc().toIso8601String()},
      if (ds.isNotEmpty) 'days': {for (final d in ds) d: days[d]},
    };
  }

  String encode() => jsonEncode(toJson());

  static BookRecord fromJson(String id, Object? j) {
    if (j is! Map) return BookRecord(id: id);
    return BookRecord(
      id: id,
      title: j['title'] as String? ?? '',
      place: SyncedPlace.fromJson(j['place']),
      marks: [
        for (final m in j['marks'] is List ? j['marks'] as List : const [])
          if (Mark.fromJson(m) case final mark? when mark.bookId == id) mark,
      ],
      removed: {
        for (final e in (j['removed'] is Map ? j['removed'] as Map : const {}).entries)
          if (DateTime.tryParse('${e.value}') case final t?) '${e.key}': t,
      },
      days: {
        for (final e in (j['days'] is Map ? j['days'] as Map : const {}).entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
      },
    );
  }
}

/// [a] and [b] made one, as a restore adds a backup to a library: places
/// by the newest, quotes and bookmarks by id (the copy changed last; gone
/// if removed after that), time per day the larger.
BookRecord mergeBooks(BookRecord a, BookRecord b) {
  final pa = a.place, pb = b.place;
  final place = pa == null ? pb : (pb == null || !pb.at.isAfter(pa.at) ? pa : pb);
  final removed = {...a.removed};
  b.removed.forEach((id, t) {
    final o = removed[id];
    if (o == null || t.isAfter(o)) removed[id] = t;
  });
  final byId = <String, Mark>{};
  for (final m in [...a.marks, ...b.marks]) {
    final o = byId[m.id];
    if (o == null || m.changed.isAfter(o.changed)) byId[m.id] = m;
  }
  byId.removeWhere((id, m) {
    final t = removed[id];
    return t != null && !m.changed.isAfter(t);
  });
  final days = {...a.days};
  b.days.forEach((d, ms) => days[d] = math.max(days[d] ?? 0, ms));
  return BookRecord(
    id: a.id,
    // The server's name for it, when [b] is the server's: two phones naming
    // one book differently must not write it back and forth.
    title: b.title.isNotEmpty ? b.title : a.title,
    place: place,
    marks: byId.values.toList(),
    removed: removed,
    days: days,
  );
}

/// Day -> its listening and reading time, words and chapters, the larger
/// of each kept (`TomeVoice/stats.json`). Time per book is in each book's
/// own record, so a shut secret shelf's books are named nowhere.
Map<String, Map<String, int>> mergeDays(Map<String, Map<String, int>> a, Map<String, Map<String, int>> b) {
  final out = {for (final e in a.entries) e.key: {...e.value}};
  b.forEach((day, fig) {
    final mine = out.putIfAbsent(day, () => {});
    fig.forEach((k, v) => mine[k] = math.max(mine[k] ?? 0, v));
  });
  return out;
}

const _figures = ['listen', 'read', 'words', 'chapters'];

Map<String, Map<String, int>> _localDays() => {
      for (final e in StatsStore.instance.days.entries)
        e.key: {
          'listen': e.value.listenMs,
          'read': e.value.readMs,
          'words': e.value.words,
          'chapters': e.value.chapters,
        },
    };

String _encodeDays(Map<String, Map<String, int>> days) {
  final keys = days.keys.toList()..sort();
  return jsonEncode({
    'app': 'TomeVoice',
    'v': 1,
    'days': {
      for (final k in keys)
        k: {for (final f in _figures) if ((days[k]![f] ?? 0) > 0) f: days[k]![f]},
    },
  });
}

/// The days' totals [text] holds; null when it cannot be read.
Map<String, Map<String, int>>? _decodeDays(String text) {
  final Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException {
    return null;
  }
  final days = j is Map && j['days'] is Map ? j['days'] as Map : const {};
  return {
    for (final e in days.entries)
      if (e.value is Map)
        '${e.key}': {
          for (final f in (e.value as Map).entries)
            if (f.value is num) '${f.key}': (f.value as num).toInt(),
        },
  };
}

/// Book [id]'s record as [text] holds it; null when it cannot be read (a
/// damaged file, or another app's), said in the error log without the
/// book's name.
BookRecord? _readRecord(String id, String text) {
  try {
    return BookRecord.fromJson(id, jsonDecode(text));
  } on Object catch (e) {
    ErrorLog.instance.record('Sync passed over a book: its file on the server could not be read (${e.runtimeType})', null);
    return null;
  }
}

String _hash(String text) => md5.convert(utf8.encode(text)).toString();

// ---------------------------------------------------------------- WebDAV

/// The server refused the user name or password.
class SyncAuthException implements Exception {
  const SyncAuthException();
  @override
  String toString() => 'The server did not take that user name and password.';
}

/// A file changed on the server between reading and writing it.
class _Changed implements Exception {
  const _Changed();
}

/// A WebDAV folder (Nextcloud's, a NAS's, or the test server's): files
/// listed, read and written under [base].
class WebDav {
  WebDav(Uri base, {this.user, this.password})
      : base = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/') {
    _http
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'TomeVoice (sync)'
      ..authenticate = _signIn;
  }

  final Uri base;
  final String? user;
  final String? password;
  final _http = HttpClient();
  final _given = <String>{};

  static const _timeout = Duration(seconds: 30);

  Future<bool> _signIn(Uri url, String scheme, String? realm) async {
    final u = user;
    if (u == null || u.isEmpty || url.host != base.host || url.port != base.port) return false;
    // Asked again for the same: what was given was refused.
    if (!_given.add('$scheme ${realm ?? ''}')) return false;
    _http.addCredentials(
      Uri(scheme: url.scheme, host: url.host, port: url.port, path: '/'),
      realm ?? '',
      scheme.toLowerCase() == 'digest'
          ? HttpClientDigestCredentials(u, password ?? '')
          : HttpClientBasicCredentials(u, password ?? ''),
    );
    return true;
  }

  void close() => _http.close(force: true);

  Future<({int status, String body, String? etag})> _send(
    String method,
    String path, {
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final req = await _http.openUrl(method, base.resolve(path)).timeout(_timeout);
    headers.forEach(req.headers.set);
    if (body != null) {
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(_timeout);
    final text = await res.transform(utf8.decoder).join().timeout(_timeout);
    if (res.statusCode == HttpStatus.unauthorized) throw const SyncAuthException();
    return (status: res.statusCode, body: text, etag: res.headers.value(HttpHeaders.etagHeader));
  }

  /// The files in [folder] and their tags, which change with them; null
  /// when there is no such folder.
  Future<Map<String, String?>?> list(String folder) async {
    final r = await _send('PROPFIND', folder,
        body: '<?xml version="1.0" encoding="utf-8"?>'
            '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/></d:prop></d:propfind>',
        headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'});
    if (r.status == HttpStatus.notFound) return null;
    if (r.status != 207) throw HttpException('The server answered HTTP ${r.status} to a listing.');
    final out = <String, String?>{};
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(r.body);
    } on XmlException {
      throw const HttpException('The server answered a listing with something unreadable.');
    }
    for (final resp in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'response')) {
      final href = resp.descendants.whereType<XmlElement>().where((e) => e.name.local == 'href').firstOrNull?.innerText;
      if (href == null) continue;
      final segments = Uri.parse(href.trim()).pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty || href.trim().endsWith('/')) continue;
      final etag = resp.descendants.whereType<XmlElement>().where((e) => e.name.local == 'getetag').firstOrNull?.innerText;
      out[Uri.decodeComponent(segments.last)] = etag?.trim();
    }
    return out;
  }

  /// [path]'s text and tag; null when there is no such file.
  Future<({String text, String? etag})?> get(String path) async {
    final r = await _send('GET', path);
    if (r.status == HttpStatus.notFound) return null;
    if (r.status != HttpStatus.ok) throw HttpException('The server answered HTTP ${r.status}.');
    return (text: r.body, etag: r.etag);
  }

  /// Write [text] to [path]; with [ifMatch], only if the file is still the
  /// one with that tag. Its new tag, when the server says.
  Future<String?> put(String path, String text, {String? ifMatch, bool create = false}) async {
    final r = await _send('PUT', path, body: text, headers: {
      'Content-Type': 'application/json; charset=utf-8',
      if (ifMatch != null) 'If-Match': ifMatch,
      if (create && ifMatch == null) 'If-None-Match': '*',
    });
    if (r.status == HttpStatus.preconditionFailed) throw const _Changed();
    if (r.status < 200 || r.status >= 300) throw HttpException('The server answered HTTP ${r.status} to a write.');
    return r.etag;
  }

  /// Make folder [path] (nothing when it is there already).
  Future<void> folder(String path) async {
    final r = await _send('MKCOL', path);
    if (r.status == HttpStatus.created || r.status == HttpStatus.methodNotAllowed) return;
    if (r.status >= 300) throw HttpException('The server would not make the folder $path (HTTP ${r.status}).');
  }
}

// ----------------------------------------------------------------- state

/// What was synced, and when: the tags of the files as last seen, what was
/// in them, and the removals last merged. In `sync_state.json` at the
/// library root, so a backup carries it with the marks it describes;
/// started afresh for a new server.
class SyncState {
  SyncState(this._file, this._j);

  final File _file;
  final Map<String, Object?> _j;

  static Future<SyncState> read(Directory root) async {
    final f = File('${root.path}/sync_state.json');
    try {
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is Map) return SyncState(f, Map<String, Object?>.from(raw));
      }
    } on Object {
      await setAside(f);
    }
    return SyncState(f, {});
  }

  /// The part kept for [kind] ('webdav', 'kosync') on [server]: forgotten
  /// when the server is another.
  Map<String, Object?> of(String kind, String server) {
    final part = _j[kind];
    if (part is Map && part['server'] == server) return _j[kind] = Map<String, Object?>.from(part);
    return _j[kind] = <String, Object?>{'server': server};
  }

  Future<void> save() => writeSafely(_file, jsonEncode(_j));
}

// ------------------------------------------------------------------ sync

/// What one sync did.
typedef SyncReport = ({int sent, int taken, String? problem});

/// The phone's own records: what is here now of book [e].
BookRecord localRecord(LibraryEntry e, {Map<String, DateTime> removed = const {}}) {
  final opened = e.openedAt;
  final c = e.cursor;
  final atStart = c.sectionIndex == 0 && c.blockIndex == 0 && c.sentenceIndex == 0;
  final hasPlace = opened != null || e.progress > 0 || !atStart;
  return BookRecord(
    id: e.id,
    title: e.title,
    place: hasPlace
        ? SyncedPlace(
            cursor: e.cursor,
            progress: e.progress,
            where: e.where,
            // Saved with every new place; a book taken off History has none,
            // and loses to any place saved elsewhere.
            at: (opened ?? DateTime.fromMillisecondsSinceEpoch(0)).toUtc(),
          )
        : null,
    marks: MarkStore.instance.forBook(e.id),
    removed: removed,
    days: {
      for (final d in StatsStore.instance.days.entries)
        if ((d.value.books[e.id] ?? 0) > 0) d.key: d.value.books[e.id]!,
    },
  );
}

/// Make the library hold [merged] for its book, as [local] was: a newer
/// place moved to, quotes and bookmarks added, changed and removed, time
/// per day raised. True when anything changed.
Future<bool> applyRecord(LibraryStore store, BookRecord local, BookRecord merged) async {
  var changed = false;
  final mp = merged.place, lp = local.place;
  if (mp != null && (lp == null || (mp.at.isAfter(lp.at) && !mp.samePlace(lp)))) {
    await store.saveCursor(merged.id, mp.cursor, mp.progress, where: mp.where);
    changed = true;
  }
  String sig(Iterable<Mark> ms) => ([for (final m in ms) '${m.id}@${m.changed.toIso8601String()}']..sort()).join(',');
  // Merged again with the marks as they are now, not as they were when the
  // sync set out: one saved, changed or removed here meanwhile stays so.
  // Nothing is awaited between the two, so nothing comes between.
  final now = MarkStore.instance.forBook(merged.id);
  final marks = mergeBooks(BookRecord(id: merged.id, marks: now, removed: MarkStore.instance.removedOf(merged.id)), merged).marks;
  if (sig(marks) != sig(now)) {
    await MarkStore.instance.replaceBook(merged.id, marks);
    changed = true;
  }
  var timeChanged = false;
  merged.days.forEach((day, ms) {
    final d = StatsStore.instance.days.putIfAbsent(day, DayStats.new);
    if ((d.books[merged.id] ?? 0) < ms) {
      d.books[merged.id] = ms;
      timeChanged = true;
    }
  });
  if (timeChanged) {
    await StatsStore.instance.flush();
    changed = true;
  }
  return changed;
}

/// Keeps the reader's phones in step: on opening the app, and on coming
/// back to the library from a book. Nothing happens until a server is set
/// up (Settings > Sync).
class BookSync {
  BookSync._();

  static final instance = BookSync._();

  LibraryStore? _store;
  Future<SyncReport>? _running;
  DateTime? _last;
  Timer? _soon;
  AppLifecycleListener? _lifecycle;

  /// The last sync's outcome, for Settings: when, and what went wrong.
  final status = ValueNotifier<({DateTime? at, String? problem})>((at: null, problem: null));

  static ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  /// Whether a server is set up at all.
  static bool get on => _prefs.webdavOn || _prefs.kosyncOn;

  /// Sync a moment after the app opens, and when it comes back.
  void start(LibraryStore store) {
    _store = store;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    Timer(const Duration(seconds: 6), () => unawaited(syncNow()));
    _lifecycle ??= AppLifecycleListener(onResume: soon);
  }

  /// Places were saved (a book read, then left): sync shortly, at most
  /// once a minute while a book reads on in the background.
  void soon() {
    if (!on || _store == null) return;
    _soon?.cancel();
    final last = _last;
    final wait = last == null
        ? const Duration(seconds: 2)
        : const Duration(minutes: 1) - DateTime.now().difference(last);
    _soon = Timer(wait.isNegative ? const Duration(seconds: 2) : wait, () => unawaited(syncNow()));
  }

  /// Sync now (or join the sync already running).
  Future<SyncReport> syncNow({LibraryStore? store}) {
    final s = store ?? _store;
    if (s == null || !on) return Future.value((sent: 0, taken: 0, problem: null));
    return _running ??= _sync(s).whenComplete(() => _running = null);
  }

  Future<SyncReport> _sync(LibraryStore store) async {
    _last = DateTime.now();
    var sent = 0, taken = 0;
    String? problem;
    final hidden = await store.hiddenIds();
    // A shut secret shelf's books are never sent, nor anything taken in.
    final books = [for (final e in await store.list(all: true)) if (!hidden.contains(e.id)) e];
    final state = await SyncState.read(store.root);
    final secrets = await Secrets.of(store.root);
    final p = _prefs;
    if (p.webdavOn && (p.webdavUrl ?? '').isNotEmpty) {
      try {
        final r = await syncWebDav(store, books, state, url: p.webdavUrl!, user: p.webdavUser, password: secrets['webdav']);
        sent += r.sent;
        taken += r.taken;
      } on Object catch (e) {
        problem = _say(e);
      }
    }
    if (p.kosyncOn && (p.kosyncUrl ?? '').isNotEmpty) {
      try {
        final r = await syncKosync(store, books, state,
            url: p.kosyncUrl!, user: p.kosyncUser ?? '', key: secrets['kosync'] ?? '', device: await deviceId(store.root));
        sent += r.sent;
        taken += r.taken;
      } on Object catch (e) {
        problem ??= _say(e);
      }
    }
    await state.save();
    status.value = (at: DateTime.now(), problem: problem);
    return (sent: sent, taken: taken, problem: problem);
  }

  static String _say(Object e) => switch (e) {
        SyncAuthException() || KosyncAuthException() => '$e',
        SocketException() => 'Could not reach the server. Check the address and the network.',
        TimeoutException() => 'The server took too long to answer.',
        HttpException(:final message) => message,
        _ => '$e',
      };
}

/// One device's id for KOReader's sync and the files it writes: made once
/// on this phone and kept off backups, so a restored phone is not taken for
/// this one.
Future<String> deviceId(Directory root) async {
  final s = await Secrets.of(root);
  final known = s['device'];
  if (known != null && known.length == 32) return known;
  final r = math.Random.secure();
  final id = [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join().toUpperCase();
  await s.set('device', id);
  return id;
}

/// Sync [books] through the WebDAV folder at [url]: each book's record and
/// the days' totals, read where they changed on the server, merged with
/// the phone's, taken in, and written back where the phone had more.
Future<({int sent, int taken})> syncWebDav(
  LibraryStore store,
  List<LibraryEntry> books,
  SyncState state, {
  required String url,
  String? user,
  String? password,
}) async {
  final dav = WebDav(Uri.parse(url), user: user, password: password);
  try {
    final st = state.of('webdav', url);
    final known = Map<String, Object?>.from(st['books'] as Map? ?? const {});
    var listing = await dav.list('TomeVoice/books/');
    if (listing == null) {
      await dav.folder('TomeVoice/');
      await dav.folder('TomeVoice/books/');
      listing = {};
    }
    var sent = 0, taken = 0;
    final now = DateTime.now().toUtc();
    for (final e in books) {
      final name = '${e.id}.json';
      final mine = Map<String, Object?>.from(known[e.id] as Map? ?? const {});
      // Marks removed, and when: elsewhere, as last merged, and here, as
      // this phone noted each. One the server has that is only missing
      // here is not taken for removed: a marks.json unreadable or lost took
      // every quote off every phone that way.
      final removed = {
        for (final r in (mine['removed'] as Map? ?? const {}).entries)
          if (DateTime.tryParse('${r.value}') case final t?) '${r.key}': t,
      };
      MarkStore.instance.removedOf(e.id).forEach((id, t) {
        final o = removed[id];
        if (o == null || t.isAfter(o)) removed[id] = t;
      });
      final local = localRecord(e, removed: removed);
      var onServer = listing.containsKey(name);
      final tag = listing[name];
      // Read only what changed there, or here, since: the rest is what was
      // merged last time. What is written is always merged with the copy
      // there, never this phone's alone over it: quotes only missing here
      // went from the server too.
      var read = onServer && (tag == null || tag != mine['etag'] || _hash(local.encode()) != mine['hash']);
      var merged = local;
      var etag = mine['etag'] as String?;
      var unreadable = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        String? theirs;
        if (read) {
          final got = await dav.get('TomeVoice/books/$name');
          onServer = got != null;
          if (got != null) {
            theirs = got.text;
            etag = got.etag ?? tag;
            final record = _readRecord(e.id, got.text);
            // Not written over (another app may know it), nor taken in:
            // this book waits, and the rest are synced.
            if (record == null) {
              unreadable = true;
              break;
            }
            merged = mergeBooks(local, record);
          }
        }
        final text = merged.encode();
        // The server has exactly this already: nothing to write.
        if (theirs != null ? theirs == text : (onServer && _hash(text) == mine['hash'])) break;
        try {
          etag = await dav.put('TomeVoice/books/$name', text, ifMatch: onServer ? etag : null, create: !onServer);
          sent++;
          break;
        } on _Changed {
          // Written by another phone meanwhile: read it again and merge.
          read = true;
        }
      }
      if (unreadable) continue;
      if (await applyRecord(store, local, merged)) taken++;
      known[e.id] = {
        if (etag != null) 'etag': etag,
        'hash': _hash(merged.encode()),
        // Removals are remembered for half a year, then let go.
        'removed': {
          for (final r in merged.removed.entries)
            if (now.difference(r.value).inDays < 183) r.key: r.value.toUtc().toIso8601String(),
        },
      };
    }
    st['books'] = known;

    // The days' totals.
    final stats = Map<String, Object?>.from(st['stats'] as Map? ?? const {});
    final localDays = _localDays();
    var mergedDays = localDays;
    final got = await dav.get('TomeVoice/stats.json');
    final theirDays = got == null ? null : _decodeDays(got.text);
    if (got != null && theirDays == null) {
      // Not written over either: the books' places and quotes still sync.
      ErrorLog.instance.record('Sync passed over the reading time: its file on the server could not be read', null);
      return (sent: sent, taken: taken);
    }
    if (theirDays != null) mergedDays = mergeDays(localDays, theirDays);
    final text = _encodeDays(mergedDays);
    if (got?.text != text) {
      try {
        await dav.put('TomeVoice/stats.json', text, ifMatch: got?.etag);
        sent++;
      } on _Changed {
        // Merged next time.
      }
    }
    if (_applyDays(mergedDays)) {
      await StatsStore.instance.flush();
      taken++;
    }
    stats['hash'] = _hash(text);
    st['stats'] = stats;
    return (sent: sent, taken: taken);
  } finally {
    dav.close();
  }
}

/// Raise this phone's day totals to [days]'. True when any rose.
bool _applyDays(Map<String, Map<String, int>> days) {
  var changed = false;
  days.forEach((day, fig) {
    final d = StatsStore.instance.days.putIfAbsent(day, DayStats.new);
    int up(int mine, String k) {
      final v = fig[k] ?? 0;
      if (v > mine) {
        changed = true;
        return v;
      }
      return mine;
    }

    d.listenMs = up(d.listenMs, 'listen');
    d.readMs = up(d.readMs, 'read');
    d.words = up(d.words, 'words');
    d.chapters = up(d.chapters, 'chapters');
  });
  return changed;
}
