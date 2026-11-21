import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import '../../dictation.dart';
import '../../journal_page.dart' show tellOfDictation;
import '../../library_store.dart';
import '../../marks.dart';
import '../../prefs.dart';
import '../../reader_screen.dart' show openBook;
import '../../speech_service.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../voices.dart';
import '../ai_consent.dart';
import '../ai_report.dart';
import '../ai_router.dart';
import '../ai_screen.dart' show wakeTime;
import '../memory/memory_db.dart' show MemoryPlace;
import '../talk/talk_engine.dart' show AnswerLength, TalkSource, spokenAnswer, spokenPieces;
import '../talk/talk_sheet.dart' show CitedText;
import 'chat_engine.dart';
import 'chat_links.dart';
import 'chat_store.dart';
import 'chat_tools.dart';

/// One chat with the AI, full screen: what it is about at the top (one
/// book, a few, or all of them; changed with a tap), the conversation, and
/// a box to type or speak into. Each answer says where it looked, cites
/// its places (a tap opens the book there), and can be copied, read aloud
/// or reported.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.store,
    this.chat,
    this.books = const [],
    this.firstQuestion,
    this.chats,
    this.engineFor,
  });

  final LibraryStore store;

  /// A chat to carry on; null: a new one about [books].
  final Chat? chat;
  final List<String> books;
  final String? firstQuestion;
  final ChatStore? chats;

  /// For tests: the engine for a chat.
  final ChatEngine Function(Chat chat, Map<String, ChatBook> books)? engineFor;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  ChatStore get _store => widget.chats ?? ChatStore.instance;
  late final Chat _chat = widget.chat ?? _store.start(widget.books);
  Map<String, ChatBook>? _books;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  ChatProgress? _busy;
  Dictation? _dictation;
  final _noWords = ValueNotifier<String>('');
  final _notListening = ValueNotifier<bool>(false);
  int _saying = 0;
  String? _sayingText;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBooks().then((_) {
      final q = widget.firstQuestion;
      if (q != null && mounted) unawaited(_send(q));
    }));
    _input.addListener(_typed);
  }

  void _typed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _busy?.stopped = true;
    _hush();
    _dictation?.dispose();
    _noWords.dispose();
    _notListening.dispose();
    _input.removeListener(_typed);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    // A chat with a few answers is summarised as it is left, to be found by
    // later chats ("like we said").
    final books = _books;
    if (books != null && _chat.answers >= 2 && _chat.summary == null && !_store.wiped(_chat.id)) {
      unawaited(_engine(books).summariseOnLeave());
    }
    super.dispose();
  }

  Future<void> _loadBooks() async {
    final books = await chatBooksFor(_chat.books);
    if (mounted) setState(() => _books = books);
  }

  ChatEngine _engine(Map<String, ChatBook> books) =>
      widget.engineFor?.call(_chat, books) ??
      ChatEngine(
        chat: _chat,
        books: books,
        store: _store,
        ownKnowledge: _prefs.aiOwnKnowledge,
        length: AnswerLength.values.firstWhere((l) => l.name == _prefs.aiLength, orElse: () => AnswerLength.normal),
        useJournal: _prefs.aiUseJournal,
        usePast: _prefs.aiChatPast,
        mayRemember: _prefs.aiChatRemember,
      );

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
      }
    });
  }

  Future<void> _send(String text) async {
    final q = text.trim();
    final books = _books;
    if (q.isEmpty || _busy != null || books == null) return;
    if (!await ensureAiConsent(context) || !mounted) return;
    if (_dictation?.listening.value ?? false) await _dictation?.stop();
    final reply = ChatMessage(mine: false, text: '');
    final p = ChatProgress(reply);
    setState(() {
      _busy = p;
      _chat.messages
        ..add(ChatMessage(mine: true, text: q))
        ..add(reply);
      if (!_chat.titled && _chat.title == 'New chat') _chat.title = chatTitleFrom(q);
      _input.clear();
    });
    _toEnd();
    final engine = _engine(books);
    try {
      await engine.answer(p, onChange: () {
        if (mounted) setState(() {});
        _toEnd();
      });
      if (_prefs.aiSpeak && !reply.held && reply.error == null && !p.stopped) _say(reply.text);
    } on AiResting catch (e) {
      reply.error = e.until != null
          ? 'Every key has used its quota for now. Ask again at ${wakeTime(e.until!)}.'
          : e.last == null
              ? 'No key can talk yet: give one a model for Talking, in AI settings.'
              : 'The AI could not answer: ${e.last!.message}';
    } on Object catch (e) {
      reply.error = 'The AI could not answer: $e';
    } finally {
      if (p.stopped && reply.text.trim().isEmpty && reply.error == null) reply.error = 'Stopped.';
      if (mounted) setState(() => _busy = null);
      _toEnd();
      await _store.put(_chat);
      unawaited(keepChatInJournal(_chat));
      unawaited(engine.compact());
    }
  }

  void _stop() {
    final p = _busy;
    if (p == null) return;
    setState(() => p.stopped = true);
  }

  /// The last question asked again (after an error, or for another answer).
  Future<void> _again(ChatMessage answer) async {
    final i = _chat.messages.indexOf(answer);
    if (i < 1 || _busy != null) return;
    final q = _chat.messages[i - 1];
    if (!q.mine) return;
    setState(() => _chat.messages.removeRange(i - 1, i + 1));
    await _send(q.text);
  }

  // The voice: the first book's own, or the usual one of its language.
  /// The voice an answer is read in: the book's own, when it speaks the
  /// answer's language; else that language's usual voice; else the best
  /// one on the phone for it (as a book with no voice chosen reads).
  Future<String?> _voiceFor(String text) async {
    final catalog = VoiceCatalog.instance;
    await catalog.ensureLoaded();
    final language = answerLanguage(text);
    final books = _books;
    final first = books == null || books.isEmpty ? null : books.values.first.id;
    final own = catalog.byName(first == null ? null : _prefs.voiceByBook[first]);
    if (own != null && own.language == language) return own.name;
    final usual = catalog.byName(_prefs.voiceByLanguage[language]);
    if (usual != null && usual.language == language) return usual.name;
    return catalog.bestFor(language)?.name;
  }

  void _say(String text) {
    final me = ++_saying;
    setState(() => _sayingText = text);
    unawaited(() async {
      try {
        final voice = await _voiceFor(text);
        if (voice == null) {
          if (mounted && me == _saying) {
            showSnack(context, 'No voice on this phone reads this. Get one in the speech settings.');
          }
          return;
        }
        for (final piece in spokenPieces(spokenAnswer(text))) {
          if (me != _saying || !mounted) break;
          await speakSample(
            voiceName: voice,
            text: piece,
            settings: _prefs.settingsFor(voice, book: _books?.values.firstOrNull?.id),
            engineId: _prefs.engineId ?? VoiceCatalog.instance.engineId,
          );
        }
      } on Object {
        if (mounted && me == _saying) showSnack(context, 'The answer could not be read aloud.');
      } finally {
        if (mounted && me == _saying) setState(() => _sayingText = null);
      }
    }());
  }

  void _hush() {
    if (_sayingText == null) return;
    _saying++;
    _sayingText = null;
    unawaited(const SpeechService().stopPlayback());
  }

  Future<void> _speak() async {
    final d = _dictation ??= Dictation()
      ..onWords = (words) {
        if (!mounted) return;
        final t = _input.text.trimRight();
        _input.text = t.isEmpty ? words : '$t $words';
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      }
      ..onProblem = (p) {
        if (mounted) showSnack(context, p);
      };
    if (d.listening.value) {
      await d.stop();
      return;
    }
    if (!await tellOfDictation(context) || !mounted) return;
    _hush();
    await d.start();
    if (mounted) setState(() {});
  }

  /// A cited place opened in its book.
  Future<void> _look(ChatMessage m, MemoryPlace place) async {
    final s = m.sources.values
        .where((s) => s.section == place.section && s.block == place.block && s.sentence == place.sentence)
        .firstOrNull;
    final id = s?.bookId;
    if (id == null) return;
    final entry = (await widget.store.list(all: true)).where((e) => e.id == id).firstOrNull;
    if (entry == null || !mounted) return;
    await openBook(
      context,
      widget.store,
      entry,
      at: Mark(
        id: 'chat-look',
        bookId: entry.id,
        bookTitle: entry.title,
        kind: MarkKind.bookmark,
        at: ReadingCursor(sectionIndex: place.section, blockIndex: place.block, sentenceIndex: place.sentence),
        text: '',
        created: DateTime.now(),
      ),
    );
  }

  Future<void> _rename() async {
    final t = await askText(context, title: 'Name this chat', hint: _chat.title, initial: _chat.title);
    final name = t?.trim() ?? '';
    if (name.isEmpty || !mounted) return;
    setState(() {
      _chat
        ..title = name
        ..titled = true;
    });
    if (_chat.messages.isNotEmpty) await _store.put(_chat);
  }

  Future<void> _delete() async {
    if (!await confirmChatDelete(context, _chat, _store) || !mounted) return;
    _busy?.stopped = true;
    _hush();
    await deleteChatCompletely(_chat, store: _store);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _pickScope() async {
    final all = await chatableBooks();
    if (!mounted) return;
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ScopeSheet(books: all, chosen: _chat.books),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _chat.books = picked;
      _books = null;
    });
    await _loadBooks();
    if (_chat.messages.isNotEmpty) await _store.put(_chat);
  }

  String _scopeLabel() {
    final books = _books;
    if (books == null) return '…';
    if (_chat.wholeLibrary) return 'All your books';
    if (books.isEmpty) return 'No book';
    if (books.length == 1) return books.values.first.title;
    return '${books.length} books';
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final books = _books;
    final guard = books?.values.where((b) => b.line != null).toList() ?? const [];
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(
                title: _chat.title,
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) {
                      switch (v) {
                        case 'rename':
                          unawaited(_rename());
                        case 'pin':
                          setState(() => _chat.pinned = !_chat.pinned);
                          if (_chat.messages.isNotEmpty) unawaited(_store.put(_chat));
                        case 'delete':
                          unawaited(_delete());
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'pin', child: Text(_chat.pinned ? 'Unpin' : 'Pin to the top')),
                      if (_chat.messages.isNotEmpty) const PopupMenuItem(value: 'delete', child: Text('Delete chat')),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: Row(
                  children: [
                    Flexible(
                      child: ActionChip(
                        tooltip: 'What this chat is about',
                        avatar: const Icon(Icons.menu_book_rounded, size: 18),
                        label: Text('About: ${_scopeLabel()}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        onPressed: _busy == null ? () => unawaited(_pickScope()) : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (guard.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                  child: Text(
                    guard.length == 1 && books!.length == 1
                        ? 'Keeping to chapter ${guard.first.line! + 1}: no spoilers past where you are'
                        : 'No spoilers past where you are, in ${guard.length == books!.length ? 'each book' : '${guard.length} of them'}',
                    style: Skin.meta(context),
                  ),
                ),
              Expanded(
                child: _chat.messages.isEmpty
                    ? _empty(context)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.l),
                        itemCount: _chat.messages.length,
                        itemBuilder: (context, i) => _message(context, _chat.messages[i]),
                      ),
              ),
              _composer(context, bottom),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final books = _books;
    final one = books != null && books.length == 1;
    final prompts = [
      if (one) ...[
        'What just happened?',
        'Catch me up in two minutes',
        'Who are the main characters so far?',
        'What mysteries are still open?',
        'What did I write in my journal about it?',
      ] else ...[
        'What am I reading at the moment?',
        'Which of my books should I go back to next?',
        'What did I write in my journal lately?',
        'Compare the main characters of my books',
      ],
      'What did we talk about last time?',
      ..._prefs.aiPrompts,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.m, Gap.page, Gap.l),
      children: [
        Text(
          books != null && books.isEmpty
              ? "No book has a memory yet. Open a book's page and tap Memory: the AI reads it once and remembers "
                  'who is who and what happened. You can still ask about your journal and earlier chats.'
              : 'Ask anything. The AI looks into the memory, Who\'s who, the graph, your journal and earlier chats '
                  'when it needs to, and shows where it looked. Answers by AI can be wrong.',
          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45),
        ),
        const SizedBox(height: Gap.l),
        Wrap(
          spacing: Gap.s,
          runSpacing: Gap.s,
          children: [
            for (final s in prompts) ActionChip(label: Text(s), onPressed: () => unawaited(_send(s))),
          ],
        ),
      ],
    );
  }

  Widget _composer(BuildContext context, double bottom) {
    final listening = _dictation?.listening;
    final busy = _busy != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, Gap.s + bottom),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: _dictation?.heard ?? _noWords,
              builder: (context, heard, _) => TextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: heard.isNotEmpty ? heard : 'Ask, or tap the microphone and speak',
                ),
              ),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: listening ?? _notListening,
            builder: (context, on, _) => IconButton(
              tooltip: on ? 'Stop listening' : 'Speak',
              isSelected: on,
              icon: const Icon(Icons.mic_none_rounded),
              selectedIcon: Icon(Icons.mic_rounded, color: Skin.accentInkOf(context)),
              onPressed: () => unawaited(_speak()),
            ),
          ),
          busy
              ? IconButton(
                  tooltip: 'Stop',
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                )
              : IconButton(
                  tooltip: 'Send',
                  onPressed: _input.text.trim().isEmpty || _books == null ? null : () => unawaited(_send(_input.text)),
                  icon: const Icon(Icons.send_rounded),
                ),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, ChatMessage m) {
    if (m.mine) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: Gap.l, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: Skin.capsuleOn(context), borderRadius: BorderRadius.circular(18)),
          child: SelectableText(m.text, style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context))),
        ),
      );
    }
    final working = identical(_busy?.message, m);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.m, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.looked.isNotEmpty) _Looked(m.looked),
          if (m.error != null)
            Text(m.error!,
                style: Skin.ui(size: 14, weight: FontWeight.w500, color: Theme.of(context).colorScheme.error))
          else if (m.held)
            Text('This answer was held back: it may have broken the rules on harmful content.',
                style: Skin.label(context, size: 14))
          else if (m.text.isEmpty && working)
            Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: Gap.s),
                Text(m.looked.isEmpty ? 'Thinking…' : 'Looking…', style: Skin.meta(context)),
              ],
            )
          else
            CitedText(
              text: m.text,
              sources: {for (final s in m.sources.values) s.n: TalkSource(s.n, s.label, _placeOf(s))},
              onLook: (p) => unawaited(_look(m, p)),
            ),
          if (!working && (m.text.isNotEmpty || m.error != null) && !m.held)
            Wrap(
              spacing: Gap.s,
              children: [
                if (m.error == null) ...[
                  _act(Icons.copy_rounded, 'Copy', () {
                    unawaited(Clipboard.setData(ClipboardData(text: journalText(m))));
                    showSnack(context, 'Copied');
                  }),
                  _sayingText == m.text
                      ? _act(Icons.stop_rounded, 'Stop reading', () => setState(_hush))
                      : _act(Icons.volume_up_outlined, 'Read aloud', () => _say(m.text)),
                ],
                _act(Icons.refresh_rounded, 'Again', () => unawaited(_again(m))),
                if (m.error == null) _act(Icons.flag_outlined, 'Report', () => unawaited(_report(m))),
              ],
            ),
        ],
      ),
    );
  }

  static MemoryPlace? _placeOf(ChatSource s) => s.section == null
      ? null
      : MemoryPlace(chapter: s.chapter ?? s.section!, section: s.section!, block: s.block, sentence: s.sentence);

  Widget _act(IconData icon, String label, VoidCallback onTap) => TextButton.icon(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 4)),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
      );

  Future<void> _report(ChatMessage m) async {
    final i = _chat.messages.indexOf(m);
    final q = i > 0 && _chat.messages[i - 1].mine ? _chat.messages[i - 1].text : '';
    final done = await reportAiAnswer(context, answer: m.text, question: q, where: 'AI chat');
    if (done && mounted) {
      setState(() => m.held = true);
      await _store.put(_chat);
    }
  }
}

