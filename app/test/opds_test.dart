// OPDS catalogues: Atom feeds as Project Gutenberg, Standard Ebooks and
// Calibre write them, OpenSearch, sign-in (Basic and Digest) kept to the
// catalogue's own host, and a book downloaded into the library through the
// normal import, never onto a secret shelf.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/catalogues_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/opds.dart';

import 'support/opds_server.dart';

/// Project Gutenberg's book feed, cut down: two editions of one book.
const _gutenbergBook = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/">
  <id>https://www.gutenberg.org/ebooks/1342.opds</id>
  <title>Pride and Prejudice by Jane Austen</title>
  <link rel="search" type="application/opensearchdescription+xml" href="https://www.gutenberg.org/catalog/osd-books.xml"/>
  <link rel="start" type="application/atom+xml;profile=opds-catalog" href="/ebooks.opds/"/>
  <entry>
    <title>Pride and Prejudice</title>
    <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>This edition has images.</p><p>Downloads: 100</p></div></content>
    <id>urn:gutenberg:1342:3</id>
    <author><name>Austen, Jane</name></author>
    <link type="application/x-mobipocket-ebook" rel="http://opds-spec.org/acquisition" title="Kindles (kf8)" href="https://www.gutenberg.org/ebooks/1342.kf8.images"/>
    <link type="application/epub+zip" rel="http://opds-spec.org/acquisition" title="EPUB3 (E-readers incl. Send-to-Kindle)" href="https://www.gutenberg.org/ebooks/1342.epub3.images"/>
    <link type="application/epub+zip" rel="http://opds-spec.org/acquisition" title="EPUB (older e-readers)" href="https://www.gutenberg.org/ebooks/1342.epub.images"/>
    <link type="image/jpeg" rel="http://opds-spec.org/image" href="https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg"/>
    <link type="image/jpeg" rel="http://opds-spec.org/image/thumbnail" href="https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg"/>
    <link type="application/atom+xml;profile=opds-catalog" rel="related" href="/ebooks/author/68.opds" title="By Austen, Jane"/>
  </entry>
</feed>''';

/// Project Gutenberg's front page: sections, each a feed of its own.
const _gutenbergRoot = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Project Gutenberg</title>
  <link rel="search" type="application/opensearchdescription+xml" href="https://www.gutenberg.org/catalog/osd-books.xml"/>
  <link rel="self" type="application/atom+xml;profile=opds-catalog" href="/ebooks.opds/"/>
  <entry>
    <title>Popular</title><id>p</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/ebooks/search.opds/?sort_order=downloads"/>
  </entry>
</feed>''';

/// Standard Ebooks' free feed: plain Atom, its files as enclosures.
const _standardNew = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <title>Standard Ebooks - Newest Ebooks</title>
  <entry>
    <id>https://standardebooks.org/ebooks/joseph-conrad/short-fiction</id>
    <title>Short Fiction</title>
    <author><name>Joseph Conrad</name></author>
    <summary type="text">The complete short fiction of Joseph Conrad.</summary>
    <link href="https://standardebooks.org/ebooks/joseph-conrad/short-fiction" rel="alternate" title="This ebook’s page at Standard Ebooks" type="application/xhtml+xml"/>
    <link href="https://standardebooks.org/ebooks/joseph-conrad/short-fiction/downloads/joseph-conrad_short-fiction.azw3?source=feed" length="2251753" rel="enclosure" title="Amazon Kindle azw3" type="application/x-mobipocket-ebook"/>
    <link href="https://standardebooks.org/ebooks/joseph-conrad/short-fiction/downloads/joseph-conrad_short-fiction.epub?source=feed" length="1544566" rel="enclosure" title="Recommended compatible epub" type="application/epub+zip"/>
    <link href="https://standardebooks.org/ebooks/joseph-conrad/short-fiction/downloads/joseph-conrad_short-fiction_advanced.epub?source=feed" length="2107910" rel="enclosure" title="Advanced epub" type="application/epub+zip"/>
    <link href="https://standardebooks.org/ebooks/joseph-conrad/short-fiction/downloads/joseph-conrad_short-fiction.kepub.epub?source=feed" length="1660619" rel="enclosure" title="Kobo Kepub epub" type="application/kepub+zip"/>
    <link href="https://standardebooks.org/ebooks/joseph-conrad/short-fiction/text/single-page" length="2787138" rel="enclosure" title="XHTML" type="application/xhtml+xml"/>
    <media:thumbnail url="https://standardebooks.org/ebooks/joseph-conrad/short-fiction/downloads/cover-thumbnail.jpg" height="525" width="350"/>
  </entry>
