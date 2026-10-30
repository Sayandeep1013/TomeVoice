import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show BackgroundIsolateBinaryMessenger, MethodChannel, RootIsolateToken;
import 'package:tomevoice_document/tomevoice_document.dart';

import 'marks.dart';
import 'ocr.dart';
import 'safe_file.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'reading_rules.dart';
import 'speech_service.dart';

/// Bumped when ingestion improves enough that stored books should be parsed
/// again from their source file (v2: multilingual sentences, compact JSON;
/// v3: pictures and covers from EPUBs, page numbers in PDFs; v4: toc nav
/// only, chapters named from first lines, drop caps, Gutenberg apparatus;
/// v5: the book's description, shown on its page; v6: footnote markers
/// silent and notes out of the flow, chapters by the contents, text in its
/// own encoding, AZW3 by its chapters, chapters and languages beyond
/// English). PDFs keep their own version, on the entry (pdfParser).
const _parsedVersion = 6;

/// On-device library: copied files, parsed books, reading positions.
///
/// JSON on disk rather than Drift. Everything heavy (parsing, JSON, building
/// the reading layout) runs on a background isolate: on the UI isolate it was
/// a 2.5 second freeze when opening a long EPUB.
class LibraryStore {
  LibraryStore(this.root) {
    // Opening or locking the secret shelves changes what every page shows.
    secretOpen.addListener(() => changes.value++);
  }

  final Directory root;

  /// Whether the secret shelves are open (unlocked with the phone's own
  /// lock; see secret_shelf.dart). While they are shut, [index] and [list]
  /// leave them and their books out, so no page shows them.
  static final secretOpen = ValueNotifier<bool>(false);

  /// Bumped after every write to the index but a saved reading place, so
  /// the shelf can refresh when a book comes, goes or changes.
  final changes = ValueNotifier<int>(0);

  /// Bumped when a reading place is saved, which the reader does every
  /// second or so. Kept apart from [changes]: each saved place re-read the
  /// shelf, History, Updates and a novel's downloads behind the reader, a
  /// hitch every time. What shows places listens here and catches up when
  /// it shows again (see WhenShown); what does not show them ignores it.
  final placeChanges = ValueNotifier<int>(0);

  static const _svc = SpeechService();

  Directory get _booksDir => Directory('${root.path}/books');
  File get _indexFile => File('${root.path}/library.json');

  Future<void> ensure() async {
    await _booksDir.create(recursive: true);
  }

  /// The index, read from disk once and then kept here: every change is
  /// made to this copy in one step, with nothing awaited between reading it
  /// and changing it, then written out. Two changes at once (a place being
  /// saved while a book is imported) can no longer each write over the
  /// other, which could make a book vanish from the shelf.
  LibraryIndex? _known;

  /// Set while a backup is being restored: library.json is being replaced
  /// on disk, and this copy must not be written back over it.
  bool _held = false;

  /// Stop writing the index (a restore is replacing it).
  void hold() {
    _held = true;
    _downloads.clear();
  }

  /// Write again, reading the index afresh (the restore did not happen).
  void release() {
    _held = false;
    _known = null;
    _downloads.clear();
  }

  /// Change the books in one step: [change] gets the current list and
  /// returns the new one. [place]: only a reading place changed.
  Future<void> _change(List<LibraryEntry> Function(List<LibraryEntry> entries) change, {bool place = false}) async {
    await index();
    if (_held) return;
    final next = change([..._known!.entries])..sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
    _known = LibraryIndex(entries: next, categories: _categories, defaultCategory: _defaultCategory);
    await _write(next, place: place);
  }

  // Categories as last read or written; every public method reads the index
  // first, so these are current whenever _write runs.
  List<Category> _categories = Category.defaults;
  String _defaultCategory = Category.defaults.first.id;

  /// Books, most recently opened first; with [all], those on shut secret
  /// shelves too.
  Future<List<LibraryEntry>> list({bool all = false}) async => [...(await index(all: all)).entries];

  /// Books plus the shelf's categories. Secret shelves and their books only
  /// while they are open, or with [all] (for what is not shown: imports,
  /// the starter book, checks for new chapters).
  Future<LibraryIndex> index({bool all = false}) async {
    var full = _known;
    if (full == null) {
      final read = await _readIndex();
      full = _known ??= read;
    }
    return all || secretOpen.value ? full : full.withoutSecret();
  }

  /// The ids of the books on secret shelves, open or not.
  Future<Set<String>> secretIds() async {
    final full = await index(all: true);
    final secret = {for (final c in full.categories) if (c.secret) c.id};
    return {
      for (final e in full.entries)
        if (secret.contains(e.categoryIn(full.categories, full.defaultCategory))) e.id,
    };
  }

  /// Whether book [id] is on a secret shelf, from the index already read
  /// (a book is opened from it, so it has been).
  bool isSecret(String id) {
    final full = _known;
    final e = full?.entries.where((e) => e.id == id).firstOrNull;
    if (full == null || e == null) return false;
    final cat = e.categoryIn(full.categories, full.defaultCategory);
    return full.categories.any((c) => c.id == cat && c.secret);
  }

  /// The ids of the books not to be shown: those on secret shelves while
  /// they are shut.
  Future<Set<String>> hiddenIds() async => secretOpen.value ? const {} : await secretIds();

  Future<LibraryIndex> _readIndex() async {
    await ensure();
    var entries = <LibraryEntry>[];
    if (await _indexFile.exists()) {
      try {
        final raw = jsonDecode(await _indexFile.readAsString());
        if (raw is Map) {
          // An entry of the wrong shape (a newer or older app's, a damaged
          // restore) is passed over, not the whole shelf: one threw before,
          // and nothing in the library opened. A copy of the file is kept.
          var skipped = 0;
          T? one<T>(T Function() read) {
            try {
              return read();
            } on Object {
              skipped++;
              return null;
            }
          }

          final books = raw['books'];
          entries = [
            for (final b in books is List ? books : const [])
              if (one(() => LibraryEntry.fromJson(Map<String, Object?>.from(b as Map))) case final e?) e,
          ];
          final listed = raw['categories'];
          final cats = [
            for (final c in listed is List ? listed : const [])
              if (one(() => Category.fromJson(Map<String, Object?>.from(c as Map))) case final c?) c,
          ];
          _categories = cats.isEmpty ? Category.defaults : cats;
          final d = raw['defaultCategory'];
          _defaultCategory = d is String && _categories.any((c) => c.id == d) ? d : _categories.first.id;
          if (skipped > 0) {
            try {
              await _indexFile.copy('${_indexFile.path}.broken');
            } on Object {
              // Nothing more to keep.
            }
          }
        }
      } on FormatException {
        // Unreadable: keep it as library.json.broken rather than let the next
        // save write an empty shelf over it. The books' folders stay.
        await setAside(_indexFile);
        entries = [];
      }
    }
    entries.sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
    return LibraryIndex(
      entries: entries,
      categories: _categories,
      defaultCategory: _defaultCategory,
    );
  }

  Future<void> _write(List<LibraryEntry> entries, {bool place = false}) async {
    // One write at a time, each to its own temp file (two writes sharing one
    // temp name could interleave into invalid JSON, read back as no books).
    await writeSafely(
      _indexFile,
      const JsonEncoder.withIndent('  ').convert({
        'categories': [for (final c in _categories) c.toJson()],
        'defaultCategory': _defaultCategory,
        'books': [for (final e in entries) e.toJson()],
      }),
    );
    if (place) {
      placeChanges.value++;
    } else {
      changes.value++;
    }
  }

  // ------------------------------------------------------------ categories

