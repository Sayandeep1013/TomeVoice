import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:tomevoice_document/tomevoice_document.dart';

import 'marks.dart';
import 'safe_file.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'reading_rules.dart';
import 'speech_service.dart';

/// Bumped when ingestion improves enough that stored books should be parsed
/// again from their source file (v2: multilingual sentences, compact JSON;
/// v3: pictures and covers from EPUBs, page numbers in PDFs; v4: toc nav
/// only, chapters named from first lines, drop caps, Gutenberg apparatus;
/// v5: the book's description, shown on its page).
const _parsedVersion = 5;

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
          entries = [
            for (final b in raw['books'] as List? ?? const [])
              LibraryEntry.fromJson(Map<String, Object?>.from(b as Map)),
          ];
          final cats = [
            for (final c in raw['categories'] as List? ?? const [])
              if (c is Map) Category.fromJson(Map<String, Object?>.from(c)),
          ];
          _categories = cats.isEmpty ? Category.defaults : cats;
          final d = raw['defaultCategory'] as String?;
          _defaultCategory = _categories.any((c) => c.id == d) ? d! : _categories.first.id;
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
      await _discardOffered(id);
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

  /// Replace a web novel's chapter list with [chapters], whatever it is (the
  /// reader chose it). Downloads follow their chapters and are never deleted
  /// (see [_replaceChapters]); a list just fetched goes through
  /// [offerWebChapters] instead, which refuses one that looks wrong.
  Future<void> saveWebChapters(String id, List<ChapterItem> chapters) async {
    final info = await settleWebChapters(id);
    if (info == null) return;
    await _replaceChapters(id, info, info.copyWith(chapters: chapters, checkedAt: DateTime.now(), clearRefusal: true));
    await _discardOffered(id);
    await _change((entries) => [for (final e in entries) e.id == id ? e.copyWith(chapterCount: chapters.length) : e]);
  }

  /// A chapter list just fetched for web novel [id]: stored in place of the
  /// one on the phone when that is safe (see [judgeChapterList]). Otherwise
  /// the stored list and its downloads stay as they are and the reason is
  /// kept with the novel, for its page and Updates to say; a list whose
  /// chapters all moved to new addresses is also kept aside, for the reader
  /// to take with [useOfferedChapters]. [complete]: false for a paged list
  /// that was not read to its end. [force]: the reader chose this list.
  Future<ListVerdict> offerWebChapters(
    String id,
    List<ChapterItem> fresh, {
    bool complete = true,
    bool force = false,
  }) async {
    final info = await settleWebChapters(id);
    if (info == null) return const ListVerdict(ListChange.refused, why: 'This novel is not in the library.');
    var verdict = judgeChapterList(info.chapters, fresh, complete: complete);
    if (force && fresh.isNotEmpty && verdict.refused) verdict = const ListVerdict(ListChange.taken);
    final now = DateTime.now();
    final file = File('${bookDir(id)}/novel.json');
    switch (verdict.change) {
      case ListChange.same:
        // Checked (so the novel's page need not ask again for a while), and
        // nothing came of it; a refusal recorded earlier no longer holds.
        await writeSafely(file, jsonEncode(info.copyWith(checkedAt: now, clearRefusal: true).toJson()));
        if (info.refusal != null) await _discardOffered(id);
      case ListChange.taken:
        await _replaceChapters(id, info, info.copyWith(chapters: fresh, checkedAt: now, clearRefusal: true));
        await _discardOffered(id);
        if (fresh.length != info.chapters.length) {
          await _change((entries) => [for (final e in entries) e.id == id ? e.copyWith(chapterCount: fresh.length) : e]);
        }
      case ListChange.refused:
        final refusal = ListRefusal(why: verdict.why ?? '', at: now, count: fresh.length, offered: verdict.offered);
        await writeSafely(file, jsonEncode(info.copyWith(refusal: refusal).toJson()));
        if (verdict.offered) {
          await writeSafely(_offeredFile(id), jsonEncode([for (final c in fresh) c.toJson()]));
        } else {
          await _discardOffered(id);
        }
    }
    return verdict;
  }

  /// Take the list [offerWebChapters] kept aside for web novel [id] (the
  /// reader chose it). Downloads find their chapters by title.
  Future<ListVerdict> useOfferedChapters(String id) async {
    final f = _offeredFile(id);
    List<ChapterItem> list;
    try {
      list = [
        for (final c in jsonDecode(await f.readAsString()) as List) ChapterItem.fromJson(Map<String, Object?>.from(c as Map)),
      ];
    } on Object {
      return const ListVerdict(ListChange.refused, why: 'Check the site again first.');
    }
    return offerWebChapters(id, list, force: true);
  }

  File _offeredFile(String id) => File('${bookDir(id)}/offered.json');

  Future<void> _discardOffered(String id) async {
    try {
      await _offeredFile(id).delete();
    } on FileSystemException {
      // None kept.
    }
  }

  /// The chapter counts a check made away from the app found (see
  /// Updates), on the shelf's cards.
  Future<void> noteChapterCounts(Map<String, int> counts) async {
    if (counts.isEmpty) return;
    await _change((entries) => [
          for (final e in entries)
            if (counts[e.id] case final n? when n != e.chapterCount) e.copyWith(chapterCount: n) else e,
        ]);
  }

  /// Write [next] over [before]. Downloads, the saved place and saved quotes
  /// are filed by a chapter's place in the list, so when the site put an
  /// entry in or took one out earlier on, they move with their chapter:
  /// found by its address, else by its title. Nothing is deleted: a
  /// download whose chapter is no longer listed is set aside (ch/orphaned)
  /// and comes back if its chapter does. The list is marked unsettled until
  /// they have moved, so a stop half way is put right the next time the
  /// novel opens.
  Future<void> _replaceChapters(String id, WebNovelInfo before, WebNovelInfo next) async {
    final file = File('${bookDir(id)}/novel.json');
    final moves = _refileMoves(before.chapters, next.chapters);
    final orphans = Directory('${bookDir(id)}/ch/orphaned').existsSync();
    await writeSafely(file, jsonEncode(next.copyWith(filed: moves.isEmpty).toJson()));
    if (moves.isEmpty && !orphans) return;
    await _refile(id, moves, [for (final c in next.chapters) c.name]);
    await writeSafely(file, jsonEncode(next.copyWith(filed: true).toJson()));
  }

  /// Append [fresh] to web novel [id]'s stored list without touching the
  /// library index, its downloads, place or quotes: for a check made away
  /// from the app (another engine may hold the index). Only when [fresh]
  /// keeps every stored chapter where it was; false otherwise (left for the
  /// app to take when it next checks).
  Future<bool> appendWebChapters(String id, WebNovelInfo info, List<ChapterItem> fresh) async {
    if (!info.filed || _refileMoves(info.chapters, fresh).isNotEmpty) return false;
    await writeSafely(
      File('${bookDir(id)}/novel.json'),
      jsonEncode(info.copyWith(chapters: fresh, checkedAt: DateTime.now(), clearRefusal: true).toJson()),
    );
    return true;
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
  /// listed: set aside), and the saved place and saved quotes with them;
  /// then put back any set aside earlier whose chapter is in [names] again.
  Future<void> _refile(String id, Map<int, int> moves, List<String> names) async {
    await _runRefile(bookDir(id), moves, names);
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
  Future<LibraryEntry> importFile(
    PickedFile file, {
    void Function(int done, int total)? onProgress,
  }) async {
    await ensure();
    final source = File(file.path);
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
    );
    final entry = await _runImport(job);

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

    // The picker's copy is now a duplicate of books/<id>/source.*.
    if (source.path.contains('/incoming/')) {
      try {
        await source.delete();
      } on FileSystemException {
        // Harmless; it is in our own folder.
      }
    }
    return merged;
  }

  /// The reading layout for [id], built on a background isolate.
  ///
  /// For a web novel, every chapter has its section (so positions are
  /// chapter numbers), and the downloaded ones have their text; with
  /// [around], only those in a window round that chapter do (see
  /// [webWindow]): opening chapter 2,000 of a long novel reads a few dozen
  /// files, not every one on the phone.
  Future<ReadingLayout> loadLayout(String id, {int? around}) async {
    final entries = await list();
    final entry = entries.where((e) => e.id == id).firstOrNull;
    if (entry != null && entry.isWeb) {
      final dir = bookDir(id);
      final layout = await _runLoadWeb(dir, id, around);
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
    final job = (
      booksDir: _booksDir.path,
      id: id,
      sourcePath: entry?.sourcePath,
    );
    final layout = await _runLoad(job);
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
Future<LibraryEntry> _runImport(_ImportJob job) => Isolate.run(() => _importSync(job));

Future<ReadingLayout> _runLoad(_LoadJob job) => Isolate.run(() => _loadLayoutSync(job));

Future<ReadingLayout> _runLoadWeb(String dir, String id, int? around) =>
    Isolate.run(() => _loadWebSync(dir, id, around: around));

Future<void> _runSaveChapter(String path, int index, String title, String html, String? language) =>
    Isolate.run(() {
      final section = webChapterSection(index: index, title: title, html: html, language: language);
      File(path).parent.createSync(recursive: true);
      _writeWholeSync(File(path), jsonEncode(section.toJson()));
    });

Future<void> _runRefile(String dir, Map<int, int> moves, List<String> names) => Isolate.run(() {
      _moveChaptersSync(dir, moves);
      _adoptOrphansSync(dir, names);
    });

Future<Map<int, int>> _runSettle(String dir, List<String> names) => Isolate.run(() => _settleSync(dir, names));

/// Where each chapter of [before] is in [after], for those that moved (-1:
/// found nowhere). A chapter is found by its address; failing that (a site
/// that moved to another domain, a plugin that writes its addresses another
/// way), by its title: the same one, nearest where its neighbours went, or
/// a like one close by (a typo the site fixed). No place is given twice.
Map<int, int> _refileMoves(List<ChapterItem> before, List<ChapterItem> after) {
  final placeOf = <int, int>{};
  final taken = <int>{};
  int? nearest(List<int>? places, int to) {
    int? best;
    for (final j in places ?? const <int>[]) {
      if (taken.contains(j)) continue;
      if (best == null || (j - to).abs() < (best - to).abs()) best = j;
    }
    return best;
  }

  void place(int i, int j) {
    placeOf[i] = j;
    taken.add(j);
  }

  final byPath = <String, List<int>>{};
  final byName = <String, List<int>>{};
  for (var j = 0; j < after.length; j++) {
    (byPath[after[j].path] ??= []).add(j);
    (byName[after[j].name] ??= []).add(j);
  }
  for (var i = 0; i < before.length; i++) {
    if (nearest(byPath[before[i].path], i) case final j?) place(i, j);
  }
  if (placeOf.length == before.length) return _changed(placeOf, before.length);
  // Where chapter i would be now, going by the nearest one before it that
  // was found: a list that gained a prologue moves everything on by one.
  int expected(int i) {
    for (var k = i - 1; k >= 0; k--) {
      if (placeOf[k] case final j?) return j + (i - k);
    }
    return i;
  }

  for (var i = 0; i < before.length; i++) {
    if (placeOf.containsKey(i)) continue;
    if (nearest(byName[before[i].name], expected(i)) case final j?) place(i, j);
  }
  final names = [for (final c in after) c.name];
  for (var i = 0; i < before.length; i++) {
    if (placeOf.containsKey(i)) continue;
    if (_likeTitle(before[i].name, names, expected(i), skip: taken) case final j?) place(i, j);
  }
  return _changed(placeOf, before.length);
}

/// [placeOf] as moves: each chapter of [count] whose place changed, to its
/// new one (-1, found nowhere).
Map<int, int> _changed(Map<int, int> placeOf, int count) => {
      for (var i = 0; i < count; i++)
        if (placeOf[i] != i) i: placeOf[i] ?? -1,
    };

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
/// match keeps it, and the other is set aside (ch/orphaned), never deleted;
/// a download that matches nothing stays where it is. Returns the moves
/// made, old place to new (-1: set aside).
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
      _setAsideSync(f, ch.path, n);
    } else {
      parked[n] = f.path.endsWith('.moving') ? f : f.renameSync('${ch.path}/$n.json.moving');
    }
  }
  for (final MapEntry(key: n, value: f) in parked.entries) {
    f.renameSync('${ch.path}/${moves[n]}.json');
  }
  moves.removeWhere((n, to) => n == to);
  _adoptOrphansSync(dir, names);
  return moves;
}

