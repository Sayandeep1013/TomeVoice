import 'dart:isolate';

import '../../journal.dart';
import '../ai_client.dart';
import '../memory/graph.dart' show describedAt, normName;
import '../memory/memory_db.dart';
import '../memory/theories.dart';
import '../talk/answer_pack.dart';
import 'chat_store.dart';

/// A book a chat is about, as the chat sees it: its memory, and how far the
/// reader may be told ([line], null when its spoiler guard is off).
class ChatBook {
  const ChatBook({
    required this.key,
    required this.id,
    required this.title,
    required this.memoryPath,
    this.authors = '',
    this.line,
    this.here = 0,
    this.hasMemory = true,
  });

  /// How the model names it in a tool call: "b1", "b2"…
  final String key;
  final String id;
  final String title;
  final String authors;
  final String memoryPath;

  /// The furthest chapter (from 0) the AI may speak of; null: all of it.
  final int? line;

  /// The chapter the reader is at (from 0).
  final int here;
  final bool hasMemory;

  String get describe => '$key: "$title"${authors.isEmpty ? '' : ' by $authors'}, the reader is at chapter ${here + 1}'
      '${line == null ? ' (spoiler guard off)' : ' (spoiler guard on: nothing after chapter ${line! + 1})'}'
      '${hasMemory ? '' : ' (no memory built yet)'}';
}

AiTool _bookTool(String name, String description, Map<String, Object?> props, List<String> required) => AiTool(
      name: name,
      description: description,
      parameters: {
        'type': 'object',
        'properties': {
          'book': {'type': 'string', 'description': 'Which book: its key from the list (b1, b2…).'},
          ...props,
        },
        'required': ['book', ...required],
      },
    );

/// The tools AI chat may call. Each reads only, and keeps to each book's
/// spoiler line, whatever the model asks.
List<AiTool> chatTools({required bool journal, required bool past, required bool remember}) => [
      const AiTool(
        name: 'list_books',
        description: 'The books this chat is about: key, title, how far the reader is, whether a memory is built.',
        parameters: {'type': 'object', 'properties': {}},
      ),
      _bookTool('search_text', "Search a book's text for words or a quoted phrase. Returns the places found.", {
        'query': {'type': 'string', 'description': 'Words to find; quote a phrase to keep it together.'},
      }, ['query']),
      _bookTool(
          'who_is',
          "Who's who: everything remembered of a character, place, group, item, power, title or term, by any of "
              'its names (aliases, titles, ranks), with its ties and key events.',
          {'name': {'type': 'string'}},
          ['name']),
      _bookTool(
          'cast',
          "The book's most important characters (or places, groups, items…), most mentioned first, each with a "
              'line about them.',
          {
            'kind': {
              'type': 'string',
              'description': 'Optional: person, place, group, item, creature, power, title or term.',
            },
          },
          const []),
      _bookTool(
          'connections',
          'The memory graph around a name: who and what it is tied to, and how (family, ally, enemy, member of, '
              'owns…), with when each tie began.',
          {'name': {'type': 'string'}},
          ['name']),
      _bookTool('events', 'The events someone or something took part in, in order, optionally between chapters.', {
        'name': {'type': 'string'},
        'from_chapter': {'type': 'integer'},
        'to_chapter': {'type': 'integer'},
      }, ['name']),
      _bookTool('chapter_notes', "Chapter summaries, one chapter or a stretch of up to ten.", {
        'chapter': {'type': 'integer', 'description': 'The chapter number as the reader counts it.'},
        'to_chapter': {'type': 'integer', 'description': 'Optional: the last chapter of a stretch.'},
      }, ['chapter']),
      _bookTool('read_chapter', "A chapter's own text, thirty passages from the one given.", {
        'chapter': {'type': 'integer'},
        'from_passage': {'type': 'integer'},
      }, ['chapter']),
      _bookTool('thread', 'A mystery, promise or foreshadowing, step by step from where it was raised.', {
        'name': {'type': 'string'},
      }, ['name']),
      _bookTool("theories", "The reader's own theories about the book, and how the story has treated each so far.",
          const {}, const []),
      if (journal)
        const AiTool(
          name: 'search_journal',
          description: "Search the reader's reading journal: what they wrote while reading (feelings, thoughts, "
              'predictions), with the chapter they were at. Leave the query empty for their latest entries.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'book': {'type': 'string', 'description': 'Optional: one book, by its key.'},
            },
          },
        ),
      if (past)
        const AiTool(
          name: 'search_past_chats',
          description: 'Search earlier conversations with the reader (chats and talks from the reader) for what '
              'was said before. Use it when they refer to an earlier talk ("like we said", "last time").',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
            },
            'required': ['query'],
          },
        ),
      if (remember)
        const AiTool(
          name: 'remember',
          description: 'Keep a short note about the reader for later chats: a lasting preference or opinion they '
              'stated ("prefers short answers", "dislikes the love triangle in b1"). Only what they said about '
              'themselves; never facts from the book. The reader can see and delete every note.',
          parameters: {
            'type': 'object',
            'properties': {
              'note': {'type': 'string', 'description': 'One short sentence, in the third person.'},
              'book': {'type': 'string', 'description': 'Optional: the book it is about, by its key.'},
            },
            'required': ['note'],
          },
        ),
    ];