</feed>''';

void main() {
  group('reading feeds', () {
    test("Gutenberg's book: EPUB first, cover and thumbnail, related feeds", () {
      final feed = parseOpdsFeed(_gutenbergBook, Uri.parse('https://www.gutenberg.org/ebooks/1342.opds'));
      expect(feed.title, 'Pride and Prejudice by Jane Austen');
      expect(feed.search, Uri.parse('https://www.gutenberg.org/catalog/osd-books.xml'));
      final book = feed.entries.single;
      expect(book.isBook, isTrue);
      expect(book.feed, isNull);
      expect(book.authorLine, 'Austen, Jane');
      expect([for (final l in book.downloads) l.title],
          ['EPUB3 (E-readers incl. Send-to-Kindle)', 'EPUB (older e-readers)', 'Kindles (kf8)']);
      expect(formatOf(book.downloads.last.type, book.downloads.last.href)!.label, 'AZW3');
      expect(book.thumbnail.toString(), endsWith('cover.small.jpg'));
      expect(book.image.toString(), endsWith('cover.medium.jpg'));
      expect(book.related.single.href, Uri.parse('https://www.gutenberg.org/ebooks/author/68.opds'));
      expect(book.description, 'This edition has images.\n\nDownloads: 100');
    });

    test("Gutenberg's front page: sections to open, made whole", () {
      final feed = parseOpdsFeed(_gutenbergRoot, Uri.parse('https://www.gutenberg.org/ebooks.opds/'));
      final popular = feed.entries.single;
      expect(popular.isBook, isFalse);
      expect(popular.feed!.href, Uri.parse('https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads'));
      expect(feed.searchable, isTrue);
    });

    test("Standard Ebooks' free feed: enclosures are its files, the compatible EPUB first", () {
      final feed = parseOpdsFeed(_standardNew, Uri.parse('https://standardebooks.org/feeds/atom/new-releases'));
      final book = feed.entries.single;
      expect(book.isBook, isTrue);
      expect(book.downloads.first.title, 'Recommended compatible epub');
      expect([for (final l in book.downloads) formatOf(l.type, l.href)!.label], ['EPUB', 'EPUB', 'Kobo EPUB', 'AZW3']);
      expect(book.downloads.first.length, 1544566);
      expect(book.thumbnail.toString(), endsWith('cover-thumbnail.jpg'));
      expect(book.summary, 'The complete short fiction of Joseph Conrad.');
    });

    test('a web page or something else is said to be no catalogue', () {
      expect(() => parseOpdsFeed('<html><body>Hi</body></html>', Uri.parse('http://x/')),
          throwsA(isA<OpdsFormatException>().having((e) => e.message, 'message', contains('web page'))));
      expect(() => parseOpdsFeed('not xml at all <', Uri.parse('http://x/')), throwsA(isA<OpdsFormatException>()));
      final bom = '${String.fromCharCode(0xFEFF)}$_gutenbergRoot';
      expect(parseOpdsFeed(bom, Uri.parse('https://www.gutenberg.org/ebooks.opds/')).title, 'Project Gutenberg');
    });

    test('OpenSearch: the Atom address, made whole, its optional parts left out', () {
      const osd = '<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">'
          '<Url type="text/html" template="/s.html?q={searchTerms}"/>'
          '<Url type="application/atom+xml" template="/search.opds/?query={searchTerms}&amp;page={startPage?}"/>'
          '</OpenSearchDescription>';
      final template = parseOpenSearch(osd, Uri.parse('https://www.gutenberg.org/catalog/osd-books.xml'))!;
      expect(template, 'https://www.gutenberg.org/search.opds/?query={searchTerms}&page=');
      expect(searchUrl(template, ' pride & joy ').toString(),
          'https://www.gutenberg.org/search.opds/?query=pride+%26+joy&page=');
    });

    test('formats TomeVoice opens, and what it does not', () {
      Uri u(String s) => Uri.parse('https://x/$s');
      expect(formatOf('application/epub+zip', u('a')), isNotNull);
      expect(formatOf('application/x-mobipocket-ebook', u('1342.kindle.images'))!.label, 'MOBI');
      expect(formatOf('application/x-mobipocket-ebook', u('a.azw3'))!.extension, '.azw3');
      expect(formatOf('application/pdf; charset=binary', u('a'))!.label, 'PDF');
      expect(formatOf('application/xhtml+xml', u('page')), isNull, reason: 'a web page, not a file');
      expect(formatOf('application/x-cbz', u('a')), isNull);
    });

    test('a downloaded file is named for its book, with its format’s extension', () {
      final feed = parseOpdsFeed(_gutenbergBook, Uri.parse('https://www.gutenberg.org/ebooks/1342.opds'));
      final book = feed.entries.single;
      expect(downloadName(book, book.downloads.first), 'Pride and Prejudice.epub');
      expect(downloadName(book, book.downloads.first, serverName: 'pg1342-images-3.epub'), 'pg1342-images-3.epub');
      expect(downloadName(book, book.downloads.first, serverName: 'index.html'), 'Pride and Prejudice.epub');
    });
  });

  group('a catalogue on the network', () {
    late OpdsTestServer server;

    tearDown(() => server.close());

    test('signs in with Basic, browses, pages on and searches', () async {
      server = await OpdsTestServer.start(user: 'reader', password: 'secret');
      final wrong = OpdsClient(server.root, user: 'reader', password: 'nope');
      await expectLater(wrong.feed(server.root), throwsA(isA<OpdsAuthException>()));
      wrong.close();
      final none = OpdsClient(server.root);
      await expectLater(none.feed(server.root), throwsA(isA<OpdsAuthException>()));
      none.close();

      final client = OpdsClient(server.root, user: 'reader', password: 'secret');
      final root = await client.feed(server.root);
      expect(root.title, 'Test Library');
      final section = root.entries.single;
      expect(section.thumbnail!.scheme, 'data');
      expect((await client.fetch(section.thumbnail!)).bytes, isNotEmpty);

      final page1 = await client.feed(section.feed!.href);
      expect([for (final e in page1.entries) e.title], ['The Test Book', 'Book 2']);
      expect(page1.entries.first.downloads.first.href.path, '/books/1.epub', reason: 'EPUB before PDF; buy left out');
      expect(page1.entries.first.downloads.map((l) => l.href.path), isNot(contains('/shop/1')));
      expect(page1.entries.first.description, 'A longer description & more.\n\nSecond paragraph.');
      final page2 = await client.feed(page1.next!);
      expect(page2.entries.single.title, 'Book 3');
      expect(page2.next, isNull);

      final found = await client.search(root, 'test');
      expect(found.entries.single.title, 'The Test Book');
      expect(server.requests, contains('GET /opds/search?q=test&start='));
      client.close();
    });

    test("signs in with Digest, as Calibre's own server asks", () async {
      server = await OpdsTestServer.start(user: 'reader', password: 'secret', digest: true);
      final client = OpdsClient(server.root, user: 'reader', password: 'secret');
      expect((await client.feed(server.root)).title, 'Test Library');
      expect(server.authorizations['/opds'], startsWith('Digest '));
      client.close();
    });

    test('the password never goes to another host the catalogue sends it to', () async {
      server = await OpdsTestServer.start(user: 'reader', password: 'secret');
      final other = await OpdsTestServer.start();
      addTearDown(other.close);
      // The same computer by another name: another host to the client.
      server.redirectTo = Uri.parse('http://localhost:${other.base.port}/opds');
      final client = OpdsClient(server.root, user: 'reader', password: 'secret');
      await client.feed(server.root); // Signed in here.
      final away = await client.feed(server.base.resolve('/away'));
      expect(away.title, 'Test Library');
      expect(other.authorizations, isEmpty);
      client.close();
    });
  });

  group('adding a book', () {
    late OpdsTestServer server;
    late Directory tmp;

    setUp(() async {
      server = await OpdsTestServer.start(user: 'reader', password: 'secret');
      tmp = Directory.systemTemp.createTempSync('tomevoice_opds');
    });

    tearDown(() async {
      await server.close();
      LibraryStore.secretOpen.value = false;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test('downloads the EPUB with progress, imports it, onto the shelf chosen', () async {
      final store = LibraryStore(tmp);
      final later = (await store.index()).categories.firstWhere((c) => c.id == 'later');
      final client = OpdsClient(server.root, user: 'reader', password: 'secret');
      final book = (await client.feed(server.base.resolve('/opds/new'))).entries.first;
      final seen = <(int, int)>[];
      var importing = false;
      final added = await addFromCatalogue(
        store,
        client,
        book,
        book.downloads.first,
        shelf: later.id,
        onProgress: (done, total) => seen.add((done, total)),
        onImporting: () => importing = true,
      );
      client.close();
      expect(importing, isTrue);
      expect(seen, isNotEmpty);
      expect(seen.last.$1, seen.last.$2, reason: 'all of it');
      expect(seen.length, greaterThan(1), reason: 'heard as it came');
      expect(added.title, 'The Test Book');
      expect(added.authors, ['Ann Author']);
      final index = await store.index();
      expect(index.entries.single.categoryIn(index.categories, index.defaultCategory), later.id);
      expect(File(index.entries.single.sourcePath).existsSync(), isTrue);
      final incoming = Directory('${tmp.path}/incoming');
      expect(incoming.existsSync() ? incoming.listSync() : const [], isEmpty, reason: 'nothing left behind');
    });

    test('a secret shelf is never a place to put it, open or shut', () async {
      final store = LibraryStore(tmp);
      final secret = await store.addCategory('Hidden', secret: true);
      for (final open in [false, true]) {
        LibraryStore.secretOpen.value = open;
        expect([for (final c in await destinationShelves(store)) c.id], isNot(contains(secret.id)));
      }
      LibraryStore.secretOpen.value = true;
      final client = OpdsClient(server.root, user: 'reader', password: 'secret');
      final book = (await client.feed(server.base.resolve('/opds/new'))).entries.first;
      final added = await addFromCatalogue(store, client, book, book.downloads.first, shelf: secret.id);
      client.close();
      final index = await store.index(all: true);
      final shelf = index.entries.firstWhere((e) => e.id == added.id).categoryIn(index.categories, index.defaultCategory);
      expect(shelf, isNot(secret.id));
      expect(shelf, index.defaultCategory);
    });
  });

  group('the catalogues kept', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tomevoice_cats'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test('the built-in ones, then the reader’s; passwords kept apart from them', () async {
      final store = CatalogueStore(tmp);
      final first = await store.all();
      expect([for (final c in first) c.id], ['gutenberg', 'standard-ebooks-new', 'standard-ebooks']);
      expect(first.first.url, 'https://www.gutenberg.org/ebooks.opds/');
      expect(first.last.url, 'https://standardebooks.org/feeds/opds');

      const calibre = Catalogue(id: 'c1', title: 'Calibre', url: 'http://192.168.1.20:8080/opds', user: 'me');
      await store.save(calibre, password: 'hunter2');
      await store.save(Catalogue.standardAll.withUser('patron@example.com'));
      final all = await store.all();
      expect(all.last.title, 'Calibre');
      expect(all.firstWhere((c) => c.id == 'standard-ebooks').user, 'patron@example.com');
      expect(await store.password(calibre), 'hunter2');

      final kept = File('${tmp.path}/catalogues.json').readAsStringSync();
      expect(kept, isNot(contains('hunter2')), reason: 'a backup carries this file');
      expect(jsonDecode(File('${tmp.path}/.secrets.json').readAsStringSync()), {'catalogue:c1': 'hunter2'});

      await store.remove(calibre);
      expect((await store.all()).map((c) => c.id), isNot(contains('c1')));
      expect(await store.password(calibre), isNull);
    });
  });
}
