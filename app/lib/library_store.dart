import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter/services.dart' show BackgroundIsolateBinaryMessenger, MethodChannel, RootIsolateToken;
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_search.dart' show foldForSearch;
import 'index_file.dart';
import 'marks.dart';
import 'narration.dart' show BookNarrationReader, epubHasNarration;
import 'ocr.dart';
import 'organise.dart' show distinctTags, seriesNamed, tagKey, tagNamed;
import 'prefs.dart';
import 'safe_file.dart';
import 'series.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'reading_rules.dart';
import 'speech_service.dart';
import 'text_print.dart';

/// Bumped when ingestion improves enough that stored books should be parsed
/// again from their source file (v2: multilingual sentences, compact JSON;
/// v3: pictures and covers from EPUBs, page numbers in PDFs; v4: toc nav
/// only, chapters named from first lines, drop caps, Gutenberg apparatus;
/// v5: the book's description, shown on its page; v6: footnote markers
/// silent and notes out of the flow, chapters by the contents, text in its
/// own encoding, AZW3 by its chapters, chapters and languages beyond
/// English; v7: front and back matter, licences and a page's navigation
/// left unread, Gutenberg text in paragraphs, Markdown, ODT and FB2 fixes,
/// found by the test corpus; v8: Russian and Ukrainian dialogue not cut
/// after "!" or "?" before who spoke, an AZW3 book's notes shown and not
/// read, transcribers' notes not read, a Gutenberg text named by its
/// header, an RTF file's notes shown and its \info title, a Word or ODT
/// table of data read a row at a time). PDFs keep their own version, on the
/// entry (pdfParser).
const _parsedVersion = 8;

/// Bumped when EPUBs are to be read again for their own narration (media
/// overlays), which books stored before it were never looked at for: an
/// EPUB whose package names one is parsed again, once; the rest are marked
/// as looked at. Other books are not touched.
const _narrationVersion = 1;

/// On-device library: copied files, parsed books, reading positions.
///
/// JSON on disk rather than Drift. Everything heavy (parsing, JSON, building
/// the reading layout) runs on a background isolate: on the UI isolate it was
/// a 2.5 second freeze when opening a long EPUB.
class LibraryStore {
  LibraryStore(this.root) {
    // Opening or locking the secret shelves changes what every page shows,
    // and the titles a series is found among.
    secretOpen.addListener(() {
      _seriesSought = false;
      changes.value++;
    });
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

  /// Stop writing the index (a restore is replacing it). Places not yet
  /// written into it are in their books' cursor.json (see [saveCursor]).
  void hold() {
    _held = true;
    _downloads.clear();
    _dropUnwritten();
  }

  /// Write again, reading the index afresh (the restore did not happen).
  void release() {
    _held = false;
    _known = null;
    _downloads.clear();
    _dropUnwritten();
  }

  /// Change the books in one step: [change] gets the current list and
  /// returns the new one. [place]: only a reading place changed.
  Future<void> _change(List<LibraryEntry> Function(List<LibraryEntry> entries) change, {bool place = false}) async {
    await index();
    if (_held) return;
    var next = change([..._known!.entries]);
    // A book come or gone, moved or put in a series: the series titles
    // share are found again (a place saved changes none).
    if (!place) next = _withSeries(next) ?? next;
    next.sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
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
    if (_known != null) _rereadIfChanged();
    var full = _known;
    if (full == null) {
      final read = await _readIndex();
      if (_known == null) {
        _known = read;
        _seriesSought = false;
        // Places a run stopped before writing them here (see saveCursor).
        _recoverPlaces();
        _warmParts(read.entries);
      }
      full = _known!;
    }
    if (!_seriesSought) {
      await _seekSeries();
      full = _known ?? full;
    }
    return all || secretOpen.value ? full : full.withoutSecret();
  }

  /// Whether the series titles share have been looked for in the index as
  /// it was last read, and among the books shown now (see [_seekSeries]).
  bool _seriesSought = false;

  /// The series titles share (see [_withSeries]), looked for in the index
  /// just read (entries from before series were kept, or that an earlier
  /// build gave the series each title names alone), and among the books
  /// shown once a secret shelf opens or shuts. Written as any change is,
  /// when one is found.
  Future<void> _seekSeries() async {
    _seriesSought = true;
    final known = _known;
    if (known == null || _held) return;
    final found = _withSeries(known.entries);
    if (found == null) return;
    _known = LibraryIndex(entries: found, categories: _categories, defaultCategory: _defaultCategory);
    try {
      await _write(found);
    } on Object {
      // Kept here, and written with the next change.
    }
  }

  /// [entries] with the series their titles share found again, or null when
  /// none changes (see seriesAcross). Asked for each book whose series comes
  /// from its title ([_fromTitle]), among the books shown; the rest lend the
  /// series they are in. While a secret shelf is shut its books are left
  /// out altogether, theirs kept as they are, so no series shown can tell
  /// of them.
  List<LibraryEntry>? _withSeries(List<LibraryEntry> entries) {
    final shut = secretOpen.value ? const <String>{} : {for (final c in _categories) if (c.secret) c.id};
    final asked = <int>[];
    final named = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (shut.isNotEmpty && shut.contains(e.categoryIn(_categories, _defaultCategory))) continue;
      if (_fromTitle(e)) {
        asked.add(i);
      } else if (e.seriesName case final name?) {
        named.add(name);
      }
    }
    if (asked.isEmpty) return null;
    final found = seriesAcross([for (final i in asked) entries[i].title], named: named);
    List<LibraryEntry>? out;
    for (var j = 0; j < asked.length; j++) {
      final e = entries[asked[j]];
      final f = found[j];
      // Spelled otherwise only where the shelf would show two series
      // ("Star Wars: Thrawn" and "Star Wars Thrawn").
      if (f == null || foldForSearch(f.name) == foldForSearch(e.series ?? '')) continue;
      (out ??= [...entries])[asked[j]] = e.copyWith(series: f.name, seriesIndex: f.index);
    }
    return out;
  }