  /// Replace the category list (rename, reorder, add, delete). Books in a
  /// category that no longer exists move to the first one.
  ///
  /// Secret shelves left out (shut, a page never had them) are kept. One
  /// shelf at least is never secret, and new books never go to a secret one.
  Future<void> saveCategories(List<Category> categories, {String? defaultCategory}) async {
    if (categories.isEmpty) return;
    await index(all: true);
    final given = {for (final c in categories) c.id};
    categories = [...categories, for (final c in _categories) if (c.secret && !given.contains(c.id)) c];
    if (categories.every((c) => c.secret)) categories = [categories.first.withSecret(false), ...categories.skip(1)];
    await _change((entries) {
      _categories = List.unmodifiable(categories);
      final d = defaultCategory ?? _defaultCategory;
      final open = [for (final c in categories) if (!c.secret) c.id];
      _defaultCategory = open.contains(d) ? d : open.first;
      final ids = {for (final c in categories) c.id};
      return [
        for (final e in entries)
          e.category == null || ids.contains(e.category) ? e : e.copyWith(category: categories.first.id),
      ];
    });
  }

  /// A new category at the end of the list.
  Future<Category> addCategory(String name, {bool secret = false}) async {
    final idx = await index(all: true);
    final cat = Category(Category.newId(name), name, secret: secret);
    await saveCategories([...idx.categories, cat]);
    return cat;
  }

  /// Put [ids] in [categoryId].
  Future<void> moveBooks(Set<String> ids, String categoryId) => _change((entries) => [
        for (final e in entries) ids.contains(e.id) ? e.copyWith(category: categoryId) : e,
      ]);

  // ------------------------------------------------------------ web novels

  /// A web novel's id: stable for the same novel on the same source.
  static String webId(String pluginId, String path) =>
      'web-${bookIdOf(Uint8List.fromList(utf8.encode('$pluginId|$path')))}';

  /// Add a web novel from [plugin] (details and chapter list in [novel]).
  /// Its cover is fetched once; chapters are fetched as they are read.
  Future<LibraryEntry> addWebNovel(PluginInfo plugin, SourceNovel novel, {String? category}) async {
    await ensure();
    final id = webId(plugin.id, novel.path);
    final dir = Directory(bookDir(id))..createSync(recursive: true);
    // Added again (from Browse): its downloads follow the list as it is now.
    final before = await settleWebChapters(id);
    final info = WebNovelInfo(
        plugin: plugin, novel: novel, chapters: novel.chapters, checkedAt: DateTime.now(), filed: true);
    if (before == null) {
      await writeSafely(File('${dir.path}/novel.json'), jsonEncode(info.toJson()));
    } else {
      await _replaceChapters(id, before, info);
    }
    String? cover;
    final url = novel.cover;
    if (url != null && url.startsWith('http')) {
      try {
        final r = await Net.instance.request(url, headers: {'Referer': plugin.site});
        if (r.ok && r.bytes.length > 200) {
          final img = Directory('${dir.path}/img')..createSync(recursive: true);
          final f = File('${img.path}/cover${_imageExt(r.headers['content-type'], url)}');
          await f.writeAsBytes(r.bytes);
          cover = f.path;
        }
      } on Object {
        // A drawn cover will do.
      }
    }
    late LibraryEntry entry;
    await _change((existing) {
      final previous = existing.where((e) => e.id == id).firstOrNull;
      entry = LibraryEntry(
        id: id,
        title: novel.name.isEmpty ? 'Untitled' : novel.name,
        authors: [if (novel.author != null) novel.author!],
        source: SourceKind.web,
        wordCount: 0,
        sourcePath: '',
        addedAt: previous?.addedAt ?? DateTime.now(),
        openedAt: previous?.openedAt,
        cursor: previous?.cursor ?? ReadingCursor.zero,
        progress: previous?.progress ?? 0,
        where: previous?.where,
        // Until its chapters are read (see loadLayout): the title's script,
        // else what the source says.
        language: previous?.language ??
            detectScriptLanguage('${novel.name} ${novel.summary ?? ''}') ??
            languageCodeOf(plugin.lang),
        cover: cover ?? previous?.cover,
        coverMode: previous?.coverMode ?? CoverMode.auto,
        customCover: previous?.customCover,
        category: previous?.category ?? category ?? _defaultCategory,
        plugin: plugin.id,
        novelPath: novel.path,
        chapterCount: novel.chapters.length,
      );
      return [entry, for (final e in existing) if (e.id != id) e];
    });
    return entry;
  }

  /// The stored details and chapter list of web novel [id].
  Future<WebNovelInfo?> webNovel(String id) async {
    final f = File('${bookDir(id)}/novel.json');
    if (!await f.exists()) return null;
    try {
      return WebNovelInfo.fromJson(Map<String, Object?>.from(jsonDecode(await f.readAsString()) as Map));
    } on Object {
      return null;
    }
  }

  /// Replace a web novel's chapter list (after checking for new chapters).
  Future<void> saveWebChapters(String id, List<ChapterItem> chapters) async {
    final info = await settleWebChapters(id);
    if (info == null) return;
    await _replaceChapters(id, info, info.copyWith(chapters: chapters, checkedAt: DateTime.now()));
    await _change((entries) => [for (final e in entries) e.id == id ? e.copyWith(chapterCount: chapters.length) : e]);
  }

  /// Write [next] over [before]. Downloads, the saved place and saved quotes
  /// are filed by a chapter's place in the list, so when the site put an
  /// entry in or took one out earlier on, they move with their chapter. The
  /// list is marked unsettled until they have, so a stop half way is put
  /// right the next time the novel opens.
  Future<void> _replaceChapters(String id, WebNovelInfo before, WebNovelInfo next) async {
    final file = File('${bookDir(id)}/novel.json');
    final moves = _movesByPath(before.chapters, next.chapters);
    await writeSafely(file, jsonEncode(next.copyWith(filed: moves.isEmpty).toJson()));
    if (moves.isEmpty) return;
    await _refile(id, moves);
    await writeSafely(file, jsonEncode(next.copyWith(filed: true).toJson()));
  }

  final _settling = <String, Future<WebNovelInfo?>>{};

  /// Web novel [id]'s details, with every download filed under its own
  /// chapter. Builds up to 1.0.2 left downloads where they were when a
  /// site's list shifted (an entry taken out earlier on), so tapping
  /// chapter 3222 opened 3221: once per novel, each download is matched to
  /// its place again by the title it was saved with.
  Future<WebNovelInfo?> settleWebChapters(String id) => _settling[id] ??= _settle(id);

  Future<WebNovelInfo?> _settle(String id) async {
    try {
      final info = await webNovel(id);
      if (info == null || info.filed) return info;
      final moves = await _runSettle(bookDir(id), [for (final c in info.chapters) c.name]);
      _downloads.remove(id);
      await _followMoves(id, moves);
      final next = info.copyWith(filed: true);
      await writeSafely(File('${bookDir(id)}/novel.json'), jsonEncode(next.toJson()));
      return next;
    } finally {
      _settling.remove(id);
    }
  }

  /// Move [id]'s downloads by [moves] (old chapter to new; -1, no longer
  /// listed), and the saved place and saved quotes with them.
  Future<void> _refile(String id, Map<int, int> moves) async {
    if (moves.isEmpty) return;
    await _runMoveChapters(bookDir(id), moves);
    _downloads.remove(id);
    await _followMoves(id, moves);
  }

  /// The saved place and saved quotes of [id], after its downloads moved.
  Future<void> _followMoves(String id, Map<int, int> moves) async {
    if (moves.isEmpty) return;
    final cursor = await cursorFor(id);
    final to = _follow(moves, cursor.sectionIndex);
    if (to != cursor.sectionIndex) {
      final moved = cursor.copyWith(sectionIndex: to);
      final entry = (await index(all: true)).entries.where((e) => e.id == id).firstOrNull;
      await writeSafely(
        File('${bookDir(id)}/cursor.json'),
        jsonEncode({'cursor': moved.toJson(), 'progress': entry?.progress ?? 0}),
      );
      await _change((entries) => [for (final e in entries) e.id == id ? e.copyWith(cursor: moved) : e]);
    }
    await MarkStore.instance.moveChapters(id, (c) => _follow(moves, c));
  }

  /// Whether chapter [index] of web novel [id] is on the phone.
  bool hasChapter(String id, int index) => File(_chapterFile(id, index)).existsSync();

