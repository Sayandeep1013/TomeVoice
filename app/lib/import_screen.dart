import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart'
    show EncryptedDocumentException, ParseException, UnsupportedDocumentException;

import 'catalogues_screen.dart';
import 'highlight_import.dart';
import 'library_store.dart';
import 'noveldokusha_import.dart';
import 'ocr.dart' show ScannedPdf;
import 'sources/source_engine.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// Bringing books and highlights from other reading apps and shops.
///
/// Most shops sell books locked to their own apps (DRM), and TomeVoice
/// never unlocks a book. So for each place this says, plainly, what can
/// come out of it and how, then takes what comes: book files (EPUB, PDF and
/// the rest), and highlights, which are put into the books they belong to.
class ImportScreen extends StatelessWidget {
  const ImportScreen({super.key, required this.store, this.onBooks});

  final LibraryStore store;

  /// Pick book files and add them as the library does (its shelf shows
  /// them arriving). Without it, they are added here.
  final Future<void> Function()? onBooks;

  Future<void> _books(BuildContext context) async {
    final add = onBooks;
    if (add != null) {
      Navigator.of(context).pop();
      await add();
      return;
    }
    await importBookFiles(context, store);
  }

  @override
  Widget build(BuildContext context) {
    final soft = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Import from another app', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    Text(
                      'Shops sell most books locked (DRM) to their own apps, and TomeVoice never unlocks a book. '
                      'What can come out, and how, for each:',
                      style: soft,
                    ),
                    const SizedBox(height: Gap.l),
                    const SectionTitle('Books'),
                    _Source(
                      name: 'Kindle',
                      steps: const [
                        'Some Kindle books can now be downloaded as EPUB or PDF, where the author allows it: on '
                            'amazon.com, Content & Devices, Books, the book\'s More actions, Download EPUB (or PDF).',
                        'Your own documents sent to Kindle: Content & Devices, Docs, Actions, Download.',
                        'Other Kindle books are locked to Kindle and cannot come across.',
                        'If a download comes as a .zip, open it in Files first and choose the EPUB inside.',
                      ],
                      action: 'Choose the downloaded books',
                      onTap: () => unawaited(_books(context)),
                    ),
                    _Source(
                      name: 'Google Play Books',
                      steps: const [
                        'On play.google.com: Library, Books, the book\'s menu (⋮), Export, Download EPUB (or PDF). '
                            'Books you uploaded yourself export as they were.',
                        'If you get an .acsm file instead, the publisher sells that book locked: it cannot be '
                            'opened here.',
                      ],
                      action: 'Choose the downloaded books',
                      onTap: () => unawaited(_books(context)),
                    ),
                    _Source(
                      name: 'Kobo',
                      steps: const [
                        'On kobo.com: My Account, My Books, the book\'s Actions, Download. A book without DRM '
                            'comes as an EPUB; an .acsm means it is locked.',
                      ],
                      action: 'Choose the downloaded books',
                      onTap: () => unawaited(_books(context)),
                    ),
                    _Source(
                      name: 'AO3, Calibre and other files',
                      steps: const [
                        'AO3: on a work, Download, EPUB.',
                        'Calibre: copy the books\' files to the phone, or turn on Calibre\'s content server and add '
                            'it under Catalogues (http://your-computer:8080/opds).',
                        'Any EPUB, PDF, DjVu, Word, MOBI/AZW without DRM, FB2, RTF, HTML or text file.',
                      ],
                      action: 'Choose book files',
                      onTap: () => unawaited(_books(context)),
                      second: 'Catalogues',
                      onSecond: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => CataloguesScreen(store: store),
                      )),
                    ),
                    _Source(
                        name: 'NovelDokusha',
                        steps: const [
                          'In NovelDokusha: Settings, Backup, Create backup. It saves a .zip: your web novels, '
                              'where you were in them and the chapters downloaded.',
                        ],
                        action: 'Choose the backup',
                        onTap: () => unawaited(importFromNovelDokusha(context, store)),
                      ),
                    const SizedBox(height: Gap.l),
                    const SectionTitle('Highlights and notes'),
                    Text(
                      'Each highlight is put in its book, at the sentence it was made at, as a quote, with its note. '
                      'Add the books first; one whose book is not here, or another edition\'s, is said and left out.',
                      style: soft,
                    ),
                    const SizedBox(height: Gap.m),
                    _Source(
                      name: 'Kindle highlights',
                      steps: const [
                        'Connect the Kindle to a computer (or the phone, with a USB cable) and copy '
                            'documents/My Clippings.txt from it. It holds every highlight and note made on that Kindle.',
                        'Highlights made in the Kindle app on a phone are not in it: there, a book\'s Notebook can be '
                            'shared, but not yet read here.',
                      ],
                      action: 'Choose My Clippings.txt',
                      onTap: () => unawaited(_highlights(context, store, _Kind.kindle)),
                    ),
                    _Source(
                      name: 'KOReader highlights',
                      steps: const [
                        'Beside each book KOReader keeps a folder named like the book with .sdr after it. Copy the '
                            'metadata file inside (metadata.epub.lua, for an EPUB) to the phone; several at once is fine.',
                      ],
                      action: 'Choose the metadata files',
                      onTap: () => unawaited(_highlights(context, store, _Kind.koreader)),
                    ),
                    _Source(
                      name: 'Kobo, Google Play Books, Libby',
                      steps: const [
                        'Kobo (kobo.com, My Books, Export annotations), Google Play Books (notes saved to a Google '
                            'Doc in Drive) and Libby (Reading Journey, Export) can give out highlights, but they are '
                            'not read here yet.',
                      ],
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

enum _Kind { kindle, koreader }

/// Highlights from [kind]'s files, picked, put into the library's books.
Future<void> _highlights(BuildContext context, LibraryStore store, _Kind kind) async {
  final List<PickedFile> files;
  try {
    files = await _svc.pickDocuments();
  } on Object {
    if (context.mounted) showSnack(context, 'The file picker could not open. Try again.');
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  final found = <ForeignHighlight>[];
  for (final f in files) {
    try {
      final raw = await File(f.path).readAsString();
      found.addAll(switch (kind) {
        _Kind.kindle => parseKindleClippings(raw),
        _Kind.koreader => parseKoreaderSidecar(raw, fileName: f.name),
      });
    } on Object {
      // Not text: said below if nothing came of any.
    }
  }
  if (!context.mounted) return;
  if (found.isEmpty) {
    showSnack(
      context,
      kind == _Kind.kindle
          ? 'No highlights in that file. It should be My Clippings.txt from the Kindle\'s documents folder.'
          : 'No highlights in that file. It should be a metadata….lua file from a book\'s .sdr folder.',
      long: true,
    );
    return;
  }
  final report = await _withProgress(
    context,
    'Placing ${found.length} highlights…',
    (progress) => importHighlights(store, found,
        onProgress: (title, done, total) => progress.value = '$title (${done + 1} of $total)'),
  );
  if (report != null && context.mounted) showSnack(context, report.summary, long: true);
}

/// [work] under a dialog that says what it is doing; null if it failed
/// (said in a snack bar).
Future<T?> _withProgress<T>(BuildContext context, String first, Future<T> Function(ValueNotifier<String>) work) async {
  final progress = ValueNotifier<String>(first);
  final nav = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Importing'),
        content: Row(
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: Gap.l),
            Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, v, __) => Text(v))),
          ],
        ),
      ),
    ),
  ));
  try {
    return await work(progress);
  } on Object catch (e) {
    if (context.mounted) showSnack(context, e is PlatformException ? (e.message ?? e.code) : '$e', long: true);
    return null;
  } finally {
    nav.pop();
    progress.dispose();
  }
}