/// Keep [f], a download of old chapter [n] that has no place in the list
/// now, under ch/orphaned: out of the reader's way, never deleted, and put
/// back if its chapter is listed again (see [_adoptOrphansSync]).
void _setAsideSync(File f, String ch, int n) {
  final dir = Directory('$ch/orphaned')..createSync(recursive: true);
  var name = '$n.json';
  for (var k = 1; File('${dir.path}/$name').existsSync(); k++) {
    name = '$n-$k.json';
  }
  f.renameSync('${dir.path}/$name');
}

/// Downloads set aside earlier (ch/orphaned) whose chapter is listed in
/// [names] again, by the very title they were saved with, and has no
/// download of its own: put back there (the place nearest where they were,
/// should the title be listed twice).
void _adoptOrphansSync(String dir, List<String> names) {
  final orphans = Directory('$dir/ch/orphaned');
  if (!orphans.existsSync()) return;
  final placesOf = <String, List<int>>{};
  for (var j = 0; j < names.length; j++) {
    (placesOf[names[j]] ??= []).add(j);
  }
  for (final f in orphans.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json')) continue;
    final title = _savedTitle(f);
    final places = title == null ? null : placesOf[title];
    if (places == null) continue;
    final was = int.tryParse(name.split(RegExp(r'[-.]')).first) ?? 0;
    final free = [for (final j in places) if (!File('$dir/ch/$j.json').existsSync()) j];
    if (free.isEmpty) continue;
    final to = free.reduce((a, b) => (a - was).abs() <= (b - was).abs() ? a : b);
    f.renameSync('$dir/ch/$to.json');
  }
  if (orphans.listSync().isEmpty) orphans.deleteSync();
}

