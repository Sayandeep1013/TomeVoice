import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../safe_file.dart';

/// Books whose memories are read together, in their order: a series. Each
/// book keeps its own memory (memory.db); the series only ties them, so a
/// book can be rebuilt, forgotten or taken out without the others changing.
/// A book is in one series at most.
@immutable
class MemorySeries {
  const MemorySeries({required this.id, required this.name, required this.books});

  final String id;
  final String name;

  /// The books by id, first to last.
  final List<String> books;

  /// Where book [bookId] stands, from 0; -1 when it is not in this series.
  int indexOf(String bookId) => books.indexOf(bookId);

  /// The books before [bookId], first to last.
  List<String> before(String bookId) {
    final i = books.indexOf(bookId);
    return i <= 0 ? const [] : books.sublist(0, i);
  }

  MemorySeries copyWith({String? name, List<String>? books}) =>
      MemorySeries(id: id, name: name ?? this.name, books: books ?? this.books);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'books': books};

  static MemorySeries? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final books = [for (final b in (j['books'] as List?) ?? const []) '$b'];
    if (books.isEmpty) return null;
    return MemorySeries(id: j['id'] as String, name: '${j['name'] ?? ''}', books: books);
  }
}

/// Every series, kept in `memory_series.json` beside the library (so the
/// app's own backup carries it, and Android's too).
class SeriesStore {
  SeriesStore._();

  static final instance = SeriesStore._();

  /// Bumped on every change.
  final changes = ValueNotifier<int>(0);

  File? _file;
  List<MemorySeries> _all = const [];

  List<MemorySeries> get all => _all;

  @visibleForTesting
  void reset() {
    _file = null;
    _all = const [];
    changes.value++;
  }

  Future<void> attach(Directory root) async {
    final f = File('${root.path}/memory_series.json');
    _file = f;
    _all = const [];
    try {
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        _all = [
          for (final s in (raw as List))
            if (MemorySeries.fromJson(s) case final s?) s,
        ];
      }
    } on Object {
      // Unreadable: no series, rather than no app.
    }
    changes.value++;
  }

  /// The series book [bookId] is in, if any.
  MemorySeries? ofBook(String bookId) => _all.where((s) => s.books.contains(bookId)).firstOrNull;

  MemorySeries? byId(String id) => _all.where((s) => s.id == id).firstOrNull;

  static var _n = 0;

  /// Book [bookId] carries on from [earlier]: it joins [earlier]'s series
  /// right after it (a new series of the two when [earlier] is in none),
  /// leaving any series it was in. [name] names a new one.
  Future<MemorySeries> carryOn(String bookId, {required String earlier, required String name}) async {
    if (bookId == earlier) throw ArgumentError('A book cannot carry on from itself');
    await remove(bookId);
    final there = ofBook(earlier);
    final MemorySeries made;
    if (there == null) {
      made = MemorySeries(
        id: 's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_n++).toRadixString(36)}',
        name: name,
        books: [earlier, bookId],
      );
      _all = [..._all, made];
    } else {
      final books = [...there.books];
      books.insert(books.indexOf(earlier) + 1, bookId);
      made = there.copyWith(books: books);
      _all = [for (final s in _all) if (s.id == there.id) made else s];
    }
    await _save();
    return made;
  }

  /// Book [bookId] out of its series (its memory stays). A series left with
  /// one book is a series no more.
  Future<void> remove(String bookId) async {
    final s = ofBook(bookId);
    if (s == null) return;
    final books = [for (final b in s.books) if (b != bookId) b];
    _all = [
      for (final x in _all)
        if (x.id != s.id)
          x
        else if (books.length > 1)
          x.copyWith(books: books),
    ];
    await _save();
  }

  Future<void> rename(String id, String name) => _change(id, (s) => s.copyWith(name: name.trim()));

  /// The books of series [id] in a new order (the same books).
  Future<void> reorder(String id, List<String> books) => _change(id, (s) {
        if (books.length != s.books.length || !books.every(s.books.contains)) return s;
        return s.copyWith(books: [...books]);
      });

  /// Series [id] undone: every book keeps its own memory.
  Future<void> dissolve(String id) async {
    _all = [for (final s in _all) if (s.id != id) s];
    await _save();
  }

  /// Books gone from the library taken out of their series.
  Future<void> keepOnly(Set<String> present) async {
    var changed = false;
    final next = <MemorySeries>[];
    for (final s in _all) {
      final books = [for (final b in s.books) if (present.contains(b)) b];
      if (books.length != s.books.length) changed = true;
      if (books.length > 1) next.add(s.copyWith(books: books));
    }
    if (!changed) return;
    _all = next;
    await _save();
  }

  Future<void> _change(String id, MemorySeries Function(MemorySeries) f) async {
    _all = [for (final s in _all) if (s.id == id) f(s) else s];
    await _save();
  }

  Future<void> _save() async {
    changes.value++;
    final f = _file;
    if (f == null) return;
    try {
      await writeSafely(f, jsonEncode([for (final s in _all) s.toJson()]));
    } on Object {
      // Kept in memory until the next change.
    }
  }
}
