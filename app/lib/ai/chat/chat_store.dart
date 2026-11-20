import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../safe_file.dart';

/// A place an answer cites, as [S3]: a book, and where in it.
class ChatSource {
  const ChatSource({
    required this.n,
    required this.label,
    this.bookId,
    this.chapter,
    this.section,
    this.block = 0,
    this.sentence = 0,
    this.chatId,
  });

  final int n;

  /// How the chip reads: "ch 12", "Book One · ch 4", "Journal", "A chat".
  final String label;
  final String? bookId;
  final int? chapter;
  final int? section;
  final int block;
  final int sentence;

  /// An earlier chat it came from (search_past_chats).
  final String? chatId;

  bool get inBook => bookId != null && section != null;

  Map<String, Object?> toJson() => {
        'n': n,
        'label': label,
        if (bookId != null) 'book': bookId,
        if (chapter != null) 'ch': chapter,
        if (section != null) 'sec': section,
        if (block != 0) 'blk': block,
        if (sentence != 0) 'sen': sentence,
        if (chatId != null) 'chat': chatId,
      };

  static ChatSource? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = (j['n'] as num?)?.toInt();
    if (n == null) return null;
    return ChatSource(
      n: n,
      label: '${j['label'] ?? ''}',
      bookId: j['book'] as String?,
      chapter: (j['ch'] as num?)?.toInt(),
      section: (j['sec'] as num?)?.toInt(),
      block: (j['blk'] as num?)?.toInt() ?? 0,
      sentence: (j['sen'] as num?)?.toInt() ?? 0,
      chatId: j['chat'] as String?,
    );
  }
}

/// One message: the reader's, or the AI's with what it cites and where it
/// looked.
class ChatMessage {
  ChatMessage({
    required this.mine,
    required this.text,
    DateTime? at,
    Map<int, ChatSource>? sources,
    List<String>? looked,
    this.error,
    this.held = false,
  })  : at = at ?? DateTime.now().toUtc(),
        sources = sources ?? {},
        looked = looked ?? [];

  final bool mine;
  String text;
  final DateTime at;
  Map<int, ChatSource> sources;

  /// Where the AI looked for this answer, in a few words each ("Who's who:
  /// Sunny", "your journal").
  List<String> looked;

  /// Why there is no answer, when there is none.
  String? error;

  /// Held back by the check (aiAnswerHeld) or reported: not shown again.
  bool held;

  Map<String, Object?> toJson() => {
        'by': mine ? 'me' : 'ai',
        'text': text,
        'at': at.toIso8601String(),
        if (sources.isNotEmpty) 'sources': [for (final s in sources.values) s.toJson()],
        if (looked.isNotEmpty) 'looked': looked,
        if (error != null) 'error': error,
        if (held) 'held': true,
      };

  static ChatMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    return ChatMessage(
      mine: j['by'] == 'me',
      text: '${j['text'] ?? ''}',
      at: DateTime.tryParse('${j['at']}') ?? DateTime.now().toUtc(),
      sources: {
        for (final s in (j['sources'] as List?) ?? const [])
          if (ChatSource.fromJson(s) case final s?) s.n: s,
      },
      looked: [for (final l in (j['looked'] as List?) ?? const []) '$l'],
      error: j['error'] as String?,
      held: j['held'] == true,
    );
  }
}

/// A conversation with the AI: about one book, several, or the whole
/// library ([books] empty).
class Chat {
  Chat({
    required this.id,
    required this.title,
    required this.books,
    DateTime? created,
    DateTime? updated,
    List<ChatMessage>? messages,
    this.summary,
    this.summarisedAt = 0,
    this.pinned = false,
    this.titled = false,
  })  : created = created ?? DateTime.now().toUtc(),
        updated = updated ?? DateTime.now().toUtc(),
        messages = messages ?? [];

  final String id;
  String title;

  /// The books it is about, by id; empty: every book with a memory.
  List<String> books;
  final DateTime created;
  DateTime updated;
  final List<ChatMessage> messages;

  /// What was said before the last few messages, in a paragraph: sent in
  /// their place, and what an earlier chat is found by.
  String? summary;

  /// How many messages [summary] covers.
  int summarisedAt;
  bool pinned;

  /// Named by the reader (or the AI): no longer named after its first
  /// question.
  bool titled;

  bool get wholeLibrary => books.isEmpty;

  /// The reader's first question.
  String get opening => messages.where((m) => m.mine).firstOrNull?.text ?? '';

  /// The answers it has (not failed or held back).
  int get answers => messages.where((m) => !m.mine && m.error == null && !m.held && m.text.trim().isNotEmpty).length;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'books': books,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'messages': [for (final m in messages) m.toJson()],
        if (summary != null) 'summary': summary,
        if (summarisedAt > 0) 'summarisedAt': summarisedAt,
        if (pinned) 'pinned': true,
        if (titled) 'titled': true,
      };

  static Chat? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    return Chat(
      id: j['id'] as String,
      title: '${j['title'] ?? ''}',
      books: [for (final b in (j['books'] as List?) ?? const []) '$b'],
      created: DateTime.tryParse('${j['created']}'),
      updated: DateTime.tryParse('${j['updated']}'),
      messages: [
        for (final m in (j['messages'] as List?) ?? const [])
          if (ChatMessage.fromJson(m) case final m?) m,
      ],
      summary: j['summary'] as String?,
      summarisedAt: (j['summarisedAt'] as num?)?.toInt() ?? 0,
      pinned: j['pinned'] == true,
      titled: j['titled'] == true,
    );
  }
}

