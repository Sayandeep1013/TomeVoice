import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'safe_file.dart';

/// A quote kept to read again or share, or a bookmark: a place to come back to.
enum MarkKind { quote, bookmark }

/// The colour a quote is washed in on the page: the book's own accent, or
/// one of three highlighter colours.
enum MarkColour {
  accent('Accent'),
  yellow('Yellow'),
  green('Green'),
  blue('Blue');

  const MarkColour(this.label);
  final String label;

  static MarkColour byName(Object? name) => values.where((c) => c.name == name).firstOrNull ?? accent;
}

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
    this.colour = MarkColour.accent,
    this.edited,
    this.left,
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

  /// When it was saved, in UTC (as [edited] and [left] are): another phone,
  /// in another time zone, reads the same moment (sync compares them).
  final DateTime created;

  /// A quote's wash on the page.
  final MarkColour colour;

  /// When its note or colour last changed (null: never since it was saved).
  final DateTime? edited;

  /// When its book was taken out of the library from an open shelf. Kept
  /// so that it is known not to have been a secret book's: those left their
  /// marks behind before 1.4, and a mark of a book no longer here that does
  /// not say this is not shown with a secret shelf shut
  /// (LibraryStore.marksShown).
  final DateTime? left;

  /// When it last changed: what wins when two copies of it meet (sync).
  DateTime get changed => edited ?? created;

  Mark _with({
    ReadingCursor? at,
    String? note,
    bool clearNote = false,
    MarkColour? colour,
    DateTime? edited,
    DateTime? left,
  }) =>
      Mark(
        id: id,
        bookId: bookId,
        bookTitle: bookTitle,
        kind: kind,
        at: at ?? this.at,
        text: text,
        created: created,
        span: span,
        chapter: chapter,
        note: clearNote ? null : (note ?? this.note),
        colour: colour ?? this.colour,
        edited: edited ?? this.edited,
        left: left ?? this.left,
      );

  /// The same mark with [note] (null or empty: none).
  Mark withNote(String? note) => note == null || note.trim().isEmpty
      ? _with(clearNote: true, edited: DateTime.now().toUtc())
      : _with(note: note.trim(), edited: DateTime.now().toUtc());

  /// The same quote washed in [colour].
  Mark withColour(MarkColour colour) => _with(colour: colour, edited: DateTime.now().toUtc());

  /// The same mark at [place].
  Mark movedTo(ReadingCursor place) => _with(at: place);

  /// The same mark, its book taken out of the library from an open shelf.
  Mark leftAt(DateTime when) => _with(left: when);

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
        // Left out for the accent, as every mark before colours was.
        if (colour != MarkColour.accent) 'colour': colour.name,
        // With a Z: written without one, another phone read the time as
        // its own clock's.
        'created': created.toUtc().toIso8601String(),
        if (edited != null) 'edited': edited!.toUtc().toIso8601String(),
        if (left != null) 'left': left!.toUtc().toIso8601String(),
      };

  static Mark? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    if (json['id'] is! String || json['book'] is! String || at is! Map) return null;
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
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
      colour: MarkColour.byName(json['colour']),
      // A time from before they carried a Z is this phone's own clock's.
      created: time(json['created']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      edited: time(json['edited']),
      left: time(json['left']),
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

  /// Forget everything without writing (between widget tests: a write left
  /// waiting inside one test's fake clock held up every save after it).
  @visibleForTesting
  void reset() {
    _file = null;
    _all = const [];
    changes.value++;
  }

  Future<void> attach(Directory root) async {
    _file = File('${root.path}/marks.json');
    _all = const [];
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString()) as List;
        _all = raw.map(Mark.fromJson).whereType<Mark>().toList();
        changes.value++;
      }
    } on Object {
      // A broken file: start empty, but keep it beside as marks.json.broken
      // so the next save does not destroy what may be recovered from it.
      await setAside(_file);
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
    MarkColour colour = MarkColour.accent,
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
      colour: colour,
      created: now.toUtc(),
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

  /// Every mark of book [bookId] gone, in one write: a book on a secret
  /// shelf leaves none behind it when it is removed (LibraryStore.remove).
  Future<void> removeBook(String bookId) async {
    if (!_all.any((m) => m.bookId == bookId)) return;
    _all = [for (final m in _all) if (m.bookId != bookId) m];
    await _save();
  }

  /// Book [bookId] was taken out of the library from an open shelf: its
  /// marks stay, and say so (see [Mark.left]).
  Future<void> leaveBook(String bookId) async {
    if (!_all.any((m) => m.bookId == bookId && m.left == null)) return;
    final now = DateTime.now().toUtc();
    _all = [for (final m in _all) m.bookId == bookId && m.left == null ? m.leftAt(now) : m];
    await _save();
  }

  /// The marks with [ids] gone, in one write (Saved's clearing of those
  /// whose books are gone).
  Future<void> removeAll(Set<String> ids) async {
    if (ids.isEmpty) return;
    _all = [for (final m in _all) if (!ids.contains(m.id)) m];
    await _save();
  }

  /// Put back [marks] just removed together (Undo).
  Future<void> restoreAll(List<Mark> marks) async {
    final have = {for (final m in _all) m.id};
    _all = [..._all, for (final m in marks) if (!have.contains(m.id)) m]..sort((a, b) => b.created.compareTo(a.created));
    await _save();
  }

  /// Book [bookId]'s marks are [marks] now (synced from another phone):
  /// those not among them go, the rest are added or replaced. One write.
  Future<void> replaceBook(String bookId, List<Mark> marks) async {
    final keep = [for (final m in _all) if (m.bookId != bookId) m];
    _all = [...keep, ...marks.where((m) => m.bookId == bookId)]..sort((a, b) => b.created.compareTo(a.created));
    await _save();
  }

  /// Web novel [bookId]'s downloads were filed again (its list changed on
  /// the site): each mark goes to where its chapter is now, [to].
  Future<void> moveChapters(String bookId, int Function(int chapter) to) async {
    var moved = false;
    final next = <Mark>[];
    for (final m in _all) {
      final c = m.bookId == bookId ? to(m.at.sectionIndex) : m.at.sectionIndex;
      moved |= c != m.at.sectionIndex;
      next.add(c == m.at.sectionIndex ? m : m.movedTo(m.at.copyWith(sectionIndex: c)));
    }
    if (!moved) return;
    _all = next;
    await _save();
  }

  /// Book [from]'s marks are book [to]'s now (a web novel moved to another
  /// source), each at its chapter there, [chapter]. One write.
  Future<void> moveBook(String from, String to, int Function(int chapter) chapter) async {
    if (!_all.any((m) => m.bookId == from)) return;
    _all = [
      for (final m in _all)
        if (m.bookId != from)
          m
        else
          Mark(
            id: m.id,
            bookId: to,
            bookTitle: m.bookTitle,
            kind: m.kind,
            at: m.at.copyWith(sectionIndex: chapter(m.at.sectionIndex)),
            text: m.text,
            created: m.created,
            span: m.span,
            chapter: m.chapter,
            note: m.note,
            colour: m.colour,
            edited: m.edited,
          ),
    ];
    await _save();
  }

  Future<void> _save() async {
    changes.value++;
    try {
      await writeSafely(_file, jsonEncode([for (final m in _all) m.toJson()]));
    } on Object {
      // Kept in memory until the next change.
    }
  }
}

