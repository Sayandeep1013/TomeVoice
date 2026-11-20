import 'dart:isolate';

import '../../journal.dart';
import '../ai_client.dart';
import '../ai_keys.dart';
import '../ai_report.dart';
import '../ai_router.dart';
import '../memory/memory_db.dart';
import '../talk/answer_pack.dart';
import '../talk/talk_engine.dart' show AnswerLength, citeMarks, citeNumbers;
import 'chat_store.dart';
import 'chat_tools.dart';

Future<List<PackItem>> _packOff(PackInput input) => Isolate.run(() => buildPack(input));
Future<void> _noteAskedOff(String path, String question, int? ch) => Isolate.run(() => noteAsked(path, question, ch));

/// How an answer is going, for the screen.
class ChatProgress {
  ChatProgress(this.message);

  final ChatMessage message;

  /// Asked to stop: what came so far stays, nothing more is asked.
  bool stopped = false;
}

/// The conversation's brain: each question answered by the Talking key,
/// which is given a small pack of what bears on it and may call tools to
/// look further (the books' memories, Who's who, the graph, the journal,
/// earlier chats), a few rounds at most, every look kept to each book's
/// spoiler line by the app, not the model.
///
/// Older messages are folded into a running summary (a cheap call to the
/// Building key) so a long chat stays within what a model can take.
class ChatEngine {
  ChatEngine({
    required this.chat,
    required this.books,
    AiRouter? router,
    ChatStore? store,
    JournalStore? journal,
    this.ownKnowledge = false,
    this.length = AnswerLength.normal,
    this.useJournal = true,
    this.usePast = true,
    this.mayRemember = true,
    this.stream = true,
  })  : router = router ?? AiRouter(about: 'AI chat'),
        store = store ?? ChatStore.instance,
        journal = journal ?? JournalStore.instance;

  final Chat chat;

  /// The books in scope, by key (b1, b2…).
  final Map<String, ChatBook> books;
  final AiRouter router;
  final ChatStore store;
  final JournalStore journal;
  final bool ownKnowledge;
  final AnswerLength length;
  final bool useJournal;
  final bool usePast;
  final bool mayRemember;

  /// Answers shown as they come (off in tests, whose provider does not
  /// stream).
  final bool stream;

  /// Rounds of tool calls before an answer is asked for outright.
  static const maxRounds = 6;

  /// Messages sent as they were; those before are in the summary.
  static const keptVerbatim = 10;

  /// Keys whose provider turned tools down: asked without them after.
  static final _noTools = <String>{};

  ChatBook? _bookOf(Map<String, Object?> args) {
    final k = '${args['book'] ?? ''}'.trim().toLowerCase();
    if (books.length == 1) return books.values.first;
    return books[k] ?? books.values.where((b) => b.title.toLowerCase() == k).firstOrNull;
  }

  Map<String, ChatBook> get _byId => {for (final b in books.values) b.id: b};

  /// Every source the chat has cited so far, by number.
  Map<int, ChatSource> get _known => {for (final m in chat.messages) ...m.sources};

  int get _next => _known.keys.fold(0, (a, b) => a > b ? a : b) + 1;

