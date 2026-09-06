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
/// monospace instrumentation. Ojuju is reserved for text being read.
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
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(book: book, store: _store),
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
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandLockup(),
                const SizedBox(height: 14),
                Text('LIBRARY', style: Skin.meta(context, size: 11)),
                const SizedBox(height: 6),
                Text(
                  'EPUB, TXT, MARKDOWN. LOCAL. YOURS.',
                  style: Skin.meta(context),
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_status.toUpperCase(),
                      style: Skin.meta(context, color: Skin.amber, size: 10)),
                ],
                const SizedBox(height: 18),
                Expanded(
                  child: ListView(
                    children: [
                      _row(
                        context,
                        title: 'Specimen',
                        subtitle: 'THE PANGRAM · TAP TO LISTEN',
                        onTap: _openSpecimen,
                      ),
                      const SizedBox(height: 10),
                      if (_entries.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'IMPORTED BOOKS APPEAR HERE.',
                          style: Skin.meta(context),
                        ),
                      ],
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
                        style: Skin.label(context,
                            size: 15, weight: FontWeight.w700),
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