/// Book files picked and added to the library, saying how it went (from
/// Settings; the library adds them itself, showing them arrive).
Future<void> importBookFiles(BuildContext context, LibraryStore store) async {
  final List<PickedFile> files;
  try {
    files = await _svc.pickDocuments();
  } on Object {
    if (context.mounted) showSnack(context, 'The file picker could not open. Try again.');
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  final failures = <String>[];
  var added = 0;
  await _withProgress(context, 'Adding ${files.length == 1 ? files.first.name : '${files.length} books'}…', (progress) async {
    for (final (i, f) in files.indexed) {
      progress.value = '${f.name} (${i + 1} of ${files.length})';
      try {
        await store.importFile(f);
        added++;
      } on Object catch (e) {
        final message = switch (e) {
          ScannedPdf() => 'a scanned PDF: add it from the Library to read its pages.',
          UnsupportedDocumentException(:final message) => message,
          EncryptedDocumentException(:final message) => message,
          ParseException(:final message) => message,
          PlatformException(:final message, :final code) => message ?? code,
          _ => '$e',
        };
        failures.add(files.length > 1 ? '${f.name}: $message' : message);
      }
    }
  });
  if (!context.mounted) return;
  showSnack(
    context,
    [
      if (added > 0) 'Added ${added == 1 ? 'the book' : '$added books'} to your library.',
      ...failures.take(2),
    ].join(' '),
    long: true,
  );
}

/// Web novels from a NovelDokusha backup (.zip): details, chapter lists,
/// places and downloaded chapters.
Future<void> importFromNovelDokusha(BuildContext context, LibraryStore store) async {
  final List<PickedFile> files;
  try {
    files = await _svc.pickDocuments();
  } on Object catch (e) {
    debugPrint('File picker failed: $e');
    if (context.mounted) showSnack(context, 'The file picker could not open. Try again.');
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  final report = await _withProgress(context, 'Reading the backup…', (progress) async {
    final json = await _svc.readNovelDokushaBackup(files.first.path);
    return importNovelDokushaJson(store, SourceEngine.instance.store, json,
        onProgress: (title, done, total) => progress.value = '$title (${done + 1} of $total)');
  });
  if (report == null || !context.mounted) return;
  showSnack(
    context,
    report.novels == 0
        ? 'That backup has no web novels in its library.'
        : 'Imported ${report.novels} ${report.novels == 1 ? 'novel' : 'novels'} '
            'with ${report.chapters} downloaded ${report.chapters == 1 ? 'chapter' : 'chapters'}.'
            '${report.unmatched.isEmpty ? '' : ' Install a source for ${report.unmatched.join(', ')} to get new chapters.'}',
    long: true,
  );
}

/// One place to import from: its name, how to get what it gives out, and
/// what to do with that.
class _Source extends StatefulWidget {
  const _Source({required this.name, required this.steps, this.action, this.onTap, this.second, this.onSecond});

  final String name;
  final List<String> steps;
  final String? action;
  final VoidCallback? onTap;
  final String? second;
  final VoidCallback? onSecond;

  @override
  State<_Source> createState() => _SourceState();
}

class _SourceState extends State<_Source> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Material(
        color: Skin.capsuleOn(context),
        shape: Skin.cardShape(context, Radii.row),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                child: Row(
                  children: [
                    Expanded(child: Text(widget.name, style: Skin.label(context, size: 16, color: Skin.inkOn(context)))),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: Motion.of(context, Motion.quick),
                      curve: Motion.out,
                      child: Icon(Icons.expand_more_rounded, color: Skin.inkSoftOn(context)),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: Motion.of(context, Motion.standard),
              curve: Motion.out,
              alignment: Alignment.topCenter,
              child: !_open
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, step) in widget.steps.indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: Gap.s),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 22,
                                    child: Text('${i + 1}', style: Skin.meta(context, color: Skin.accentInkOf(context))),
                                  ),
                                  Expanded(child: Text(step, style: faint)),
                                ],
                              ),
                            ),
                          if (widget.action != null || widget.second != null)
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: Gap.s,
                              children: [
                                if (widget.second != null)
                                  OutlinedButton(onPressed: widget.onSecond, child: Text(widget.second!)),
                                if (widget.action != null)
                                  FilledButton(onPressed: widget.onTap, child: Text(widget.action!)),
                              ],
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
