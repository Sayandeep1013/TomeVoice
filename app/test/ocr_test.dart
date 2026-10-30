// OCR for scanned PDFs, the Dart side: the languages offered, what Tesseract
// reads turned into a book through the PDF pipeline, the scan's text kept so
// it is never read again, and the jobs that track the reading. The reading
// itself is Kotlin (Ocr.kt), so the platform is mocked here. The language
// data's downloads are in ocr_download_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/ocr.dart';
import 'package:tomevoice_spike/ocr_jobs.dart';
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

    test('pages with text keep theirs and their layout; the others are what OCR read', () {
      final pdf = {
        ...scanText(4, typed: {1: '${_mark}A typed notice of the publisher, kept as it is.'}),
        'layout': [<int>[], [1, 2, 3, 4, 5], <int>[], <int>[]],
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
  /// OcrJobs.start leaves one, and its pages as Ocr.kt writes them.
  Future<LibraryEntry> ocrBook(LibraryStore store, File pdf, {int pages = 12}) async {
    final id = bookIdOf(pdf.readAsBytesSync());
    final dir = Directory('${tmp.path}/ocr/jobs/$id')..createSync(recursive: true);
    final source = pdf.renameSync('${dir.path}/source.pdf');
    File('${dir.path}/pdf.json').writeAsStringSync(jsonEncode(scanText(pages)));
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
}