  /// Chapter numbers of [id] already on the phone.
  ///
  /// The folder is listed once and then kept up to date as chapters are
  /// saved, moved and taken off: a novel's page asks on every change, and
  /// listing a folder of thousands of chapters on the UI thread each time
  /// was a hitch.
  Set<int> downloadedChapters(String id) => _downloads[id] ??= _listDownloads(id);

  final _downloads = <String, Set<int>>{};

  Set<int> _listDownloads(String id) {
    final dir = Directory('${bookDir(id)}/ch');
    if (!dir.existsSync()) return const {};
    return Set.unmodifiable({
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.json'))
          if (int.tryParse(f.uri.pathSegments.last.split('.').first) case final n?) n,
    });
  }

  /// Keep a fetched chapter, parsed, so it opens offline from now on.
  Future<void> saveChapter(String id, int index, String title, String html, {String? language}) async {
    final path = _chapterFile(id, index);
    await _runSaveChapter(path, index, title, html, language);
    final known = _downloads[id];
    if (known != null) _downloads[id] = Set.unmodifiable({...known, index});
  }

  String _chapterFile(String id, int index) => '${bookDir(id)}/ch/$index.json';

  /// Take the downloaded text of chapters [indexes] of [id] off the phone.
  /// They stay in the chapter list and are fetched again when read.
  Future<void> deleteChapters(String id, Iterable<int> indexes) async {
    for (final i in indexes) {
      try {
        await File(_chapterFile(id, i)).delete();
      } on FileSystemException {
        // Not downloaded.
      }
    }
    _downloads.remove(id);
  }

  /// Take [id] off the history (and the Continue card) without touching the
  /// place it is saved at.
  Future<void> forgetOpened(String id) =>
      _change((entries) => [for (final e in entries) e.id == id ? e.copyWith(clearOpened: true) : e]);

  /// Import [file]: parse it off the UI thread, store the source and the
  /// parsed book, and add it to the index. Re-importing a book keeps its
  /// reading position.
  ///
  /// A PDF whose pages are pictures throws [ScannedPdf], its file kept so it
  /// can be read with OCR (ocr_sheet.dart). One with only a few pages of text
  /// is imported, and [onScan], when given, is told so in place of [onNote]:
  /// OCR can read the rest.
  Future<LibraryEntry> importFile(
    PickedFile file, {
    void Function(int done, int total)? onProgress,
    void Function(String note)? onNote,
    void Function(OcrOffer offer)? onScan,
  }) async {
    await ensure();
    final source = File(file.path);
    // A scan's file stays, for OCR.
    var keep = false;
    try {
      final head = await _head(source);
      final isPdf = head.startsWith('%PDF-') ||
          (file.name.toLowerCase().endsWith('.pdf') && !head.startsWith('PK'));

      Map<String, Object?>? pdf;
      if (isPdf) {
        final sub = SpeechService.events.listen((e) {
          if (e['type'] == 'importProgress') {
            onProgress?.call(e['done'] as int? ?? 0, e['total'] as int? ?? 0);
          }
        });
        try {
          pdf = await _svc.extractPdf(file.path);
        } finally {
          await sub.cancel();
        }
      }

      final job = (
        booksDir: _booksDir.path,
        sourcePath: file.path,
        name: file.name,
        mime: file.mime,
        pdf: pdf,
        token: RootIsolateToken.instance,
      );
      final _Imported made;
      try {
        made = await _runImport(job);
      } on UnsupportedDocumentException catch (e) {
        if (pdf == null) rethrow;
        keep = true;
        throw ScannedPdf(e.message, OcrOffer(path: file.path, name: file.name, pdf: pdf));
      }
      final entry = made.entry;
      if (made.note != null) {
        if (onScan != null) {
          onScan(OcrOffer(path: entry.sourcePath, name: file.name, pdf: pdf!, bookId: entry.id, language: entry.language));
        } else {
          onNote?.call(made.note!);
        }
      }

      late LibraryEntry merged;
      await _change((existing) {
        final previous = existing.where((e) => e.id == entry.id).firstOrNull;
        merged = previous == null
            ? entry.copyWith(category: _defaultCategory)
            : entry
                .copyWith(
                  cursor: previous.cursor,
                  progress: previous.progress,
                  openedAt: previous.openedAt,
                  where: previous.where,
                  category: previous.category,
                )
                .withCover(previous.coverMode, previous.customCover);
        return [
          merged,
          for (final e in existing)
            if (e.id != entry.id) e,
        ];
      });
      return merged;
    } finally {
      // The picker's copy: a duplicate of books/<id>/source.* once imported,
      // and of no use when the import failed (it used to stay behind). A
      // scan's is kept for OCR, and goes when OCR is declined (or is swept
      // with the rest of incoming/ an hour on).
      if (!keep) await _dropIncoming(source);
    }
  }

  /// A scan read by OCR made into a book (the import that OCR finishes):
  /// [jobDir] holds what was read (ocr_jobs.dart). Its pages are its own
  /// text where they had any and OCR's elsewhere, made into a book as any
  /// PDF's are. The text is kept beside the book (ocr.json), so opening it,
  /// or a newer PDF reader, never reads the pages again. A book on the shelf
  /// already (a PDF with a few pages of text) keeps its place, shelf and
  /// cover. The job's folder goes once the book is made.
  Future<LibraryEntry> addOcrBook(String jobDir) async {
    await ensure();
    final made = await _runOcrImport((booksDir: _booksDir.path, jobDir: jobDir));
    late LibraryEntry merged;
    await _change((existing) {
      final previous = existing.where((e) => e.id == made.id).firstOrNull;
      merged = previous == null
          ? made.copyWith(category: _defaultCategory)
          : made
              .copyWith(
                cursor: previous.cursor,
                progress: previous.progress,
                openedAt: previous.openedAt,
                where: previous.where,
                category: previous.category,
              )
              .withCover(previous.coverMode, previous.customCover);
      return [
        merged,
        for (final e in existing)
          if (e.id != made.id) e,
      ];
    });
    try {
      await Directory(jobDir).delete(recursive: true);
    } on FileSystemException {
      // Its book is made; a folder left over is only space.
    }
    return merged;
  }

  /// Delete [source] if it is the picker's copy under incoming/, with the
  /// folder of its own it came in (see MainActivity's copy into incoming).
  static Future<void> _dropIncoming(File source) async {
    if (!source.path.contains('/incoming/')) return;
    try {
      final slot = source.parent;
      if (slot.parent.path.endsWith('/incoming')) {
        await slot.delete(recursive: true);
      } else if (await source.exists()) {
        await source.delete();
      }
    } on FileSystemException {
      // Harmless: our own folder, swept at a later start.
    }
  }

  /// Copies the picker left under incoming/ over an hour ago, by an import a
  /// crash stopped. (A newer one may be a file just handed to the app.)
  Future<void> sweepIncoming() async {
    final dir = Directory('${root.path}/incoming');
    try {
      if (!await dir.exists()) return;
      final before = DateTime.now().subtract(const Duration(hours: 1));
      await for (final e in dir.list()) {
        if ((await e.stat()).modified.isBefore(before)) await e.delete(recursive: true);
      }
    } on FileSystemException {
      // Tried again next start.
    }
  }