/// The sentence [c] points at in [units] (a layout's, in reading order), as
/// a saved place is found: the sentence itself, or the first after its
/// paragraph when that is gone. Searched by halves: a book's quotes are all
/// looked for each time one changes, and a long book has 30,000 sentences.
int unitAtCursor(List<Speakable> units, ReadingCursor c) {
  if (units.isEmpty) return 0;
  var lo = 0, hi = units.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    final u = units[mid];
    if (u.sectionIndex < c.sectionIndex || (u.sectionIndex == c.sectionIndex && u.blockIndex < c.blockIndex)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  var i = lo;
  while (i < units.length && units[i].sectionIndex == c.sectionIndex && units[i].blockIndex == c.blockIndex) {
    if (units[i].sentenceIndex == c.sentenceIndex) return i;
    i++;
  }
  return i < units.length ? i : units.length - 1;
}

/// Where mark [m] is in [layout]: its address when that still holds its
/// words, otherwise the nearest sentence that does (a book re-parsed since).
int unitOfMark(ReadingLayout layout, Mark m) {
  if (layout.isEmpty) return 0;
  // What unitForCursor finds for a saved place, without its walk through
  // the whole book: every sentence of a layout is in one of its chapters.
  final u = unitAtCursor(layout.units, m.at);
  final want = m.text.split(RegExp(r'\s+')).take(6).join(' ');
  bool holds(int i) => i >= 0 && i < layout.units.length && layout.units[i].text.startsWith(want);
  if (want.isEmpty || holds(u)) return u;
  for (var d = 1; d < 400; d++) {
    if (holds(u - d)) return u - d;
    if (holds(u + d)) return u + d;
  }
  return u;
}
