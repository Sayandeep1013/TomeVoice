import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// A quote kept to read again or share, or a bookmark: a place to come back to.
enum MarkKind { quote, bookmark }

/// Something saved from a book: where it is (the same address as a reading
/// place), and a copy of its words, so it still shows if the book is removed
/// and can be found again if the book's text is re-parsed.
class Mark {
  const Mark({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.kind,
    required this.at,
    required this.text,
    required this.created,
    this.span = 1,
    this.chapter,
    this.note,
  });

  final String id;
  final String bookId;
  final String bookTitle;
  final MarkKind kind;

  /// The first sentence.
  final ReadingCursor at;

  /// How many sentences, from [at].
  final int span;
  final String text;
  final String? chapter;
  final String? note;
  final DateTime created;

  /// The same mark with [note] (null or empty: none).
  Mark withNote(String? note) => Mark(
        id: id,
        bookId: bookId,
        bookTitle: bookTitle,
        kind: kind,
        at: at,
        text: text,
        created: created,
        span: span,
        chapter: chapter,
        note: note == null || note.trim().isEmpty ? null : note.trim(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'book': bookId,
        'bookTitle': bookTitle,
        'kind': kind.name,
        'at': at.toJson(),
        if (span != 1) 'span': span,
        'text': text,
        if (chapter != null) 'chapter': chapter,
        if (note != null) 'note': note,
        'created': created.toIso8601String(),
      };

  static Mark? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    if (json['id'] is! String || json['book'] is! String || at is! Map) return null;
    return Mark(
      id: json['id'] as String,
      bookId: json['book'] as String,
      bookTitle: json['bookTitle'] as String? ?? '',
      kind: MarkKind.values.where((k) => k.name == json['kind']).firstOrNull ?? MarkKind.quote,
      at: ReadingCursor.fromJson(Map<String, Object?>.from(at)),
      span: json['span'] as int? ?? 1,
      text: json['text'] as String? ?? '',
      chapter: json['chapter'] as String?,
      note: json['note'] as String?,
      created: DateTime.tryParse(json['created'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Everything saved, newest first, in `marks.json` at the library root (so
/// a backup carries it).
class MarkStore {
  MarkStore._();

  static final instance = MarkStore._();

  /// Bumped on every change.
  final changes = ValueNotifier<int>(0);

  File? _file;
  List<Mark> _all = const [];

  List<Mark> get all => _all;

  List<Mark> forBook(String bookId) => [for (final m in _all) if (m.bookId == bookId) m];

  Future<void> attach(Directory root) async {
    _file = File('${root.path}/marks.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString()) as List;
        _all = raw.map(Mark.fromJson).whereType<Mark>().toList();
        changes.value++;
      }
    } on Object {
      // Nothing saved yet, or a broken file: start empty.
    }
  }

  Future<Mark> add({
    required String bookId,
    required String bookTitle,
    required MarkKind kind,
    required ReadingCursor at,
    required String text,
    int span = 1,
    String? chapter,
    String? note,
  }) async {
    final now = DateTime.now();
    final mark = Mark(
      id: '${now.microsecondsSinceEpoch.toRadixString(36)}${math.Random().nextInt(1 << 20).toRadixString(36)}',
      bookId: bookId,
      bookTitle: bookTitle,
      kind: kind,
      at: at,
      text: text,
      span: span,
      chapter: chapter,
      note: note == null || note.trim().isEmpty ? null : note.trim(),
      created: now,
    );
    _all = [mark, ..._all];
    await _save();
    return mark;
  }

  /// Replace the mark with [mark]'s id (a note added or changed).
  Future<void> update(Mark mark) async {
    _all = [for (final m in _all) m.id == mark.id ? mark : m];
    await _save();
  }

  Future<void> remove(String id) async {
    _all = [for (final m in _all) if (m.id != id) m];
    await _save();
  }

  /// Put back a mark just removed (Undo).
  Future<void> restore(Mark mark) async {
    _all = [mark, ..._all]..sort((a, b) => b.created.compareTo(a.created));
    await _save();
  }

  Future<void> _save() async {
    changes.value++;
    try {
      await _file?.writeAsString(jsonEncode([for (final m in _all) m.toJson()]));
    } on Object {
      // Kept in memory until the next change.
    }
  }
}

/// Where mark [m] is in [layout]: its address when that still holds its
/// words, otherwise the nearest sentence that does (a book re-parsed since).
int unitOfMark(ReadingLayout layout, Mark m) {
  if (layout.isEmpty) return 0;
  final u = layout.unitForCursor(m.at);
  final want = m.text.split(RegExp(r'\s+')).take(6).join(' ');
  bool holds(int i) => i >= 0 && i < layout.units.length && layout.units[i].text.startsWith(want);
  if (want.isEmpty || holds(u)) return u;
  for (var d = 1; d < 400; d++) {
    if (holds(u - d)) return u - d;
    if (holds(u + d)) return u + d;
  }
  return u;
}