/// Something the AI keeps about the reader, across chats: what they like,
/// what they think of a book, how they like answers. Shown, and each one
/// deletable, in AI chat.
class ReaderNote {
  const ReaderNote({required this.id, required this.text, required this.made, this.bookId, this.bookTitle, this.chatId});

  final String id;
  final String text;
  final DateTime made;

  /// The book it is about, if one.
  final String? bookId;
  final String? bookTitle;

  /// The chat it was kept from.
  final String? chatId;

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'made': made.toIso8601String(),
        if (bookId != null) 'book': bookId,
        if (bookTitle != null) 'bookTitle': bookTitle,
        if (chatId != null) 'chat': chatId,
      };

  static ReaderNote? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['text'] is! String) return null;
    return ReaderNote(
      id: j['id'] as String,
      text: j['text'] as String,
      made: DateTime.tryParse('${j['made']}') ?? DateTime.now().toUtc(),
      bookId: j['book'] as String?,
      bookTitle: j['bookTitle'] as String?,
      chatId: j['chat'] as String?,
    );
  }
}

/// Every chat, a file each in `chats/` beside the library (so a backup
/// carries them), and the notes the AI keeps about the reader
/// (`chats/notes.json`).
class ChatStore {
  ChatStore._();

  static final instance = ChatStore._();

  /// Bumped on every change.
  final changes = ValueNotifier<int>(0);

  Directory? _dir;
  final _chats = <String, Chat>{};
  List<ReaderNote> _notes = const [];

  /// Every chat, the pinned first, then the latest.
  List<Chat> get all => _chats.values.toList()
    ..sort((a, b) => a.pinned != b.pinned ? (a.pinned ? -1 : 1) : b.updated.compareTo(a.updated));

  Chat? byId(String id) => _chats[id];

  List<ReaderNote> get notes => _notes;

  @visibleForTesting
  void reset() {
    _dir = null;
    _chats.clear();
    _notes = const [];
    changes.value++;
  }

  Future<void> attach(Directory root) async {
    final dir = Directory('${root.path}/chats');
    _dir = dir;
    _chats.clear();
    _notes = const [];
    try {
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          try {
            final raw = jsonDecode(await f.readAsString());
            if (f.uri.pathSegments.last == 'notes.json') {
              _notes = [
                for (final n in (raw as List))
                  if (ReaderNote.fromJson(n) case final n?) n,
              ];
            } else if (Chat.fromJson(raw) case final c?) {
              _chats[c.id] = c;
            }
          } on Object {
            await setAside(f);
          }
        }
      }
    } on Object {
      // No chats to read: start with none.
    }
    changes.value++;
  }

  static var _n = 0;

  static String newId() => 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_n++).toRadixString(36)}';

  /// A new chat about [books] (empty: the whole library), not kept until
  /// something is said in it.
  Chat start(List<String> books) => Chat(id: newId(), title: 'New chat', books: [...books]);

  /// Keep [chat] (new, or changed).
  Future<void> put(Chat chat) async {
    chat.updated = DateTime.now().toUtc();
    _chats[chat.id] = chat;
    changes.value++;
    final dir = _dir;
    if (dir == null || RestoreGate.shut) return;
    try {
      await dir.create(recursive: true);
      await writeSafely(File('${dir.path}/${chat.id}.json'), jsonEncode(chat.toJson()));
    } on Object {
      // Kept in memory until the next change.
    }
  }

  Future<void> remove(String id) async {
    _chats.remove(id);
    changes.value++;
    final dir = _dir;
    if (dir == null) return;
    try {
      final f = File('${dir.path}/$id.json');
      if (await f.exists()) await f.delete();
    } on Object {
      // Gone from the list; the file goes next time.
    }
  }

  /// Keep a note about the reader; the same words twice are kept once.
  Future<ReaderNote?> remember(String text, {String? bookId, String? bookTitle, String? chatId}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    final same = _notes.where((n) => n.text.toLowerCase() == t.toLowerCase()).firstOrNull;
    if (same != null) return same;
    final note = ReaderNote(
      id: 'n${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_n++).toRadixString(36)}',
      text: t.length > 300 ? t.substring(0, 300) : t,
      made: DateTime.now().toUtc(),
      bookId: bookId,
      bookTitle: bookTitle,
      chatId: chatId,
    );
    _notes = [note, ..._notes];
    await _saveNotes();
    return note;
  }

  Future<void> forget(String noteId) async {
    _notes = [for (final n in _notes) if (n.id != noteId) n];
    await _saveNotes();
  }

  Future<void> forgetAll() async {
    _notes = const [];
    await _saveNotes();
  }

  Future<void> _saveNotes() async {
    changes.value++;
    final dir = _dir;
    if (dir == null || RestoreGate.shut) return;
    try {
      await dir.create(recursive: true);
      await writeSafely(File('${dir.path}/notes.json'), jsonEncode([for (final n in _notes) n.toJson()]));
    } on Object {
      // Kept in memory until the next change.
    }
  }
}