  /// The reading layout for [id], built on a background isolate.
  Future<ReadingLayout> loadLayout(String id) async {
    final entries = await list();
    final entry = entries.where((e) => e.id == id).firstOrNull;
    if (entry != null && entry.isWeb) {
      final dir = bookDir(id);
      final layout = await _runLoadWeb(dir, id);
      // The chapters' script settles the language the source only named;
      // the library's card says the same.
      final language = layout.book.metadata.language;
      if (language != null && entry.language != language) {
        await _change((now) => [
              for (final e in now)
                if (e.id == id) e.copyWith(language: language) else e,
            ]);
      }
      return layout;
    }
    // A PDF read by an older PDF reader is read again from its file, once:
    // its text from the platform, the book built anew, the place carried.
    Map<String, Object?>? pdf;
    final source = entry?.sourcePath;
    if (entry != null &&
        entry.source == SourceKind.pdf &&
        entry.pdfParser < pdfParserVersion &&
        source != null &&
        File(source).existsSync()) {
      try {
        // A scan read by OCR is made again from the text OCR gave it, kept
        // with the book: its pages are never read again.
        pdf = entry.ocr != null ? readOcrText(bookDir(id)) : await _svc.extractPdf(source);
      } on Object {
        // Kept as it was; tried again next time.
      }
    }
    final job = (
      booksDir: _booksDir.path,
      id: id,
      sourcePath: entry?.sourcePath,
      pdf: pdf,
      token: RootIsolateToken.instance,
    );
    final layout = await _runLoad(job);
    if (pdf != null) {
      await _change((now) => [
            for (final e in now)
              if (e.id == id) e.copyWith(pdfParser: pdfParserVersion) else e,
          ]);
    }
    // Books imported before covers were stored get theirs on first open.
    final cover = coverFileOf(bookDir(id), layout.book);
    if (entry != null && entry.cover != cover && cover != null) {
      await _change((now) => [
            for (final e in now)
              if (e.id == id) e.copyWith(cover: cover) else e,
          ]);
    }
    return layout;
  }

  /// How a book's cover is chosen: [CoverMode.auto] (the book's own, or one
  /// made from the title), a picture of the user's, or a plain title cover.
  Future<LibraryEntry?> setCover(String id, CoverMode mode, {PickedFile? picture}) async {
    String? custom;
    if (picture != null) {
      final dir = Directory('${bookDir(id)}/img')..createSync(recursive: true);
      // A new name every time: the image cache keys on the path, so reusing
      // one would keep showing the previous picture.
      for (final old in dir.listSync().whereType<File>()) {
        if (old.uri.pathSegments.last.startsWith('custom_cover_')) old.deleteSync();
      }
      final dest = '${dir.path}/custom_cover_${DateTime.now().millisecondsSinceEpoch}${_ext(picture.name)}';
      await File(picture.path).copy(dest);
      try {
        await File(picture.path).delete();
      } on FileSystemException {
        // The picker's copy; harmless if it stays.
      }
      custom = dest;
    }
    LibraryEntry? updated;
    await _change((entries) => [
          for (final e in entries)
            if (e.id == id)
              updated = e.withCover(mode, custom ?? e.customCover)
            else
              e,
        ]);
    return updated;
  }

  /// Folder holding a book's source, parsed text and pictures.
  /// A book's folder. An id is 16 hex digits, or web- and 16 more; anything
  /// else (a "..", a slash) could reach outside the books, so it is refused.
  String bookDir(String id) {
    if (!isBookId(id)) throw ArgumentError.value(id, 'id', 'not a book id');
    return '${_booksDir.path}/$id';
  }

  static final _bookId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Whether [id] has the shape of a book id (and so is safe as a folder name).
  static bool isBookId(String id) => _bookId.hasMatch(id);

  Future<ReadingCursor> cursorFor(String id) async {
    final file = File('${bookDir(id)}/cursor.json');
    try {
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          return ReadingCursor.fromJson(
            Map<String, Object?>.from(raw['cursor'] as Map? ?? const {}),
          );
        }
      }
    } on FormatException {
      // Fall through to the index copy.
    }
    final entries = await list();
    for (final e in entries) {
      if (e.id == id) return e.cursor;
    }
    return ReadingCursor.zero;
  }

  Future<void> saveCursor(
    String id,
    ReadingCursor cursor,
    double progress, {
    String? where,
  }) async {
    await ensure();
    final dir = Directory(bookDir(id));
    await dir.create(recursive: true);
    await writeSafely(
      File('${dir.path}/cursor.json'),
      jsonEncode({'cursor': cursor.toJson(), 'progress': progress}),
    );
    await _change(
      (entries) => [
        for (final e in entries)
          if (e.id == id)
            e.copyWith(
              cursor: cursor,
              progress: progress,
              openedAt: DateTime.now(),
              where: where,
            )
          else
            e,
      ],
      place: true,
    );
  }

  Future<void> remove(String id) async {
    final dir = Directory(bookDir(id));
    if (await dir.exists()) await dir.delete(recursive: true);
    _downloads.remove(id);
    await _change((entries) => [for (final e in entries) if (e.id != id) e]);
  }

  static Future<String> _head(File f) async {
    try {
      final raf = await f.open();
      try {
        final bytes = await raf.read(5);
        return String.fromCharCodes(bytes);
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return '';
    }
  }
}

// ------------------------------------------------------------------ isolate

// Top-level so the closure handed to Isolate.run captures only the job record.
// A closure created inside a method can share a context with other captured
// variables (callbacks holding widget state), which cannot be sent.
Future<_Imported> _runImport(_ImportJob job) => Isolate.run(() => _import(job));

Future<ReadingLayout> _runLoad(_LoadJob job) => Isolate.run(() => _loadLayout(job));

Future<ReadingLayout> _runLoadWeb(String dir, String id) => Isolate.run(() => _loadWebSync(dir, id));

Future<void> _runSaveChapter(String path, int index, String title, String html, String? language) =>
    Isolate.run(() {
      final section = webChapterSection(index: index, title: title, html: html, language: language);
      File(path).parent.createSync(recursive: true);
      _writeWholeSync(File(path), jsonEncode(section.toJson()));
    });

Future<void> _runMoveChapters(String dir, Map<int, int> moves) => Isolate.run(() => _moveChaptersSync(dir, moves));

Future<Map<int, int>> _runSettle(String dir, List<String> names) => Isolate.run(() => _settleSync(dir, names));

/// Where each chapter of [before] is in [after], for those that moved (-1:
/// no longer listed).
Map<int, int> _movesByPath(List<ChapterItem> before, List<ChapterItem> after) {
  final at = <String, int>{};
  for (var j = after.length - 1; j >= 0; j--) {
    at[after[j].path] = j;
  }
  return {
    for (var i = 0; i < before.length; i++)
      if (at[before[i].path] != i) i: at[before[i].path] ?? -1,
  };
}

/// Where old chapter [c] is now; one no longer listed hands on to the next
/// one that is.
int _follow(Map<int, int> moves, int c) {
  for (var k = c; k < c + 50; k++) {
    final to = moves[k] ?? k;
    if (to >= 0) return to;
  }
  return c;
}

/// Put each download under [dir]/ch back under its own chapter of [names]
/// (the list as it is now), by the title it was saved with: the same title
/// (the nearest, should one be listed twice), else the nearby title most
/// like it (a site that fixed a typo, "Siniste" for "Sinister", or gave a
/// title its missing number). Where two downloads want one place the surer
/// match keeps it; a download that matches nothing stays where it is.
/// Returns the moves made, old place to new (-1: dropped).
Map<int, int> _settleSync(String dir, List<String> names) {
  final ch = Directory('$dir/ch');
  if (!ch.existsSync()) return const {};
  final placesOf = <String, List<int>>{};
  for (var j = 0; j < names.length; j++) {
    (placesOf[names[j]] ??= []).add(j);
  }
  // Every download by place; one left half moved by an earlier run counts
  // as at its place, unless that place has its file.
  final files = <int, File>{};
  for (final f in ch.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    final n = int.tryParse(name.split('.').first);
    if (n == null) continue;
    if (name.endsWith('.json')) {
      files[n] = f;
    } else if (name.endsWith('.json.moving')) {
      files.putIfAbsent(n, () => f);
    }
  }
  // Where each wants to be, and how sure that is: 2 the same title, 1 a
  // like one, 0 nothing better than where it is.
  final want = <int, (int, int)>{};
  for (final MapEntry(key: n, value: f) in files.entries) {
    final title = _savedTitle(f);
    final places = title == null ? null : placesOf[title];
    final like = title == null || places != null ? null : _likeTitle(title, names, n);
    if (places != null) {
      want[n] = (places.reduce((a, b) => (a - n).abs() <= (b - n).abs() ? a : b), 2);
    } else if (like != null) {
      want[n] = (like, 1);
    } else {
      want[n] = (n, 0);
    }
  }
  final holder = <int, int>{};
  for (final MapEntry(key: n, value: (to, sure)) in want.entries) {
    final other = holder[to];
    if (other == null) {
      holder[to] = n;
      continue;
    }
    final (_, otherSure) = want[other]!;
    if (sure > otherSure || (sure == otherSure && (n - to).abs() < (other - to).abs())) holder[to] = n;
  }
  final placeOf = {for (final MapEntry(key: to, value: n) in holder.entries) n: to};
  final moves = <int, int>{
    for (final n in files.keys)
      if (placeOf[n] != n || files[n]!.path.endsWith('.moving')) n: placeOf[n] ?? -1,
  };
  final parked = <int, File>{};
  for (final MapEntry(key: n, value: to) in moves.entries) {
    final f = files[n]!;
    if (to < 0) {
      f.deleteSync();
    } else {
      parked[n] = f.path.endsWith('.moving') ? f : f.renameSync('${ch.path}/$n.json.moving');
    }
  }
  for (final MapEntry(key: n, value: f) in parked.entries) {
    f.renameSync('${ch.path}/${moves[n]}.json');
  }
  moves.removeWhere((n, to) => n == to);
  return moves;
}

