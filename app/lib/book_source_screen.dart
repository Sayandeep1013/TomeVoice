import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'browser_check.dart' show signInToSite;
import 'library_store.dart';
import 'novel_screen.dart';
import 'reader_screen.dart' show openBook;
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/net_image.dart';
import 'sources/source_engine.dart';
import 'speech_service.dart' show PickedFile;
import 'store_build.dart';
import 'theme.dart';
import 'ui.dart';

/// Which sources offer whole book files, as each has said (asked once).
final _offers = <String, bool>{};

/// A result from a source opened: a book-file source's as a book to
/// download (the GitHub build only), a web-novel source's as its novel.
Future<void> openSourceResult(BuildContext context, LibraryStore store, PluginInfo plugin, NovelItem item) async {
  var books = _offers[plugin.id];
  if (books == null) {
    try {
      books = await SourceEngine.instance.offersBooks(plugin);
    } on Object {
      books = false;
    }
    _offers[plugin.id] = books;
  }
  if (!context.mounted) return;
  if (books && playBuild) {
    showSnack(context, 'This source offers book files, which this version of TomeVoice does not open.');
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => books!
        ? BookSourceScreen(store: store, plugin: plugin, path: item.path, name: item.name, cover: item.cover)
        : NovelScreen(store: store, plugin: plugin, path: item.path, name: item.name, cover: item.cover),
  ));
}

/// File [file] of [book] from source [plugin] downloaded (with the cookies
/// of the reader's sign-in to that site) and added to the library through
/// the normal import. [onProgress] hears the bytes so far and the whole.
Future<LibraryEntry> addFromSource(
  LibraryStore store,
  PluginInfo plugin,
  SourceBook book,
  BookFile file, {
  void Function(int done, int total)? onProgress,
  void Function(String note)? onNote,
}) async {
  final link = await SourceEngine.instance.fileLink(plugin, file.url);
  // In a folder of its own under incoming/, as a picked file is: the import
  // removes it once the book is in, and a crash leaves it to be swept.
  final dir = Directory('${store.root.path}/incoming/source-${DateTime.now().microsecondsSinceEpoch}');
  await dir.create(recursive: true);
  try {
    final part = File('${dir.path}/download.part');
    await Net.instance.refreshCookies();
    final got = await Net.instance
        .download(link.url, part, headers: link.headers, partition: plugin.id, onProgress: onProgress);
    final name = _fileName(got.name, book, file);
    final named = await part.rename('${dir.path}/$name');
    return await store.importFile(PickedFile(path: named.path, name: name, mime: got.type), onNote: onNote);
  } finally {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Swept at a later start (LibraryStore.sweepIncoming).
    }
  }
}

/// The downloaded file's name: the book's own (as the source gave it), so
/// a file with no title inside (a PDF, often) is not shelved under the
/// site's file name; the extension from the site's name, else the format.
String _fileName(String? given, SourceBook book, BookFile file) {
  String clean(String t) => t.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  final title = clean(book.name);
  final named = clean(given ?? '');
  final dot = named.lastIndexOf('.');
  final ext = dot > 0 && dot < named.length - 1 ? named.substring(dot + 1) : (file.format == 'file' ? 'epub' : file.format);
  if (title.isEmpty) return named.isNotEmpty && dot > 0 ? named : 'book.$ext';
  return '$title.$ext';
}

/// A book from a book-file source: its cover, name, author and blurb, and a
/// button for each file it comes as. A tap downloads it into the library.
class BookSourceScreen extends StatefulWidget {
  const BookSourceScreen({
    super.key,
    required this.store,
    required this.plugin,
    required this.path,
    required this.name,
    this.cover,
  });

  final LibraryStore store;
  final PluginInfo plugin;
  final String path;
  final String name;
  final String? cover;

  @override
  State<BookSourceScreen> createState() => _BookSourceScreenState();
}

class _BookSourceScreenState extends State<BookSourceScreen> {
  SourceBook? _book;
  Object? _error;