/// Where the AI looked for an answer: the first few in a line, the rest a
/// tap away. Plain words, no icons.
class _Looked extends StatefulWidget {
  const _Looked(this.looked);

  final List<String> looked;

  @override
  State<_Looked> createState() => _LookedState();
}

class _LookedState extends State<_Looked> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final all = widget.looked;
    final shown = _open || all.length <= 3 ? all : all.take(3).toList();
    final more = all.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: all.length > 3 ? () => setState(() => _open = !_open) : null,
        child: Text(
          'Looked in: ${shown.join(' · ')}${more > 0 ? ' · and $more more' : ''}',
          style: Skin.meta(context, size: 12),
        ),
      ),
    );
  }
}

/// What a chat is about: all the books, or the ones ticked.
class ScopeSheet extends StatefulWidget {
  const ScopeSheet({super.key, required this.books, required this.chosen});

  final List<LibraryEntry> books;
  final List<String> chosen;

  @override
  State<ScopeSheet> createState() => _ScopeSheetState();
}

class _ScopeSheetState extends State<ScopeSheet> {
  late final _picked = {...widget.chosen};

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('About', subtitle: 'What this chat is about'),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _row(
                      title: 'All your books',
                      subtitle: 'Every book with a memory',
                      on: _picked.isEmpty,
                      onTap: () => setState(_picked.clear),
                    ),
                    for (final b in widget.books)
                      _row(
                        title: b.title,
                        subtitle: b.authors.isEmpty ? null : b.authors.join(', '),
                        on: _picked.contains(b.id),
                        onTap: () => setState(() => _picked.contains(b.id) ? _picked.remove(b.id) : _picked.add(b.id)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.l),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop([
                    for (final b in widget.books)
                      if (_picked.contains(b.id)) b.id,
                  ]),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      );