/// The place near [n] whose title in [names] is most like [title]: most of
/// their words (and numbers) the same, "Chapter" aside.
int? _likeTitle(String title, List<String> names, int n) {
  Set<String> words(String t) =>
      t.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty && w != 'chapter').toSet();
  final mine = words(title);
  if (mine.isEmpty) return null;
  int? best;
  var bestScore = 0.5;
  for (var j = math.max(0, n - 8); j < math.min(names.length, n + 9); j++) {
    final theirs = words(names[j]);
    final score = mine.intersection(theirs).length / mine.union(theirs).length;
    if (score > bestScore || (score == bestScore && best != null && (j - n).abs() < (best - n).abs())) {
      best = j;
      bestScore = score;
    }
  }
  return best;
}

/// The title a downloaded chapter was saved with (near the start of its
/// file, so only that much is read).
String? _savedTitle(File f) {
  try {
    final raf = f.openSync();
    final String head;
    try {
      head = utf8.decode(raf.readSync(2048), allowMalformed: true);
    } finally {
      raf.closeSync();
    }
    final m = RegExp(r'"title":("(?:[^"\\]|\\.)*")').firstMatch(head);
    if (m != null) return jsonDecode(m.group(1)!) as String;
    return (jsonDecode(f.readAsStringSync()) as Map)['title'] as String?;
  } on Object {
    return null;
  }
}

/// Move downloads by [moves]: all out of the way first, then each to its
/// place, so a chain of moves never lands on a file still to go. One whose
/// place already holds that chapter (or that is no longer listed) goes.
void _moveChaptersSync(String dir, Map<int, int> moves) {
  final ch = '$dir/ch';
  for (final from in moves.keys) {
    final f = File('$ch/$from.json');
    if (f.existsSync()) f.renameSync('$ch/$from.json.moving');
  }
  for (final MapEntry(key: from, value: to) in moves.entries) {
    final f = File('$ch/$from.json.moving');
    if (!f.existsSync()) continue;
    if (to < 0 || File('$ch/$to.json').existsSync()) {
      f.deleteSync();
    } else {
      f.renameSync('$ch/$to.json');
    }
  }
}

/// Whether [fresh], a chapter list just fetched, should replace [stored]:
/// it differs, and is not a copy cut short (a site that failed part way
/// through its list would otherwise take downloads with it).
bool replacesChapterList(List<ChapterItem> stored, List<ChapterItem> fresh) {
  if (fresh.isEmpty || fresh.length < stored.length - math.max(3, stored.length ~/ 50)) return false;
  if (fresh.length != stored.length) return true;
  for (var i = 0; i < fresh.length; i++) {
    if (fresh[i].path != stored[i].path || fresh[i].name != stored[i].name) return true;
  }
  return false;
}

typedef _ImportJob = ({
  String booksDir,
  String sourcePath,
  String name,
  String? mime,
  Map<String, Object?>? pdf,
  RootIsolateToken? token,
});

/// [pdf]: a PDF's text as the platform has just read it again, when the
/// book was read by an older PDF reader (see [LibraryStore.loadLayout]).
typedef _LoadJob = ({String booksDir, String id, String? sourcePath, Map<String, Object?>? pdf, RootIsolateToken? token});

/// [bytes] as a book, on a background isolate. Text in an East Asian legacy
/// encoding (GBK, Big5, Shift_JIS, EUC-KR...) is decoded by Android's own
/// charsets through [token]; without one (tests) such a book is refused, as
/// it was misread before.
Future<Book> _ingest(Uint8List bytes,
    {String? filename, String? mime, String? id, RootIsolateToken? token}) async {
  if (token == null) return ingestBytes(bytes, filename: filename, mime: mime, id: id);
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  return ingestBytesAsync(bytes, filename: filename, mime: mime, id: id, decodeLegacy: (b, charset) async {
    final text = await const MethodChannel('tomevoice/tts').invokeMethod<String>(
      'decodeCharset',
      {'bytes': b, 'charset': charset},
    );
    if (text == null) throw LegacyEncodingException(charset);
    return text;
  });
}

/// A book made from a file, and anything the reader should hear about it.
typedef _Imported = ({LibraryEntry entry, String? note});

/// A PDF from the text, bookmarks and line layout the platform read from it.
Book _pdfBook(String id, Map<String, Object?> pdf, String? filename) {
  final text = pdf['text'] as String? ?? '';
  return ingestPdfText(
    id: id,
    pages: text.split(String.fromCharCode(0x0C)),
    // Every bookmark level, and where lines sit (for footnotes and columns).
    outline: pdfOutlineFromPlatform(pdf['outline']),
    layout: pdfLayoutFromPlatform(pdf['layout']),
    title: pdf['title'] as String?,
    author: pdf['author'] as String?,
    filename: filename,
  );
}

/// What to say about a PDF whose pages are mostly pictures (a scan with a
/// few typed pages): it imports, but only those pages read aloud.
String? _scanNote(Map<String, Object?> pdf) {
  final text = pdf['text'] as String? ?? '';
  final c = pdfTextCoverage(text.split(String.fromCharCode(0x0C)), layout: pdfLayoutFromPlatform(pdf['layout']));
  if (!c.mostlyPictures) return null;
  return 'Most pages of this PDF are pictures: only ${c.pagesWithText} of ${c.pages} have text to read aloud.';
}

Future<_Imported> _import(_ImportJob job) async {
  final bytes = File(job.sourcePath).readAsBytesSync();
  final id = bookIdOf(bytes);
  final Book book;
  final pdf = job.pdf;
  // A scan read by OCR before: the text OCR gave it stands, and its pages
  // are not read again (they have no text of their own).
  final ocr = pdf == null ? null : readOcrText('${job.booksDir}/$id');
  if (ocr != null) {
    book = _pdfBook(id, ocr, job.name);
  } else if (pdf != null) {
    book = _pdfBook(id, pdf, job.name);
  } else {
    book = await _ingest(bytes, filename: job.name, mime: job.mime, id: id, token: job.token);
  }

  final dir = Directory('${job.booksDir}/$id')..createSync(recursive: true);
  final dest = File('${dir.path}/source${_ext(job.name)}');
  dest.writeAsBytesSync(bytes, flush: true);
  _writeParsed(dir.path, book);
  _writeImages(dir.path, bytes, book);

  final entry = LibraryEntry(
    id: id,
    title: book.metadata.title,
    authors: book.metadata.authors,
    source: book.source,
    wordCount: book.wordCount,
    sourcePath: dest.path,
    addedAt: DateTime.now(),
    language: book.metadata.language,
    cover: coverFileOf(dir.path, book),
    pdfParser: pdf != null ? pdfParserVersion : 0,
    ocr: ocr?['ocr'] as String?,
  );
  return (entry: entry, note: pdf != null && ocr == null ? _scanNote(pdf) : null);
}