  /// library.json's time and size when it was last read or written here
  /// (a size of -1: there was none).
  (DateTime, int)? _seen;

  (DateTime, int) _stamp() {
    final s = _indexFile.statSync();
    return s.type == FileSystemEntityType.notFound ? (DateTime(0), -1) : (s.modified, s.size);
  }

  /// A library.json that is not as this copy last left it was written by
  /// another copy of the app (an engine of its own, with the index in memory
  /// too): it is read again, in the same step, before anything here changes
  /// it, so that change cannot write over a book the other copy just added.
  void _rereadIfChanged() {
    final seen = _seen;
    if (seen == null) return;
    try {
      final now = _stamp();
      if (now == seen || now.$2 < 0) return;
      final raw = jsonDecode(_indexFile.readAsStringSync());
      if (raw is! Map) return;
      final entries = <LibraryEntry>[];
      _take(raw, entries);
      // Places saved here and not written yet stay, unless the other copy
      // has a later one.
      _keepUnwritten(entries);
      entries.sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
      _known = LibraryIndex(entries: entries, categories: _categories, defaultCategory: _defaultCategory);
      _seriesSought = false;
      _seen = now;
      _warmParts(entries);
      // After this step: a listener may well call index() again.
      scheduleMicrotask(() => changes.value++);
    } on Object {
      // Unreadable just now: the copy here stands.
    }
  }