/// The few words shown under an answer for a tool call ("Who's who:
/// Sunny").
String lookedLabel(String name, Map<String, Object?> args, ChatBook? book, {bool many = false}) {
  final of = many && book != null ? ' in ${book.title}' : '';
  String q(String k) => '${args[k] ?? ''}'.trim();
  return switch (name) {
    'list_books' => 'Your books',
    'search_text' => 'Searched the text for "${q('query')}"$of',
    'who_is' => "Who's who: ${q('name')}$of",
    'cast' => 'The cast$of',
    'connections' => 'The graph around ${q('name')}$of',
    'events' => 'What ${q('name')} did$of',
    'chapter_notes' => 'Notes for chapter ${q('chapter')}${q('to_chapter').isEmpty ? '' : '–${q('to_chapter')}'}$of',
    'read_chapter' => 'Read chapter ${q('chapter')}$of',
    'thread' => 'The thread "${q('name')}"$of',
    'theories' => 'Your theories$of',
    'search_journal' => q('query').isEmpty ? 'Your journal' : 'Your journal, for "${q('query')}"',
    'search_past_chats' => 'Earlier chats, for "${q('query')}"',
    'remember' => 'Kept a note about you',
    _ => name,
  };
}

/// [name] run on a book's memory, off the UI thread.
Future<List<PackItem>> bookToolOff(ChatBook book, String name, Map<String, Object?> args) {
  final path = book.memoryPath;
  final line = book.line;
  return Isolate.run(() => bookTool(path, line, name, args));
}

/// What a book tool answers, within [line].
List<PackItem> bookTool(String path, int? line, String name, Map<String, Object?> args) {
  if (!MemoryDb.existsAt(path)) return [const PackItem('Memory', "This book's memory is not built yet.")];
  switch (name) {
    case 'who_is':
      return runTool(path, 'card', args, line);
    case 'chapter_notes':
      final from = (args['chapter'] as num?)?.toInt() ?? 1;
      final to = ((args['to_chapter'] as num?)?.toInt() ?? from).clamp(from, from + 9);
      return [
        for (var c = from; c <= to; c++) ...runTool(path, 'chapter_notes', {'chapter': c}, line),
      ];
    case 'cast':
      return castOf(path, line, '${args['kind'] ?? ''}');
    case 'connections':
      return connectionsOf(path, line, '${args['name'] ?? ''}');
    case 'theories':
      final at = line ?? 1 << 30;
      final all = theoriesAt(path, at);
      if (all.isEmpty) return [const PackItem('Theories', 'The reader has stated no theories about this book.')];
      return [
        for (final t in all)
          PackItem('Theories', '"${t.text}" (stated at ${chapterLabel(t.ch)}): ${t.status}'
              '${t.verdict == null ? '' : '. ${t.verdict}'}'),
      ];
    default:
      return runTool(path, name, args, line);
  }
}

/// The most mentioned entities, of [kind] if given.
List<PackItem> castOf(String path, int? line, String kind) {
  final m = MemoryDb.open(path);
  try {
    final at = line ?? 1 << 30;
    final k = kind.trim().toLowerCase();
    final rows = m.db.select(
      'SELECT id, kind, name, first_ch FROM entities WHERE merged_into IS NULL AND (first_ch IS NULL OR first_ch <= ?) '
      '${k.isEmpty ? '' : 'AND lower(kind) = ? '}ORDER BY mentions DESC LIMIT 25',
      [at, if (k.isNotEmpty) k],
    );
    if (rows.isEmpty) return [const PackItem('Cast', 'Nobody of that kind is known yet.')];
    return [
      for (final r in rows)
        PackItem(
          'Cast',
          '${r['name']} (${r['kind']}): ${asSentence(describedAt(m, r['id'] as int, at))}'
              'First met in ${chapterLabel((r['first_ch'] as int?) ?? 0)}.',
          place: (r['first_ch'] as int?) == null || (r['first_ch'] as int) < 0
              ? null
              : MemoryPlace(chapter: r['first_ch'] as int, section: r['first_ch'] as int),
        ),
    ];
  } finally {
    m.close();
  }
}