/// What OCR read of a book's pages, as it is kept in the book's folder
/// [dir] (ocr.json, in the platform's PDF form: see ocrPdfText); null for a
/// book not read by OCR.
Map<String, Object?>? readOcrText(String dir) {
  final f = File('$dir/ocr.json');
  try {
    if (!f.existsSync()) return null;
    final raw = jsonDecode(f.readAsStringSync());
    return raw is Map ? Map<String, Object?>.from(raw) : null;
  } on Object {
    return null;
  }
}

typedef _OcrImportJob = ({String booksDir, String jobDir});

Future<LibraryEntry> _runOcrImport(_OcrImportJob job) => Isolate.run(() => _ocrImport(job));

/// The book made from an OCR job's folder (see [LibraryStore.addOcrBook]):
/// job.json says what was read and in which languages, pdf.json is the
/// platform's text of the PDF, pages/<n>.txt what OCR read of page n.
LibraryEntry _ocrImport(_OcrImportJob job) {
  final info = Map<String, Object?>.from(jsonDecode(File('${job.jobDir}/job.json').readAsStringSync()) as Map);
  final pdf = Map<String, Object?>.from(jsonDecode(File('${job.jobDir}/pdf.json').readAsStringSync()) as Map);
  final name = info['name'] as String? ?? 'scan.pdf';
  final languages = info['languages'] as String? ?? '';
  final source = File(info['source'] as String? ?? '');
  if (!source.existsSync()) throw ParseException('“$name” is no longer on the phone.');
  final read = <int, String>{};
  for (final p in info['pages'] as List? ?? const []) {
    final page = File('${job.jobDir}/pages/$p.txt');
    if (p is int && page.existsSync()) read[p] = page.readAsStringSync();
  }
  final text = ocrPdfText(pdf, read, languages: languages);
  final id = info['id'] as String? ?? bookIdOf(source.readAsBytesSync());
  final Book book;
  try {
    book = _pdfBook(id, text, name);
  } on Exception catch (e) {
    // Refused as a scan again: what OCR read was too little to be a book.
    if (e is! UnsupportedDocumentException && e is! ParseException) rethrow;
    final said = ocrLanguagesOf(languages).map((l) => l.name).join(' and ');
    throw ParseException('OCR found nothing to read in “$name”${said.isEmpty ? '' : ' in $said'}. '
        'If its pages are in another language, import it again and pick that one.');
  }

  final dir = Directory('${job.booksDir}/$id')..createSync(recursive: true);
  final dest = File('${dir.path}/source.pdf');
  if (source.absolute.path != dest.absolute.path) {
    try {
      source.renameSync(dest.path);
    } on FileSystemException {
      source.copySync(dest.path);
    }
  }
  // The book as it was, when a few of its pages had text: the place the
  // reader had reached there is found again in the whole book.
  Book? before;
  try {
    final raw = jsonDecode(File('${dir.path}/parsed.json').readAsStringSync());
    if (raw is Map && raw['book'] is Map) before = Book.fromJson(Map<String, Object?>.from(raw['book'] as Map));
  } on Object {
    // A new book.
  }
  _writeWholeSync(File('${dir.path}/ocr.json'), jsonEncode(text));
  _writeParsed(dir.path, book);
  if (before != null) _carryCursor(dir.path, before, ReadingLayout.build(book, displayOnly: true));
  return LibraryEntry(
    id: id,
    title: book.metadata.title,
    authors: book.metadata.authors,
    source: book.source,
    wordCount: book.wordCount,
    sourcePath: dest.path,
    addedAt: DateTime.now(),
    language: book.metadata.language,
    cover: coverFileOf(dir.path, book),
    pdfParser: pdfParserVersion,
    ocr: languages,
  );
}

void _writeParsed(String dir, Book book) {
  _writeWholeSync(File('$dir/parsed.json'), jsonEncode({'v': _parsedVersion, 'book': book.toJson()}));
}

/// Write [text] beside [file] and rename it over: a crash leaves the old
/// file or the new one, never half of one. (For background isolates, where
/// writeSafely's queue does not reach.)
void _writeWholeSync(File file, String text) {
  final tmp = File('${file.path}.${Isolate.current.hashCode}.tmp');
  tmp.writeAsStringSync(text, flush: true);
  tmp.renameSync(file.path);
}

/// Store the pictures an EPUB uses under `<book>/img/`, so the reader shows
/// them without opening the archive again.
void _writeImages(String dir, Uint8List source, Book book) {
  if (book.source != SourceKind.epub) return;
  final wanted = imagesOf(book);
  if (wanted.isEmpty) return;
  final out = Directory('$dir/img')..createSync(recursive: true);
  for (final e in epubResources(source, wanted).entries) {
    File('${out.path}/${imageFileName(e.key)}').writeAsBytesSync(e.value);
  }
}

/// Where a picture from the source file is stored, by its path in the source.
String imageFileName(String path) =>
    path.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

String? coverFileOf(String dir, Book book) {
  final cover = book.metadata.cover;
  return cover == null ? null : '$dir/img/${imageFileName(cover)}';
}

/// A web novel as one book: every chapter in order, the fetched ones with
/// their text, the rest empty (and so skipped by the reader).
ReadingLayout _loadWebSync(String dir, String id) {
  final info = WebNovelInfo.fromJson(
    Map<String, Object?>.from(jsonDecode(File('$dir/novel.json').readAsStringSync()) as Map),
  );
  final sections = <Section>[];
  // Lines the reader chose not to hear, from rules.json at the library root.
  final skip = ReadingRules.skipTextsSync(Directory(dir).parent.parent.path, info.plugin.id);
  for (var i = 0; i < info.chapters.length; i++) {
    final title = info.chapters[i].name;
    final f = File('$dir/ch/$i.json');
    Section? s;
    if (f.existsSync()) {
      try {
        s = cleanWebChapter(
          Section.fromJson(Map<String, Object?>.from(jsonDecode(f.readAsStringSync()) as Map)),
          skip: skip,
        );
      } on Object {
        s = null;
      }
      // Moved here from another place (the list shifted): its place now.
      if (s != null && s.index != i) s = Section(id: 'ch$i', index: i, title: s.title, blocks: s.blocks);
    }
    sections.add(s ?? pendingWebChapter(index: i, title: title));
  }
  final cover = File('$dir/img').existsSync()
      ? Directory('$dir/img').listSync().whereType<File>().where((f) => f.path.contains('cover')).firstOrNull?.path
      : null;
  // Notes shown on the page, not read aloud (see ReadingLayout.build).
  return ReadingLayout.build(displayOnly: true, webNovelBook(
    id: id,
    title: info.novel.name,
    authors: [if (info.novel.author != null) info.novel.author!],
    language: languageCodeOf(info.plugin.lang),
    cover: cover,
    description: info.novel.summary,
    sections: sections,
  ));
}

