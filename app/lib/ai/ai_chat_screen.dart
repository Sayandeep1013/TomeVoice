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
import 'memory/memory_section.dart' show MemoriesScreen;
import 'memory/memory_service.dart';
import 'talk/talk_sheet.dart';

/// Main menu > AI chat: where talking with the AI starts. Pick a book and
/// talk; the AI looks into its memory, Who's who and your journal as it
/// needs. Past talks are kept in the journal, and shown here by themselves.
/// Keys and everything else of the AI are behind the settings button.
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key, required this.store, this.ring});

  final LibraryStore store;
  final AiRing? ring;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  AiRing get _ring => widget.ring ?? AiRing.instance;
  final _journal = JournalStore.instance;
  final _service = MemoryService.instance;
  List<LibraryEntry>? _books;

  @override
  void initState() {
    super.initState();
    _ring.addListener(_changed);
    _journal.changes.addListener(_changed);
    unawaited(_load());
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
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final books = await _service.booksWithMemory();
    if (mounted) setState(() => _books = books);
  }

  Future<void> _settings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AiScreen()));
    // A memory begun there shows here on coming back.
    unawaited(_load());
  }

  /// Talk about [book], from where the reader is in it.
  Future<void> _talk(LibraryEntry book) async {
    if (!_service.maySend(book.id)) {
      showSnack(context, 'This book is kept away from the AI.');
      return;
    }
    final line = await _service.lineOf(book.id);
    final here = await _service.hereOf(book.id);
    final stamp = await _service.stampOf(book.id);
    if (stamp == null || !mounted) return;
    await showTalk(
      context,
      bookId: book.id,
      bookTitle: book.title,
      memoryPath: _service.pathOf(book.id),
      stampNow: () => stamp,
      line: () => line,
      here: () => here,
      passage: () => '',
      onLook: (_) {},
    );
  }

  void _pastTalks() => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => JournalScreen(store: widget.store, onlyTalks: true),
      )));

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final books = _books;
    final talks = [for (final e in _journal.all) if (e.isTalk) e]..sort((a, b) => b.created.compareTo(a.created));
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
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
                    icon: Icons.settings_outlined,
                    tooltip: 'AI settings',
                    onTap: () => unawaited(_settings()),
                  ),
                ],
              ),
              Expanded(
                child: !_ring.hasKeys
                    ? EmptyState(
                        icon: Icons.forum_outlined,
                        title: 'Talk about your books',
                        body: 'Add a key of your own in AI settings (the button at the top), then build a '
                            "book's memory. After that, ask anything about it here.",
                      )
                    : ListView(
                        padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xxl + bottom),
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                            child: Text(
                              'Pick a book and ask. The AI looks into its memory, Who\'s who and your journal '
                              'as it needs, and keeps to where you are unless you let it go further.',
                              style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                                  .copyWith(height: 1.4),
                            ),
                          ),
                          const SizedBox(height: Gap.xl),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: Gap.page),
                            child: SectionTitle('Talk about'),
                          ),
                          const SizedBox(height: Gap.s),
                          if (books != null && books.isEmpty)
                            SettingRow(
                              icon: Icons.psychology_outlined,
                              title: 'No book has a memory yet',
                              subtitle: "Open a book's page and tap Memory: the AI reads it once and remembers it",
                              onTap: () => unawaited(Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => const MemoriesScreen()))),
                            ),
                          for (final b in books ?? const <LibraryEntry>[])
                            SettingRow(
                              icon: Icons.forum_outlined,
                              title: b.title,
                              subtitle: b.authors.isEmpty ? null : b.authors.join(', '),
                              onTap: () => unawaited(_talk(b)),
                            ),
                          const SizedBox(height: Gap.xl),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: Gap.page),
                            child: SectionTitle('Past talks'),
                          ),
                          const SizedBox(height: Gap.s),
                          if (talks.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                              child: Text('None yet. Each talk is kept in its book\'s journal.',
                                  style: Skin.meta(context)),
                            ),
                          for (final t in talks.take(5))
                            SettingRow(
                              icon: Icons.chat_bubble_outline_rounded,
                              title: _short(t.talk.firstWhere((l) => l.mine, orElse: () => t.talk.first).text),
                              subtitle: '${t.bookTitle} · ${t.created.toLocal().toString().substring(0, 10)}',
                              onTap: _pastTalks,
                            ),
                          if (talks.length > 5)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: Gap.page - Gap.s),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(onPressed: _pastTalks, child: Text('All ${talks.length} talks')),
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

/// A first question cut to a line or two.
String _short(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= 90 ? t : '${t.substring(0, 88).trimRight()}…';
}
