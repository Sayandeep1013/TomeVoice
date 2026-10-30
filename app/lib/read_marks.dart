import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import 'library_store.dart';
import 'safe_file.dart';

/// A web novel's chapters marked read or unread by hand, each by its
/// address on its site: a site's list gains and loses entries, and the
/// address finds the chapter again wherever it moved.
///
/// A chapter with no mark is read once the place is past it, as it always
/// was. A mark says otherwise for its chapter: read ahead of the place (read
/// elsewhere), or unread behind it (to hear again). A chapter marked unread
/// is read again by reading it: its mark goes when the reader reaches it.
class ReadMarks {
  const ReadMarks({this.read = const {}, this.unread = const {}});

  static const none = ReadMarks();

  /// Chapters marked read, by address.
  final Set<String> read;

  /// Chapters marked unread, by address.
  final Set<String> unread;

  bool get isEmpty => read.isEmpty && unread.isEmpty;

  /// Whether chapter [index] (at [path]) shows as read, with the place in
  /// chapter [current] (-1: not begun).
  bool isRead(int index, String path, int current) =>
      read.contains(path) || (!unread.contains(path) && current >= 0 && index < current);

  /// These marks with the chapters at [paths] marked read, or unread.
  ReadMarks marking(Iterable<String> paths, {required bool asRead}) {
    final r = {...read}, u = {...unread};
    for (final p in paths) {
      if (asRead) {
        r.add(p);
        u.remove(p);
      } else {
        u.add(p);
        r.remove(p);
      }
    }
    return ReadMarks(read: r, unread: u);
  }

  /// These marks with none left for the chapters at [paths].
  ReadMarks clearing(Iterable<String> paths) {
    final gone = paths.toSet();
    return ReadMarks(
      read: {for (final p in read) if (!gone.contains(p)) p},
      unread: {for (final p in unread) if (!gone.contains(p)) p},
    );
  }

  /// These marks for the same chapters at their addresses elsewhere (the
  /// novel moved to another source): [to] gives each address its new one,
  /// or null for a chapter the other list does not have (its mark goes).
  ReadMarks mapped(String? Function(String path) to) => ReadMarks(
        read: {for (final p in read) if (to(p) case final q?) q},
        unread: {for (final p in unread) if (to(p) case final q?) q},
      );

  Map<String, Object?> toJson() => {
        if (read.isNotEmpty) 'read': [...read],
        if (unread.isNotEmpty) 'unread': [...unread],
      };

  static ReadMarks fromJson(Object? raw) {
    if (raw is! Map) return none;
    Set<String> paths(Object? list) => {for (final p in list is List ? list : const []) if (p is String) p};
    return ReadMarks(read: paths(raw['read']), unread: paths(raw['unread']));
  }
}

/// The addresses of the chapters before chapter [index] in [paths] (the
/// list in the novel's own order): what "Mark all above as read" marks, the
/// chapters above it as the list runs oldest first (below it, newest first).
List<String> chaptersBefore(List<String> paths, int index) => [
      for (var i = 0; i < index && i < paths.length; i++) paths[i],
    ];

/// Every web novel's read marks, in its folder (books/<id>/read.json, so a
/// backup carries them), read once and kept here until the file changes.
class ReadMarkStore {
  ReadMarkStore._();

  static final instance = ReadMarkStore._();

  /// Bumped on every change, for the novel's page.
  final changes = ValueNotifier<int>(0);

  /// By file: the marks as last read or written, and the file's time and
  /// size then (a novel removed and added again, or a restore, is read
  /// afresh).
  final _known = <String, (ReadMarks, DateTime, int)>{};

  File _file(LibraryStore store, String id) => File('${store.bookDir(id)}/read.json');

  /// Web novel [id]'s marks (none when it has none).
  Future<ReadMarks> of(LibraryStore store, String id) async {
    final f = _file(store, id);
    final known = _known[f.path];
    try {
      final stat = await f.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        _known.remove(f.path);
        return ReadMarks.none;
      }
      if (known != null && known.$2 == stat.modified && known.$3 == stat.size) return known.$1;
      final marks = ReadMarks.fromJson(jsonDecode(await f.readAsString()));
      _known[f.path] = (marks, stat.modified, stat.size);
      return marks;
    } on Object {
      // Unreadable: no marks, as if none were made.
      return known?.$1 ?? ReadMarks.none;
    }
  }

  /// Mark the chapters at [paths] of web novel [id] read, or unread. The
  /// marks as they are now.
  Future<ReadMarks> mark(LibraryStore store, String id, Iterable<String> paths, {required bool read}) async {
    final next = (await of(store, id)).marking(paths, asRead: read);
    await replace(store, id, next);
    return next;
  }

  /// The reader reached chapter [chapter] of web novel [id] (it is read
  /// again): a mark saying it is unread no longer holds. Nothing is read
  /// from disk for a novel with no chapter marked unread.
  Future<void> reached(LibraryStore store, String id, int chapter) async {
    final marks = await of(store, id);
    if (marks.unread.isEmpty) return;
    final path = (await store.webNovel(id))?.chapters.elementAtOrNull(chapter)?.path;
    if (path == null || !marks.unread.contains(path)) return;
    await replace(store, id, marks.clearing([path]));
  }

  /// Web novel [id]'s marks are [marks] now.
  Future<void> replace(LibraryStore store, String id, ReadMarks marks) async {
    final f = _file(store, id);
    if (marks.isEmpty) {
      _known.remove(f.path);
      try {
        await f.delete();
      } on FileSystemException {
        // None kept.
      }
    } else {
      await f.parent.create(recursive: true);
      await writeSafely(f, jsonEncode(marks.toJson()));
      try {
        final stat = await f.stat();
        _known[f.path] = (marks, stat.modified, stat.size);
      } on Object {
        _known.remove(f.path);
      }
    }
    changes.value++;
  }

  /// Forget what was read (between tests: each library has files of its own).
  @visibleForTesting
  void reset() => _known.clear();
}