Future<ReadingLayout> _loadLayout(_LoadJob job) async {
  final dir = '${job.booksDir}/${job.id}';
  final parsed = File('$dir/parsed.json');
  Book? book;
  // The book as it was stored, when it is about to be re-parsed: the saved
  // place has to be carried across (see _carryCursor).
  Book? before;
  Object? raw;
  if (parsed.existsSync()) {
    try {
      raw = jsonDecode(parsed.readAsStringSync());
    } on FormatException {
      // Cut short (an older build wrote it in place): parsed again below
      // from the book's own file.
    }
  }
  if (raw != null) {
    if (raw is Map && raw['v'] == _parsedVersion && raw['book'] is Map) {
      book = Book.fromJson(Map<String, Object?>.from(raw['book'] as Map));
    } else if (raw is Map) {
      // Written by an older build. Parse the source again so the book gets
      // today's sentence splitting, language detection and pictures; PDFs
      // need the platform for that, so they keep what they have.
      final inner = raw['book'];
      final legacy = Book.fromJson(
        Map<String, Object?>.from(inner is Map ? inner : raw),
      );
      before = legacy;
      final source = job.sourcePath == null ? null : File(job.sourcePath!);
      if (legacy.source != SourceKind.pdf && source != null && source.existsSync()) {
        try {
          final bytes = source.readAsBytesSync();
          book = await _ingest(
            bytes,
            filename: legacy.sourceName ?? source.path,
            id: job.id,
            token: job.token,
          );
          _writeParsed(dir, book);
          _writeImages(dir, bytes, book);
        } on Object {
          book = withResolvedLanguage(legacy);
        }
      } else {
        book = withResolvedLanguage(legacy);
      }
    }
  }
  // A PDF read again by today's PDF reader (nested bookmarks, running
  // heads, footnotes and columns): the place is carried across.
  final pdf = job.pdf;
  if (pdf != null) {
    try {
      final again = _pdfBook(job.id, pdf, book?.sourceName ?? job.sourcePath);
      before ??= book;
      book = again;
      _writeParsed(dir, again);
    } on Object {
      // Kept as it was stored.
    }
  }
  if (book == null) {
    final source = job.sourcePath == null ? null : File(job.sourcePath!);
    if (source == null || !source.existsSync()) {
      throw const ParseException('This book\'s files are missing. Import it again.');
    }
    final bytes = source.readAsBytesSync();
    book = await _ingest(bytes, filename: source.path, id: job.id, token: job.token);
    _writeParsed(dir, book);
    _writeImages(dir, bytes, book);
  }
  // PDFs stored one section per page get real chapters from their own text.
  final resectioned = resectionPdf(book);
  if (!identical(resectioned, book)) {
    before ??= book;
    book = resectioned;
    _writeParsed(dir, book);
  }
  // Footnotes and captions shown on the page, not read aloud.
  final layout = ReadingLayout.build(book, displayOnly: true);
  if (before != null && !identical(before, book)) _carryCursor(dir, before, layout);
  return layout;
}

/// A saved place is section/paragraph/sentence numbers. Re-parsing a book
/// can regroup those (a PDF going from pages to chapters), and the old
/// numbers then point somewhere else entirely: a book reopened at its last
/// chapter. Find the sentence the reader was on by its text and save that.
void _carryCursor(String dir, Book before, ReadingLayout after) {
  final file = File('$dir/cursor.json');
  if (!file.existsSync() || after.units.isEmpty) return;
  try {
    final raw = jsonDecode(file.readAsStringSync()) as Map;
    final cursor = ReadingCursor.fromJson(Map<String, Object?>.from(raw['cursor'] as Map? ?? const {}));
    final old = flattenSpeakable(before);
    if (old.isEmpty) return;
    // Found again by its words, a sentence split or joined in the new parse
    // as well (see relocateCursor).
    final target = relocateCursor(old, cursor, after).clamp(0, after.units.length - 1);
    file.writeAsStringSync(jsonEncode({
      'cursor': cursorOf(after.units[target]).toJson(),
      'progress': raw['progress'],
    }));
  } on Object {
    // Losing the place is better than failing to open the book.
  }
}

// -------------------------------------------------------------------- entry

class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.title,
    required this.authors,
    required this.source,
    required this.wordCount,
    required this.sourcePath,
    required this.addedAt,
    this.openedAt,
    this.cursor = ReadingCursor.zero,
    this.progress = 0,
    this.where,
    this.language,
    this.cover,
    this.coverMode = CoverMode.auto,
    this.customCover,
    this.category,
    this.plugin,
    this.novelPath,
    this.chapterCount = 0,
    this.pdfParser = 0,
    this.ocr,
  });

  final String id;
  final String title;
  final List<String> authors;
  final SourceKind source;
  final int wordCount;
  final String sourcePath;
  final DateTime addedAt;
  final DateTime? openedAt;
  final ReadingCursor cursor;
  final double progress;

  /// Where the reader left off, in words: "Chapter 12: The Fool".
  final String? where;
  final String? language;

  /// The book's own cover picture on disk, when it has one.
  final String? cover;

  /// Which cover the shelf shows; see [shownCover].
  final CoverMode coverMode;

  /// A picture the user chose, on disk.
  final String? customCover;

  /// The category id it sits in; null means the shelf's default.
  final String? category;

  /// For a web novel: the source plugin it comes from and its path there.
  final String? plugin;
  final String? novelPath;

  /// For a web novel: how many chapters the source lists.
  final int chapterCount;

  /// For a PDF: the PDF reader it was last read with (pdfParserVersion); 0
  /// from before that was kept. An older one is read again from the file.
  final int pdfParser;

  /// For a scan read by OCR: the languages it was read in ("ben+eng"). Its
  /// page says the text may have mistakes; its text is kept with it.
  final String? ocr;

  bool get isWeb => source == SourceKind.web;

  /// The picture to show, or null for a cover drawn from the title.
  String? get shownCover => switch (coverMode) {
        CoverMode.plain => null,
        CoverMode.custom => customCover ?? cover,
        CoverMode.auto => cover,
      };

  LibraryEntry withCover(CoverMode mode, String? custom) =>
      copyWith(coverMode: mode, customCover: custom, clearCustomCover: custom == null);

  DateTime get lastTouched => openedAt ?? addedAt;

  String get authorLine => authors.join(', ');

  bool get finished => progress >= 0.995;

  /// "EPUB", "PDF", "DOCX"…
  String get formatLabel => switch (source) {
        SourceKind.text => 'TXT',
        SourceKind.markdown => 'MD',
        SourceKind.unknown => 'TEXT',
        SourceKind.web => 'WEB',
        _ => source.name.toUpperCase(),
      };

  /// The category this book shows under, given the shelf's [categories].
  String categoryIn(List<Category> categories, String fallback) =>
      category != null && categories.any((c) => c.id == category) ? category! : fallback;

  LibraryEntry copyWith({
    ReadingCursor? cursor,
    double? progress,
    DateTime? openedAt,
    bool clearOpened = false,
    String? where,
    String? cover,
    CoverMode? coverMode,
    String? customCover,
    bool clearCustomCover = false,
    String? category,
    int? chapterCount,
    String? language,
    int? pdfParser,
  }) =>
      LibraryEntry(
        id: id,
        title: title,
        authors: authors,
        source: source,
        wordCount: wordCount,
        sourcePath: sourcePath,
        addedAt: addedAt,
        openedAt: clearOpened ? null : (openedAt ?? this.openedAt),
        cursor: cursor ?? this.cursor,
        progress: progress ?? this.progress,
        where: where ?? this.where,
        language: language ?? this.language,
        cover: cover ?? this.cover,
        coverMode: coverMode ?? this.coverMode,
        customCover: clearCustomCover ? null : (customCover ?? this.customCover),
        category: category ?? this.category,
        plugin: plugin,
        novelPath: novelPath,
        chapterCount: chapterCount ?? this.chapterCount,
        pdfParser: pdfParser ?? this.pdfParser,
        ocr: ocr,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'authors': authors,
        'source': source.name,
        'wordCount': wordCount,
        'sourcePath': sourcePath,
        'addedAt': addedAt.toIso8601String(),
        if (openedAt != null) 'openedAt': openedAt!.toIso8601String(),
        'cursor': cursor.toJson(),
        'progress': progress,
        if (where != null) 'where': where,
        if (language != null) 'language': language,
        if (cover != null) 'cover': cover,
        if (coverMode != CoverMode.auto) 'coverMode': coverMode.name,
        if (customCover != null) 'customCover': customCover,
        if (category != null) 'category': category,
        if (plugin != null) 'plugin': plugin,
        if (novelPath != null) 'novelPath': novelPath,
        if (chapterCount > 0) 'chapterCount': chapterCount,
        if (pdfParser > 0) 'pdfParser': pdfParser,
        if (ocr != null) 'ocr': ocr,
      };

  static LibraryEntry fromJson(Map<String, Object?> json) => LibraryEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Untitled',
        authors: [
          for (final a in (json['authors'] as List? ?? const [])) a.toString(),
        ],
        source: SourceKind.values.firstWhere(
          (k) => k.name == json['source'],
          orElse: () => SourceKind.unknown,
        ),
        wordCount: json['wordCount'] as int? ?? 0,
        sourcePath: json['sourcePath'] as String? ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        openedAt: DateTime.tryParse(json['openedAt'] as String? ?? ''),
        cursor: ReadingCursor.fromJson(
          Map<String, Object?>.from(json['cursor'] as Map? ?? const {}),
        ),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        where: json['where'] as String?,
        language: json['language'] as String?,
        cover: json['cover'] as String?,
        coverMode: CoverMode.values.firstWhere(
          (m) => m.name == json['coverMode'],
          orElse: () => CoverMode.auto,
        ),
        customCover: json['customCover'] as String?,
        category: json['category'] as String?,
        plugin: json['plugin'] as String?,
        novelPath: json['novelPath'] as String?,
        chapterCount: json['chapterCount'] as int? ?? 0,
        pdfParser: json['pdfParser'] as int? ?? 0,
        ocr: json['ocr'] as String?,
      );
}