  String _system() {
    final many = books.length > 1;
    final notes = mayRemember ? store.notes : const <ReaderNote>[];
    return [
      'You are the reading companion in TomeVoice, an app where people listen to and read books. You are talking '
          'with the reader in their AI chat. Be warm, direct and specific, like a friend who has read closely. '
          'Keep to what they ask.',
      if (books.isEmpty)
        'No book has a memory yet. Help as you can, and tell them that building a book\'s memory (on its page, '
            'Memory) lets you answer about it.'
      else
        'This chat is about ${many ? 'these books' : 'this book'}:\n${books.values.map((b) => '- ${b.describe}').join('\n')}',
      ownKnowledge
          ? 'Use the material given and what your tools find first. You may add what you know of these books from '
              'elsewhere, and say when you do.'
          : "Use only the material given and what your tools find in the books' memories and the reader's own "
              'notes. Do not use anything you may know of these books from elsewhere. If nothing says, tell the '
              'reader plainly that you do not remember that part yet.',
      'Spoilers: for a book with its guard on, never reveal, hint at or guess anything after the chapter given. '
          'The tools already stop there.',
      'Look things up before answering when the material given is not enough: who_is for a name, connections '
          'for how people are tied, events and chapter_notes for what happened, search_text for exact words'
          '${useJournal ? ', search_journal for what the reader wrote' : ''}'
          '${usePast ? ', search_past_chats when they refer to an earlier talk' : ''}. '
          'Do not call a tool for small talk.',
      if (mayRemember)
        'When the reader tells you something lasting about themselves (a taste, an opinion of a book, how they '
            'like answers), keep it with the remember tool, briefly, without making a fuss of it.',
      if (notes.isNotEmpty)
        'What you have kept about this reader (theirs to delete):\n${notes.take(30).map((n) => '- ${n.text}'
            '${n.bookTitle == null ? '' : ' (about "${n.bookTitle}")'}').join('\n')}',
      'After each sentence that rests on the material, cite it as [S3] (several: [S3, S7]). Cite only numbers '
          'given to you.${many ? ' Say which book something is from.' : ''}',
      length.ask,
      aiSafetyRule,
    ].join('\n\n');
  }

  /// Items rendered for the model, each numbered as a source, the sources
  /// kept in [into].
  String _render(List<PackItem> items, ChatBook? book, Map<int, ChatSource> into, {String? chatId}) {
    final many = books.length > 1;
    final b = StringBuffer();
    String? section;
    var n = into.keys.fold(_next - 1, (a, c) => a > c ? a : c) + 1;
    for (final i in items) {
      final head = book != null && many ? '${i.section} (${book.title})' : i.section;
      if (head != section) {
        section = head;
        b.writeln('\n## $head');
      }
      final p = i.place;
      final label = i.label ??
          (p == null
              ? (chatId != null ? 'A chat' : i.section)
              : many && book != null
                  ? '${book.title} · ${chapterLabel(p.chapter)}'
                  : chapterLabel(p.chapter));
      into[n] = ChatSource(
        n: n,
        label: label,
        bookId: p == null ? null : book?.id,
        chapter: p?.chapter,
        section: p?.section,
        block: p?.block ?? 0,
        sentence: p?.sentence ?? 0,
        chatId: chatId,
      );
      b.writeln('[S$n] ${i.text}');
      n++;
    }
    return b.toString().trim();
  }

  /// What is sent before any tool: for each book (a few at most), what its
  /// memory says that bears on [question]; the journal entries that do.
  Future<String> _pack(String question, Map<int, ChatSource> into) async {
    final parts = <String>[];
    final shown = books.values.where((b) => b.hasMemory).take(4).toList();
    for (final b in shown) {
      try {
        final items = await _packOff(PackInput(
          path: b.memoryPath,
          question: question,
          line: b.line,
          here: b.here,
          maxCards: shown.length == 1 ? 8 : 3,
        ));
        final kept = shown.length == 1 ? items : items.take(8).toList();
        if (kept.isNotEmpty) parts.add(_render(kept, b, into));
      } on Object {
        // That book's memory could not be read: the tools may still.
      }
    }
    if (useJournal) {
      final hits = journalHits(journal.all, _byId, question, max: 5);
      if (hits.isNotEmpty) {
        parts.add(_render([
          for (final h in hits)
            PackItem("The reader's journal",
                '${h.entry.bookTitle}, ${h.entry.stamp.label}, ${h.entry.created.toLocal().toString().substring(0, 10)}: ${h.text}',
                label: 'Journal'),
        ], null, into));
      }
    }
    return parts.join('\n\n');
  }

  /// The chat so far as messages: the summary of the older part, then the
  /// last few as they were (failed and held-back ones left out).
  List<Map<String, Object?>> _history() {
    // Up to the question being asked, which is sent apart.
    final upTo = chat.messages.lastIndexWhere((m) => m.mine).clamp(0, chat.messages.length);
    final from = (upTo - keptVerbatim).clamp(chat.summarisedAt.clamp(0, upTo), upTo);
    return [
      if (chat.summary != null && chat.summary!.trim().isNotEmpty)
        aiMessage('system', 'Earlier in this chat (summary): ${chat.summary}'),
      for (final m in chat.messages.sublist(from, upTo))
        if (m.error == null && !m.held && m.text.trim().isNotEmpty) aiMessage(m.mine ? 'user' : 'assistant', m.text),
    ];
  }

  /// Answers the last message of the chat (the reader's) into [p.message]:
  /// [onChange] as the text comes and each look is made.
  Future<void> answer(ChatProgress p, {required void Function() onChange}) async {
    final reply = p.message;
    final question = chat.messages.lastWhere((m) => m.mine).text;
    final sources = <int, ChatSource>{};
    final material = await _pack(question, sources);
    final messages = [
      aiMessage('system', _system()),
      ..._history(),
      aiMessage('user', '${material.isEmpty ? '' : 'Material:\n$material\n\n---\n'}The reader says: $question'),
    ];
    final key = router.ring.forJob(AiJob.talker).firstOrNull;
    var tools = key != null && !_noTools.contains(key.id);
    final offered = chatTools(journal: useJournal, past: usePast, remember: mayRemember);
    var text = '';
    for (var round = 0; round <= maxRounds; round++) {
      if (p.stopped) break;
      final last = round == maxRounds;
      if (last) messages.add(aiMessage('user', 'Answer now, from what you have found.'));
      final AiReply r;
      try {
        r = await router.chat(AiJob.talker, messages, tools: tools && !last ? offered : const [], onText: !stream ? null : (piece) {
          if (p.stopped) return;
          reply.text += piece;
          if (aiAnswerHeld(reply.text)) reply.held = true;
          onChange();
        });
      } on AiResting catch (e) {
        // A provider that turns tools down: once more without them.
        if (tools && e.last?.kind == AiFailure.request) {
          if (key != null) _noTools.add(key.id);
          tools = false;
          reply.text = '';
          continue;
        }
        rethrow;
      }
      if (r.toolCalls.isEmpty || p.stopped) {
        text = r.text.trim();
        break;
      }
      // Words said before the tool calls ("Let me look…") are not the answer.
      reply.text = '';
      messages.add(r.asMessage);
      for (final call in r.toolCalls) {
        final args = call.args;
        final book = _bookOf(args);
        reply.looked.add(lookedLabel(call.name, args, book, many: books.length > 1));
        onChange();
        messages.add(aiToolAnswer(call.id, await _run(call.name, args, book, sources)));
      }
    }
    if (!p.stopped) reply.text = text.isEmpty ? reply.text.trim() : text;
    reply.held = reply.held || aiAnswerHeld(reply.text);
    // The sources the answer cites, wherever in the chat they were given.
    final all = {..._known, ...sources};
    reply.sources = {
      for (final m in citeMarks.allMatches(reply.text))
        for (final n in citeNumbers(m.group(0)!))
          if (all[n] != null) n: all[n]!,
    };
    if (reply.text.trim().isEmpty && !p.stopped) {
      reply.error = 'The AI sent back no answer. Ask again, or try another model.';
    }
    // Asked about one book: kept with its memory, for "you asked this before".
    if (books.length == 1 && !p.stopped) {
      final b = books.values.first;
      if (b.hasMemory && MemoryDb.existsAt(b.memoryPath)) {
        try {
          await _noteAskedOff(b.memoryPath, question, b.here);
        } on Object {
          // Only a convenience.
        }
      }
    }
  }

  /// One tool's answer, as the model reads it.
  Future<String> _run(String name, Map<String, Object?> args, ChatBook? book, Map<int, ChatSource> into) async {
    try {
      switch (name) {
        case 'list_books':
          return books.isEmpty ? 'No book has a memory yet.' : books.values.map((b) => b.describe).join('\n');
        case 'search_journal':
          final only = '${args['book'] ?? ''}'.trim().isEmpty ? null : _bookOf(args);
          final scope = only == null ? _byId : {only.id: only};
          final hits = journalHits(journal.all, scope, '${args['query'] ?? ''}');
          if (hits.isEmpty) return 'Nothing in the journal matches.';
          return _render([
            for (final h in hits)
              PackItem("The reader's journal",
                  '${h.entry.bookTitle}, ${h.entry.stamp.label}, ${h.entry.created.toLocal().toString().substring(0, 10)}: ${h.text}',
                  label: 'Journal'),
          ], null, into);
        case 'search_past_chats':
          final hits = pastHits(store.all, journal.all, '${args['query'] ?? ''}', notChat: chat.id);
          if (hits.isEmpty) return 'No earlier chat matches.';
          final b = StringBuffer();
          for (final h in hits) {
            b.writeln(_render([PackItem('Earlier chats', '${h.label}: ${h.text}', label: 'Earlier chat')], null, into,
                chatId: h.chatId));
          }
          return b.toString().trim();
        case 'remember':
          final about = '${args['book'] ?? ''}'.trim().isEmpty ? null : _bookOf(args);
          final note = await store.remember('${args['note'] ?? ''}',
              bookId: about?.id, bookTitle: about?.title, chatId: chat.id);
          return note == null ? 'Nothing kept.' : 'Kept.';
      }
      if (book == null) {
        return 'Say which book, by its key: ${books.values.map((b) => '${b.key} "${b.title}"').join(', ')}.';
      }
      final items = await bookToolOff(book, name, args);
      return items.isEmpty ? 'Nothing found.' : _render(items, book, into);
    } on Object catch (e) {
      return 'That could not be looked up: $e';
    }
  }

  /// Folds all but the last few messages into the summary, with the
  /// Building key, once enough have gathered. Quiet when it cannot.
  Future<bool> compact({int every = 16}) async {
    final keep = chat.messages.length - keptVerbatim;
    if (keep - chat.summarisedAt < every) return false;
    return _summarise(keep);
  }

  /// A summary of the whole chat, for finding it again: made when a chat
  /// with a few answers is left without one.
  Future<bool> summariseOnLeave() async {
    if (chat.answers < 2 || chat.summarisedAt >= chat.messages.length) return false;
    return _summarise(chat.messages.length);
  }

  Future<bool> _summarise(int upTo) async {
    final part = [
      for (final m in chat.messages.sublist(chat.summarisedAt.clamp(0, upTo), upTo))
        if (m.error == null && !m.held && m.text.trim().isNotEmpty)
          '${m.mine ? 'Reader' : 'AI'}: ${m.text.replaceAll(citeMarks, '')}',
    ].join('\n');
    if (part.trim().isEmpty) return false;
    final job = router.ring.forJob(AiJob.builder).isNotEmpty ? AiJob.builder : AiJob.talker;
    try {
      final r = await router.chat(job, [
        aiMessage(
            'system',
            'Summarise a conversation between a reader and their reading companion, in at most 150 words, in the '
                'third person. Keep names, chapters, the questions asked, conclusions reached, and anything the '
                'reader said about themselves. No preamble.'),
        aiMessage('user', '${chat.summary == null ? '' : 'Summary so far: ${chat.summary}\n\nThen:\n'}$part'),
      ], maxTokens: 400);
      final s = r.text.trim();
      if (s.isEmpty) return false;
      chat
        ..summary = s
        ..summarisedAt = upTo;
      await store.put(chat);
      return true;
    } on Object {
      return false;
    }
  }
}

/// A chat's name from its first question: its first line, cut short.
String chatTitleFrom(String question) {
  final t = question.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return 'New chat';
  return t.length <= 48 ? t : '${t.substring(0, 46).trimRight()}…';
}