  /// [raw]'s books into [into], and its categories into this store. An
  /// entry of the wrong shape (a newer or older app's, a damaged restore) is
  /// passed over, not the whole shelf: one threw before, and nothing in the
  /// library opened. Returns how many were passed over.
  int _take(Map<Object?, Object?> raw, List<LibraryEntry> into) {
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
    into.addAll([
      for (final b in books is List ? books : const [])
        if (one(() => LibraryEntry.fromJson(Map<String, Object?>.from(b as Map))) case final e?) e,
    ]);
    final listed = raw['categories'];
    final cats = [
      for (final c in listed is List ? listed : const [])
        if (one(() => Category.fromJson(Map<String, Object?>.from(c as Map))) case final c?) c,
    ];
    _categories = cats.isEmpty ? Category.defaults : cats;
    final d = raw['defaultCategory'];
    _defaultCategory = d is String && _categories.any((c) => c.id == d) ? d : _categories.first.id;
    return skipped;
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

  /// Which saved quotes and bookmarks may be shown (Saved, exports): none
  /// of a book on a shut secret shelf, and, while a secret shelf is shut,
  /// none of a book no longer in the library unless it is known to have
  /// left from an open shelf (Mark.left). A secret book removed takes its
  /// marks with it, but before 1.4 they stayed behind, and those cannot be
  /// told from any other removed book's: they show once the shelf is open.
  Future<bool Function(Mark)> marksShown() async {
    final all = await index(all: true);
    final hidden = await hiddenIds();
    final here = {for (final e in all.entries) e.id};
    final shut = !secretOpen.value && all.categories.any((c) => c.secret);
    return (m) => here.contains(m.bookId) ? !hidden.contains(m.bookId) : !shut || m.left != null;
  }

  Future<LibraryIndex> _readIndex() async {
    await ensure();
    var entries = <LibraryEntry>[];
    _seen = _stamp();
    if (await _indexFile.exists()) {
      try {
        final raw = jsonDecode(await _indexFile.readAsString());
        if (raw is Map) {
          // A copy of the file is kept when an entry was passed over.
          final skipped = _take(raw, entries);
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
    // What is written now holds every place kept here so far.
    final written = Map.of(_unwritten);
    _unwritten.clear();
    try {
      // One write at a time, each to its own temp file (two writes sharing
      // one temp name could interleave into invalid JSON, read back as no
      // books). Only the books that changed since the last are encoded.
      await writeBytesSafely(
        _indexFile,
        encodeIndex(
          categories: [for (final c in _categories) c.toJson()],
          defaultCategory: _defaultCategory,
          books: entries,
          toJson: (e) => e.toJson(),
          parts: _encoded,
        ),
      );
    } on Object {
      // Not written: those places wait for the next write.
      written.forEach((id, p) => _unwritten.putIfAbsent(id, () => p));
      if (_unwritten.isNotEmpty && _window == null) _openWindow();
      rethrow;
    }
    _seen = _stamp();
    if (place) {
      placeChanges.value++;
    } else {
      changes.value++;
    }
  }

  /// Each book's part of library.json as last encoded (see encodeIndex).
  final _encoded = Expando<Uint8List>('library.json');

  /// Every book's part made on a background isolate once a large index is
  /// read, so that the first write after it does not make them all on the
  /// UI thread.
  void _warmParts(List<LibraryEntry> entries) {
    if (entries.length < 64) return;
    warming = _runParts(entries).then((parts) {
      for (var i = 0; i < parts.length && i < entries.length; i++) {
        _encoded[entries[i]] ??= parts[i];
      }
    }, onError: (Object _) {});
  }

  /// The parts being made, while they are.
  @visibleForTesting
  Future<void>? warming;

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

  // ------------------------------------------------------- tags and series

  // A tag or series typed is spelled as the books shown already spell it,
  // and only those are asked (organise.dart): with a secret shelf shut, a
  // name never takes its spelling from one of its books. Renaming or taking
  // off a tag likewise touches only the books shown.

  /// Book [id]'s tags are [tags] now, each once.
  Future<void> setTags(String id, List<String> tags) async {
    final shown = (await index()).entries;
    final named = distinctTags([for (final t in tags) tagNamed(t, shown)]);
    await _change((entries) => [for (final e in entries) e.id == id ? e.copyWith(tags: named) : e]);
  }

  /// [tag] put on the books [ids], or taken off them with [on] false.
  Future<void> tagBooks(Set<String> ids, String tag, {bool on = true}) async {
    final name = tagNamed(tag, (await index()).entries);
    final key = tagKey(name);
    if (key.isEmpty) return;
    bool has(LibraryEntry e) => e.tags.any((t) => tagKey(t) == key);
    await _change((entries) => [
          for (final e in entries)
            if (!ids.contains(e.id) || has(e) == on)
              e
            else
              e.copyWith(tags: on ? [...e.tags, name] : [for (final t in e.tags) if (tagKey(t) != key) t]),
        ]);
  }

  /// Tag [from] called [to] on every book shown; with [to] empty, taken off
  /// them. A shut secret shelf's books keep theirs.
  Future<void> renameTag(String from, String to) async {
    final hidden = await hiddenIds();
    final key = tagKey(from);
    bool has(LibraryEntry e) => e.tags.any((t) => tagKey(t) == key);
    // Spelled as another tag it is joined to; a new spelling of the same
    // tag ("fantasy" to "Fantasy") as typed.
    final name = to.trim().isEmpty ? '' : tagNamed(to, (await index()).entries.where((e) => !has(e)));
    await _change((entries) => [
          for (final e in entries)
            if (hidden.contains(e.id) || !has(e))
              e
            else
              e.copyWith(tags: distinctTags([for (final t in e.tags) tagKey(t) == key ? name : t])),
        ]);
  }

  /// Book [id] in series [name] (empty: in none, and none found in its
  /// title again), at [number] in it.
  Future<void> setSeries(String id, String name, double? number) async {
    final named = name.trim().isEmpty ? '' : seriesNamed(name, (await index()).entries);
    await _change((entries) => [
          for (final e in entries)
            e.id == id
                ? e.copyWith(series: named, seriesIndex: named.isEmpty ? null : number, clearSeriesIndex: named.isEmpty || number == null)
                : e,
        ]);
  }

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
        tags: previous?.tags ?? const [],
        series: previous?.series,
        seriesIndex: previous?.seriesIndex,
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

  /// Web novel [from] is [to] now, moved to another source (novel_move.dart,
  /// which makes [to]'s folder first): its entry swapped in one step.
  Future<void> swapWebNovel(String from, LibraryEntry to) async {
    _downloads.remove(from);
    _downloads.remove(to.id);
    await _change((entries) => [to, for (final e in entries) if (e.id != from && e.id != to.id) e]);
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
    try {
      return Set.unmodifiable({
        for (final f in dir.listSync().whereType<File>())
          if (f.path.endsWith('.json'))
            if (int.tryParse(f.uri.pathSegments.last.split('.').first) case final n?) n,
      });
    } on FileSystemException {
      // Gone between the look and the listing: a novel moved to another
      // source, or taken off, as its page asked.
      return const {};
    }
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
        // Its language, when its title or name is in a script that says
        // (a Bengali file name): the sheet offers it first.
        final language = detectScriptLanguage('${pdf['title'] ?? ''} ${file.name}');
        throw ScannedPdf(e.message, OcrOffer(path: file.path, name: file.name, pdf: pdf, language: language));
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
                .withCover(previous.coverMode, previous.customCover)
                .organisedAs(previous);
        return [
          merged,
          for (final e in existing)
            if (e.id != entry.id) e,
        ];
      });
      return _inIndex(merged);
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
              .withCover(previous.coverMode, previous.customCover)
              .organisedAs(previous);
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
    return _inIndex(merged);
  }

  /// [entry] as the index has it now: the change that put it there may
  /// have found the series its title shares with the library's.
  LibraryEntry _inIndex(LibraryEntry entry) => _known?.entries.where((e) => e.id == entry.id).firstOrNull ?? entry;

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

  /// A book made in the app rather than picked: an article read from the
  /// web, or words shared to TomeVoice, as [bytes] named [name] (".html",
  /// ".txt"), kept as its source like a picked file. [id] makes it the same
  /// book whenever it comes again (an article's is its address); a new one
  /// goes on [category], never on a secret shelf. [details] are what the
  /// file cannot say: a page's byline, site and address.
  Future<LibraryEntry> importMade({
    required String id,
    required String name,
    required Uint8List bytes,
    String? category,
    BookMetadata? details,
  }) async {
    await ensure();
    final made = await _runMade((
      dir: bookDir(id),
      id: id,
      name: name,
      bytes: bytes,
      details: details,
      token: RootIsolateToken.instance,
    ));
    late LibraryEntry merged;
    await _change((existing) {
      final previous = existing.where((e) => e.id == id).firstOrNull;
      final shelf = _categories.any((c) => c.id == category && !c.secret) ? category : _defaultCategory;
      merged = previous == null
          ? made.copyWith(category: shelf)
          : made
              .copyWith(
                cursor: previous.cursor,
                progress: previous.progress,
                openedAt: previous.openedAt,
                where: previous.where,
                category: previous.category,
              )
              .withCover(previous.coverMode, previous.customCover)
              .organisedAs(previous);
      return [
        merged,
        for (final e in existing)
          if (e.id != id) e,
      ];
    });
    return _inIndex(merged);
  }

  /// The reading layout for [id], built on a background isolate, with notes
  /// read aloud when the reader asked for that (Settings > Listening); a
  /// change there is taken up by the next layout loaded.
  ///
  /// For a web novel, every chapter has its section (so positions are
  /// chapter numbers), and the downloaded ones have their text; with
  /// [around], only those in a window round that chapter do (see
  /// [webWindow]): opening chapter 2,000 of a long novel reads a few dozen
  /// files, not every one on the phone. With [chapters], only those do (a
  /// window with the chapters after it joined on, read aloud).
  Future<ReadingLayout> loadLayout(String id, {int? around, Set<int>? chapters}) async {
    final notes = ListeningPrefs.loaded?.notesAloud ?? false;
    final entries = await list();
    final entry = entries.where((e) => e.id == id).firstOrNull;
    if (entry != null && entry.isWeb) {
      final dir = bookDir(id);
      final layout = await _runLoadWeb(dir, id, around, chapters, notes);
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
      notes: notes,
    );
    final layout = await _runLoad(job);
    // A book with its own narration plays its audio from its EPUB.
    if (layout.book.narration != null && entry != null) BookNarrationReader.files[id] = entry.sourcePath;
    // A book read again carried its place across in cursor.json (see
    // _carryCursor); the index's copy of the place follows it, for what reads
    // the place from there (Undo after Start over, the shelf).
    final place = await cursorFor(id);
    final carried = entry != null && !_samePlace(place, entry.cursor);
    if (pdf != null || carried) {
      await _change((now) => [
            for (final e in now)
              if (e.id == id)
                e.copyWith(pdfParser: pdf != null ? pdfParserVersion : null, cursor: carried ? place : null)
              else
                e,
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
    if (entry != null) await _noteDetails(entry, layout);
    return layout;
  }

  /// What a book imported before they were kept gets on its first opening:
  /// the series its own metadata names, and a print of its text, made off
  /// the UI thread, to know it again in another file (duplicates.dart).
  Future<void> _noteDetails(LibraryEntry entry, ReadingLayout layout) async {
    final meta = layout.book.metadata;
    final series = entry.series == null && (meta.series?.trim().isNotEmpty ?? false) ? meta.series!.trim() : null;
    String? print;
    if (entry.textPrint == null && !layout.isEmpty) {
      try {
        // Empty for a text too short to have one: not made again each time.
        print = await _runPrint([for (final u in layout.units) u.text]) ?? '';
      } on Object {
        // Without one, a copy is known by its title and author.
      }
    }
    if (series == null && print == null) return;
    await _change(
      (now) => [
        for (final e in now)
          if (e.id == entry.id && (series != null || print != null))
            e.copyWith(
              series: e.series == null ? series : null,
              seriesIndex: e.series == null && series != null ? meta.seriesIndex : null,
              textPrint: e.textPrint ?? print,
            )
          else
            e,
      ],
      // Nothing shown changes at once: the shelf catches up when it shows.
      place: true,
    );
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

  /// Save where the reader is in book [id]: at once in the book's own
  /// cursor.json, which is what a book opens at ([cursorFor]), and in the
  /// copy of the index here, which every page reads.
  ///
  /// library.json, every book's entry, is written at once only for the
  /// first place saved in a while; those saved within [placeWindow] of it
  /// wait, and are written together at its end (and at once when the book
  /// is left, its reading paused or the app put away: [settlePlaces]). The
  /// place is saved about once a sentence while a book is read aloud, and
  /// each save wrote the whole index again on the UI thread. A run stopped
  /// before the index took a place loses nothing: the next one finds it in
  /// cursor.json (see [_recoverPlaces]).
  Future<void> saveCursor(
    String id,
    ReadingCursor cursor,
    double progress, {
    String? where,
  }) async {
    final dir = Directory(bookDir(id));
    // Made once a run, not once a sentence.
    if (_madeDirs.add(id)) await dir.create(recursive: true);
    final place = _Place(cursor, progress, where, DateTime.now());
    await writeSafely(File('${dir.path}/cursor.json'), jsonEncode(place.toJson()));
    await index();
    if (_held || !_keepPlace(id, place)) return;
    placeChanges.value++;
    if (_window == null) {
      _openWindow();
      await _writePlaces();
    }
  }

  // ---------------------------------------------------------------- places

  /// How long after a place is written into library.json the places saved
  /// next wait, at most, to be written together (see [saveCursor]).
  @visibleForTesting
  Duration placeWindow = const Duration(seconds: 5);

  /// Places saved and not yet written into library.json, by book. They are
  /// in [_known] already, and in each book's cursor.json.
  final _unwritten = <String, _Place>{};

  /// Open for [placeWindow] after a place is written.
  Timer? _window;

  /// The zone the store was made in: the window's end runs there (its timer
  /// is the root zone's, so a widget test's fake clock does not hold it).
  final _zone = Zone.current;

  void _openWindow() {
    _window?.cancel();
    _window = Zone.root.createTimer(placeWindow, () => _zone.run(_windowEnded));
  }

  void _windowEnded() {
    _window = null;
    if (_unwritten.isEmpty) return;
    // The library's folder gone (storage taken away): nothing to write into.
    if (!root.existsSync()) return _unwritten.clear();
    _openWindow();
    unawaited(_writePlaces().catchError((Object _) {
      // Kept for the next write; each is in its cursor.json meanwhile.
    }));
  }

  Future<void> _writePlaces() async {
    if (_unwritten.isEmpty) return;
    await _change((entries) => entries, place: true);
  }

  /// Write the places waiting here now, and let the next one saved be
  /// written at once: the book was left, its reading paused, or the app put
  /// away. (A reader saves its place as it closes, a moment after.)
  Future<void> settlePlaces() async {
    _window?.cancel();
    _window = null;
    await _writePlaces();
  }

  void _dropUnwritten() {
    _window?.cancel();
    _window = null;
    _unwritten.clear();
    _madeDirs.clear();
  }

  /// Books whose folder a place has been saved into in this run.
  final _madeDirs = <String>{};

  /// [place] for book [id] in the copy here, to be written; false if the
  /// book is not in the library (removed meanwhile).
  bool _keepPlace(String id, _Place place) {
    final known = _known;
    final i = known?.entries.indexWhere((e) => e.id == id) ?? -1;
    if (known == null || i < 0) return false;
    _unwritten[id] = place;
    final moved = place.onto(known.entries[i]);
    final entries = [...known.entries]..removeAt(i);
    // Newest first, as the index is kept: before the first book touched
    // before it (nearly always the front).
    var at = 0;
    while (at < entries.length && !entries[at].lastTouched.isBefore(moved.lastTouched)) {
      at++;
    }
    entries.insert(at, moved);
    _known = LibraryIndex(entries: entries, categories: _categories, defaultCategory: _defaultCategory);
    return true;
  }

  /// The places waiting here, laid over [entries] (just read from the file
  /// another copy of the app wrote) where the file's is not later.
  void _keepUnwritten(List<LibraryEntry> entries) {
    if (_unwritten.isEmpty) return;
    final kept = <String>{};
    for (var i = 0; i < entries.length; i++) {
      final p = _unwritten[entries[i].id];
      if (p == null) continue;
      // Saved at the same moment (a clock that counts in milliseconds or
      // coarser), the one here is the later: it was saved after what this
      // copy last wrote.
      final theirs = entries[i].openedAt;
      if (theirs != null && p.at.isBefore(theirs)) continue;
      entries[i] = p.onto(entries[i]);
      kept.add(entries[i].id);
    }
    // A book the other copy removed, or read on further, needs nothing.
    _unwritten.removeWhere((id, _) => !kept.contains(id));
  }

  /// Places saved into cursor.json after library.json was last written,
  /// which a run stopped in between never wrote there: taken into the index
  /// read just now, to be written with the next. A small library's are
  /// looked for at once, a large one's on a background isolate.
  void _recoverPlaces() {
    final (since, size) = _seen ?? (DateTime(0), -1);
    final known = _known;
    if (size < 0 || known == null || known.entries.isEmpty) return;
    final ids = [for (final e in known.entries) e.id];
    if (ids.length <= 64) {
      _takeRecovered(_newerPlaces(_booksDir.path, since, ids));
    } else {
      recovering = _runNewerPlaces(_booksDir.path, since, ids).then(_takeRecovered, onError: (Object _) {});
    }
  }

  /// The large library's look for places to recover, while it runs.
  @visibleForTesting
  Future<void>? recovering;

  void _takeRecovered(Map<String, Map<String, Object?>> found) {
    final known = _known;
    if (found.isEmpty || known == null || _held) return;
    final entries = [...known.entries];
    var taken = 0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final place = _Place.fromFile(found[e.id], e);
      if (place == null) continue;
      _unwritten[e.id] = place;
      entries[i] = place.onto(e);
      taken++;
    }
    if (taken == 0) return;
    entries.sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
    _known = LibraryIndex(entries: entries, categories: _categories, defaultCategory: _defaultCategory);
    // Written a moment on, or with the next place saved if that is sooner.
    Zone.root.createTimer(placeWindow, () => _zone.run(() => unawaited(_writePlaces().catchError((Object _) {}))));
    scheduleMicrotask(() => changes.value++);
  }

  /// Take book [id] out of the library, with its folder. Its quotes and
  /// bookmarks stay (they keep a copy of their words), except a secret
  /// shelf's: those go first, with the book. Kept, they showed in Saved and
  /// in exports with the shelf shut, as the book was no longer on it to hide
  /// them, and travelled in every backup.
  Future<void> remove(String id) async {
    await index(all: true);
    if (isSecret(id)) {
      await MarkStore.instance.removeBook(id);
    } else {
      // Known to have left from an open shelf: what was saved from it shows
      // on with a secret shelf shut (see marksShown).
      await MarkStore.instance.leaveBook(id);
    }
    final dir = Directory(bookDir(id));
    if (await dir.exists()) await dir.delete(recursive: true);
    _downloads.remove(id);
    _madeDirs.remove(id);
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

Future<ReadingLayout> _runLoadWeb(String dir, String id, int? around, Set<int>? chapters, bool notes) =>
    Isolate.run(() => _loadWebSync(dir, id, around: around, chapters: chapters, notes: notes));

/// The roles read aloud beyond the usual: footnotes (endnotes are marked the
/// same) when the reader asked for notes; captions stay on the page only.
Set<BlockRole> _spoken(bool notes) => notes ? const {BlockRole.footnote} : const {};

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
  RootIsolateToken? token,
});

/// [pdf]: a PDF's text as the platform has just read it again, when the
/// book was read by an older PDF reader (see [LibraryStore.loadLayout]).
typedef _LoadJob = ({
  String booksDir,
  String id,
  String? sourcePath,
  Map<String, Object?>? pdf,
  RootIsolateToken? token,
  bool notes,
});

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
    // Every bookmark level, where lines sit (for footnotes and columns),
    // and their raised runs (notes' marks, not said).
    outline: pdfOutlineFromPlatform(pdf['outline']),
    layout: pdfLayoutFromPlatform(pdf['layout']),
    raised: pdfRaisedFromPlatform(pdf['raised']),
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
    series: _seriesOf(book)?.name,
    seriesIndex: _seriesOf(book)?.index,
    textPrint: _printOf(book),
  );
  return (entry: entry, note: pdf != null && ocr == null ? _scanNote(pdf) : null);
}

/// The series [book] says it is in, else the one its title names (the
/// library's other titles are asked once it is in: see _withSeries).
({String name, double? index})? _seriesOf(Book book) {
  final m = book.metadata;
  final named = m.series?.trim() ?? '';
  if (named.isNotEmpty) return (name: named, index: m.seriesIndex);
  return seriesFromTitle(m.title);
}

/// Whether [e]'s series is its title's to say, and so may be found again as
/// the library changes: it has none, or the very one its title names alone
/// (seriesFromTitle), as an import gives it, and a build that asked each
/// title alone kept it. A series the book or the reader named otherwise,
/// or one the reader took away, stays; a web novel's or an article's title
/// says nothing of the kind.
bool _fromTitle(LibraryEntry e) {
  if (e.isWeb || e.source == SourceKind.html) return false;
  final s = e.series;
  if (s == null) return true;
  final alone = s.isEmpty ? null : seriesFromTitle(e.title);
  return alone != null && alone.name == s && alone.index == e.seriesIndex;
}

/// A print of [book]'s words, to know it again in another file (see
/// text_print.dart).
String? _printOf(Book book) => textPrint([
      for (final s in book.sections)
        for (final b in s.blocks)
          if (!b.isImage) b.text,
    ]);

Future<String?> _runPrint(List<String> texts) => Isolate.run(() => textPrint(texts));

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
    series: _seriesOf(book)?.name,
    seriesIndex: _seriesOf(book)?.index,
    textPrint: _printOf(book),
  );
}

typedef _MadeJob = ({
  String dir,
  String id,
  String name,
  Uint8List bytes,
  BookMetadata? details,
  RootIsolateToken? token,
});

Future<LibraryEntry> _runMade(_MadeJob job) => Isolate.run(() => _made(job));

/// A book made in the app (see [LibraryStore.importMade]), parsed and kept.
Future<LibraryEntry> _made(_MadeJob job) async {
  var book = await _ingest(job.bytes, filename: job.name, id: job.id, token: job.token);
  if (job.details case final d?) book = _withDetails(book, d);
  final dir = Directory(job.dir)..createSync(recursive: true);
  final dest = File('${dir.path}/source${_ext(job.name)}');
  dest.writeAsBytesSync(job.bytes, flush: true);
  _writeParsed(dir.path, book);
  return LibraryEntry(
    id: job.id,
    title: book.metadata.title,
    authors: book.metadata.authors,
    source: book.source,
    wordCount: book.wordCount,
    sourcePath: dest.path,
    addedAt: DateTime.now(),
    language: book.metadata.language,
  );
}

/// [book] with [d] laid over what its parser found: an article's title,
/// byline, site and address, which its file does not hold where the
/// parser looks (a page's head is not read).
Book _withDetails(Book book, BookMetadata d) {
  final m = book.metadata;
  return book.copyWith(
    metadata: BookMetadata(
      title: d.title.isEmpty ? m.title : d.title,
      authors: d.authors.isEmpty ? m.authors : d.authors,
      language: m.language,
      publisher: d.publisher ?? m.publisher,
      identifier: d.identifier ?? m.identifier,
      cover: m.cover,
      description: d.description ?? m.description,
    ),
  );
}

void _writeParsed(String dir, Book book) {
  _writeWholeSync(
    File('$dir/parsed.json'),
    jsonEncode({'v': _parsedVersion, 'n': _narrationVersion, 'book': book.toJson()}),
  );
}

/// Whether [raw], an EPUB stored before its narration was looked for, has
/// one in its file [source] (its package says so), and so is to be parsed
/// again. One without is marked as looked at in [dir], and not looked at
/// again.
bool _narrationUnread(Map<Object?, Object?> raw, String? source, String dir) {
  final looked = raw['n'];
  if (looked is num && looked >= _narrationVersion) return false;
  final book = raw['book'];
  if (book is! Map || book['source'] != SourceKind.epub.name) return false;
  if (source != null && epubHasNarration(source)) return true;
  try {
    _writeWholeSync(File('$dir/parsed.json'), jsonEncode({...raw, 'n': _narrationVersion}));
  } on Object {
    // Looked at again next time.
  }
  return false;
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
/// only the chapters of [webWindow] round it have their text; with
/// [chapters], only those. [notes]: the reader asked for notes read aloud.
ReadingLayout _loadWebSync(String dir, String id, {int? around, Set<int>? chapters, bool notes = false}) {
  final info = WebNovelInfo.fromJson(
    Map<String, Object?>.from(jsonDecode(File('$dir/novel.json').readAsStringSync()) as Map),
  );
  final sections = <Section>[];
  // Lines the reader chose not to hear, from rules.json at the library root.
  final skip = ReadingRules.skipTextsSync(Directory(dir).parent.parent.path, info.plugin.id);
  final window = chapters ??
      (around == null
          ? null
          : webWindow(around.clamp(0, math.max(0, info.chapters.length - 1)), info.chapters.length,
              (i) => File('$dir/ch/$i.json').existsSync()));
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
  // Notes shown on the page, not read aloud (see ReadingLayout.build),
  // unless the reader asked for them.
  return ReadingLayout.build(displayOnly: true, spoken: _spoken(notes), webNovelBook(
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
    if (raw is Map && raw['v'] == _parsedVersion && raw['book'] is Map && !_narrationUnread(raw, job.sourcePath, dir)) {
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
          // An article's byline, site and address came with it, not in its
          // file (see importMade): they stay.
          if (legacy.metadata.identifier != null && book.metadata.identifier == null) {
            book = _withDetails(book, legacy.metadata);
          }
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
  // Footnotes and captions shown on the page, not read aloud; footnotes
  // read too when the reader asked for them.
  final layout = ReadingLayout.build(book, displayOnly: true, spoken: _spoken(job.notes));
  if (before != null && !identical(before, book)) _carryCursor(dir, before, layout);
  return layout;
}

bool _samePlace(ReadingCursor a, ReadingCursor b) =>
    a.sectionIndex == b.sectionIndex && a.blockIndex == b.blockIndex && a.sentenceIndex == b.sentenceIndex;

/// A reading place as it is saved: where, how far, the chapter it is in,
/// and when (cursor.json holds all four).
class _Place {
  const _Place(this.cursor, this.progress, this.where, this.at, {this.opened = true});

  final ReadingCursor cursor;
  final double progress;
  final String? where;
  final DateTime at;

  /// Whether saving it was opening the book (a place saved by an older
  /// build, recovered, says nothing of when).
  final bool opened;

  Map<String, Object?> toJson() => {
        'cursor': cursor.toJson(),
        'progress': progress,
        if (where != null) 'where': where,
        'at': at.toIso8601String(),
      };

  LibraryEntry onto(LibraryEntry e) =>
      e.copyWith(cursor: cursor, progress: progress, where: where, openedAt: opened ? at : null);

  /// A cursor.json's place, [raw], when it is later than [e]'s own: saved
  /// after the place [e] has, or (with no time, as older builds wrote it)
  /// another place.
  static _Place? fromFile(Map<String, Object?>? raw, LibraryEntry e) {
    if (raw == null || raw['cursor'] is! Map) return null;
    final cursor = ReadingCursor.fromJson(Map<String, Object?>.from(raw['cursor'] as Map));
    final progress = (raw['progress'] as num?)?.toDouble() ?? e.progress;
    final where = raw['where'] as String? ?? e.where;
    final at = DateTime.tryParse(raw['at'] as String? ?? '');
    if (at == null) {
      if (_samePlace(cursor, e.cursor)) return null;
      return _Place(cursor, progress, where, e.openedAt ?? DateTime(0), opened: false);
    }
    // At the same moment (a coarse clock) only another place is later.
    final opened = e.openedAt;
    if (opened != null && (at.isBefore(opened) || (at == opened && _samePlace(cursor, e.cursor)))) return null;
    return _Place(cursor, progress, where, at);
  }
}

Future<List<Uint8List>> _runParts(List<LibraryEntry> entries) =>
    Isolate.run(() => [for (final e in entries) encodePart(e.toJson())]);

Future<Map<String, Map<String, Object?>>> _runNewerPlaces(String booksDir, DateTime since, List<String> ids) =>
    Isolate.run(() => _newerPlaces(booksDir, since, ids));

/// The cursor.json of each of [ids] (under [booksDir]) written after
/// [since] (library.json's time), by book: a place saved after the index
/// was last written. A few seconds before it count too, for a disk that
/// keeps times in whole seconds; the time each place was saved, inside the
/// file, is what decides (see _Place.fromFile).
Map<String, Map<String, Object?>> _newerPlaces(String booksDir, DateTime since, List<String> ids) {
  final out = <String, Map<String, Object?>>{};
  final from = since.subtract(const Duration(seconds: 2));
  for (final id in ids) {
    final f = File('$booksDir/$id/cursor.json');
    try {
      final s = f.statSync();
      if (s.type == FileSystemEntityType.notFound || s.modified.isBefore(from)) continue;
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is Map) out[id] = Map<String, Object?>.from(raw);
    } on Object {
      // Unreadable: the index's copy of the place stands.
    }
  }
  return out;
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
    // The same place, so when and in which chapter it was saved stay.
    file.writeAsStringSync(jsonEncode({
      ...raw,
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
    this.tags = const [],
    this.series,
    this.seriesIndex,
    this.textPrint,
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

  /// The reader's own words for the book ("Fantasy", "To lend"): as many
  /// as they like, each once (see organise.dart).
  final List<String> tags;

  /// The series it is in, as the book says (an EPUB's own metadata), its
  /// title does, alone or with the library's other titles ("A Song of Ice
  /// and Fire 3", "A Storm of Swords A Song of Ice and Fire 3"; see
  /// series.dart), or the reader put it; empty when the reader said it is
  /// in none, so that it is not found again in its title. Read it through
  /// [seriesName].
  final String? series;

  /// Its number in [series], when known.
  final double? seriesIndex;

  /// A print of its text, to find another copy of it in another file or
  /// format (text_print.dart): made on import, or on its first opening for
  /// a book imported before; empty for a text too short to have one.
  final String? textPrint;

  bool get isWeb => source == SourceKind.web;

  /// The series it is in, if any.
  String? get seriesName => series == null || series!.isEmpty ? null : series;

  /// The picture to show, or null for a cover drawn from the title.
  String? get shownCover => switch (coverMode) {
        CoverMode.plain => null,
        CoverMode.custom => customCover ?? cover,
        CoverMode.auto => cover,
      };

  LibraryEntry withCover(CoverMode mode, String? custom) =>
      copyWith(coverMode: mode, customCover: custom, clearCustomCover: custom == null);

  /// This book, made again (imported again, or read by OCR), with what the
  /// reader gave [previous]: its tags, and its series or that it has none.
  LibraryEntry organisedAs(LibraryEntry previous) => copyWith(
        tags: previous.tags,
        series: previous.series,
        seriesIndex: previous.series == null ? null : previous.seriesIndex,
        clearSeriesIndex: previous.series != null && previous.seriesIndex == null,
        textPrint: textPrint ?? previous.textPrint,
      );

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
    List<String>? tags,
    String? series,
    double? seriesIndex,
    bool clearSeriesIndex = false,
    String? textPrint,
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
        tags: tags ?? this.tags,
        series: series ?? this.series,
        seriesIndex: clearSeriesIndex ? null : (seriesIndex ?? this.seriesIndex),
        textPrint: textPrint ?? this.textPrint,
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
        if (tags.isNotEmpty) 'tags': tags,
        if (series != null) 'series': series,
        if (seriesIndex != null) 'seriesIndex': seriesIndex,
        if (textPrint != null) 'print': textPrint,
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
        tags: [
          for (final t in json['tags'] is List ? json['tags'] as List : const [])
            if (t is String && t.trim().isNotEmpty) t,
        ],
        // An entry from before series were kept has its title asked (see
        // series.dart), and the store asks the library's other titles too
        // (_withSeries); one with a series, or an empty one, says itself.
        series: json.containsKey('series') ? json['series'] as String? ?? '' : _titleSeries(json)?.name,
        seriesIndex: json.containsKey('series')
            ? (json['seriesIndex'] as num?)?.toDouble()
            : _titleSeries(json)?.index,
        textPrint: json['print'] as String?,
      );

  /// The series an entry's title names, for a book that is a book: a web
  /// novel's or an article's title says nothing of the kind.
  static ({String name, double index})? _titleSeries(Map<String, Object?> json) =>
      json['source'] == SourceKind.web.name || json['source'] == SourceKind.html.name
          ? null
          : seriesFromTitle(json['title'] as String? ?? '');
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
