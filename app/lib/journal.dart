import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import 'prefs.dart';
import 'safe_file.dart';

/// One question of the journal's template: its words, and the answers to
/// tap ([picks]; none for a question answered in words). A pick question
/// also takes a word of the reader's own (see [JournalPage]).
@immutable
class JournalQuestion {
  const JournalQuestion(this.text, {this.picks = const []});

  final String text;
  final List<String> picks;

  bool get isPick => picks.isNotEmpty;

  Map<String, Object?> toJson() => {'text': text, if (picks.isNotEmpty) 'picks': picks};

  static JournalQuestion? fromJson(Object? json) {
    if (json is! Map || json['text'] is! String) return null;
    final text = (json['text'] as String).trim();
    if (text.isEmpty) return null;
    final picks = json['picks'];
    return JournalQuestion(text, picks: [
      if (picks is List)
        for (final p in picks)
          if (p is String && p.trim().isNotEmpty) p.trim(),
    ]);
  }

  @override
  bool operator ==(Object other) => other is JournalQuestion && other.text == text && listEquals(other.picks, picks);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(picks));
}

/// The questions TomeVoice starts with (the owner's own, 18 November 2026):
/// how it feels, why, what stood out, and a guess at what comes next.
const defaultJournalQuestions = [
  JournalQuestion('How am I feeling?', picks: ['Loving it', 'Good', 'Mixed', 'Meh', 'Frustrated']),
  JournalQuestion('Why?'),
  JournalQuestion('What stood out?'),
  JournalQuestion('What do I think happens next?'),
];

/// The reader's template: their own questions (kept in the prefs), or
/// TomeVoice's.
List<JournalQuestion> journalQuestionsOf(ListeningPrefs prefs) {
  final own = [
    for (final q in prefs.journalQuestions ?? const <Object?>[])
      if (JournalQuestion.fromJson(q) case final q?) q,
  ];
  return own.isEmpty ? defaultJournalQuestions : own;
}

/// One answer in an entry: the question as it was asked then (a template
/// changed later does not change what was written), the pick tapped, and
/// the words written.
@immutable
class JournalAnswer {
  const JournalAnswer({required this.question, this.pick, this.text = ''});

  final String question;
  final String? pick;
  final String text;

  bool get isEmpty => (pick == null || pick!.trim().isEmpty) && text.trim().isEmpty;

  Map<String, Object?> toJson() => {
        'q': question,
        if (pick != null && pick!.trim().isNotEmpty) 'pick': pick!.trim(),
        if (text.trim().isNotEmpty) 'text': text.trim(),
      };

  static JournalAnswer? fromJson(Object? json) {
    if (json is! Map || json['q'] is! String) return null;
    return JournalAnswer(
      question: json['q'] as String,
      pick: json['pick'] is String ? json['pick'] as String : null,
      text: json['text'] is String ? json['text'] as String : '',
    );
  }
}

/// Where the story had reached when an entry was written: the chapter the
/// voice was reading, or the reader's place when nothing played. [from] is
/// the chapter it was in when the pen was taken up, when the voice moved
/// on meanwhile.
@immutable
class JournalStamp {
  const JournalStamp({required this.at, required this.chapter, this.number, this.title, this.fromNumber});

  /// The sentence, as a place in the book.
  final ReadingCursor at;

  /// The chapter, an index into the book's.
  final int chapter;

  /// The number the chapter goes by (a web novel's "Chapter 412"), and its
  /// title, as they were then.
  final int? number;
  final String? title;

  /// The number of the chapter the writing began in, when it is another.
  final int? fromNumber;

  /// "up to chapter 6", "chapters 4 to 6".
  String get label {
    final n = number ?? chapter + 1;
    final f = fromNumber;
    if (f != null && f != n) return 'chapters ${math.min(f, n)} to ${math.max(f, n)}';
    return 'up to chapter $n';
  }

  Map<String, Object?> toJson() => {
        'at': at.toJson(),
        'chapter': chapter,
        if (number != null) 'number': number,
        if (title != null) 'title': title,
        if (fromNumber != null) 'from': fromNumber,
      };

