import '../../journal.dart';
import '../../library_store.dart' show LibraryEntry;
import '../../prefs.dart';
import '../memory/memory_db.dart';
import '../memory/memory_service.dart';
import '../talk/talk_engine.dart' show citeMarks, citeNumbers;
import 'chat_store.dart';
import 'chat_tools.dart';

/// The books a chat may be about: those with a memory that may be sent to
/// the AI (not on a secret shelf, not kept away from it), the latest read
/// first.
Future<List<LibraryEntry>> chatableBooks({MemoryService? service}) async {
  final s = service ?? MemoryService.instance;
  final books = [for (final b in await s.booksWithMemory()) if (s.maySend(b.id)) b];
  books.sort((a, b) => (b.openedAt ?? b.addedAt).compareTo(a.openedAt ?? a.addedAt));
  return books;
}

/// [ids] as a chat sees them (empty: every book it may be about), each with
/// a key for the model, its memory and its spoiler line.
Future<Map<String, ChatBook>> chatBooksFor(List<String> ids, {MemoryService? service}) async {
  final s = service ?? MemoryService.instance;
  final all = await chatableBooks(service: s);
  final chosen = ids.isEmpty ? all : [for (final id in ids) ...all.where((b) => b.id == id)];
  final out = <String, ChatBook>{};
  for (final (i, b) in chosen.indexed) {
    final key = 'b${i + 1}';
    final path = s.pathOf(b.id);
    out[key] = ChatBook(
      key: key,
      id: b.id,
      title: b.title,
      authors: b.authors.join(', '),
      memoryPath: path,
      line: await s.lineOf(b.id),
      here: await s.hereOf(b.id),
      hasMemory: MemoryDb.existsAt(path),
    );
  }
  return out;
}

/// An answer as the journal keeps it: its [S3] marks as the chapters they
/// named, no markdown.
String journalText(ChatMessage m) => m.text
    .replaceAllMapped(citeMarks, (x) {
      final labels = {
        for (final n in citeNumbers(x.group(0)!))
          if (m.sources[n] case final s? when s.inBook) s.label,
      };
      return labels.isEmpty ? '' : ' (${labels.join(', ')})';
    })
    .replaceAll('**', '')
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .replaceAllMapped(RegExp(r'\s+([.,;:!?])'), (x) => x.group(1)!)
    .trim();

/// The journal entry a chat about one book is kept as.
String journalIdOf(Chat chat) => 'chat-${chat.id}';

/// A chat about one book kept in that book's journal (as Talk's talks are),
/// one entry a chat, brought up to date as it goes on; stamped where the
/// reader was when it began. Off when Keep talks in the journal is.
Future<void> keepChatInJournal(Chat chat, {JournalStore? journal, MemoryService? service}) async {
  final j = journal ?? JournalStore.instance;
  if (!(ListeningPrefs.loaded?.aiKeepTalks ?? true) || chat.books.length != 1) return;
  final lines = [
    for (final m in chat.messages)
      if (m.error == null && !m.held && m.text.trim().isNotEmpty) TalkLine(mine: m.mine, text: m.mine ? m.text.trim() : journalText(m)),
  ];
  if (!lines.any((l) => !l.mine)) return;
  final id = journalIdOf(chat);
  final before = j.all.where((e) => e.id == id).firstOrNull;
  final s = service ?? MemoryService.instance;
  final bookId = chat.books.first;
  final stamp = before?.stamp ?? await s.stampOf(bookId);
  if (stamp == null) return;
  final title = before?.bookTitle ?? (await chatableBooks(service: s)).where((b) => b.id == bookId).firstOrNull?.title;
  if (title == null) return;
  await j.put(JournalEntry(
    id: id,
    bookId: bookId,
    bookTitle: title,
    created: before?.created ?? chat.created,
    stamp: stamp,
    talk: lines,
  ));
}
