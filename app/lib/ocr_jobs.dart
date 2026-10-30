import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ParseException, bookIdOf;

import 'library_store.dart';
import 'ocr.dart';
import 'safe_file.dart';
import 'speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

/// A scan being read by OCR, or waiting to be, kept in files/ocr/jobs/<id>/
/// (the id is its book's): job.json says what to read and in which
/// languages; pdf.json is the platform's text of the PDF (pages with text
/// keep theirs, and its bookmarks are its chapters); source.pdf is a refused
/// scan's file (a book's own stays in the book's folder); pages/<n>.txt is
/// page n as Ocr.kt read it. Whatever stops the reading, it goes on from the
/// first page without a file.
class OcrJob {
  OcrJob({
    required this.dir,
    required this.name,
    required this.source,
    required this.pages,
    required this.languages,
    required this.created,
    this.bookId,
    this.error,
  });

  final Directory dir;

  /// The file's name, as it was picked.
  final String name;
  final String source;

  /// The pages to read (0-based): those with no text of their own.
  final List<int> pages;

  /// Tesseract's languages: "ben+eng".
  String languages;

  final DateTime created;

  /// The book already on the shelf, for a PDF with a few pages of text.
  final String? bookId;

  /// Why it stopped, when it was not stopped on purpose.
  String? error;

  /// Pages read so far.
  int done = 0;

  String get id => dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

  bool get finished => done >= pages.length;

  /// "Some Book", for the notification.
  String get title {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Directory get _pages => Directory('${dir.path}/pages');

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'source': source,
        'pages': pages,
        'languages': languages,
        'created': created.toIso8601String(),
        if (bookId != null) 'bookId': bookId,
        if (error != null) 'error': error,
      };

  /// The job kept in [dir], with how far it got; null when there is none.
  static Future<OcrJob?> read(Directory dir) async {
    try {
      final j = jsonDecode(await File('${dir.path}/job.json').readAsString()) as Map;
      final job = OcrJob(
        dir: dir,
        name: j['name'] as String? ?? 'scan.pdf',
        source: j['source'] as String? ?? '',
        pages: [for (final p in j['pages'] as List? ?? const []) if (p is int) p],
        languages: j['languages'] as String? ?? 'eng',
        created: DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        bookId: j['bookId'] as String?,
        error: j['error'] as String?,
      );
      await job._count();
      return job;
    } on Object {
      return null;
    }
  }

  Future<void> save() => writeSafely(File('${dir.path}/job.json'), jsonEncode(toJson()));

  /// How many of its pages have their text, by the files.
  Future<void> _count() async {
    final want = pages.toSet();
    var n = 0;
    try {
      await for (final f in _pages.list()) {
        final file = f.uri.pathSegments.last;
        if (!file.endsWith('.txt')) continue;
        if (want.contains(int.tryParse(file.substring(0, file.length - 4)))) n++;
      }
    } on FileSystemException {
      // Nothing read yet.
    }
    done = n;
  }

  /// Forget what was read: it is to be read in other languages.
  Future<void> _forget() async {
    try {
      await _pages.delete(recursive: true);
    } on FileSystemException {
      // Nothing read yet.
    }
    done = 0;
  }
}

/// The scans being read, and the books made of them once they are read to
/// the end. Started from the sheet that offers OCR (ocr_sheet.dart), shown on
/// the shelf, and told how far the phone has got by Ocr.kt's events. One
/// scan is read at a time; the rest wait in the service's queue, or, after a
/// stop, on the shelf until Go on.
class OcrJobs extends ChangeNotifier {
  OcrJobs._();

  static final instance = OcrJobs._();

  LibraryStore? _store;
  StreamSubscription<Map<String, Object?>>? _events;

  /// Every scan not yet made into a book, oldest first.
  final jobs = <OcrJob>[];

  /// The scan the phone is reading, and those waiting their turn.
  String? running;
  final waiting = <String>{};

  /// Stop was asked for: the page being read is the last.
  bool stopping = false;

  /// The scan being made into a book.
  String? making;

  final _news = StreamController<String>.broadcast();

  /// What the reader should hear about: a book ready, a scan that stopped.
  Stream<String> get news => _news.stream;

  /// Books are made one at a time.
  Future<void> _making = Future<void>.value();

  Directory get _dir => Directory('${_store!.root.path}/ocr/jobs');

  /// The scan the shelf shows: the one being read or made into a book, else
  /// the first waiting for Go on.
  OcrJob? get shown =>
      _byId(running) ?? _byId(making) ?? jobs.where((j) => !waiting.contains(j.id)).firstOrNull ?? jobs.firstOrNull;

