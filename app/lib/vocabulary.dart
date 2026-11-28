import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'safe_file.dart';

/// Where a word was met: the book, the sentence, and its place there.
@immutable
class WordSeen {
  const WordSeen({required this.bookId, required this.bookTitle, required this.sentence, required this.at, required this.when});

  final String bookId;
  final String bookTitle;
  final String sentence;
  final ReadingCursor at;
  final DateTime when;

  Map<String, Object?> toJson() =>
      {'book': bookId, 'title': bookTitle, 'sentence': sentence, 'at': at.toJson(), 'when': when.toUtc().toIso8601String()};

  static WordSeen? fromJson(Object? j) {
    if (j is! Map || j['book'] is! String || j['at'] is! Map) return null;
    try {
      return WordSeen(
        bookId: j['book'] as String,
        bookTitle: j['title'] as String? ?? '',
        sentence: j['sentence'] as String? ?? '',
        at: ReadingCursor.fromJson(Map<String, Object?>.from(j['at'] as Map)),
        when: DateTime.tryParse('${j['when']}')?.toUtc() ?? DateTime.now().toUtc(),
      );
    } on Object {
      return null;
    }
  }
}

/// A word the reader looked up or kept, to learn: where they met it, what
/// they wrote it means, and when it is next due for review.
///
/// Review spaces the words out by how well they are known (a Leitner box):
/// knowing one sends it further off (a day, three, a week, two, a month),
/// not knowing it brings it back tomorrow. Past the last box it is learnt
/// and leaves the reviews, though it stays in the list.
@immutable
class VocabWord {
  const VocabWord({
    required this.word,
    required this.seen,
    required this.added,
    this.meaning = '',
    this.box = 0,
    this.due,
    this.learnt = false,
  });

  /// As written in the book the first time ("Ephemeral" at a sentence's
  /// start is kept as "ephemeral").
  final String word;

  /// Every place it was looked up, the latest last (at most [maxSeen]).
  final List<WordSeen> seen;
  final DateTime added;

  /// What it means, in the reader's own words.
  final String meaning;

  /// 0: new. 1 to 5: known that many times running.
  final int box;

  /// Next due for review (null: now).
  final DateTime? due;
  final bool learnt;

  static const maxSeen = 5;

  /// Days to the next review after knowing it in [box].
  static const spacing = [1, 3, 7, 14, 30];

  String get key => keyOf(word);

  static String keyOf(String w) => w.toLowerCase();

  bool dueAt(DateTime now) => !learnt && (due == null || !due!.isAfter(now));

  VocabWord copyWith({List<WordSeen>? seen, String? meaning, int? box, DateTime? due, bool clearDue = false, bool? learnt}) => VocabWord(
        word: word,
        seen: seen ?? this.seen,
        added: added,
        meaning: meaning ?? this.meaning,
        box: box ?? this.box,
        due: clearDue ? null : (due ?? this.due),
        learnt: learnt ?? this.learnt,
      );

  Map<String, Object?> toJson() => {
        'word': word,
        'seen': [for (final s in seen) s.toJson()],
        'added': added.toUtc().toIso8601String(),
        if (meaning.isNotEmpty) 'meaning': meaning,
        if (box > 0) 'box': box,
        if (due != null) 'due': due!.toUtc().toIso8601String(),
        if (learnt) 'learnt': true,
      };

  static VocabWord? fromJson(Object? j) {
    if (j is! Map || j['word'] is! String || (j['word'] as String).trim().isEmpty) return null;
    return VocabWord(
      word: j['word'] as String,
      seen: [for (final s in (j['seen'] as List? ?? const [])) WordSeen.fromJson(s)].whereType<WordSeen>().toList(),
      added: DateTime.tryParse('${j['added']}')?.toUtc() ?? DateTime.now().toUtc(),
      meaning: j['meaning'] as String? ?? '',
      box: (j['box'] as num?)?.toInt() ?? 0,
      due: DateTime.tryParse('${j['due'] ?? ''}')?.toUtc(),
      learnt: j['learnt'] == true,
    );
  }
}

/// The reader's words, in `vocabulary.json` at the library root (so a
/// backup carries them).
class VocabularyStore {
  VocabularyStore._();

  static final instance = VocabularyStore._();

  /// Bumped on every change.
  final changes = ValueNotifier<int>(0);

  File? _file;
  final Map<String, VocabWord> _words = {};

  @visibleForTesting
  void reset() {
    _file = null;
    _words.clear();
    changes.value++;
  }

