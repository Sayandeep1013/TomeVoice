import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'brand.dart';
import 'library_store.dart';
import 'reader_screen.dart';
import 'speech_service.dart';
import 'theme.dart';

const _svc = SpeechService();

/// The shelf of books. Same chrome language as the reader: gradient, capsules,
/// monospace instrumentation. Ojuju is for titles; the page of a book is not.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryStore? _store;
  List<LibraryEntry> _entries = [];
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final dir = await _svc.outputDir();
      if (dir == null) {
        if (mounted) setState(() => _status = 'No storage');
        return;
      }
      final store = LibraryStore(Directory(dir));
      final entries = await store.list();
      if (!mounted) return;
      setState(() {
        _store = store;
        _entries = entries;
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = '${e.code}: ${e.message}');
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final picked = await _svc.pickDocument();
      if (picked == null) return;
      final path = picked['path'];
      if (path == null || path.isEmpty) return;
      if (_store == null) await _open();
      final store = _store;
      if (store == null) {
        if (mounted) setState(() => _status = 'No storage');
        return;
      }
      final entry = await store.importFile(
        source: File(path),
        displayName: picked['name'],
        mime: picked['mime'],
      );
      final entries = await store.list();
      if (!mounted) return;
      setState(() => _entries = entries);
      await _openBook(entry.id);
    } on EncryptedDocumentException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } on UnsupportedDocumentException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } on ParseException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = '${e.code}: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBook(String id) async {
    final store = _store;
    if (store == null) return;
    try {
      final book = await store.loadBook(id);
      final cursor = await store.cursorFor(id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
            book: book,
            store: store,
            initialCursor: cursor,
          ),
        ),
      );
      final entries = await store.list();
      if (mounted) setState(() => _entries = entries);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _openSpecimen() async {
    final book = specimenBook();
    final cursor = await _store?.cursorFor(book.id) ?? ReadingCursor.zero;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          book: book,
          store: _store,
          initialCursor: cursor,
        ),
      ),
    );
  }

  Future<void> _delete(LibraryEntry e) async {
    final onDark = Skin.onDark(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Skin.darkOn(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('REMOVE',
            style: Skin.meta(context, color: onDark, size: 11)),
        content: Text(
          e.title,
          style: Skin.label(context, color: onDark, size: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('KEEP', style: Skin.label(context, color: onDark)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                Text('REMOVE', style: Skin.label(context, color: Skin.amber)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store?.remove(e.id);
    final entries = await _store?.list() ?? const [];
    if (mounted) setState(() => _entries = entries);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final hero = (width * 0.155).clamp(46.0, 72.0);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandMark(size: 36),
                const SizedBox(height: 18),
                Text('TomeVoice', style: Skin.title(context, size: hero)),
                const SizedBox(height: 8),
                Text(
                  'EPUB, TXT, MARKDOWN. PDF IS NEXT.',
                  style: Skin.meta(context),
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_status.toUpperCase(),
                      style: Skin.meta(context, color: Skin.amber, size: 10)),
                ],
                const SizedBox(height: 22),
                Expanded(
                  child: ListView(
                    children: [
                      _specimenStage(context),
                      const SizedBox(height: 22),
                      Text('YOUR BOOKS', style: Skin.meta(context, size: 11)),
                      const SizedBox(height: 10),
                      if (_entries.isEmpty)
                        Text(
                          'IMPORTED BOOKS APPEAR HERE.',
                          style: Skin.meta(context),
                        ),
                      for (final e in _entries) ...[
                        _row(
                          context,
                          title: e.title,
                          subtitle: '${e.authorLine.toUpperCase()}  ·  '
                              '${e.source.name.toUpperCase()}  ·  '
                              '${(e.progress * 100).round()}%',
                          onTap: () => _openBook(e.id),
                          onDelete: () => _delete(e),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
                Capsule(
                  onTap: _busy ? null : _import,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  color: Skin.darkOn(context),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _busy
                            ? Icons.hourglass_empty_rounded
                            : Icons.add_rounded,
                        size: 18,
                        color: Skin.onDark(context),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _busy ? 'IMPORTING' : 'IMPORT A FILE',
                        style: Skin.label(context,
                            color: Skin.onDark(context), size: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The original specimen surface, now the way into the reader: oversized
  /// chrome around a readable pangram, tap anywhere to listen.
  Widget _specimenStage(BuildContext context) {
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openSpecimen,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            border: Border.all(color: Skin.capsuleEdge),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SPECIMEN · TAP TO LISTEN', style: Skin.meta(context)),
              const SizedBox(height: 10),
              Text('Specimen', style: Skin.title(context, size: 28)),
              const SizedBox(height: 12),
              Text(
                'The quick brown fox jumps over the lazy dog.',
                style: Skin.display(context, 22),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('PLAY',
                      style: Skin.label(context, weight: FontWeight.w700)),
                  const Spacer(),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: Material(
                      color: Skin.darkOn(context),
                      shape: const CircleBorder(),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Skin.onDark(context),
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Delete is a sibling of the open-target, not a child of it. Nesting two
  /// InkWells made Remove eat the row tap, or the row eat Remove, depending
  /// on the device.
  Widget _row(
    BuildContext context, {
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onDelete,
  }) {
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(22)),
          border: Border.all(color: Skin.capsuleEdge),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.title(context, size: 20),
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle, style: Skin.meta(context, size: 8.5)),
                    ],
                  ),
                ),
              ),
            ),
            if (onDelete != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: RoundButton(
                  icon: Icons.close_rounded,
                  size: 34,
                  tooltip: 'Remove',
                  onTap: onDelete,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