/// The ties of the entity called [name], as the graph keeps them.
List<PackItem> connectionsOf(String path, int? line, String name) {
  final m = MemoryDb.open(path);
  try {
    final at = line ?? 1 << 30;
    final norm = normName(name);
    final hit = m.db.select(
      'SELECT e.id FROM aliases a JOIN entities e ON e.id = a.entity WHERE a.norm = ? AND (a.ch IS NULL OR a.ch <= ?) '
      'ORDER BY e.mentions DESC LIMIT 1',
      [norm, at],
    );
    final idRows = hit.isNotEmpty
        ? hit
        : m.db.select(
            'SELECT id FROM entities WHERE merged_into IS NULL AND lower(name) LIKE ? AND (first_ch IS NULL OR first_ch <= ?) '
            'ORDER BY mentions DESC LIMIT 1',
            ['%${name.trim().toLowerCase()}%', at]);
    if (idRows.isEmpty) return [const PackItem('Connections', 'Nobody and nothing of that name is known yet.')];
    var id = idRows.first['id'] as int;
    // Followed to what it was merged into.
    for (var i = 0; i < 10; i++) {
      final r = m.db.select('SELECT merged_into FROM entities WHERE id = ?', [id]);
      final into = r.isEmpty ? null : r.first['merged_into'] as int?;
      if (into == null) break;
      id = into;
    }
    final rows = m.db.select(
      'SELECT r.rel, r.from_ch ch, r.until_ch, r.sec, r.blk, r.sen, r.note, ea.name an, eb.name bn FROM relations r '
      'JOIN entities ea ON ea.id = r.a JOIN entities eb ON eb.id = r.b '
      'WHERE (r.a = ? OR r.b = ?) AND r.from_ch <= ? ORDER BY r.from_ch LIMIT 40',
      [id, id, at],
    );
    if (rows.isEmpty) return [const PackItem('Connections', 'No ties of theirs are known yet.')];
    return [
      for (final r in rows)
        PackItem(
          'Connections',
          '${r['an']} ${r['rel']} ${r['bn']}${r['note'] == null ? '' : ' (${r['note']})'}, from ${chapterLabel(r['ch'] as int)}'
              '${r['until_ch'] != null && (r['until_ch'] as int) <= at ? ' until ${chapterLabel(r['until_ch'] as int)}' : ''}',
          place: r['sec'] == null
              ? null
              : MemoryPlace(
                  chapter: r['ch'] as int,
                  section: r['sec'] as int,
                  block: (r['blk'] as int?) ?? 0,
                  sentence: (r['sen'] as int?) ?? 0),
        ),
    ];
  } finally {
    m.close();
  }
}

/// How well [text] matches the words of [query]: the share of them in it.
double matchScore(String query, String text) {
  final words = searchWords(query).toLowerCase().split(' ').where((w) => w.length > 2).toSet();
  if (words.isEmpty) return 0;
  final t = text.toLowerCase();
  return words.where(t.contains).length / words.length;
}

/// The reader's journal entries (not talks) of [books], each within its
/// line, best matches of [query] first (the latest, with no query).
List<({JournalEntry entry, String text})> journalHits(
  List<JournalEntry> all,
  Map<String, ChatBook> books,
  String query, {
  int max = 8,
}) {
  final fit = [
    for (final e in all)
      if (!e.isTalk && books[e.bookId] case final b?)
        if (b.line == null || e.stamp.chapter <= b.line!) e,
  ];
  if (query.trim().isEmpty) {
    fit.sort((a, b) => b.created.compareTo(a.created));
    return [for (final e in fit.take(max)) (entry: e, text: e.words)];
  }
  final scored = [
    for (final e in fit)
      if (matchScore(query, '${e.bookTitle} ${e.words}') case final s when s > 0) (e, s),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (e, _) in scored.take(max)) (entry: e, text: e.words)];
}

/// Earlier chats and talks that bear on [query]: each a line to send and
/// where it came from.
List<({String label, String text, String? chatId})> pastHits(
  List<Chat> chats,
  List<JournalEntry> talks,
  String query, {
  String? notChat,
  int max = 5,
}) {
  final out = <(double, ({String label, String text, String? chatId}))>[];
  String day(DateTime d) => d.toLocal().toString().substring(0, 10);
  for (final c in chats) {
    if (c.id == notChat || c.answers == 0) continue;
    final body = [for (final m in c.messages) if (!m.held && m.error == null) '${m.mine ? 'Reader' : 'AI'}: ${m.text}']
        .join('\n');
    final s = matchScore(query, '${c.title} ${c.summary ?? ''} $body');
    if (s <= 0) continue;
    final text = c.summary ?? (body.length > 1200 ? '${body.substring(0, 1200)}…' : body);
    out.add((s, (label: 'Chat "${c.title}", ${day(c.created)}', text: text, chatId: c.id)));
  }
  for (final e in talks) {
    if (!e.isTalk || e.id.startsWith('chat-')) continue;
    final s = matchScore(query, '${e.bookTitle} ${e.words}');
    if (s <= 0) continue;
    final w = e.words;
    out.add((s, (label: 'Talk about ${e.bookTitle}, ${day(e.created)}', text: w.length > 1200 ? '${w.substring(0, 1200)}…' : w, chatId: null)));
  }
  out.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final (_, h) in out.take(max)) h];
}