  Future<void> attach(Directory root) async {
    _file = File('${root.path}/vocabulary.json');
    _words.clear();
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map && raw['words'] is List) {
          for (final j in raw['words'] as List) {
            final w = VocabWord.fromJson(j);
            if (w != null) _words[w.key] = w;
          }
        }
      }
    } on Object {
      // A list that cannot be read is started afresh, the old one set
      // aside, never written over.
      await setAside(_file);
    }
    changes.value++;
  }

  /// Every word, the latest met first.
  List<VocabWord> get all => _words.values.toList()
    ..sort((a, b) => (b.seen.lastOrNull?.when ?? b.added).compareTo(a.seen.lastOrNull?.when ?? a.added));

  VocabWord? byWord(String w) => _words[VocabWord.keyOf(cleanWord(w))];

  int dueCount([DateTime? now]) {
    final t = (now ?? DateTime.now()).toUtc();
    return _words.values.where((w) => w.dueAt(t)).length;
  }

  /// The words due now, those met longest ago first (new words first of all).
  List<VocabWord> due([DateTime? now]) {
    final t = (now ?? DateTime.now()).toUtc();
    return _words.values.where((w) => w.dueAt(t)).toList()
      ..sort((a, b) {
        final byBox = a.box.compareTo(b.box);
        return byBox != 0 ? byBox : (a.due ?? a.added).compareTo(b.due ?? b.added);
      });
  }

  /// [raw] as a word: the punctuation around it gone ("“Ephemeral,”" is
  /// "Ephemeral"), an apostrophe's "s" too.
  static String cleanWord(String raw) {
    var w = raw.trim().replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true), '');
    w = w.replaceFirst(RegExp(r"['’]s$"), '');
    return w;
  }

  /// Keep [rawWord], met in [sentence] at [at] of the book: a word already
  /// kept gains the place (and, if it was learnt, comes back to learn).
  /// Null when there is no word in it.
  Future<VocabWord?> add({
    required String rawWord,
    required String sentence,
    required String bookId,
    required String bookTitle,
    required ReadingCursor at,
    DateTime? now,
  }) async {
    final word = cleanWord(rawWord);
    if (word.isEmpty || !RegExp(r'\p{L}', unicode: true).hasMatch(word)) return null;
    final t = (now ?? DateTime.now()).toUtc();
    final seen = WordSeen(bookId: bookId, bookTitle: bookTitle, sentence: sentence.trim(), at: at, when: t);
    final old = _words[VocabWord.keyOf(word)];
    final VocabWord next;
    if (old == null) {
      // A sentence's capital is not the word's: "Ephemeral beauty" keeps
      // "ephemeral"; a name in the middle of one keeps its capital.
      final start = sentence.trimLeft().startsWith(rawWord.trim()) || sentence.trimLeft().startsWith(word);
      final shown = start && word.length > 1 && word.substring(1) == word.substring(1).toLowerCase() ? word.toLowerCase() : word;
      next = VocabWord(word: shown, seen: [seen], added: t);
    } else {
      final same = old.seen.any((s) => s.bookId == bookId && s.sentence == seen.sentence);
      final places = same ? old.seen : [...old.seen, seen];
      next = old.copyWith(
        seen: places.length > VocabWord.maxSeen ? places.sublist(places.length - VocabWord.maxSeen) : places,
        // Looked up again: not known as well as thought.
        learnt: false,
        box: old.learnt || old.box > 1 ? 1 : old.box,
        clearDue: true,
      );
    }
    _words[next.key] = next;
    await _save();
    return next;
  }

  Future<void> setMeaning(String word, String meaning) => _change(word, (w) => w.copyWith(meaning: meaning.trim()));

  /// A review: [knew] sends it to the next box and further off; not
  /// knowing it starts it again, due tomorrow.
  Future<void> review(String word, {required bool knew, DateTime? now}) {
    final t = (now ?? DateTime.now()).toUtc();
    return _change(word, (w) {
      if (!knew) return w.copyWith(box: 0, due: t.add(const Duration(days: 1)));
      final box = w.box + 1;
      if (box > VocabWord.spacing.length) return w.copyWith(box: box, learnt: true, clearDue: true);
      return w.copyWith(box: box, due: t.add(Duration(days: VocabWord.spacing[box - 1])));
    });
  }

  Future<void> setLearnt(String word, bool learnt) =>
      _change(word, (w) => learnt ? w.copyWith(learnt: true, clearDue: true) : w.copyWith(learnt: false, box: 0, clearDue: true));

  Future<void> remove(String word) async {
    if (_words.remove(VocabWord.keyOf(word)) != null) await _save();
  }

  /// Put [w] back as it was (Undo after a removal).
  Future<void> restore(VocabWord w) async {
    _words[w.key] = w;
    await _save();
  }

  Future<void> _change(String word, VocabWord Function(VocabWord) f) async {
    final w = _words[VocabWord.keyOf(word)];
    if (w == null) return;
    _words[w.key] = f(w);
    await _save();
  }

  Future<void> _save() async {
    changes.value++;
    final f = _file;
    if (f == null) return;
    await writeSafely(
      f,
      jsonEncode({
        'version': 1,
        'words': [for (final w in _words.values) w.toJson()],
      }),
    );
  }
}
