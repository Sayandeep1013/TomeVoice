// A web novel's downloaded chapters as an EPUB: a file any reader opens
// (mimetype first and stored, the container, the package, the contents),
// its chapters in order with their words intact, and nothing named for a
// novel on a shut secret shelf.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/epub_export.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:xml/xml.dart';

const _plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_epub_test');
    store = LibraryStore(tmp);
  });

  tearDown(() {
    LibraryStore.secretOpen.value = false;
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  /// Shadow: three chapters, the first and third on the phone.
  Future<LibraryEntry> novel() async {
    final e = await store.addWebNovel(
      _plugin,
      SourceNovel(
        path: 'novel/1',
        name: 'Shadow & Light',
        author: 'A. Writer',
        summary: 'A story <of> shadows.',
        chapters: [for (var i = 1; i <= 3; i++) ChapterItem(name: 'Chapter $i: Part <$i>', path: 'ch/$i')],
      ),
    );
    await store.saveChapter(
      e.id,
      0,
      'Chapter 1: Part <1>',
      '<h2>Chapter 1: Part &lt;1&gt;</h2><p>Fish &amp; chips &lt;3, said the ${String.fromCharCode(1)}cook.</p>'
          '<ul><li>One thing</li><li>Another</li></ul><p>The end of it.</p>',
    );
    await store.saveChapter(e.id, 2, 'Chapter 3: Part <3>', '<p>The third chapter&#8217;s words.</p>');
    return (await store.list(all: true)).single;
  }

  /// [bytes] as a zip, by name, in the order they are stored.
  Archive unzip(List<int> bytes) => ZipDecoder().decodeBytes(bytes);

  String text(Archive zip, String name) => utf8.decode(zip.findFile(name)!.content as List<int>);

  test('mimetype first and stored, then the container, the package, its contents and every page', () async {
    final e = await novel();
    final job = (await epubJobFor(store, e))!;
    final out = '${tmp.path}/out.epub';
    expect(await writeEpub(job, out), 2, reason: 'the chapters on the phone');

    final bytes = File(out).readAsBytesSync();
    // The first local header: "mimetype", stored (method 0), no extra field,
    // its words right after its name, as OCF asks.
    expect(bytes.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(bytes[8] | bytes[9] << 8, 0, reason: 'stored, not deflated');
    expect(bytes[26] | bytes[27] << 8, 8);
    expect(bytes[28] | bytes[29] << 8, 0, reason: 'no extra field');
    expect(ascii.decode(bytes.sublist(30, 38)), 'mimetype');
    expect(ascii.decode(bytes.sublist(38, 58)), 'application/epub+zip');

    final zip = unzip(bytes);
    expect(zip.files.first.name, 'mimetype');
    final container = XmlDocument.parse(text(zip, 'META-INF/container.xml'));
    final rootfile = container.findAllElements('rootfile').single;
    expect(rootfile.getAttribute('full-path'), 'OEBPS/content.opf');
    expect(rootfile.getAttribute('media-type'), 'application/oebps-package+xml');

    final opf = XmlDocument.parse(text(zip, 'OEBPS/content.opf'));
    final package = opf.rootElement;
    expect((package.name.local, package.getAttribute('version')), ('package', '3.0'));
    final uid = package.getAttribute('unique-identifier');
    final metadata = package.findElements('metadata').single;
    String dc(String name) => metadata.findElements('dc:$name').single.innerText;
    expect(metadata.findElements('dc:identifier').single.getAttribute('id'), uid);
    expect((dc('title'), dc('creator'), dc('language')), ('Shadow & Light', 'A. Writer', 'en'));
    expect(dc('description'), 'A story <of> shadows.');
    expect(
      metadata.findElements('meta').any((m) => m.getAttribute('property') == 'dcterms:modified' && m.innerText.endsWith('Z')),
      isTrue,
    );

    // Every file the manifest names is there; one is the nav.
    final items = {
      for (final i in package.findElements('manifest').single.findElements('item')) i.getAttribute('id')!: i,
    };
    for (final i in items.values) {
      expect(zip.findFile('OEBPS/${i.getAttribute('href')}'), isNotNull, reason: i.getAttribute('href'));
    }
    final nav = items.values.singleWhere((i) => i.getAttribute('properties') == 'nav');
    final spine = [for (final r in package.findElements('spine').single.findElements('itemref')) r.getAttribute('idref')!];
    final pages = [for (final id in spine) items[id]!.getAttribute('href')!];
    expect(pages, ['text/c0001.xhtml', 'text/c0002.xhtml']);
    expect(package.findElements('spine').single.getAttribute('toc'), 'ncx');

    final contents = XmlDocument.parse(text(zip, 'OEBPS/${nav.getAttribute('href')}'));
    final toc = contents.findAllElements('nav').single;
    expect(toc.getAttribute('epub:type'), 'toc');
    final links = toc.findAllElements('a').toList();
    expect([for (final a in links) a.getAttribute('href')], pages);
    expect([for (final a in links) a.innerText], ['Chapter 1: Part <1>', 'Chapter 3: Part <3>']);
    final ncx = XmlDocument.parse(text(zip, 'OEBPS/toc.ncx'));
    expect(ncx.findAllElements('navPoint'), hasLength(2));

    // The pages are XML, with the words as they were, and the chapter's own
    // heading heading it.
    final first = XmlDocument.parse(text(zip, 'OEBPS/text/c0001.xhtml'));
    expect([for (final h in first.findAllElements('h1')) h.innerText], ['Chapter 1: Part <1>']);
    expect(first.findAllElements('p').map((p) => p.innerText), contains('Fish & chips <3, said the cook.'));
    expect(first.findAllElements('li').map((l) => l.innerText), ['One thing', 'Another']);
    final third = XmlDocument.parse(text(zip, 'OEBPS/text/c0002.xhtml'));
    expect(third.findAllElements('h1').single.innerText, 'Chapter 3: Part <3>', reason: 'its title, as it has no heading');
    expect(third.findAllElements('p').single.innerText, contains('third chapter'));
  });

  test('a cover is the book\'s cover', () async {
    final e = await novel();
    final img = File('${store.bookDir(e.id)}/img/cover.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    final job = (await epubJobFor(store, e))!;
    final withCover = (
      identifier: job.identifier,
      title: job.title,
      authors: job.authors,
      language: job.language,
      description: job.description,
      publisher: job.publisher,
      site: job.site,
      cover: img.path,
      chapters: job.chapters,
      made: job.made,
    );
    final out = '${tmp.path}/cover.epub';
    await writeEpub(withCover, out);
    final zip = unzip(File(out).readAsBytesSync());
    final opf = XmlDocument.parse(text(zip, 'OEBPS/content.opf'));
    final cover = opf.findAllElements('item').singleWhere((i) => i.getAttribute('properties') == 'cover-image');
    expect((cover.getAttribute('href'), cover.getAttribute('media-type')), ('cover.png', 'image/png'));
    expect(zip.findFile('OEBPS/cover.png')!.content, [0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  });

  test("a file's name has nothing a folder refuses", () {
    expect(epubFileName('Re: Zero / Part 2?'), 'Re Zero Part 2.epub');
    expect(epubFileName('   '), 'Novel.epub');
  });

  group('a novel on a secret shelf', () {
    late List<String> asked;
    var allow = false;

    setUp(() {
      asked = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        asked.add(call.method);
        if (call.method == 'confirmUser') return allow;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    });

    Future<LibraryEntry> secret(WidgetTester tester) async => (await tester.runAsync(() async {
          final e = await novel();
          final shelf = await store.addCategory('Hidden', secret: true);
          await store.moveBooks({e.id}, shelf.id);
          await store.index(all: true);
          return e;
        }))!;

    Future<void> openExport(WidgetTester tester, LibraryEntry e) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => exportNovelEpub(context, store, e),
              child: const Text('Export'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Export'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('asks for the lock first; refused, no sheet, nothing named', (tester) async {
      final e = await secret(tester);
      LibraryStore.secretOpen.value = false;
      allow = false;
      await openExport(tester, e);
      expect(asked, contains('confirmUser'));
      expect(find.text('Export as EPUB'), findsNothing);
      expect(find.textContaining('Shadow'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opened with the lock, the sheet shows', (tester) async {
      final e = await secret(tester);
      LibraryStore.secretOpen.value = false;
      allow = true;
      await openExport(tester, e);
      expect(find.text('Export as EPUB'), findsOneWidget);
      expect(find.text('2 of 3 chapters: those on the phone'.toUpperCase()), findsOneWidget);
      LibraryStore.secretOpen.value = false;
      await tester.pumpWidget(const SizedBox());
    });

    test('saved after the shelf shut, its name is not said', () {
      expect(epubSaved(file: 'Shadow.epub', folder: 'Books', hidden: true), 'Saved the EPUB to Books.');
      expect(epubSaved(file: 'Shadow.epub', folder: 'Books', hidden: false), 'Saved Shadow.epub to Books.');
    });
  });
}
