// OCR for scanned PDFs, the Dart side: the languages offered, what Tesseract
// reads turned into a book through the PDF pipeline, the scan's text kept so
// it is never read again, and the jobs that track the reading. The reading
// itself is Kotlin (Ocr.kt), so the platform is mocked here. The language
// data's downloads are in ocr_download_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/ocr.dart';
import 'package:tomevoice_spike/ocr_jobs.dart';
import 'package:tomevoice_spike/ocr_sheet.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

final _ff = String.fromCharCode(0x0C);
final _mark = String.fromCharCode(0x2029);

/// A traineddata file as tessdata_fast has them: a count of entries, where
/// each starts (-1 for none), then the entries.
Uint8List traineddata(int size) {
  final b = ByteData(size);
  const n = 24;
  b.setInt32(0, n, Endian.little);
  final starts = [for (var i = 0; i < n; i++) i < 17 ? -1 : 4 + 8 * n + (i - 17) * 1000];
  for (var i = 0; i < n; i++) {
    b.setInt64(4 + 8 * i, starts[i], Endian.little);
  }
  final r = math.Random(7);
  for (var i = 4 + 8 * n; i < size; i++) {
    b.setUint8(i, r.nextInt(256));
  }
  return b.buffer.asUint8List();
}

/// The platform's text of a scan of [pages] pages: nothing on any of them.
Map<String, Object?> scanText(int pages, {Map<int, String> typed = const {}}) => {
      'text': [for (var p = 0; p < pages; p++) '${typed[p] ?? ''}$_ff'].join(),
      'pages': pages,
      'title': null,
      'author': null,
      'outline': const [],
      'layout': [for (var p = 0; p < pages; p++) <int>[]],
    };