  OcrJob? _byId(String? id) => id == null ? null : jobs.where((j) => j.id == id).firstOrNull;

  OcrJob? _byDir(String? path) => path == null ? null : jobs.where((j) => j.dir.path == path).firstOrNull;

  /// Take up [store]'s scans: one read to the end while the app was away is
  /// made into a book now; one that stopped waits for Go on. Asked again
  /// while it is under way (the shelf asks as it opens, a scan's offer
  /// too), the same work is waited for.
  Future<void> attach(LibraryStore store) {
    if (identical(_store, store)) return _attaching ?? Future<void>.value();
    _store = store;
    return _attaching = _attach(store);
  }

  Future<void>? _attaching;

  Future<void> _attach(LibraryStore store) async {
    OcrData.instance.attach(store.root);
    _events ??= SpeechService.events.listen(_onEvent);
    final found = <OcrJob>[];
    final jobsDir = Directory('${store.root.path}/ocr/jobs');
    try {
      await for (final e in jobsDir.list()) {
        if (e is! Directory) continue;
        // Named as start() names it, so the platform's events match it.
        final dir = Directory('${jobsDir.path}/${e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)}');
        if (await OcrJob.read(dir) case final job?) found.add(job);
      }
    } on FileSystemException {
      // No scans yet.
    }
    found.sort((a, b) => a.created.compareTo(b.created));
    jobs
      ..clear()
      ..addAll(found);
    await _sync();
    notifyListeners();
  }

  /// What the phone is reading now, as the service says.
  Future<void> _sync() async {
    Map<String, Object?>? now;
    try {
      now = await _channel.invokeMapMethod<String, Object?>('ocrStatus');
    } on Object {
      // No platform to ask: nothing is being read.
    }
    final job = _byDir(now?['job'] as String?);
    running = job?.id;
    if (job != null) job.done = now?['done'] as int? ?? job.done;
    stopping = now?['stopping'] == true;
    waiting
      ..clear()
      ..addAll([
        for (final d in now?['queued'] as List? ?? const [])
          if (_byDir(d as String?)?.id case final id?) id,
      ]);
    for (final j in [...jobs]) {
      if (j.finished && j.id != running && !waiting.contains(j.id)) _make(j);
    }
  }

  /// Read [offer]'s pages in [languages], whose data must be on the phone
  /// (OcrData.ensure). The same scan again goes on from where it got to,
  /// unless it is now to be read in other languages.
  Future<OcrJob> start(OcrOffer offer, List<OcrLanguage> languages) async {
    if (_store == null) throw StateError('OCR has no library yet');
    final langs = ocrLanguageString(languages);
    final id = offer.bookId ?? await _idOf(offer.path);
    var job = _byId(id);
    if (job == null) {
      final dir = Directory('${_dir.path}/$id');
      await dir.create(recursive: true);
      // A refused scan's file comes into the job; a book's own stays put.
      final source = offer.imported ? offer.path : await _moveInto(offer.path, '${dir.path}/source.pdf');
      await writeSafely(File('${dir.path}/pdf.json'), jsonEncode(offer.pdf));
      job = OcrJob(
        dir: dir,
        name: offer.name,
        source: source,
        pages: await _toRead(offer.pdf),
        languages: langs,
        created: DateTime.now(),
        bookId: offer.bookId,
      );
      jobs.add(job);
    } else {
      // Its own copy is in its folder already.
      if (!offer.imported) await declineOcr(offer);
      if (job.languages != langs && running != job.id && !waiting.contains(job.id)) {
        await job._forget();
        job.languages = langs;
      }
    }
    await OcrData.instance.remember(languages);
    await _run(job);
    return job;
  }

  /// Go on reading [job] from its next page, its language data fetched again
  /// if it went.
  Future<void> resume(OcrJob job) async {
    await OcrData.instance.ensure(ocrLanguagesOf(job.languages));
    await _run(job);
  }

  Future<void> _run(OcrJob job) async {
    job.error = null;
    await job.save();
    if (job.finished) {
      // Every page had text of its own, or was read already.
      _make(job);
      notifyListeners();
      return;
    }
    final answer = await _channel.invokeMethod<String>('ocrStart', {
      'job': job.dir.path,
      'pdf': job.source,
      'pages': job.pages,
      'languages': job.languages,
      'data': OcrData.instance.dataDir.path,
      'title': job.title,
    });
    if (answer == 'queued') {
      waiting.add(job.id);
    } else if (answer == 'started') {
      running = job.id;
      stopping = false;
    }
    notifyListeners();
  }