/// A shelf in the library: "Reading", "Later", or one the user made.
class Category {
  const Category(this.id, this.name, {this.secret = false});

  final String id;
  final String name;

  /// Shown, with its books, only once opened with the phone's own lock.
  final bool secret;

  /// The two the library starts with. Both can be renamed or deleted.
  static const defaults = [Category('reading', 'Reading'), Category('later', 'Later')];

  static String newId(String name) {
    final slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '${slug.isEmpty ? 'shelf' : slug}-$stamp';
  }

  Category renamed(String to) => Category(id, to, secret: secret);

  Category withSecret(bool to) => Category(id, name, secret: to);

  Map<String, Object?> toJson() => {'id': id, 'name': name, if (secret) 'secret': true};

  static Category fromJson(Map<String, Object?> json) => Category(
        json['id'] as String? ?? newId('shelf'),
        json['name'] as String? ?? 'Shelf',
        secret: json['secret'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is Category && other.id == id && other.name == name && other.secret == secret;

  @override
  int get hashCode => Object.hash(id, name, secret);
}

/// What the library index holds.
class LibraryIndex {
  const LibraryIndex({
    required this.entries,
    required this.categories,
    required this.defaultCategory,
  });

  final List<LibraryEntry> entries;
  final List<Category> categories;
  final String defaultCategory;

  /// The index with the secret shelves and their books left out.
  LibraryIndex withoutSecret() {
    if (!categories.any((c) => c.secret)) return this;
    final shown = [for (final c in categories) if (!c.secret) c];
    return LibraryIndex(
      entries: [
        for (final e in entries)
          if (shown.any((c) => c.id == e.categoryIn(categories, defaultCategory))) e,
      ],
      categories: shown,
      defaultCategory: defaultCategory,
    );
  }

  /// Books in [categoryId].
  List<LibraryEntry> inCategory(String categoryId) => [
        for (final e in entries)
          if (e.categoryIn(categories, defaultCategory) == categoryId) e,
      ];
}

enum CoverMode { auto, custom, plain }

String _ext(String path) {
  final slash = path.replaceAll(r'\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  if (dot <= 0) return '';
  return slash.substring(dot).toLowerCase();
}

/// A small built-in book, used as a fixture by the widget tests.
Book specimenBook() => ingestString(
      'The quick brown fox jumps over the lazy dog. '
      'Pack my box with five dozen liquor jugs.\n\n'
      'TomeVoice reads a document you already own, on the device, with '
      'control over the voice that a normal reader does not give you. '
      'Word gap, comma pauses, sentence pauses, and speed all land on '
      'the audio you hear.\n\n'
      'Open the library and import an EPUB, a PDF, a Word file or plain '
      'text. Playback walks sentence by sentence so a chapter is not one '
      'giant utterance. Press and hold any sentence, then Read from here.',
      filename: 'specimen.txt',
      title: 'Specimen',
    );

/// What TomeVoice keeps about a web novel: where it comes from, its details,
/// and the chapter list as the source last gave it.
class WebNovelInfo {
  const WebNovelInfo({
    required this.plugin,
    required this.novel,
    required this.chapters,
    this.checkedAt,
    this.filed = false,
  });

  final PluginInfo plugin;

  /// Details only (name, cover, author, summary, status, genres); the
  /// chapters are in [chapters].
  final SourceNovel novel;
  final List<ChapterItem> chapters;

  /// When the chapter list was last fetched.
  final DateTime? checkedAt;

  /// Every download is known to be filed under its own chapter (see
  /// LibraryStore.settleWebChapters).
  final bool filed;

  WebNovelInfo copyWith({List<ChapterItem>? chapters, DateTime? checkedAt, bool? filed}) => WebNovelInfo(
        plugin: plugin,
        novel: novel,
        chapters: chapters ?? this.chapters,
        checkedAt: checkedAt ?? this.checkedAt,
        filed: filed ?? this.filed,
      );

  Map<String, Object?> toJson() => {
        'plugin': plugin.toJson(),
        'novel': {
          'path': novel.path,
          'name': novel.name,
          if (novel.cover != null) 'cover': novel.cover,
          if (novel.author != null) 'author': novel.author,
          if (novel.summary != null) 'summary': novel.summary,
          if (novel.status != null) 'status': novel.status,
          'genres': novel.genres.join(', '),
        },
        'chapters': [for (final c in chapters) c.toJson()],
        if (checkedAt != null) 'checkedAt': checkedAt!.toIso8601String(),
        if (filed) 'filed': true,
      };

  static WebNovelInfo fromJson(Map<String, Object?> j) {
    final n = Map<String, Object?>.from(j['novel'] as Map? ?? const {});
    return WebNovelInfo(
      plugin: PluginInfo.fromJson(Map<String, Object?>.from(j['plugin'] as Map? ?? const {})) ??
          const PluginInfo(id: '', name: '', site: '', lang: 'English', version: '0', url: ''),
      novel: SourceNovel.fromJs(n, path: n['path'] as String? ?? ''),
      chapters: [
        for (final c in (j['chapters'] as List? ?? const []))
          ChapterItem.fromJson(Map<String, Object?>.from(c as Map)),
      ],
      checkedAt: DateTime.tryParse(j['checkedAt'] as String? ?? ''),
      filed: j['filed'] == true,
    );
  }
}

/// A source's language name ("English", "Русский") as a language code, or
/// null for one not known ("Multi", a site's own spelling): the chapters'
/// script then decides, rather than a guess of English.
String? languageCodeOf(String name) {
  final n = name.replaceAll(String.fromCharCode(0x200E), '').trim().toLowerCase();
  const names = {
    'english': 'en', 'русский': 'ru', 'russian': 'ru', 'español': 'es', 'spanish': 'es',
    'français': 'fr', 'french': 'fr', 'português': 'pt', 'portuguese': 'pt', 'türkçe': 'tr',
    'turkish': 'tr', 'indonesia': 'id', 'indonesian': 'id', 'bahasa indonesia': 'id',
    '中文': 'zh', 'chinese': 'zh', '日本語': 'ja', 'japanese': 'ja', '한국어': 'ko', 'korean': 'ko',
    'tiếng việt': 'vi', 'vietnamese': 'vi', 'ไทย': 'th', 'thai': 'th', 'українська': 'uk',
    'ukrainian': 'uk', 'polski': 'pl', 'polish': 'pl', 'العربية': 'ar', 'arabic': 'ar',
    'deutsch': 'de', 'german': 'de', 'italiano': 'it', 'italian': 'it',
    'বাংলা': 'bn', 'bangla': 'bn', 'bengali': 'bn', 'हिन्दी': 'hi', 'हिंदी': 'hi', 'hindi': 'hi',
  };
  return names[n];
}

String _imageExt(String? contentType, String url) {
  final t = (contentType ?? '').toLowerCase();
  if (t.contains('png')) return '.png';
  if (t.contains('webp')) return '.webp';
  if (t.contains('gif')) return '.gif';
  final u = url.toLowerCase().split('?').first;
  for (final e in const ['.png', '.webp', '.gif', '.jpeg']) {
    if (u.endsWith(e)) return e;
  }
  return '.jpg';
}