/// Page [p] of a scanned novel as Tesseract reads it: a running head, the
/// text in paragraphs (a blank line after each), and the page number. Its
/// lines differ from page to page, as a book's do: a line on every page is
/// a running head. Chapters open on pages 1, 5 and 9.
String ocrPage(int p) {
  const words = ['amber', 'birch', 'cedar', 'dune', 'ember', 'fern', 'gorse', 'heath', 'iris', 'juniper', 'kelp'];
  final w = words[p % words.length];
  final v = words[(p + 5) % words.length];
  final opening = p % 4 == 1 ? 'CHAPTER ${['I', 'II', 'III'][p ~/ 4]}\n\nThe ${w[0].toUpperCase()}${w.substring(1)} Road\n\n' : '';
  return 'THE LANTERN KEEPER\n\n'
      '$opening'
      'The keeper climbed the $w stairs of the light-\nhouse every evening, and the $v sellers\n'
      'went home along the shingle in a patient row.\n\n'
      'Nobody was about but the gulls, who watched\nhim go up the $v path and down at dawn.\n\n'
      '${p + 1}\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final calls = <MethodCall>[];

  /// What the platform says a PDF's text is, by the file's path.
  final pdfs = <String, Map<String, Object?>>{};

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tomevoice_ocr');
    OcrData.instance.attach(tmp);
    OcrJobs.instance.reset();
    calls.clear();
    pdfs.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'extractPdf' => pdfs[(call.arguments as Map)['path']] ?? scanText(3),
        'ocrStart' => 'started',
        'outputDir' => tmp.path,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    OcrJobs.instance.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  /// A file picked into incoming/, as MainActivity copies one in.
  File picked(String name, List<int> bytes) =>
      File('${tmp.path}/incoming/${name.hashCode}/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  /// A job as an older build left one: [pages] to read, the PDF's own text
  /// [pdf], and why it stopped.
  Directory olderJob(String name, Map<String, Object?> pdf, {List<int> pages = const [], String? error}) {
    final f = picked(name, utf8.encode('%PDF-1.4 $name'));
    final id = bookIdOf(f.readAsBytesSync());
    final dir = Directory('${tmp.path}/ocr/jobs/$id')..createSync(recursive: true);
    final source = f.renameSync('${dir.path}/source.pdf');
    File('${dir.path}/pdf.json').writeAsStringSync(jsonEncode(pdf));
    File('${dir.path}/job.json').writeAsStringSync(jsonEncode({
      'id': id,
      'name': name,
      'source': source.path,
      'pages': pages,
      'languages': 'eng',
      if (error != null) 'error': error,
    }));
    return dir;
  }

  group('languages', () {
    test('the catalogue is tessdata_fast, with Bengali and Hindi to the byte', () {
      expect({for (final l in ocrLanguages) l.code}, hasLength(ocrLanguages.length));
      expect(ocrLanguageByCode('ben')!.bytes, 855841);
      expect(ocrLanguageByCode('hin')!.bytes, 1122751);
      expect(ocrLanguageByCode('eng')!.bytes, 4113088);
      for (final c in featuredOcrLanguages) {
        expect(ocrLanguageByCode(c), isNotNull, reason: c);
      }
      // Not languages, or not files.
      expect(ocrLanguageByCode('osd'), isNull);
      expect(ocrLanguageByCode('frk'), isNull);
      expect(ocrLanguageByCode('ben')!.url.toString(),
          'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/$tessdataCommit/ben.traineddata');
      expect(ocrLanguageByCode('ben')!.label, 'Bengali · বাংলা');
    });

    test('a language tag finds what Tesseract reads it as', () {
      expect(ocrLanguageForIso('bn')?.code, 'ben');
      expect(ocrLanguageForIso('bn-IN')?.code, 'ben');
      expect(ocrLanguageForIso('hi_IN')?.code, 'hin');
      expect(ocrLanguageForIso('zh')?.code, 'chi_sim');
      expect(ocrLanguageForIso('zh-Hant-TW')?.code, 'chi_tra');
      expect(ocrLanguageForIso('nb')?.code, 'nor');
      expect(ocrLanguageForIso('iw')?.code, 'heb');
      expect(ocrLanguageForIso('xx'), isNull);
      expect(ocrLanguageForIso(null), isNull);
    });

    test("the book's language and the app's are offered; a book that says nothing gets the last picked", () {
      List<String> codes(List<OcrLanguage> ls) => [for (final l in ls) l.code];
      expect(codes(defaultOcrLanguages(book: 'bn', app: 'en')), ['ben', 'eng']);
      expect(codes(defaultOcrLanguages(book: 'en', app: 'en')), ['eng']);
      expect(codes(defaultOcrLanguages(app: 'en')), ['eng']);
      expect(codes(defaultOcrLanguages(app: 'en', last: ['ben'])), ['ben', 'eng']);
      expect(codes(defaultOcrLanguages(book: 'hi', app: 'en', last: ['ben'])), ['hin', 'eng']);
      expect(codes(defaultOcrLanguages(app: 'xx')), ['eng']);
      expect(ocrLanguageString(defaultOcrLanguages(book: 'bn', app: 'en')), 'ben+eng');
      expect(codes(ocrLanguagesOf('ben+eng+nope')), ['ben', 'eng']);
    });

    test('the languages picked last are remembered for next time', () async {
      expect(OcrData.instance.lastPicked(), isEmpty);
      await OcrData.instance.remember([ocrLanguageByCode('hin')!, ocrLanguageByCode('eng')!]);
      expect(OcrData.instance.lastPicked(), ['hin', 'eng']);
    });

    test('a traineddata file is told from a web page or a file cut short', () {
      final good = traineddata(9000);
      expect(looksLikeTraineddata(good.sublist(0, 600), 9000), isTrue);
      expect(looksLikeTraineddata(Uint8List.fromList(utf8.encode('<!DOCTYPE html><html>' * 30)), 9000), isFalse);
      expect(looksLikeTraineddata(good.sublist(0, 600), 4000), isFalse, reason: 'its entries run past the end');
      expect(looksLikeTraineddata(Uint8List(3), 9000), isFalse);
    });
  });

  group('the text OCR reads', () {
    test("Tesseract's paragraphs become the platform's", () {
      final page = ocrPageText('First line\nsecond line\n\n  \nNext para-\ngraph here\n${_ff}tail\n');
      expect(page, '${_mark}First line\nsecond line\n${_mark}Next para-\ngraph here\n${_mark}tail');
      expect(ocrPageText('\n\n'), '');
    });

    test('pages with text keep theirs, their layout and raised runs; the others are what OCR read', () {
      final pdf = {
        ...scanText(4, typed: {1: '${_mark}A typed notice of the publisher, kept as it is.'}),
        'layout': [<int>[], [1, 2, 3, 4, 5], <int>[], <int>[]],
        'raised': [<int>[], [0, 8, 1], <int>[], [0, 1, 1]],
        'title': 'The Lantern Keeper',
        'outline': [
          {'title': 'One', 'page': 0, 'level': 0},
        ],
      };
      final merged = ocrPdfText(pdf, {0: 'Page one\n', 2: 'Page three\n', 3: ''}, languages: 'ben+eng');
      final pages = (merged['text'] as String).split(_ff);
      expect(pages, hasLength(5), reason: 'every page ends with a page break');
      expect(pages.last, isEmpty);
      expect(pages[0], '${_mark}Page one');
      expect(pages[1], '${_mark}A typed notice of the publisher, kept as it is.');
      expect(pages[3], isEmpty);
      expect(merged['layout'], [<int>[], [1, 2, 3, 4, 5], <int>[], <int>[]]);
      expect(merged['raised'], [<int>[], [0, 8, 1], <int>[], <int>[]], reason: 'an OCR read page has none');
      expect(merged['pages'], 4);
      expect(merged['ocr'], 'ben+eng');
      expect(merged['ocrPages'], [0, 2, 3]);
      expect(merged['title'], 'The Lantern Keeper');
      expect(merged['outline'], pdf['outline']);
      // Stored as JSON and read back the same.
      expect(jsonDecode(jsonEncode(merged)), merged);
    });

    test('only the pages without text are read', () {
      final pdf = scanText(6, typed: {
        2: '$_mark${'The keeper climbed the stairs every evening at six. ' * 3}',
      });
      expect(ocrPagesToRead(pdf), [0, 1, 3, 4, 5]);
      expect(ocrPagesToRead(scanText(3)), [0, 1, 2]);
    });

    test("an extraction that left a page out is read whole: which page has which text is not known", () {
      // Six pages, the third with nothing drawn on it: PDFBox wrote no page
      // break for it, and the typed page that was the fourth came third.
      final typed = '$_mark${'The keeper climbed the stairs every evening at six. ' * 3}';
      final pdf = {...scanText(5, typed: {2: typed}), 'pages': 6};
      expect(ocrPagesToRead(pdf), [0, 1, 2, 3, 4, 5]);
    });

    test('a scan read by OCR is a book as any PDF: heads, numbers and broken words mended, chapters found', () {
      final read = {for (var p = 0; p < 12; p++) p: ocrPage(p)};
      final merged = ocrPdfText(scanText(12), read, languages: 'eng');
      final book = ingestPdfText(
        id: 'scan',
        pages: (merged['text'] as String).split(_ff),
        layout: pdfLayoutFromPlatform(merged['layout']),
        filename: 'The Lantern Keeper.pdf',
      );
      final texts = [
        for (final s in book.sections)
          for (final b in s.blocks) b.text,
      ];
      final all = texts.join(' ');
      expect(all, contains('amber stairs of the lighthouse every evening'), reason: 'a broken word mended');
      expect(all, isNot(contains('THE LANTERN KEEPER')), reason: 'the running head is not read');
      expect(texts.where((t) => RegExp(r'^\d+$').hasMatch(t)), isEmpty, reason: 'nor are the page numbers');
      expect(texts.where((t) => t.startsWith('Nobody was about')), hasLength(12), reason: 'paragraphs stay paragraphs');
      expect([for (final s in book.sections) s.title],
          containsAll([contains('Birch Road'), contains('Fern Road'), contains('Juniper Road')]));
      expect(book.metadata.title, 'The Lantern Keeper');
    });

    test('Bengali read by OCR is a Bengali book', () {
      const words = ['সে', 'প্রতিদিন', 'সন্ধ্যায়', 'বাতিঘরের', 'সিঁড়ি', 'বেয়ে', 'উপরে', 'উঠত', 'আর', 'গাঙচিলেরা', 'তাকে', 'দেখত', 'নদীর', 'ধারে', 'নৌকা', 'বাঁধা', 'ছিল'];
      String line(int p, int k) => '${[for (var i = 0; i < 9; i++) words[(p * 3 + k * 5 + i) % words.length]].join(' ')}।';
      final read = {for (var p = 0; p < 4; p++) p: '${line(p, 0)}\n${line(p, 1)}\n\n${line(p, 2)}\n'};
      final merged = ocrPdfText(scanText(4), read, languages: 'ben');
      final book = ingestPdfText(id: 'bn', pages: (merged['text'] as String).split(_ff));
      expect(book.metadata.language, 'bn');
      expect(book.wordCount, greaterThan(50));
    });
  });

  /// A scan read to its end, made into a book in [store]: its job as
  /// OcrJobs.start leaves one, and its pages as Ocr.kt writes them. [outline]
  /// is the scan's own bookmarks.
  Future<LibraryEntry> ocrBook(LibraryStore store, File pdf, {int pages = 12, List<Object?> outline = const []}) async {
    final id = bookIdOf(pdf.readAsBytesSync());
    final dir = Directory('${tmp.path}/ocr/jobs/$id')..createSync(recursive: true);
    final source = pdf.renameSync('${dir.path}/source.pdf');
    File('${dir.path}/pdf.json').writeAsStringSync(jsonEncode({...scanText(pages), 'outline': outline}));
    File('${dir.path}/job.json').writeAsStringSync(jsonEncode({
      'id': id,
      'name': 'The Lantern Keeper.pdf',
      'source': source.path,
      'pages': [for (var p = 0; p < pages; p++) p],
      'languages': 'eng',
    }));
    for (var p = 0; p < pages; p++) {
      File('${dir.path}/pages/$p.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync(ocrPage(p));
    }
    return store.addOcrBook(dir.path);
  }

  /// Let real file work and isolates finish, then settle the frame.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  group('a scan in the library', () {
    late LibraryStore store;
    setUp(() => store = LibraryStore(tmp));

    Future<LibraryEntry> made(File pdf) => ocrBook(store, pdf);

    test('a refused scan keeps its file, to be read with OCR', () async {
      final f = picked('scan.pdf', utf8.encode('%PDF-1.4 a scan of pictures'));
      pdfs[f.path] = scanText(5);
      final failed = store.importFile(PickedFile(path: f.path, name: 'scan.pdf'));
      await expectLater(failed, throwsA(isA<ScannedPdf>()));
      final scan = await failed.then<ScannedPdf?>((_) => null, onError: (Object e) => e as ScannedPdf);
      expect(scan!.offer.path, f.path);
      expect(scan.offer.imported, isFalse);
      expect(scan.offer.pageCount, 5);
      expect(f.existsSync(), isTrue, reason: 'kept for OCR');
      expect(scan.message, contains('scanned'), reason: 'still says why, where OCR is not offered');
      expect(await store.list(), isEmpty);

      await declineOcr(scan.offer);
      expect(f.existsSync(), isFalse, reason: 'declined, the copy goes');
      expect(f.parent.existsSync(), isFalse);
    });

    test("a refused scan's language is told by a name in its own script", () async {
      Future<OcrOffer> refused(String name) async {
        final f = picked(name, utf8.encode('%PDF-1.4 $name'));
        pdfs[f.path] = scanText(3);
        final scan = await store
            .importFile(PickedFile(path: f.path, name: name))
            .then<ScannedPdf?>((_) => null, onError: (Object e) => e as ScannedPdf);
        return scan!.offer;
      }

      expect((await refused('সোনার তরী.pdf')).language, 'bn');
      expect((await refused('The Lantern Keeper.pdf')).language, isNull, reason: 'Latin letters do not say which');
    });

    test('a PDF with a few typed pages is imported, and OCR is offered for the rest', () async {
      final f = picked('mostly.pdf', utf8.encode('%PDF-1.4 mostly pictures'));
      final typed = '$_mark${'The keeper climbed the stairs of the lighthouse every evening at six. ' * 6}';
      pdfs[f.path] = scanText(10, typed: {0: typed, 1: typed});
      final offers = <OcrOffer>[];
      final notes = <String>[];
      final entry = await store.importFile(
        PickedFile(path: f.path, name: 'mostly.pdf'),
        onNote: notes.add,
        onScan: offers.add,
      );
      expect(notes, isEmpty, reason: 'told as an offer instead');
      expect(offers.single.bookId, entry.id);
      expect(offers.single.imported, isTrue);
      expect(offers.single.path, entry.sourcePath);
      expect(ocrPagesToRead(offers.single.pdf), [2, 3, 4, 5, 6, 7, 8, 9]);
      expect(entry.ocr, isNull);
    });

    test('made whole by OCR while a reader is open on it, a book keeps the place carried into it', () async {
      // Typed text on its last two pages only: OCR reads the eight before,
      // and in the book made of them the typed sentences come later.
      String typed(int p) => '$_mark${[for (var i = 0; i < 8; i++) 'Line $i of page $p tells of the keeper and the gulls.'].join(' ')}';
      final f = picked('mostly.pdf', utf8.encode('%PDF-1.4 two typed pages'));
      final pdf = scanText(10, typed: {8: typed(8), 9: typed(9)});
      pdfs[f.path] = pdf;
      final entry = await store.importFile(PickedFile(path: f.path, name: 'mostly.pdf'), onScan: (_) {});
      final open = await store.loadLayout(entry.id);
      const u = 3;
      await store.saveCursor(entry.id, cursorOf(open.units[u]), 0.1, layout: open);

      final dir = Directory('${tmp.path}/ocr/jobs/${entry.id}')..createSync(recursive: true);
      File('${dir.path}/pdf.json').writeAsStringSync(jsonEncode(pdf));
      File('${dir.path}/job.json').writeAsStringSync(jsonEncode({
        'id': entry.id,
        'name': 'mostly.pdf',
        'source': entry.sourcePath,
        'pages': [for (var p = 0; p < 8; p++) p],
        'languages': 'eng',
      }));
      for (var p = 0; p < 8; p++) {
        File('${dir.path}/pages/$p.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync(ocrPage(p));
      }
      await store.addOcrBook(dir.path);
      final carried = await store.cursorFor(entry.id);
      expect(carried.toJson(), isNot(cursorOf(open.units[u]).toJson()), reason: 'the sentence moved');
      expect((await store.list()).single.cursor.toJson(), carried.toJson(), reason: 'the index has it too');

      // The reader still open on the book as it was saves where it has got
      // to, counted the old way: not over the place carried.
      await store.saveCursor(entry.id, cursorOf(open.units[u + 1]), 0.12, layout: open);
      expect((await store.cursorFor(entry.id)).toJson(), carried.toJson());
      final now = await store.loadLayout(entry.id);
      expect(now.units[now.unitForCursor(carried, saved: true)].text, open.units[u].text);
      // Open on the new book, it saves as ever.
      await store.saveCursor(entry.id, cursorOf(now.units[5]), 0.2, layout: now);
      expect((await store.cursorFor(entry.id)).toJson(), cursorOf(now.units[5]).toJson());
    });

    test('what OCR read is made into a book, marked, and its text kept', () async {
      final pdf = picked('lantern.pdf', utf8.encode('%PDF-1.4 the lantern keeper, scanned'));
      final entry = await made(pdf);
      expect(entry.ocr, 'eng');
      expect(entry.title, 'The Lantern Keeper');
      expect(entry.source, SourceKind.pdf);
      expect(entry.pdfParser, pdfParserVersion);
      expect(File(entry.sourcePath).existsSync(), isTrue);
      expect(entry.sourcePath, endsWith('/books/${entry.id}/source.pdf'));
      expect(File('${store.bookDir(entry.id)}/ocr.json').existsSync(), isTrue);
      expect(Directory('${tmp.path}/ocr/jobs/${entry.id}').existsSync(), isFalse, reason: 'the job is done with');
      final listed = (await store.list()).single;
      expect(listed.ocr, 'eng', reason: 'kept in the index');
      expect(LibraryEntry.fromJson(listed.toJson()).ocr, 'eng');

      final layout = await store.loadLayout(entry.id);
      expect(layout.units.map((u) => u.text).join(' '), contains('lighthouse'));
      expect(layout.chapters.length, greaterThanOrEqualTo(3));
    });

    test("a PDF's note mark, set small and raised, is shown in the book and not said", () async {
      // As PdfText.kt reads a typed page: two lines, where they sit, and the
      // "1" after "Michaelmas," set small and raised.
      const lines = [
        'The keeper climbed the stairs of the lighthouse every evening, long before',
        'Michaelmas,1 and the gulls watched him go up the path and come down at dawn.',
      ];
      final f = picked('notes.pdf', utf8.encode('%PDF-1.4 a book with a note'));
      pdfs[f.path] = {
        'text': '$_mark${lines.join('\n')}$_ff',
        'pages': 1,
        'title': 'The Lantern Keeper',
        'author': null,
        'outline': const [],
        'layout': [
          [72, 100, 400, 105, lines[0].length, 72, 114, 400, 105, lines[1].length],
        ],
        'raised': [
          [1, 11, 1],
        ],
      };
      final entry = await store.importFile(PickedFile(path: f.path, name: 'notes.pdf'));
      final layout = await store.loadLayout(entry.id);
      final unit = layout.units.firstWhere((u) => u.text.contains('Michaelmas'));
      expect(unit.text, contains('long before Michaelmas,1 and the gulls'), reason: 'shown');
      expect(spokenText(unit.text, unit.silent).text, contains('long before Michaelmas, and the gulls'));
    });

    test("a scan's bookmarks, a picture's name on every page, are not its chapters", () async {
      // As an image-to-PDF tool makes a scan: a bookmark a page, named after
      // the page's picture. Each was a chapter, its name over the page.
      final pdf = picked('kheya.pdf', utf8.encode('%PDF-1.4 a scan, a bookmark a page'));
      final entry = await ocrBook(store, pdf, outline: [
        for (var p = 0; p < 12; p++) {'title': 'DSC0${1139 + p}.tif', 'page': p, 'level': 0},
      ]);
      List<String> chapters(ReadingLayout l) => [for (var c = 0; c < l.chapters.length; c++) l.chapterTitle(c)];
      final layout = await store.loadLayout(entry.id);
      expect(chapters(layout), [contains('Birch Road'), contains('Fern Road'), contains('Juniper Road')]);
      expect(layout.units.map((u) => u.text).join(' '), isNot(contains('DSC0')));

      // A book made from the same scan by an older PDF reader, its pictures'
      // names its chapters, is made again from the text OCR gave it.
      final index = File('${tmp.path}/library.json');
      index.writeAsStringSync(index.readAsStringSync().replaceAll('"pdfParser": $pdfParserVersion', '"pdfParser": 4'));
      final again = LibraryStore(tmp);
      expect(chapters(await again.loadLayout(entry.id)), [contains('Birch Road'), contains('Fern Road'), contains('Juniper Road')]);
      expect((await again.list()).single.pdfParser, pdfParserVersion);
    });

    test('opened again, or made by a newer PDF reader, it is never read again', () async {
      final bytes = utf8.encode('%PDF-1.4 the lantern keeper, scanned');
      final entry = await made(picked('lantern.pdf', bytes));
      // A newer PDF reader since: the book is made again from the text OCR
      // gave it, not from the platform, and not by OCR.
      final index = File('${tmp.path}/library.json');
      index.writeAsStringSync(index.readAsStringSync().replaceAll('"pdfParser": $pdfParserVersion', '"pdfParser": 1'));
      final again = LibraryStore(tmp);
      expect((await again.list()).single.pdfParser, 1);
      calls.clear();
      final layout = await again.loadLayout(entry.id);
      expect(layout.units.map((u) => u.text).join(' '), contains('lighthouse'));
      expect(calls.map((c) => c.method), isNot(contains('extractPdf')));
      expect(calls.map((c) => c.method), isNot(contains('ocrStart')));
      expect((await again.list()).single.pdfParser, pdfParserVersion);

      // The same file imported again: the book OCR made, not a refusal.
      final f = picked('lantern again.pdf', bytes);
      pdfs[f.path] = scanText(12);
      final re = await again.importFile(PickedFile(path: f.path, name: 'lantern again.pdf'));
      expect(re.id, entry.id);
      expect(re.ocr, 'eng');
      expect((await again.loadLayout(re.id)).units.map((u) => u.text).join(' '), contains('lighthouse'));
      expect(calls.map((c) => c.method), isNot(contains('ocrStart')));
    });

    test('pages OCR found nothing on are not a book, and say so', () async {
      final pdf = picked('blank.pdf', utf8.encode('%PDF-1.4 photographs'));
      final id = bookIdOf(pdf.readAsBytesSync());
      final dir = Directory('${tmp.path}/ocr/jobs/$id')..createSync(recursive: true);
      File('${dir.path}/pdf.json').writeAsStringSync(jsonEncode(scanText(3)));
      File('${dir.path}/job.json').writeAsStringSync(jsonEncode({
        'id': id,
        'name': 'blank.pdf',
        'source': pdf.path,
        'pages': [0, 1, 2],
        'languages': 'ben',
      }));
      for (var p = 0; p < 3; p++) {
        File('${dir.path}/pages/$p.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync(p == 1 ? '|~ .' : '');
      }
      await expectLater(
        store.addOcrBook(dir.path),
        throwsA(isA<ParseException>().having((e) => e.message, 'message', contains('in Bengali'))),
      );
      expect(await store.list(), isEmpty);
    });
  });

  group('jobs', () {
    late LibraryStore store;
    setUp(() async {
      store = LibraryStore(tmp);
      await OcrJobs.instance.attach(store);
    });

    Map<String, Object?>? started() {
      final c = calls.where((c) => c.method == 'ocrStart').lastOrNull;
      return c == null ? null : Map<String, Object?>.from(c.arguments as Map);
    }

    test('a refused scan becomes a job the phone reads, then a book', () async {
      final f = picked('scan.pdf', utf8.encode('%PDF-1.4 the lantern keeper, scanned'));
      final offer = OcrOffer(path: f.path, name: 'The Lantern Keeper.pdf', pdf: scanText(12));
      final job = await OcrJobs.instance.start(offer, [ocrLanguageByCode('ben')!, ocrLanguageByCode('eng')!]);

      final args = started()!;
      expect(args['job'], job.dir.path);
      expect(args['pdf'], '${job.dir.path}/source.pdf');
      expect(args['pages'], [for (var p = 0; p < 12; p++) p]);
      expect(args['languages'], 'ben+eng');
      expect(args['data'], '${tmp.path}/ocr');
      expect(args['title'], 'The Lantern Keeper');
      expect(f.existsSync(), isFalse, reason: 'the picked copy moved into the job');
      expect(f.parent.existsSync(), isFalse);
      expect(File('${job.dir.path}/source.pdf').existsSync(), isTrue);
      expect(OcrJobs.instance.running, job.id);
      expect(OcrData.instance.lastPicked(), ['ben', 'eng']);

      // The phone reads the pages, one file each.
      for (var p = 0; p < 12; p++) {
        File('${job.dir.path}/pages/$p.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync(ocrPage(p));
        OcrJobs.instance.handle({'type': 'ocrProgress', 'job': job.dir.path, 'done': p + 1, 'total': 12});
      }
      expect(job.done, 12);
      final news = OcrJobs.instance.news.first;
      OcrJobs.instance.handle({'type': 'ocrDone', 'job': job.dir.path, 'done': 12, 'total': 12});
      await OcrJobs.instance.settled;
      expect(await news, contains('The Lantern Keeper'));
      expect(OcrJobs.instance.jobs, isEmpty);
      expect(OcrJobs.instance.running, isNull);
      final entry = (await store.list()).single;
      expect(entry.ocr, 'ben+eng');
      expect(entry.id, job.id);
    });

    test('a stop keeps what was read, and the scan goes on from its next page', () async {
      final f = picked('scan.pdf', utf8.encode('%PDF-1.4 stopped half way'));
      final job = await OcrJobs.instance.start(
        OcrOffer(path: f.path, name: 'scan.pdf', pdf: scanText(6)),
        [ocrLanguageByCode('eng')!],
      );
      for (var p = 0; p < 3; p++) {
        File('${job.dir.path}/pages/$p.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync(ocrPage(p));
      }
      await OcrJobs.instance.stop();
      expect(calls.map((c) => c.method), contains('ocrStop'));
      OcrJobs.instance.handle({'type': 'ocrStopped', 'job': job.dir.path, 'done': 3, 'total': 6});
      OcrJobs.instance.handle({'type': 'ocrIdle'});
      expect(OcrJobs.instance.running, isNull);
      expect(OcrJobs.instance.shown, job);

      // The app opened again later: the scan is found, three pages read.
      OcrJobs.instance.reset();
      await OcrJobs.instance.attach(LibraryStore(tmp));
      final found = OcrJobs.instance.jobs.single;
      expect(found.id, job.id);
      expect(found.done, 3);
      expect(found.languages, 'eng');

      // Go on: its data is on the phone, so nothing is downloaded.
      final data = OcrData.instance.fileOf(ocrLanguageByCode('eng')!)..createSync(recursive: true);
      data.writeAsBytesSync(traineddata(ocrLanguageByCode('eng')!.bytes));
      calls.clear();
      await OcrJobs.instance.resume(found);
      expect(started()!['job'], job.dir.path, reason: 'the platform skips the pages that have their files');
    });

    test('a scan read to its end while the app was away is made into a book when it opens', () async {
      final f = picked('scan.pdf', utf8.encode('%PDF-1.4 read while away'));
      final job = await OcrJobs.instance.start(
        OcrOffer(path: f.path, name: 'Away.pdf', pdf: scanText(12)),
        [ocrLanguageByCode('eng')!],
      );
      for (var p = 0; p < 12; p++) {
        File('${job.dir.path}/pages/$p.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync(ocrPage(p));
      }
      OcrJobs.instance.reset();
      final again = LibraryStore(tmp);
      await OcrJobs.instance.attach(again);
      await OcrJobs.instance.settled;
      expect(OcrJobs.instance.jobs, isEmpty);
      expect((await again.list()).single.ocr, 'eng');
    });

    test('language data that would not load goes, to be fetched again', () async {
      final eng = ocrLanguageByCode('eng')!;
      OcrData.instance.fileOf(eng)
        ..createSync(recursive: true)
        ..writeAsBytesSync(traineddata(eng.bytes));
      final f = picked('scan.pdf', utf8.encode('%PDF-1.4 bad data'));
      final job = await OcrJobs.instance.start(OcrOffer(path: f.path, name: 'scan.pdf', pdf: scanText(3)), [eng]);
      final news = OcrJobs.instance.news.first;
      OcrJobs.instance.handle({'type': 'ocrFailed', 'job': job.dir.path, 'message': 'It would not load.', 'data': true});
      expect(await news, contains('It would not load.'));
      expect(OcrData.instance.installed(eng), isFalse);
      expect(job.error, 'It would not load.');
      expect(OcrJobs.instance.running, isNull);
    });

    test('a scan with no page for OCR to read ends, and says why', () async {
      // An older build refused a PDF each of whose pages had a line of its
      // own as a scan, and OCR found no page in it to read: the job stayed,
      // made again and refused again at every start.
      final dir = olderJob('blank.pdf', scanText(3));
      OcrJobs.instance.reset();
      final news = OcrJobs.instance.news.first;
      await OcrJobs.instance.attach(LibraryStore(tmp));
      await OcrJobs.instance.settled;
      expect(await news, contains('no selectable text'));
      expect(OcrJobs.instance.jobs, isEmpty);
      expect(dir.existsSync(), isFalse, reason: 'it ends as Discard ends one');
    });

    test("an older build's scan whose every page had a line is made into a book", () async {
      olderJob('notice.pdf', scanText(2, typed: {
        0: '${_mark}Notice of the harbour meeting',
        1: '${_mark}Bring the minutes of the last one',
      }));
      OcrJobs.instance.reset();
      final again = LibraryStore(tmp);
      await OcrJobs.instance.attach(again);
      await OcrJobs.instance.settled;
      expect(OcrJobs.instance.jobs, isEmpty);
      expect((await again.list()).single.title, 'notice');
    });

    test('a scan discarded takes its file and what was read with it', () async {
      final f = picked('scan.pdf', utf8.encode('%PDF-1.4 discarded'));
      final job = await OcrJobs.instance.start(OcrOffer(path: f.path, name: 'scan.pdf', pdf: scanText(3)), [
        ocrLanguageByCode('eng')!,
      ]);
      OcrJobs.instance.handle({'type': 'ocrIdle'});
      await OcrJobs.instance.discard(job);
      expect(job.dir.existsSync(), isFalse);
      expect(OcrJobs.instance.jobs, isEmpty);
    });
  });

  test('the platform events reach the jobs through the channel', () async {
    final store = LibraryStore(tmp);
    await OcrJobs.instance.attach(store);
    final f = picked('scan.pdf', utf8.encode('%PDF-1.4 events'));
    final job = await OcrJobs.instance.start(OcrOffer(path: f.path, name: 'scan.pdf', pdf: scanText(4)), [
      ocrLanguageByCode('eng')!,
    ]);
    final heard = SpeechService.events.firstWhere((e) => e['type'] == 'ocrProgress');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'tomevoice/tts',
      const StandardMethodCodec().encodeMethodCall(MethodCall('platformEvent', {
        'type': 'ocrProgress',
        'job': job.dir.path,
        'done': 2,
        'total': 4,
      })),
      (_) {},
    );
    await heard;
    expect(job.done, 2);
  });

  group('on screen', () {
    testWidgets("a refused scan is offered OCR in the book's and the app's languages, Hindi to hand",
        (tester) async {
      final store = LibraryStore(tmp);
      late File f;
      await tester.runAsync(() async {
        f = picked('scan.pdf', utf8.encode('%PDF-1.4 sonar tori'));
        await OcrJobs.instance.attach(store);
      });
      final offer = OcrOffer(path: f.path, name: 'Sonar Tori.pdf', pdf: scanText(40), language: 'bn');
      bool? started;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                started = await offerOcr(context, store, offer);
              },
              child: const Text('Import'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Import'));
      // The library was taken up in real time above: what waits on it does too.
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Read it with OCR?'), findsOneWidget);
      expect(find.textContaining('its 40 pages are pictures'), findsOneWidget);
      FilterChip chip(String label) => tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));
      expect(chip('Bengali · বাংলা').selected, isTrue, reason: "the book's language");
      expect(chip('English').selected, isTrue, reason: "the app's");
      expect(chip('Hindi · हिन्दी').selected, isFalse, reason: 'one tap away');
      expect(find.textContaining('First downloads the Bengali and English language data'), findsOneWidget);
      expect(find.textContaining('pick two only when the pages mix them'), findsOneWidget);

      // English off: Bengali alone, a smaller download.
      await tester.tap(find.widgetWithText(FilterChip, 'English'));
      await tester.pump();
      expect(chip('English').selected, isFalse);
      expect(find.textContaining('First downloads the Bengali language data (0.8 MB)'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(started, isFalse);
      expect(f.existsSync(), isFalse, reason: 'declined, the kept copy goes');
    });

    testWidgets('the shelf shows how far a scan is, with Stop; a stopped one goes on or goes', (tester) async {
      final store = LibraryStore(tmp);
      late OcrJob job;
      await tester.runAsync(() async {
        await OcrJobs.instance.attach(store);
        final f = picked('scan.pdf', utf8.encode('%PDF-1.4 the card'));
        job = await OcrJobs.instance.start(
          OcrOffer(path: f.path, name: 'Sonar Tori.pdf', pdf: scanText(12)),
          [ocrLanguageByCode('ben')!],
        );
      });
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [OcrProgressCard()]))));
      OcrJobs.instance.handle({'type': 'ocrProgress', 'job': job.dir.path, 'done': 2, 'total': 12});
      await tester.pumpAndSettle();
      expect(find.text('OCR: Sonar Tori'), findsOneWidget);
      expect(find.text('READING PAGE 3 OF 12'), findsOneWidget);

      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(find.text('STOPPING AFTER THIS PAGE…'), findsOneWidget);
      OcrJobs.instance.handle({'type': 'ocrStopped', 'job': job.dir.path, 'done': 3, 'total': 12});
      OcrJobs.instance.handle({'type': 'ocrIdle'});
      await tester.pumpAndSettle();
      expect(find.text('STOPPED AT PAGE 4 OF 12'), findsOneWidget);
      expect(find.text('Go on'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('OCR: Sonar Tori'), findsNothing);
      expect(job.dir.existsSync(), isFalse);
    });

    testWidgets('a scan with no page to read is shown with none, and the shelf stays', (tester) async {
      // The phone reading a scan an older build left with no page to read:
      // "page 1 of 0" threw as the card was built, and the shelf under it
      // went for good.
      late Directory dir;
      await tester.runAsync(() async {
        dir = olderJob('blank.pdf', scanText(3));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'ocrStatus'
              ? {'job': dir.path, 'done': 0, 'total': 0, 'stopping': false, 'queued': const []}
              : null;
        });
        await OcrJobs.instance.attach(LibraryStore(tmp));
      });
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Column(children: [OcrProgressCard(), Expanded(child: Center(child: Text('Shelf')))])),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('READING'), findsOneWidget);
      expect(find.text('Shelf').hitTestable(), findsOneWidget);
    });

    testWidgets("a scan's card is held to a third of the screen: its message scrolls, Discard stays", (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        olderJob('long.pdf', scanText(3), pages: [0, 1, 2], error: 'The page could not be drawn. ' * 80);
        await OcrJobs.instance.attach(LibraryStore(tmp));
      });
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Column(children: [OcrProgressCard(), Expanded(child: Center(child: Text('Shelf')))])),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      expect(find.textContaining('could not be drawn'), findsOneWidget);
      expect(tester.getSize(find.byType(OcrProgressCard)).height, lessThanOrEqualTo(2340 / 2.75 / 3));
      expect(find.text('Discard').hitTestable(), findsOneWidget);
      expect(find.text('Go on').hitTestable(), findsOneWidget);
      expect(find.text('Shelf').hitTestable(), findsOneWidget);
    });

    testWidgets("a book OCR read says so on its page", (tester) async {
      final store = LibraryStore(tmp);
      late LibraryEntry entry;
      await tester.runAsync(() async {
        entry = await ocrBook(store, picked('lantern.pdf', utf8.encode('%PDF-1.4 the lantern keeper')));
      });
      await tester.pumpWidget(MaterialApp(home: BookScreen(store: store, entry: entry)));
      await settle(tester);
      expect(find.text('Read by OCR: may contain errors'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