  static JournalStamp? fromJson(Object? json) {
    if (json is! Map || json['at'] is! Map || json['chapter'] is! int) return null;
    return JournalStamp(
      at: ReadingCursor.fromJson(Map<String, Object?>.from(json['at'] as Map)),
      chapter: json['chapter'] as int,
      number: json['number'] is int ? json['number'] as int : null,
      title: json['title'] is String ? json['title'] as String : null,
      fromNumber: json['from'] is int ? json['from'] as int : null,
    );
  }

  JournalStamp movedTo(ReadingCursor at, int chapter) =>
      JournalStamp(at: at, chapter: chapter, number: number, title: title, fromNumber: fromNumber);
}

/// One turn of a talk with the AI companion: the reader's ([mine]) or its
/// answer.
@immutable
class TalkLine {
  const TalkLine({required this.mine, required this.text});

  final bool mine;
  final String text;

  Map<String, Object?> toJson() => {'by': mine ? 'me' : 'ai', 'text': text};

  static TalkLine? fromJson(Object? v) {
    if (v is! Map || v['text'] is! String) return null;
    return TalkLine(mine: v['by'] == 'me', text: v['text'] as String);
  }
}

/// One entry of a book's journal: the template's questions answered, a
/// page written freely ([page]), or a talk with the AI companion ([talk]),
/// stamped with where the story had reached.
@immutable
class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.created,
    required this.stamp,
    this.answers = const [],
    this.page = '',
    this.talk = const [],
    this.edited,
  });

  final String id;
  final String bookId;
  final String bookTitle;
  final DateTime created;
  final DateTime? edited;
  final JournalStamp stamp;
  final List<JournalAnswer> answers;

  /// Written freely, without the questions.
  final String page;

  /// A talk with the AI companion, kept when its sheet closed.
  final List<TalkLine> talk;

  bool get isTalk => talk.isNotEmpty;

  bool get isPage => answers.isEmpty && talk.isEmpty;

  bool get isEmpty => page.trim().isEmpty && answers.every((a) => a.isEmpty) && talk.isEmpty;

  /// The feeling picked, for the sticker on the page (the first pick
  /// answered).
  String? get feeling => answers.where((a) => a.pick != null && a.pick!.trim().isNotEmpty).firstOrNull?.pick;

  /// Everything written, as one text (search, and the helper's reading).
  String get words => isTalk
      ? [for (final l in talk) '${l.mine ? 'Me' : 'AI'}: ${l.text}'].join('\n')
      : isPage
          ? page.trim()
          : [
              for (final a in answers)
                if (!a.isEmpty) '${a.question} ${[if (a.pick != null) a.pick, if (a.text.isNotEmpty) a.text].join(' — ')}',
            ].join('\n');

  /// The entry's first lines for a preview (the book page's Journal row,
  /// the Journal's book cards): each answer on a line of its own, without
  /// its question ("Good", then the why on the next line), never run
  /// together on one line; blank lines left out.
  String get preview {
    final lines = isTalk
        ? [for (final l in talk) '${l.mine ? 'Me' : 'AI'}: ${l.text}']
        : isPage
            ? page.split('\n')
            : [
                for (final a in answers)
                  if (!a.isEmpty) [if (a.pick != null) a.pick!.trim(), if (a.text.trim().isNotEmpty) a.text.trim()].join(': '),
              ];
    return [
      for (final l in lines)
        for (final part in l.split('\n'))
          if (part.trim().isNotEmpty) part.trim(),
    ].join('\n');
  }

  JournalEntry copyWith({List<JournalAnswer>? answers, String? page, DateTime? edited, JournalStamp? stamp, String? bookId}) =>
      JournalEntry(
        id: id,
        bookId: bookId ?? this.bookId,
        bookTitle: bookTitle,
        created: created,
        stamp: stamp ?? this.stamp,
        answers: answers ?? this.answers,
        page: page ?? this.page,
        talk: talk,
        edited: edited ?? this.edited,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'book': bookId,
        'title': bookTitle,
        'created': created.toUtc().toIso8601String(),
        if (edited != null) 'edited': edited!.toUtc().toIso8601String(),
        'stamp': stamp.toJson(),
        if (answers.isNotEmpty) 'answers': [for (final a in answers) a.toJson()],
        if (page.trim().isNotEmpty) 'page': page,
        if (talk.isNotEmpty) 'talk': [for (final l in talk) l.toJson()],
      };

  static JournalEntry? fromJson(Object? json) {
    try {
      if (json is! Map) return null;
      final stamp = JournalStamp.fromJson(json['stamp']);
      final created = DateTime.tryParse('${json['created']}');
      if (stamp == null || created == null || json['id'] is! String || json['book'] is! String) return null;
      return JournalEntry(
        id: json['id'] as String,
        bookId: json['book'] as String,
        bookTitle: json['title'] is String ? json['title'] as String : '',
        created: created.toUtc(),
        edited: DateTime.tryParse('${json['edited']}')?.toUtc(),
        stamp: stamp,
        answers: [
          for (final a in (json['answers'] is List ? json['answers'] as List : const []))
            if (JournalAnswer.fromJson(a) case final a?) a,
        ],
        page: json['page'] is String ? json['page'] as String : '',
        talk: [
          for (final l in (json['talk'] is List ? json['talk'] as List : const []))
            if (TalkLine.fromJson(l) case final l?) l,
        ],
      );
    } on Object {
      return null;
    }
  }
}

