import 'dart:async';

import 'package:flutter/material.dart';

import '../guide.dart';
import '../journal.dart';
import '../journal_screen.dart';
import '../library_store.dart';
import '../prefs.dart';
import '../theme.dart';
import '../ui.dart';
import 'ai_keys.dart';
import 'ai_screen.dart';
import 'chat/chat_links.dart';
import 'chat/chat_runner.dart';
import 'chat/chat_screen.dart';
import 'chat/chat_store.dart';
import 'memory/memory_section.dart' show MemoriesScreen;

/// Main menu > AI chat: every conversation with the AI, the newest first,
/// a new one a tap away. Behind the buttons at the top: the books'
/// memories, and AI settings (keys and everything else of the AI).
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key, required this.store, this.ring, this.chats});

  final LibraryStore store;
  final AiRing? ring;
  final ChatStore? chats;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  AiRing get _ring => widget.ring ?? AiRing.instance;
  ChatStore get _chats => widget.chats ?? ChatStore.instance;
  final _journal = JournalStore.instance;
  Map<String, String> _titles = const {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _ring.addListener(_changed);
    _journal.changes.addListener(_changed);
    _chats.changes.addListener(_changed);
    unawaited(_loadTitles());
    // The guide to the AI, by itself the first time AI chat (or its
    // settings) opens.
    final prefs = ListeningPrefs.loaded;
    if (GuideScreen.onFirstLaunch && prefs != null && !prefs.aiGuideShown) {
      prefs.aiGuideShown = true;
      prefs.save();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(showAiGuide(context));
      });
    }
  }

  @override
  void dispose() {
    _ring.removeListener(_changed);
    _journal.changes.removeListener(_changed);
    _chats.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadTitles() async {
    try {
      final all = await widget.store.list(all: true);
      if (mounted) setState(() => _titles = {for (final e in all) e.id: e.title});
    } on Object {
      // Chats show without their books' names.
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) setState(() {});
  }

  /// A new chat, about the book read last (that has a memory), or about all
  /// of them when none has.
  ///
  /// Finding that book reads each memory (seconds, while one is being
  /// built): taps meanwhile are the same tap, not a chat each.
  Future<void> _newChat() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final books = await chatableBooks();
      if (!mounted) return;
      setState(() => _opening = false);
      await _push(ChatScreen(store: widget.store, books: [if (books.isNotEmpty) books.first.id], chats: widget.chats));
    } finally {
      if (mounted && _opening) setState(() => _opening = false);
    }
  }

  /// A new chat on its way (its books being found).
  bool _opening = false;

  Future<void> _rename(Chat c) async {
    final t = await askText(context, title: 'Name this chat', initial: c.title);
    final name = t?.trim() ?? '';
    if (name.isEmpty) return;
    c
      ..title = name
      ..titled = true;
    await _chats.put(c);
  }

  Future<void> _delete(Chat c) async {
    if (await confirmChatDelete(context, c, _chats)) await deleteChatCompletely(c, store: _chats, journal: _journal);
  }

  String _about(Chat c) {
    if (c.wholeLibrary) return 'All your books';
    if (c.books.length == 1) return _titles[c.books.first] ?? 'A book';
    return '${c.books.length} books';
  }

  static int _daysAgo(DateTime t) {
    final at = t.toLocal();
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
  }

  static String _when(DateTime t) {
    final at = t.toLocal();
    final days = _daysAgo(t);
    if (days == 0) return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    if (days == 1) return 'Yesterday';
    if (days < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][at.weekday - 1];
    return at.toString().substring(0, 10);
  }

  /// Which group a chat goes under.
  static String _group(Chat c) {
    if (c.pinned) return 'Pinned';
    final days = _daysAgo(c.updated);
    if (days == 0) return 'Today';
    if (days < 7) return 'This week';
    return 'Earlier';
  }

  bool _matches(Chat c, String q) {
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    return has(c.title) || has(c.summary ?? '') || has(_about(c)) || c.messages.any((m) => has(m.text));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final q = _query.trim().toLowerCase();
    final all = _chats.all;
    final chats = [for (final c in all) if (_matches(c, q)) c];
    final talks = [for (final e in _journal.all) if (e.isTalk && !e.id.startsWith('chat-')) e];
    final notes = _chats.notes.length;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(
                title: 'AI chat',
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  RoundButton(
                    icon: Icons.psychology_outlined,
                    tooltip: 'Book memories',
                    onTap: () => unawaited(_push(const MemoriesScreen())),
                  ),
                  const SizedBox(width: Gap.s),
                  RoundButton(
                    icon: Icons.settings_outlined,
                    tooltip: 'AI settings',
                    onTap: () => unawaited(_push(const AiScreen())),
                  ),
                ],
              ),
              Expanded(
                child: !_ring.hasKeys
                    ? Center(
                        child: SingleChildScrollView(
                          child: EmptyState(
                            icon: Icons.forum_outlined,
                            title: 'Talk about your books',
                            body: 'TomeVoice talks to the AI with a key of your own, straight from this phone. Add '
                                "one in AI settings, then build a book's memory, and ask anything about it here.",
                            action: FilledButton.icon(
                              onPressed: () => unawaited(_push(const AiScreen())),
                              icon: const Icon(Icons.settings_outlined),
                              label: const Text('Open AI settings'),
                            ),
                          ),
                        ),
                      )
                    // Every child keyed: an answer ending in the background
                    // moves its chat to the top (a group heading may come
                    // or go), and unkeyed, the rows after it each took
                    // another's place, built anew under a finger pressing
                    // one (the Also rows among them).
                    : ListView(
                        padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xxl + bottom),
                        children: [
                          Padding(
                            key: const ValueKey('new'),
                            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.icon(
                                onPressed: () => unawaited(_newChat()),
                                icon: _opening
                                    ? const SizedBox(
                                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.add_rounded),
                                label: const Text('New chat'),
                              ),
                            ),
                          ),
                          if (all.length > 3) ...[
                            const SizedBox(key: ValueKey('search gap'), height: Gap.l),
                            Padding(
                              key: const ValueKey('search'),
                              padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                              child: SearchField(hint: 'Find a chat', onChanged: (v) => setState(() => _query = v)),
                            ),
                          ],
                          if (all.isEmpty)
                            Padding(
                              key: const ValueKey('intro'),
                              padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, 0),
                              child: Text(
                                'Your chats are kept here. A chat about one book is also kept in its journal, '
                                'and the AI can look back at earlier chats when you mention them.',
                                style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                                    .copyWith(height: 1.4),
                              ),
                            ),
                          if (all.isNotEmpty && chats.isEmpty)
                            Padding(
                              key: const ValueKey('no match'),
                              padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, 0),
                              child: Text('No chat has those words.', style: Skin.meta(context)),
                            ),
                          for (final (i, c) in chats.indexed) ...[
                            if (i == 0 || _group(chats[i - 1]) != _group(c)) ...[
                              SizedBox(key: ValueKey('gap ${_group(c)}'), height: Gap.l),
                              Padding(
                                key: ValueKey('group ${_group(c)}'),
                                padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                                child: Eyebrow(_group(c)),
                              ),
                              SizedBox(key: ValueKey('gap under ${_group(c)}'), height: Gap.xs),
                            ],
                            _chatRow(context, c),
                          ],
                          const SizedBox(key: ValueKey('also gap'), height: Gap.xl),
                          const Padding(
                            key: ValueKey('also'),
                            padding: EdgeInsets.symmetric(horizontal: Gap.page),
                            child: Eyebrow('Also'),
                          ),
                          const SizedBox(key: ValueKey('also gap under'), height: Gap.xs),
                          SettingRow(
                            key: const ValueKey('reader notes'),
                            icon: Icons.bookmark_border_rounded,
                            title: 'What the AI remembers about you',
                            subtitle: notes == 0
                                ? 'Nothing yet. It keeps what you tell it about yourself, if you let it'
                                : '$notes ${notes == 1 ? 'note' : 'notes'}: see or delete them',
                            onTap: () => unawaited(_push(ReaderNotesScreen(chats: widget.chats))),
                          ),
                          if (talks.isNotEmpty)
                            SettingRow(
                              key: const ValueKey('talks'),
                              icon: Icons.chat_bubble_outline_rounded,
                              title: 'Talks from the reader',
                              subtitle: '${talks.length} kept in the journal',
                              onTap: () => unawaited(_push(JournalScreen(store: widget.store, onlyTalks: true))),
                            ),
                          SettingRow(
                            key: const ValueKey('memories'),
                            icon: Icons.psychology_outlined,
                            title: 'Book memories',
                            subtitle: 'What the AI has read and remembers of each book',
                            onTap: () => unawaited(_push(const MemoriesScreen())),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chatRow(BuildContext context, Chat c) => InkWell(
        key: ValueKey('chat ${c.id}'),
        onTap: () => unawaited(_push(ChatScreen(store: widget.store, chat: c, chats: widget.chats))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.s, Gap.s),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context))),
                    const SizedBox(height: 2),
                    Text(ChatRunner.instance.busy(c.id) ? 'Answering… · ${_about(c)}' : '${_about(c)} · ${_when(c.updated)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: Icon(Icons.more_vert_rounded, color: Skin.inkFaintOn(context)),
                onSelected: (v) {
                  switch (v) {
                    case 'rename':
                      unawaited(_rename(c));
                    case 'pin':
                      c.pinned = !c.pinned;
                      unawaited(_chats.put(c));
                    case 'delete':
                      unawaited(_delete(c));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'pin', child: Text(c.pinned ? 'Unpin' : 'Pin to the top')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      );
}

/// What the AI keeps about the reader across chats: each note, and where
/// it came from, deletable; and whether it may keep any, or look back at
/// earlier chats.
class ReaderNotesScreen extends StatefulWidget {
  const ReaderNotesScreen({super.key, this.chats});

  final ChatStore? chats;

  @override
  State<ReaderNotesScreen> createState() => _ReaderNotesScreenState();
}

class _ReaderNotesScreenState extends State<ReaderNotesScreen> {
  ChatStore get _chats => widget.chats ?? ChatStore.instance;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  @override
  void initState() {
    super.initState();
    _chats.changes.addListener(_changed);
  }

  @override
  void dispose() {
    _chats.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _forgetAll() async {
    final sure = await confirm(context,
        title: 'Forget everything?',
        body: 'Every note the AI kept about you goes, so later chats start without them. '
            'Your chats themselves, your journal and the book memories stay.',
        action: 'Forget all');
    if (sure) await _chats.forgetAll();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _chats.notes;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'What the AI remembers', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xxl + bottom),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                      child: Text(
                        'When you tell the AI something lasting about yourself in a chat (what you like, what you '
                        'think of a book, how you like answers), it can keep a short note, and every chat after '
                        'starts with them. They stay on this phone.',
                        style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                            .copyWith(height: 1.4),
                      ),
                    ),
                    const SizedBox(height: Gap.m),
                    SwitchRow(
                      title: 'Keep notes about me',
                      subtitle: 'Off: nothing new is kept, and the notes below are not used',
                      value: _prefs.aiChatRemember,
                      onChanged: (v) {
                        setState(() => _prefs.aiChatRemember = v);
                        _prefs.save();
                      },
                    ),
                    SwitchRow(
                      title: 'Look back at earlier chats',
                      subtitle: 'The AI may search your earlier chats and talks when you refer to them',
                      value: _prefs.aiChatPast,
                      onChanged: (v) {
                        setState(() => _prefs.aiChatPast = v);
                        _prefs.save();
                      },
                    ),
                    const SizedBox(height: Gap.l),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: Gap.page),
                      child: SectionTitle('Notes'),
                    ),
                    const SizedBox(height: Gap.s),
                    if (notes.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                        child: Text('None yet.', style: Skin.meta(context)),
                      ),
                    for (final n in notes)
                      SettingRow(
                        title: n.text,
                        subtitle: [
                          if (n.bookTitle != null) n.bookTitle!,
                          n.made.toLocal().toString().substring(0, 10),
                        ].join(' · '),
                        trailing: IconButton(
                          tooltip: 'Forget this',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => unawaited(_chats.forget(n.id)),
                        ),
                      ),
                    if (notes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Gap.page - Gap.s, Gap.m, Gap.page, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(onPressed: () => unawaited(_forgetAll()), child: const Text('Forget all')),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