  /// Stop after the page being read; what was read is kept, for Go on.
  Future<void> stop() async {
    if (running == null && waiting.isEmpty) return;
    stopping = true;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('ocrStop');
    } on Object {
      stopping = false;
      notifyListeners();
    }
  }

  /// Give [job] up: what was read goes, and a refused scan's file with it
  /// (a book's own file stays with the book).
  Future<void> discard(OcrJob job) async {
    if (running == job.id || waiting.contains(job.id) || making == job.id) return;
    jobs.remove(job);
    notifyListeners();
    try {
      await job.dir.delete(recursive: true);
    } on FileSystemException {
      // Gone already.
    }
  }

  void _onEvent(Map<String, Object?> e) {
    final type = e['type'];
    if (type is! String || !type.startsWith('ocr')) return;
    final job = _byDir(e['job'] as String?);
    final done = e['done'];
    if (job != null && done is int) job.done = done;
    switch (type) {
      case 'ocrProgress':
        if (job != null) {
          running = job.id;
          waiting.remove(job.id);
        }
      case 'ocrDone':
        if (running == job?.id) running = null;
        if (job != null) {
          job.done = job.pages.length;
          _make(job);
        }
      case 'ocrStopped':
        // The ones waiting were let go with it.
        running = null;
        stopping = false;
        waiting.clear();
      case 'ocrFailed':
        if (running == job?.id) running = null;
        if (job != null) unawaited(_failed(job, e['message'] as String? ?? 'It stopped.', data: e['data'] == true));
      case 'ocrIdle':
        running = null;
        stopping = false;
        waiting.clear();
    }
    notifyListeners();
  }

  Future<void> _failed(OcrJob job, String message, {required bool data}) async {
    job.error = message;
    // Data that would not load is fetched again on Go on.
    if (data) await OcrData.instance.remove(ocrLanguagesOf(job.languages));
    try {
      await job.save();
    } on FileSystemException {
      // Its folder went.
    }
    _news.add('Reading “${job.title}” stopped at page ${job.done + 1}. $message');
    notifyListeners();
  }

  void _make(OcrJob job) => _making = _making.then((_) => _build(job)).catchError((Object _) {});

  Future<void> _build(OcrJob job) async {
    final store = _store;
    if (store == null || !jobs.contains(job)) return;
    making = job.id;
    notifyListeners();
    try {
      final entry = await store.addOcrBook(job.dir.path);
      jobs.remove(job);
      _news.add('“${entry.title}” is read and on your shelf. The words may have mistakes.');
    } on Object catch (e) {
      job.error = e is ParseException ? e.message : '$e';
      try {
        await job.save();
      } on FileSystemException {
        // Its folder went.
      }
      _news.add('“${job.title}” could not be made into a book. ${job.error}');
    } finally {
      making = null;
      notifyListeners();
    }
  }

  /// Hand an event over as the platform would (tests).
  @visibleForTesting
  void handle(Map<String, Object?> event) => _onEvent(event);

  /// Forget the library and every scan (between tests).
  @visibleForTesting
  void reset() {
    _store = null;
    _attaching = null;
    jobs.clear();
    running = null;
    making = null;
    stopping = false;
    waiting.clear();
    _making = Future<void>.value();
  }

  /// Done with every book being made (tests).
  @visibleForTesting
  Future<void> get settled => _making;
}

/// [offer] declined: a refused scan's copy, kept for OCR, goes now with the
/// folder of its own it came in (a book's own file stays).
Future<void> declineOcr(OcrOffer offer) async {
  if (offer.imported) return;
  await _dropCopy(File(offer.path));
}

Future<String> _idOf(String path) => Isolate.run(() => bookIdOf(File(path).readAsBytesSync()));

Future<List<int>> _toRead(Map<String, Object?> pdf) => Isolate.run(() => ocrPagesToRead(pdf));

/// [from] moved to [to] (copied, across file systems), and the picker's
/// folder it came in let go.
Future<String> _moveInto(String from, String to) async {
  final f = File(from);
  try {
    await f.rename(to);
  } on FileSystemException {
    await f.copy(to);
  }
  await _dropCopy(f);
  return to;
}

/// The picker's copy under incoming/<slot>/, with its slot.
Future<void> _dropCopy(File f) async {
  try {
    final slot = f.parent;
    if (slot.parent.path.replaceAll(r'\', '/').endsWith('/incoming')) {
      await slot.delete(recursive: true);
    } else if (await f.exists()) {
      await f.delete();
    }
  } on FileSystemException {
    // Swept with incoming/ at a later start.
  }
}