  /// The file being downloaded, and how far it is (0 to 1; null: not said).
  BookFile? _getting;
  double? _progress;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final b = await SourceEngine.instance.book(widget.plugin, widget.path);
      if (mounted) setState(() => _book = b);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _get(BookFile file) async {
    final book = _book;
    if (book == null || _getting != null) return;
    setState(() {
      _getting = file;
      _progress = null;
    });
    try {
      final added = await addFromSource(widget.store, widget.plugin, book, file, onProgress: (done, total) {
        if (mounted && total > 0) setState(() => _progress = done / total);
      });
      if (!mounted) return;
      showSnack(context, 'Added to your library.',
          actionLabel: 'Open', onAction: () => unawaited(openBook(context, widget.store, added)));
    } on HttpException catch (e) {
      if (!mounted) return;
      final m = e.message;
      // Signed out (never signed in, or the site's sign-in ran out): said
      // so, with the way back in a tap away.
      if (m.contains('HTTP 401') || m.contains('HTTP 403')) {
        showSnack(context, '${widget.plugin.name} wants you signed in to download.',
            long: true,
            actionLabel: 'Sign in',
            onAction: () => unawaited(signInToSite(context, widget.plugin)));
      } else if (m.contains('HTTP 429')) {
        showSnack(context, '${widget.plugin.name} says you have downloaded as much as it allows for now. Try later.',
            long: true);
      } else {
        showSnack(context, 'It could not be downloaded: ${friendlyError(e)}');
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, 'It could not be downloaded: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _getting = null);
    }
  }

  static String _size(int bytes) => bytes >= 1 << 20
      ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final cover = book?.cover ?? widget.cover;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: widget.plugin.name, onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: _error != null && book == null
                    ? EmptyState(
                        icon: Icons.cloud_off_rounded,
                        title: 'Could not open the book',
                        body: friendlyError(_error!),
                        action: FilledButton(onPressed: () => unawaited(_load()), child: const Text('Try again')),
                      )
                    : ListView(
                        padding: EdgeInsets.fromLTRB(
                            Gap.page, Gap.s, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  width: 110,
                                  height: 160,
                                  child: cover == null
                                      ? ColoredBox(color: Skin.capsuleOn(context))
                                      : Image(
                                          image: NetImage(cover, referer: widget.plugin.site, partition: widget.plugin.id),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => ColoredBox(color: Skin.capsuleOn(context)),
                                        ),
                                ),
                              ),
                              const SizedBox(width: Gap.l),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(book?.name ?? widget.name, style: Skin.title(context, size: 22)),
                                    if (book?.author != null) ...[
                                      const SizedBox(height: Gap.xs),
                                      Text(book!.author!, style: Skin.meta(context, size: 14)),
                                    ],
                                    if (book != null && (book.year != null || book.language != null)) ...[
                                      const SizedBox(height: Gap.xs),
                                      Text([book.year, book.language].whereType<String>().join(' · '),
                                          style: Skin.meta(context)),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: Gap.l),
                          if (book == null)
                            const Center(child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator()))
                          else ...[
                            for (final f in book.files)
                              Padding(
                                padding: const EdgeInsets.only(bottom: Gap.s),
                                child: FilledButton.tonalIcon(
                                  onPressed: _getting == null ? () => unawaited(_get(f)) : null,
                                  icon: _getting == f
                                      ? SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2, value: _progress),
                                        )
                                      : const Icon(Icons.download_rounded),
                                  label: Text(f.label ??
                                      [f.format.toUpperCase(), if (f.size != null) _size(f.size!)].join(' · ')),
                                ),
                              ),
                            if (book.summary != null) ...[
                              const SizedBox(height: Gap.m),
                              Text(book.summary!,
                                  style: Skin.page(context, size: 16, height: 1.5).copyWith(color: Skin.inkSoftOn(context))),
                            ],
                          ],
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