/// The place near [n] whose title in [names] is most like [title]: most of
/// their words (and numbers) the same, "Chapter" aside. Places in [skip]
/// are not offered.
int? _likeTitle(String title, List<String> names, int n, {Set<int> skip = const {}}) {
  Set<String> words(String t) =>
      t.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty && w != 'chapter').toSet();
  final mine = words(title);
  if (mine.isEmpty) return null;
  int? best;
  var bestScore = 0.5;
  for (var j = math.max(0, n - 8); j < math.min(names.length, n + 9); j++) {
    if (skip.contains(j)) continue;
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
/// place, so a chain of moves never lands on a file still to go. One with
/// no place now (-1), or whose place already holds a download, is set
/// aside (ch/orphaned), never deleted.
void _moveChaptersSync(String dir, Map<int, int> moves) {
  final ch = '$dir/ch';
  if (moves.isEmpty || !Directory(ch).existsSync()) return;
  for (final from in moves.keys) {
    final f = File('$ch/$from.json');
    if (f.existsSync()) f.renameSync('$ch/$from.json.moving');
  }
  for (final MapEntry(key: from, value: to) in moves.entries) {
    final f = File('$ch/$from.json.moving');
    if (!f.existsSync()) continue;
    if (to < 0 || File('$ch/$to.json').existsSync()) {
      _setAsideSync(f, ch, from);
    } else {
      f.renameSync('$ch/$to.json');
    }
  }
}

/// What a chapter list just fetched does to the one stored.
enum ListChange {
  /// Nothing new.
  same,

  /// Stored in its place: new chapters, or entries renamed or moved.
  taken,

  /// Kept out: the stored list and its downloads stay as they are.
  refused,
}

/// [judgeChapterList]'s answer.
class ListVerdict {
  const ListVerdict(this.change, {this.why, this.offered = false});

  final ListChange change;

  /// Why a list was refused, said to the reader.
  final String? why;

  /// A refused list was kept aside for the reader to choose instead (its
  /// chapters all moved to new addresses).
  final bool offered;

  bool get taken => change == ListChange.taken;
  bool get refused => change == ListChange.refused;
}

/// Whether [fresh], a chapter list just fetched, may replace [stored].
///
/// Refused: an empty list; one whose pages were not all read ([complete]
/// false); one cut short (a site that failed part way would take the later
/// chapters' places with it); and one in which most chapters on the phone
/// are no longer listed. That is a site that moved to another domain or a
/// plugin that now writes its addresses another way, more often than a
/// novel rewritten: the reader is asked (it is offered, see
/// LibraryStore.useOfferedChapters) rather than the downloads re-filed by
/// guesswork.
ListVerdict judgeChapterList(List<ChapterItem> stored, List<ChapterItem> fresh, {bool complete = true}) {
  if (fresh.isEmpty) return const ListVerdict(ListChange.refused, why: 'The site listed no chapters.');
  if (!complete) {
    return ListVerdict(ListChange.refused,
        why: "The site's chapter list came back incomplete (${fresh.length} chapters), so the list on the phone was kept.");
  }
  if (stored.isEmpty) return const ListVerdict(ListChange.taken);
  if (fresh.length < stored.length - math.max(3, stored.length ~/ 50)) {
    return ListVerdict(ListChange.refused,
        why: 'The site listed ${fresh.length} chapters, fewer than the ${stored.length} on the phone, so those were kept.');
  }
  final listed = {for (final c in fresh) c.path};
  final missing = stored.where((c) => !listed.contains(c.path)).length;
  if (missing * 2 > stored.length) {
    return ListVerdict(ListChange.refused,
        offered: true,
        why: 'The site now lists its chapters under new addresses '
            '($missing of the ${stored.length} on the phone no longer match), so the list on the phone was kept.');
  }
  if (fresh.length == stored.length) {
    var same = true;
    for (var i = 0; i < fresh.length && same; i++) {
      same = fresh[i].path == stored[i].path && fresh[i].name == stored[i].name;
    }
    if (same) return const ListVerdict(ListChange.same);
  }
  return const ListVerdict(ListChange.taken);
}

/// Whether [fresh], a chapter list just fetched, should replace [stored]
/// (see [judgeChapterList]).
bool replacesChapterList(List<ChapterItem> stored, List<ChapterItem> fresh, {bool complete = true}) =>
    judgeChapterList(stored, fresh, complete: complete).taken;

typedef _ImportJob = ({
  String booksDir,
  String sourcePath,
  String name,
  String? mime,
  Map<String, Object?>? pdf,
});

typedef _LoadJob = ({String booksDir, String id, String? sourcePath});

LibraryEntry _importSync(_ImportJob job) {
  final bytes = File(job.sourcePath).readAsBytesSync();
  final id = bookIdOf(bytes);
  final Book book;
  final pdf = job.pdf;
  if (pdf != null) {
    final text = pdf['text'] as String? ?? '';
    book = ingestPdfText(
      id: id,
      pages: text.split(String.fromCharCode(0x0C)),
      outline: [
        for (final o in (pdf['outline'] as List? ?? const []))
          if (o is Map)
            (title: o['title']?.toString() ?? '', page: o['page'] as int? ?? 0),
      ],
      title: pdf['title'] as String?,
      author: pdf['author'] as String?,
      filename: job.name,
    );
  } else {
    book = ingestBytes(bytes, filename: job.name, mime: job.mime, id: id);
  }

  final dir = Directory('${job.booksDir}/$id')..createSync(recursive: true);
  final dest = File('${dir.path}/source${_ext(job.name)}');
  dest.writeAsBytesSync(bytes, flush: true);
  _writeParsed(dir.path, book);
  _writeImages(dir.path, bytes, book);

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

/// The chapters of a web novel read into a layout opened at chapter [at]:
/// the downloaded ones among the [before] before it, and from it on those
/// downloaded one after another, at most [after] (the reader carries on
/// past the window's end through its onReachedEnd, which fetches what is
/// missing and opens a new window there). [have] says which are on the
/// phone; [count] is how many the novel lists.
Set<int> webWindow(int at, int count, bool Function(int chapter) have, {int before = 10, int after = 30}) {
  final window = <int>{};
  for (var i = at - 1, found = 0; i >= 0 && found < before && i >= at - 60; i--) {
    if (have(i)) {
      window.add(i);
      found++;
    }
  }
  for (var i = at; i < count && i < at + after; i++) {
    if (!have(i)) break;
    window.add(i);
  }
  return window;
}

/// A web novel as one book: every chapter in order, the fetched ones with
/// their text, the rest empty (and so skipped by the reader). With [around],
/// only the chapters of [webWindow] round it have their text.
ReadingLayout _loadWebSync(String dir, String id, {int? around}) {
  final info = WebNovelInfo.fromJson(
    Map<String, Object?>.from(jsonDecode(File('$dir/novel.json').readAsStringSync()) as Map),
  );
  final sections = <Section>[];
  // Lines the reader chose not to hear, from rules.json at the library root.
  final skip = ReadingRules.skipTextsSync(Directory(dir).parent.parent.path, info.plugin.id);
  final window = around == null
      ? null
      : webWindow(around.clamp(0, math.max(0, info.chapters.length - 1)), info.chapters.length,
          (i) => File('$dir/ch/$i.json').existsSync());
  for (var i = 0; i < info.chapters.length; i++) {
    final title = info.chapters[i].name;
    final f = File('$dir/ch/$i.json');
    Section? s;
    if ((window == null || window.contains(i)) && f.existsSync()) {
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
  return ReadingLayout.build(webNovelBook(
    id: id,
    title: info.novel.name,
    authors: [if (info.novel.author != null) info.novel.author!],
    language: languageCodeOf(info.plugin.lang),
    cover: cover,
    description: info.novel.summary,
    sections: sections,
  ));
}

ReadingLayout _loadLayoutSync(_LoadJob job) {
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
          book = ingestBytes(
            bytes,
            filename: legacy.sourceName ?? source.path,
            id: job.id,
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
  if (book == null) {
    final source = job.sourcePath == null ? null : File(job.sourcePath!);
    if (source == null || !source.existsSync()) {
      throw const ParseException('This book\'s files are missing. Import it again.');
    }
    final bytes = source.readAsBytesSync();
    book = ingestBytes(bytes, filename: source.path, id: job.id);
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
  final layout = ReadingLayout.build(book);
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
    final at = indexOfCursor(old, cursor);
    final text = old[at].text;
    // Nearest unit with the same text to where it sat proportionally.
    final guess = (at * after.units.length / old.length).round().clamp(0, after.units.length - 1);
    var best = -1;
    for (var d = 0; d < after.units.length; d++) {
      for (final i in [guess - d, guess + d]) {
        if (i >= 0 && i < after.units.length && after.units[i].text == text) {
          best = i;
          break;
        }
      }
      if (best >= 0 || d > 3000) break;
    }
    final target = best >= 0 ? best : guess;
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
    this.refusal,
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

  /// Why the site's latest list was not taken, if it was not (see
  /// LibraryStore.offerWebChapters).
  final ListRefusal? refusal;

  WebNovelInfo copyWith({
    List<ChapterItem>? chapters,
    DateTime? checkedAt,
    bool? filed,
    ListRefusal? refusal,
    bool clearRefusal = false,
  }) =>
      WebNovelInfo(
        plugin: plugin,
        novel: novel,
        chapters: chapters ?? this.chapters,
        checkedAt: checkedAt ?? this.checkedAt,
        filed: filed ?? this.filed,
        refusal: clearRefusal ? null : (refusal ?? this.refusal),
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
        if (refusal != null) 'refused': refusal!.toJson(),
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
      refusal: ListRefusal.fromJson(j['refused']),
    );
  }
}

/// A chapter list the site gave that was not taken, and why.
class ListRefusal {
  const ListRefusal({required this.why, required this.at, required this.count, this.offered = false});

  final String why;
  final DateTime at;

  /// How many chapters the site listed.
  final int count;

  /// The list was kept aside for the reader to take instead.
  final bool offered;

  Map<String, Object?> toJson() => {
        'why': why,
        'at': at.toIso8601String(),
        'count': count,
        if (offered) 'offered': true,
      };

  static ListRefusal? fromJson(Object? o) {
    if (o is! Map) return null;
    final at = DateTime.tryParse(o['at'] as String? ?? '');
    if (at == null) return null;
    return ListRefusal(
      why: o['why'] as String? ?? '',
      at: at,
      count: o['count'] as int? ?? 0,
      offered: o['offered'] == true,
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