/// Every book's journal, newest first, in `journal.json` at the library
/// root (so a backup carries it, and the reading helper can read it).
class JournalStore {
  JournalStore._();

  static final instance = JournalStore._();

  /// Bumped on every change.
  final changes = ValueNotifier<int>(0);

  File? _file;
  List<JournalEntry> _all = const [];

  List<JournalEntry> get all => _all;

  /// Book [bookId]'s entries, newest first.
  List<JournalEntry> forBook(String bookId) => [for (final e in _all) if (e.bookId == bookId) e];

  @visibleForTesting
  void reset() {
    _file = null;
    _all = const [];
    changes.value++;
  }

  Future<void> attach(Directory root) async {
    _file = File('${root.path}/journal.json');
    _all = const [];
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString()) as List;
        _all = [
          for (final e in raw)
            if (JournalEntry.fromJson(e) case final e?) e,
        ];
      }
    } on Object {
      // A broken file: start empty, kept beside as journal.json.broken.
      await setAside(_file);
    }
    changes.value++;
  }

  static var _n = 0;

  /// A new id: when, and a count (two in the same millisecond differ).
  static String newId() => 'j${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_n++).toRadixString(36)}';

  /// Keep [entry]: a new one first, one written before in its place.
  Future<void> put(JournalEntry entry) async {
    final i = _all.indexWhere((e) => e.id == entry.id);
    _all = i < 0 ? [entry, ..._all] : [..._all.sublist(0, i), entry, ..._all.sublist(i + 1)];
    await _save();
  }

  Future<void> remove(String id) async {
    _all = [for (final e in _all) if (e.id != id) e];
    await _save();
  }

  /// Book [bookId]'s entries gone (a book on a secret shelf removed).
  Future<void> removeBook(String bookId) async {
    if (!_all.any((e) => e.bookId == bookId)) return;
    _all = [for (final e in _all) if (e.bookId != bookId) e];
    await _save();
  }

  /// Book [from]'s entries are book [to]'s, each at [place] of where it was
  /// written, in [chapterOf] that place's chapter (a web novel moved to
  /// another source; a book's file replaced).
  Future<void> rebook(String from, String to, ReadingCursor Function(ReadingCursor at) place,
      {int Function(ReadingCursor at)? chapterOf}) async {
    if (!_all.any((e) => e.bookId == from)) return;
    _all = [
      for (final e in _all)
        if (e.bookId != from)
          e
        else
          () {
            final at = place(e.stamp.at);
            return e.copyWith(bookId: to, stamp: e.stamp.movedTo(at, chapterOf?.call(at) ?? at.sectionIndex));
          }(),
    ];
    await _save();
  }

  Future<void> _save() async {
    changes.value++;
    if (RestoreGate.shut || _file == null) return;
    try {
      await writeSafely(_file, jsonEncode([for (final e in _all) e.toJson()]));
    } on Object {
      // Kept in memory until the next change.
    }
  }
}
