import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../backup_flow.dart' show sizeLabel;
import '../journal.dart';
import '../library_store.dart' show LibraryEntry;
import '../speech_service.dart';
import '../theme.dart';
import '../ui.dart';
import 'ai_keys.dart';
import 'memory/hand_off.dart' show handOffMarkdown;
import 'memory/memory_service.dart';

/// How much room a book's memory takes on the phone: its database and the
/// journal SQLite keeps beside it.
int memorySizeAt(String path) {
  var n = 0;
  for (final p in [path, '$path-wal', '$path-shm']) {
    final f = File(p);
    if (f.existsSync()) n += f.lengthSync();
  }
  return n;
}

/// AI > Your data: what was sent, every memory taken away as one file, or
/// all of them forgotten.
class AiDataSection extends StatelessWidget {
  const AiDataSection({super.key, this.ring});

  final AiRing? ring;

  @override
  Widget build(BuildContext context) {
    final r = ring ?? AiRing.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Gap.page),
          child: SectionTitle('Your data', size: 18),
        ),
        ListenableBuilder(
          listenable: r,
          builder: (context, _) => ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('What was sent'),
            subtitle: Text(r.log.isEmpty
                ? 'Nothing yet'
                : 'The last ${r.log.length} ${r.log.length == 1 ? 'call' : 'calls'}: when, for what, to whom'),
            onTap: () => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AiLogScreen(ring: r),
            ))),
          ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
          leading: const Icon(Icons.ios_share_rounded),
          title: const Text('Export every memory'),
          subtitle: const Text('One page per book: story so far, who matters, threads, your theories and journal'),
          onTap: () => unawaited(exportAllMemories(context)),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
          leading: Icon(Icons.delete_sweep_outlined, color: Theme.of(context).colorScheme.error),
          title: const Text('Forget every memory'),
          subtitle: const Text('Every book\'s notes, cast and graph; your journal and books stay'),
          onTap: () => unawaited(forgetAllMemories(context)),
        ),
      ],
    );
  }
}

/// Every book's memory as one Markdown file, shared.
Future<void> exportAllMemories(BuildContext context) async {
  final service = MemoryService.instance;
  final books = await service.booksWithMemory();
  if (!context.mounted) return;
  if (books.isEmpty) {
    showSnack(context, 'No book has a memory yet.');
    return;
  }
  showSnack(context, 'Gathering ${books.length} ${books.length == 1 ? 'memory' : 'memories'}…');
  final parts = <String>[];
  for (final b in books) {
    parts.add(await _pageOff(service.pathOf(b.id), b.title, b.authors.join(', '), _journalOf(b)));
  }
  final file = File('${Directory.systemTemp.path}/TomeVoice memories.md');
  await file.writeAsString('# TomeVoice: what the AI remembers\n\n${parts.join('\n---\n\n')}');
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  await const SpeechService().shareFile(file.path, mime: 'text/markdown');
}

List<String> _journalOf(LibraryEntry b) => [
      for (final e in JournalStore.instance.all)
        if (e.bookId == b.id) '${e.stamp.label}: ${e.words.replaceAll('\n', ' ')}',
    ];

Future<String> _pageOff(String path, String title, String author, List<String> journal) =>
    Isolate.run(() => handOffMarkdown(path, title: title, author: author, journal: journal));

/// Every book's memory deleted, after asking.
Future<void> forgetAllMemories(BuildContext context) async {
  final service = MemoryService.instance;
  final books = await service.booksWithMemory();
  if (!context.mounted) return;
  if (books.isEmpty) {
    showSnack(context, 'No book has a memory to forget.');
    return;
  }
  final sure = await confirm(
    context,
    title: 'Forget every memory?',
    body: 'The notes, cast, graph, threads and theories of ${books.length} '
        '${books.length == 1 ? 'book' : 'books'} go from this phone. Your books, downloaded chapters, places, journal and AI chats stay. '
        'A memory can be built again, at the cost of the calls.',
    action: 'Forget them all',
  );
  if (!sure) return;
  for (final b in books) {
    await service.forget(b.id);
  }
  if (context.mounted) showSnack(context, 'Every memory is forgotten.');
}

/// AI > What was sent: each call, newest first.
class AiLogScreen extends StatelessWidget {
  const AiLogScreen({super.key, this.ring});

  final AiRing? ring;

  @override
  Widget build(BuildContext context) {
    final r = ring ?? AiRing.instance;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: ListenableBuilder(
            listenable: r,
            builder: (context, _) {
              final log = r.log.reversed.toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ScreenTopBar(
                    title: 'What was sent',
                    onBack: () => Navigator.of(context).maybePop(),
                    actions: [
                      if (log.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear the list',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () async {
                            final sure = await confirm(
                              context,
                              title: 'Clear the list?',
                              body: 'Only this list of what was sent goes. The tokens counted for each key today, and its daily limit, '
                                  'stay as they are; nothing at the provider changes.',
                              action: 'Clear',
                            );
                            if (sure) await r.clearLog();
                          },
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                    child: Text(
                      'Each call TomeVoice made to an AI with your keys, kept on this phone alone (the last '
                      '${AiRing.logKept}). What goes in each is said under AI > What is sent.',
                      style: Skin.label(context, size: 13.5),
                    ),
                  ),
                  Expanded(
                    child: log.isEmpty
                        ? const EmptyState(
                            icon: Icons.receipt_long_outlined,
                            title: 'Nothing sent yet',
                            body: 'Calls show here once a memory builds or you ask something.',
                          )
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xl + bottom),
                            itemCount: log.length,
                            itemBuilder: (context, i) => _row(context, log[i]),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, AiLogEntry e) {
    final when = e.at.toLocal();
    final t = '${when.day} ${_months[when.month - 1]}, ${'${when.hour}'.padLeft(2, '0')}:'
        '${'${when.minute}'.padLeft(2, '0')}';
    final tokens = e.input + e.output == 0 ? '' : ' · ${_n(e.input)} in, ${_n(e.output)} out';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
      dense: true,
      title: Text('${e.job.label}${e.about == null ? '' : ' · ${e.about}'}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$t · ${e.provider}${e.model.isEmpty ? '' : ' · ${e.model}'}$tokens'),
    );
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _n(int v) => v < 1000 ? '$v' : '${(v / 1000).toStringAsFixed(v < 10000 ? 1 : 0)}k';
}

/// "· 12 MB" for a memory's line.
String memorySizeNote(String path) {
  final n = memorySizeAt(path);
  return n == 0 ? '' : ' · ${sizeLabel(n)}';
}
