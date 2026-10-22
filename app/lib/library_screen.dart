import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'brand.dart';
import 'library_store.dart';
import 'reader_screen.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'voices.dart';

const _svc = SpeechService();

/// The shelf. Same chrome language as the reader: gradient, capsules,
/// monospace instrumentation. Ojuju is for titles; the page of a book is not.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _Importing {
  _Importing(this.name);
  final String name;
  int done = 0;
  int total = 0;
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryStore? _store;
  List<LibraryEntry> _entries = [];
  bool _loaded = false;
  _Importing? _importing;

  /// Files handed over by "Open with" arrive both as an event and as the
  /// pending-open value; whichever reaches us second is ignored.
  final _handled = <String>{};
  StreamSubscription<Map<String, Object?>>? _events;

  @override
  void initState() {
    super.initState();
    unawaited(VoiceCatalog.instance.ensureLoaded());
    _events = SpeechService.events.listen(_onPlatformEvent);
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final dir = await _svc.outputDir();
      if (dir == null) throw const FileSystemException('No storage');
      final store = LibraryStore(Directory(dir));
      final entries = await store.list();
      if (!mounted) return;
      setState(() {
        _store = store;
        _entries = entries;
        _loaded = true;
      });
      final pending = await _svc.pendingOpen();
      if (pending != null && _handled.add(pending.path)) {
        await _importAll([pending], openAfter: true);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loaded = true);
      _snack('Could not open the library: $e');
    }
  }

  void _onPlatformEvent(Map<String, Object?> e) {
    if (e['type'] == 'openFile') {
      // "Open with TomeVoice" while the app is running: come back to the
      // shelf, import, open.
      final file = PickedFile.fromMap(e);
      // Before the shelf has loaded, _open picks it up from pendingOpen.
      if (!_loaded || !_handled.add(file.path)) return;
      unawaited(_svc.pendingOpen());
      Navigator.of(context).popUntil((r) => r.isFirst);
      unawaited(_importAll([file], openAfter: true));
    } else if (e['type'] == 'openFailed') {
      _snack('Could not open that file: ${e['message']}');
    }
  }

  Future<void> _pick() async {
    if (_importing != null) return;
    try {
      final files = await _svc.pickDocuments();
      if (files.isEmpty) return;
      await _importAll(files, openAfter: files.length == 1);
    } on PlatformException catch (e) {
      _snack(e.message ?? e.code);
    }
  }

  Future<void> _importAll(List<PickedFile> files, {required bool openAfter}) async {
    final store = _store;
    if (store == null) return;
    final imported = <LibraryEntry>[];
    final failures = <String>[];
    for (final f in files) {
      final job = _Importing(f.name);
      setState(() => _importing = job);
      try {
        imported.add(await store.importFile(f, onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            job.done = done;
            job.total = total;
          });
        }));
      } on EncryptedDocumentException catch (e) {
        failures.add('${f.name}: ${e.message}');
      } on UnsupportedDocumentException catch (e) {
        failures.add('${f.name}: ${e.message}');
      } on ParseException catch (e) {
        failures.add('${f.name}: ${e.message}');
      } on PlatformException catch (e) {
        failures.add('${f.name}: ${e.message ?? e.code}');
      } on Object catch (e) {
        failures.add('${f.name}: $e');
      }
    }
    final entries = await store.list();
    if (!mounted) return;
    setState(() {
      _importing = null;
      _entries = entries;
    });
    if (failures.isNotEmpty) {
      _snack(failures.join('\n'), long: true);
    } else if (imported.length > 1) {
      _snack('Added ${imported.length} books.');
    }
    if (openAfter && imported.length == 1) await _openBook(imported.single);
  }

  Future<void> _openBook(LibraryEntry entry, {bool autoplay = false}) async {
    final store = _store;
    if (store == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookLoader(store: store, entry: entry, autoplay: autoplay),
      ),
    );
    final entries = await store.list();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _bookMenu(LibraryEntry e) async {
    final onDark = Skin.onDark(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Skin.darkOn(context),
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Skin.title(context, size: 22, color: onDark)),
            const SizedBox(height: 4),
            Text(
              [
                e.formatLabel,
                if (e.wordCount > 0) '${_thousands(e.wordCount)} WORDS',
                if (e.language != null) languageName(e.language!).toUpperCase(),
              ].join('  ·  '),
              style: Skin.meta(context, color: onDark.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 18),
            _sheetAction(ctx, Icons.play_arrow_rounded, 'Read aloud from where I left off', 'play'),
            _sheetAction(ctx, Icons.restart_alt_rounded, 'Start from the beginning', 'restart'),
            _sheetAction(ctx, Icons.delete_outline_rounded, 'Remove from library', 'remove',
                danger: true),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'play':
        await _openBook(e, autoplay: true);
      case 'restart':
        await _store?.saveCursor(e.id, ReadingCursor.zero, 0);
        final fresh = (await _store?.list())?.where((x) => x.id == e.id).firstOrNull;
        if (fresh != null) await _openBook(fresh);
      case 'remove':
        await _store?.remove(e.id);
        final entries = await _store?.list() ?? const <LibraryEntry>[];
        if (mounted) setState(() => _entries = entries);
        _snack('Removed "${e.title}".');
    }
  }

  Widget _sheetAction(BuildContext ctx, IconData icon, String label, String value,
      {bool danger = false}) {
    final color = danger ? Skin.amber : Skin.onDark(ctx);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Text(label, style: Skin.label(ctx, color: color, size: 13.5)),
          ],
        ),
      ),
    );
  }

  void _snack(String text, {bool long = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text, style: Skin.label(context, color: Skin.onDark(context), size: 12.5)),
      backgroundColor: Skin.darkOn(context),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: long ? 8 : 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final hero = (width * 0.12).clamp(38.0, 56.0);
    final recent = _entries.where((e) => e.openedAt != null).firstOrNull;
    final rest = [for (final e in _entries) if (e != recent) e];

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Stack(
            children: [
              CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const BrandMark(size: 34),
                              const SizedBox(width: 12),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text('TomeVoice', style: Skin.title(context, size: hero)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text('ANY BOOK, READ ALOUD.', style: Skin.meta(context, size: 10)),
                          const SizedBox(height: 22),
                          if (_importing != null) ...[
                            _importCard(context, _importing!),
                            const SizedBox(height: 16),
                          ],
                          if (recent != null) ...[
                            Text('CONTINUE', style: Skin.meta(context, size: 10)),
                            const SizedBox(height: 8),
                            _continueCard(context, recent),
                            const SizedBox(height: 24),
                          ],
                          if (rest.isNotEmpty) ...[
                            Text(recent == null ? 'YOUR BOOKS' : 'MORE BOOKS',
                                style: Skin.meta(context, size: 10)),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_loaded && _entries.isEmpty && _importing == null)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(child: _emptyState(context)),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
                    sliver: SliverList.separated(
                      itemCount: rest.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _bookRow(context, rest[i]),
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 18,
                child: _addButton(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addButton(BuildContext context) {
    final busy = _importing != null;
    return Capsule(
      onTap: busy ? null : _pick,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      color: Skin.darkOn(context),
      border: false,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(busy ? Icons.hourglass_top_rounded : Icons.add_rounded,
              size: 20, color: Skin.amberSoft),
          const SizedBox(width: 10),
          Text(
            busy ? 'Adding…' : 'Add books',
            style: Skin.label(context, color: Skin.onDark(context), size: 13.5, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Skin.capsuleOn(context),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Skin.capsuleEdge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your shelf is empty', style: Skin.title(context, size: 24)),
            const SizedBox(height: 8),
            Text(
              'Tap Add books and pick any file. TomeVoice opens it, finds the '
              'chapters and reads it to you — screen on or off.',
              style: Skin.page(context, size: 15.5),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in const ['EPUB', 'PDF', 'DOCX', 'MOBI', 'AZW3', 'TXT', 'RTF', 'ODT', 'FB2', 'HTML', 'MD'])
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Skin.inkFaintOn(context).withValues(alpha: 0.4)),
                    ),
                    child: Text(f, style: Skin.meta(context, size: 9)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'TIP: IN ANY FILE MANAGER, OPEN A BOOK WITH TOMEVOICE.',
              style: Skin.meta(context, size: 8.5),
            ),
          ],
        ),
      );

  Widget _importCard(BuildContext context, _Importing job) {
    final frac = job.total > 0 ? job.done / job.total : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Skin.capsuleEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(job.name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 17)),
          const SizedBox(height: 4),
          Text(
            frac == null ? 'OPENING AND FINDING CHAPTERS…' : 'READING PAGE ${job.done} OF ${job.total}…',
            style: Skin.meta(context, size: 8.5),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 4,
              color: Skin.amber,
              backgroundColor: Skin.inkFaintOn(context).withValues(alpha: 0.2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueCard(BuildContext context, LibraryEntry e) {
    final onDark = Skin.onDark(context);
    return Material(
      color: Skin.darkOn(context),
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openBook(e),
        onLongPress: () => _bookMenu(e),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.title(context, size: 22, color: onDark)),
                    const SizedBox(height: 4),
                    Text(
                      (e.where ?? e.authorLine).toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.meta(context, color: onDark.withValues(alpha: 0.6), size: 8.5),
                    ),
                    const SizedBox(height: 10),
                    _progress(context, e.progress, onDark),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: 'Continue reading aloud',
                child: Material(
                  color: Skin.amber,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _openBook(e, autoplay: true),
                    child: const SizedBox(
                      width: 56,
                      height: 56,
                      child: Icon(Icons.play_arrow_rounded, size: 32, color: Skin.dark),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookRow(BuildContext context, LibraryEntry e) {
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Skin.capsuleEdge),
        ),
        child: InkWell(
          onTap: () => _openBook(e),
          onLongPress: () => _bookMenu(e),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 4, 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.title(context, size: 19)),
                      const SizedBox(height: 4),
                      Text(
                        [
                          e.formatLabel,
                          if (e.authorLine.isNotEmpty) e.authorLine.toUpperCase(),
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.meta(context, size: 8.5),
                      ),
                      if (e.progress > 0) ...[
                        const SizedBox(height: 8),
                        _progress(context, e.progress, Skin.inkOn(context)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'More',
                  onPressed: () => _bookMenu(e),
                  icon: Icon(Icons.more_vert_rounded, color: Skin.inkSoftOn(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _progress(BuildContext context, double p, Color ink) => Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: p.clamp(0.0, 1.0),
                minHeight: 4,
                color: Skin.amber,
                backgroundColor: ink.withValues(alpha: 0.14),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('${(p * 100).round()}%', style: Skin.meta(context, color: ink.withValues(alpha: 0.6), size: 8.5)),
        ],
      );
}

String _thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