  // Every row keeps the same mark slot, so ticking one moves nothing.
  Widget _row({required String title, String? subtitle, required bool on, required VoidCallback onTap}) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Icon(on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    size: 22, color: on ? Skin.accentInkOf(context) : Skin.inkFaintOn(context)),
              ),
              const SizedBox(width: Gap.l),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.ui(size: 16, weight: on ? FontWeight.w700 : FontWeight.w500, color: Skin.inkOn(context))),
                    if (subtitle != null)
                      Text(subtitle, style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// Asks before chat [chat] is deleted completely, saying all that goes.
Future<bool> confirmChatDelete(BuildContext context, Chat chat, ChatStore store) {
  final notes = store.notesFrom(chat.id).length;
  final gone = [
    if (chat.books.length == 1) 'its page in the journal',
    if (notes > 0) notes == 1 ? 'the note the AI kept from it' : 'the $notes notes the AI kept from it',
    if (chat.books.length == 1) "its questions in the book's memory",
    if (chat.summary != null) 'its summary, which later chats could look back at',
  ];
  return confirm(context,
      title: 'Delete this chat completely?',
      body: gone.isEmpty
          ? 'It goes from the app, and nothing of it is kept. This cannot be undone.'
          : 'It goes from the app, and so does ${_listed(gone)}. Nothing of it is kept. This cannot be undone.',
      action: 'Delete');
}

String _listed(List<String> items) =>
    items.length == 1 ? items.first : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// The language an answer is written in, by its letters: Bengali, Hindi
/// and the others with scripts of their own; else English.
String answerLanguage(String text) {
  const scripts = <(int, int, String)>[
    (0x0980, 0x09FF, 'bn'),
    (0x0900, 0x097F, 'hi'),
    (0x0A80, 0x0AFF, 'gu'),
    (0x0A00, 0x0A7F, 'pa'),
    (0x0B80, 0x0BFF, 'ta'),
    (0x0C00, 0x0C7F, 'te'),
    (0x0C80, 0x0CFF, 'kn'),
    (0x0D00, 0x0D7F, 'ml'),
    (0x0600, 0x06FF, 'ar'),
    (0x0400, 0x04FF, 'ru'),
    (0x0E00, 0x0E7F, 'th'),
    (0x3040, 0x30FF, 'ja'),
    (0xAC00, 0xD7AF, 'ko'),
    (0x4E00, 0x9FFF, 'zh'),
  ];
  final counts = <String, int>{};
  var latin = 0;
  for (final r in text.runes) {
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      latin++;
      continue;
    }
    for (final (lo, hi, l) in scripts) {
      if (r >= lo && r <= hi) {
        counts[l] = (counts[l] ?? 0) + 1;
        break;
      }
    }
  }
  if (counts.isEmpty) return 'en';
  final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  return top.value > latin ? top.key : 'en';
}
