// OPDS 2 catalogues (JSON): Project Gutenberg's, the OPDS test catalogue's,
// read into the same feeds and entries as Atom ones; the search template,
// the next page, the file chosen, and the Atom feed still read alike from
// one client, with Gutenberg's older feed read when its new one cannot be.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/catalogues_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/opds.dart';

import 'support/opds_server.dart' show sampleEpub;

/// Project Gutenberg's front page at /opds/, cut down: its Navigation group
/// and two groups of books, each with a feed of its own. Written as
/// Gutenberg's own server writes it (autocat3, OPDS2.py and
/// opds_catalog/publications.py): the site was down for maintenance when
/// this was made, so it could not be fetched.
const _gutenbergRoot = r'''
{
  "metadata": {"title": "Project Gutenberg"},
  "links": [
    {"rel": "self", "href": "https://www.gutenberg.org/opds/", "type": "application/opds+json"},
    {"rel": "start", "href": "https://www.gutenberg.org/opds/", "type": "application/opds+json"},
    {"rel": "search", "href": "https://www.gutenberg.org/opds/search{?query,title,author}", "type": "application/opds+json", "templated": true}
  ],
  "groups": [
    {
      "metadata": {"title": "Navigation", "numberOfItems": 2},
      "navigation": [
        {"href": "https://www.gutenberg.org/opds/bookshelves", "title": "Browse Bookshelves", "type": "application/opds+json", "rel": "subsection"},
        {"href": "https://www.gutenberg.org/opds/loccs", "title": "Browse Subjects", "type": "application/opds+json", "rel": "subsection"}
      ]
    },
    {
      "metadata": {"title": "Recently Added", "numberOfItems": 76012},
      "links": [{"rel": "self", "href": "https://www.gutenberg.org/opds/search?sort=release_date&sort_order=desc", "type": "application/opds+json"}],
      "publications": [
        {
          "metadata": {"@type": "http://schema.org/Book", "identifier": "https://www.gutenberg.org/ebooks/77001", "title": "A New Book", "language": "en", "author": {"name": "Writer, A.", "sortAs": "Writer, A."}},
          "links": [{"rel": "self", "href": "https://www.gutenberg.org/opds/publications?id=77001", "type": "application/opds-publication+json"}]
        }
      ]
    },
    {
      "metadata": {"title": "Most Popular", "numberOfItems": 76012},
      "links": [{"rel": "self", "href": "https://www.gutenberg.org/opds/search?sort=downloads&sort_order=desc", "type": "application/opds+json"}],
      "publications": []
    }
  ]
}''';

/// A page of Gutenberg's search, cut down (facets left out but one): a
/// book with its EPUB3 and covers, a book with no file yet (its link is
/// its web page), and the next page.
const _gutenbergSearch = r'''
{
  "metadata": {"title": "Project Gutenberg", "numberOfItems": 60, "itemsPerPage": 25, "currentPage": 1},
  "links": [
    {"rel": "self", "href": "https://www.gutenberg.org/opds/search?limit=25&query=pride&page=1", "type": "application/opds+json"},
    {"rel": "start", "href": "https://www.gutenberg.org/opds/", "type": "application/opds+json"},
    {"rel": "up", "href": "https://www.gutenberg.org/opds/", "type": "application/opds+json"},
    {"rel": "search", "href": "https://www.gutenberg.org/opds/search{?query,title,author}", "type": "application/opds+json", "templated": true},
    {"rel": "next", "href": "https://www.gutenberg.org/opds/search?limit=25&query=pride&page=2", "type": "application/opds+json"},
    {"rel": "last", "href": "https://www.gutenberg.org/opds/search?limit=25&query=pride&page=3", "type": "application/opds+json"}
  ],
  "publications": [
    {
      "metadata": {"@type": "http://schema.org/Book", "identifier": "https://www.gutenberg.org/ebooks/1342", "title": "Pride and Prejudice", "language": "en", "author": {"name": "Austen, Jane", "sortAs": "Austen, Jane"}},
      "links": [
        {"rel": "self", "href": "https://www.gutenberg.org/opds/publications?id=1342", "type": "application/opds-publication+json"},
        {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/cache/epub/1342/pg1342-images-3.epub", "type": "application/epub+zip", "length": 25165824, "title": "EPUB3 (E-readers incl. Send-to-Kindle)"}
      ],
      "images": [
        {"href": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg", "type": "image/jpeg", "rel": "http://opds-spec.org/image"},
        {"href": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg", "type": "image/jpeg", "rel": "http://opds-spec.org/image/thumbnail"}
      ]
    },
    {
      "metadata": {"@type": "http://schema.org/Book", "identifier": "https://www.gutenberg.org/ebooks/99999", "title": "Pride: A Poem", "language": "en", "author": [{"name": "One, A.", "sortAs": "One, A."}, {"name": "Two, B.", "sortAs": "Two, B."}], "translator": {"name": "Three, C.", "sortAs": "Three, C."}},
      "links": [
        {"rel": "self", "href": "https://www.gutenberg.org/opds/publications?id=99999", "type": "application/opds-publication+json"},
        {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/ebooks/99999", "type": "text/html"}
      ]
    }
  ],
  "facets": [
    {"metadata": {"title": "Sort By"}, "links": [{"href": "https://www.gutenberg.org/opds/search?limit=25&query=pride&page=1&sort=downloads&sort_order=desc", "type": "application/opds+json", "title": "Most Popular", "rel": "self"}]}
  ]
}''';

/// One of Gutenberg's books in full (/opds/publications?id=1342): its
/// description in paragraphs, and "Readers also downloaded".
const _gutenbergPublication = r'''
{
  "metadata": {
    "@type": "http://schema.org/Book",
    "identifier": "https://www.gutenberg.org/ebooks/1342",
    "title": "Pride and Prejudice",
    "language": "en",
    "author": {"name": "Austen, Jane", "sortAs": "Austen, Jane", "identifier": "https://www.gutenberg.org/ebooks/author/68", "links": [{"href": "https://www.gutenberg.org/opds/search?author_id=68", "type": "application/opds+json"}]},
    "published": "1998-06-01",
    "description": "Creators: Jane Austen (1775-1817)\n\nA novel of manners.\n\nRights: Public domain in the USA.\n\nDownloads: 100"
  },
  "links": [
    {"rel": "self", "href": "https://www.gutenberg.org/opds/publications?id=1342", "type": "application/opds-publication+json"},
    {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/cache/epub/1342/pg1342-images-3.epub", "type": "application/epub+zip", "title": "EPUB3 (E-readers incl. Send-to-Kindle)"},
    {"rel": "related", "href": "https://www.gutenberg.org/opds/also?id=1342", "type": "application/opds+json", "title": "Readers also downloaded"}
  ]
}''';

/// The OPDS test catalogue's front page (https://test.opds.io/2.0/home.json,
/// fetched November 2026), cut down: navigation, a group with a feed of its
/// own, a group of links, a group of books with none, and a book; its images
/// have sizes and no rel, and it is sent as plain application/json.
const _testCatalogue = r'''
{
  "metadata": {"title": "OPDS 2.0 Test Catalog"},
  "links": [{"rel": "self", "href": "https://test.opds.io/2.0/home.json", "type": "application/opds+json"}],
  "navigation": [
    {"href": "https://test.opds.io/2.0/navigation.json", "title": "Explore (Navigation Feed)", "type": "application/opds+json"},
    {"href": "https://test.opds.io/2.0/publications.json", "title": "French Books (Publications Feed)", "type": "application/opds+json"}
  ],
  "groups": [
    {
      "metadata": {"title": "French Classics", "numberOfItems": 5},
      "links": [{"rel": "self", "href": "https://test.opds.io/2.0/publications.json", "type": "application/opds+json"}],
      "publications": [
        {
          "metadata": {"@type": "http://schema.org/Book", "title": "Voyage au centre de la Terre", "author": {"name": "Jules Verne", "sortAs": "Verne, Jules"}, "identifier": "http://fr.feedbooks.com/book/1474/voyage-au-centre-de-la-terre", "language": "fr"},
          "links": [{"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://test.opds.io/assets/centredelaterre/file.epub", "type": "application/epub+zip"}]
        }
      ]
    },
    {
      "metadata": {"title": "More Navigation"},
      "navigation": [{"href": "https://test.opds.io/2.0/home.json", "title": "French Books", "type": "application/opds+json"}]
    },
    {
      "metadata": {"title": "English Classics", "numberOfItems": 3},
      "publications": [
        {
          "metadata": {"@type": "http://schema.org/Book", "title": "Romeo and Juliet", "author": {"name": "William Shakespeare", "sortAs": "Shakespeare, William"}, "identifier": "http://www.feedbooks.com/book/2936/romeo-and-juliet", "language": "en"},
          "links": [{"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://test.opds.io/assets/romeo/file.epub", "type": "application/epub+zip"}],
          "images": [
            {"href": "https://test.opds.io/assets/romeo/small.jpg", "type": "image/jpeg", "height": 169, "width": 110},
            {"href": "https://test.opds.io/assets/romeo/normal.jpg", "type": "image/jpeg", "height": 400, "width": 260}
          ]
        }
      ]
    }
  ],
  "publications": [
    {
      "metadata": {"@type": "http://schema.org/Book", "title": "Moby-Dick", "author": {"name": "Herman Melville", "sortAs": "Melville, Herman"}, "identifier": "http://www.feedbooks.com/book/54/moby-dick", "language": "en", "publisher": "Feedbooks"},
      "links": [{"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://test.opds.io/assets/moby/file.epub", "type": "application/epub+zip"}],
      "images": [
        {"href": "https://test.opds.io/assets/moby/normal.jpg", "type": "image/jpeg", "height": 400, "width": 260},
        {"href": "https://test.opds.io/assets/moby/small.jpg", "type": "image/jpeg", "height": 169, "width": 110}
      ]
    }
  ]
}''';

void main() {
  group('reading OPDS 2', () {
    test("Gutenberg's front page: its browse links and its groups, each a feed to open; its search", () {
      final feed = parseOpds2Feed(_gutenbergRoot, Uri.parse('https://www.gutenberg.org/opds/'));
      expect(feed.title, 'Project Gutenberg');
      expect([for (final e in feed.entries) e.title], ['Browse Bookshelves', 'Browse Subjects', 'Recently Added']);
      expect(feed.entries.every((e) => !e.isBook), isTrue);
      expect(feed.entries.first.feed!.href, Uri.parse('https://www.gutenberg.org/opds/bookshelves'));
      expect(feed.entries.last.feed!.href,
          Uri.parse('https://www.gutenberg.org/opds/search?sort=release_date&sort_order=desc'),
          reason: "a group's own feed is the way into it");
      expect(feed.searchable, isTrue);
      expect(feed.searchTemplate, 'https://www.gutenberg.org/opds/search?query={searchTerms}');
      expect(searchUrl(feed.searchTemplate!, ' pride & joy ').toString(),
          'https://www.gutenberg.org/opds/search?query=pride+%26+joy');
      expect(feed.next, isNull);
    });

    test("Gutenberg's search: books with their EPUB and covers, the next page", () {
      final feed = parseOpds2Feed(_gutenbergSearch, Uri.parse('https://www.gutenberg.org/opds/search?query=pride'));
      expect(feed.next, Uri.parse('https://www.gutenberg.org/opds/search?limit=25&query=pride&page=2'));
      expect(feed.entries, hasLength(2), reason: 'facets are not entries');
      final book = feed.entries.first;
      expect(book.id, 'https://www.gutenberg.org/ebooks/1342');
      expect(book.title, 'Pride and Prejudice');
      expect(book.authorLine, 'Austen, Jane');
      expect(book.isBook, isTrue);
      expect(book.feed, isNull);
      final epub = book.downloads.single;
      expect(epub.href, Uri.parse('https://www.gutenberg.org/cache/epub/1342/pg1342-images-3.epub'));
      expect(epub.title, 'EPUB3 (E-readers incl. Send-to-Kindle)');
      expect(epub.length, 25165824);
      expect(formatOf(epub.type, epub.href)!.label, 'EPUB');
      expect(downloadName(book, epub), 'Pride and Prejudice.epub');
      expect(book.thumbnail.toString(), endsWith('cover.small.jpg'));
      expect(book.image.toString(), endsWith('cover.medium.jpg'));

      final noFile = feed.entries.last;
      expect(noFile.isBook, isFalse, reason: 'its only link is a web page');
      expect(noFile.feed, isNull);
      expect(noFile.authors, ['One, A.', 'Two, B.']);
    });

    test("one of Gutenberg's books in full: its description in paragraphs, related feeds", () {
      final feed = parseOpds2Feed(_gutenbergPublication, Uri.parse('https://www.gutenberg.org/opds/publications?id=1342'));
      final book = feed.entries.single;
      expect(book.isBook, isTrue);
      expect(book.description,
          'Creators: Jane Austen (1775-1817)\n\nA novel of manners.\n\nRights: Public domain in the USA.\n\nDownloads: 100');
      expect(book.related.single.href, Uri.parse('https://www.gutenberg.org/opds/also?id=1342'));
      expect(book.related.single.title, 'Readers also downloaded');
    });

    test("the OPDS test catalogue: navigation, groups with and without a feed, books, covers by size", () {
      final feed = parseOpds2Feed(_testCatalogue, Uri.parse('https://test.opds.io/2.0/home.json'));
      expect(feed.title, 'OPDS 2.0 Test Catalog');
      expect([for (final e in feed.entries) e.title], [
        'Explore (Navigation Feed)',
        'French Books (Publications Feed)',
        'Moby-Dick',
        'French Classics',
        'French Books',
        'Romeo and Juliet',
      ]);
      expect(feed.entries.first.feed!.href, Uri.parse('https://test.opds.io/2.0/navigation.json'));
      final moby = feed.entries[2];
      expect(moby.isBook, isTrue);
      expect(moby.authorLine, 'Herman Melville');
      expect(moby.thumbnail.toString(), endsWith('small.jpg'), reason: 'the smaller, though listed second');
      expect(moby.image.toString(), endsWith('normal.jpg'));
      expect(feed.entries[3].feed!.href, Uri.parse('https://test.opds.io/2.0/publications.json'));
      final romeo = feed.entries.last;
      expect(romeo.downloads.single.href, Uri.parse('https://test.opds.io/assets/romeo/file.epub'));
      expect(feed.searchable, isFalse);
    });

    test('names in several languages, authors as plain text, links with several rels, a description in HTML', () {
      const json = r'''
{
  "metadata": {"title": {"fr": "Livres", "en": "Books"}},
  "links": [{"rel": ["next", "http://example.org/more"], "href": "page2.json", "type": "application/opds+json"}],
  "publications": [
    {
      "metadata": {"title": "Le Rouge et le Noir", "author": "Stendhal", "description": "<p>One &amp; two.</p><p>Three.</p>"},
      "links": [
        {"rel": ["http://opds-spec.org/acquisition/buy"], "href": "/buy/1", "type": "application/epub+zip"},
        {"rel": ["self", "http://opds-spec.org/acquisition"], "href": "/books/1.epub", "type": "application/epub+zip"},
        {"rel": "http://opds-spec.org/acquisition/borrow", "href": "/loan/1", "type": "application/epub+zip"},
        {"rel": "http://opds-spec.org/acquisition/open-access", "href": "/books/1.pdf", "type": "application/pdf"}
      ]
    }
  ]
}''';
      final feed = parseOpds2Feed(json, Uri.parse('https://books.example.org/opds/new.json'));
      expect(feed.title, 'Books');
      expect(feed.next, Uri.parse('https://books.example.org/opds/page2.json'));
      final book = feed.entries.single;
      expect(book.authors, ['Stendhal']);
      expect(book.description, 'One & two.\n\nThree.');
      expect([for (final l in book.downloads) l.href.path], ['/books/1.epub', '/books/1.pdf'],
          reason: 'EPUB before PDF; a purchase or a loan is not a file to take');
    });

    test('search templates: the words go in query, else the first variable', () {
      String t(String raw) => parseOpds2Feed(
            jsonEncode({
              'metadata': {'title': 'x'},
              'links': [
                {'rel': 'search', 'href': raw, 'type': 'application/opds+json', 'templated': true},
              ],
              'publications': <Object>[],
            }),
            Uri.parse('https://x.org/opds/'),
          ).searchTemplate!;
      expect(t('/search{?query,title,author}'), 'https://x.org/search?query={searchTerms}');
      expect(t('search{?title,query}'), 'https://x.org/opds/search?query={searchTerms}');
      expect(t('/s{?q,page}'), 'https://x.org/s?q={searchTerms}');
      expect(t('/s?lang=en{&query,page}'), 'https://x.org/s?lang=en&query={searchTerms}');
      expect(t('/s/{query}'), 'https://x.org/s/{searchTerms}');
    });

    test('JSON or Atom told apart; something else is said to be no catalogue', () {
      expect(looksLikeJson('${String.fromCharCode(0xFEFF)}\n  {"metadata": {}}'), isTrue);
      expect(looksLikeJson('<?xml version="1.0"?><feed/>'), isFalse);
      expect(() => parseOpds2Feed('{"metadata": ', Uri.parse('https://x/')), throwsA(isA<OpdsFormatException>()));
      expect(() => parseOpds2Feed('[1, 2]', Uri.parse('https://x/')), throwsA(isA<OpdsFormatException>()));
      expect(() => parseOpds2Feed('{"error": "no"}', Uri.parse('https://x/')), throwsA(isA<OpdsFormatException>()));
    });
  });

  group('an OPDS 2 catalogue on the network', () {
    late HttpServer server;
    late Uri base;
    final requests = <String>[];

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((r) async {
        requests.add(r.uri.toString());
        final res = r.response;
        void send(String type, String body) {
          res.headers.contentType = ContentType.parse(type);
          res.write(body);
        }

        switch (r.uri.path) {
          case '/opds/':
            send('application/opds+json', '''
{"metadata": {"title": "Small Library"},
 "links": [{"rel": "search", "href": "/opds/search{?query,title,author}", "type": "application/opds+json", "templated": true}],
 "navigation": [{"href": "/opds/new", "title": "New books", "type": "application/opds+json", "rel": "subsection"}]}''');
          case '/opds/new' when r.uri.queryParameters['page'] == '2':
            // Sent as text: told apart from Atom by what it is.
            send('text/plain', _page([('Book 3', '/books/3.epub')]));
          case '/opds/new':
            send('application/json', _page([('The Test Book', '/books/1.epub')], next: '/opds/new?page=2'));
          case '/opds/search':
            send('application/opds+json', _page([('Found: ${r.uri.queryParameters['query']}', '/books/1.epub')]));
          case '/books/1.epub':
            res.headers.contentType = ContentType('application', 'epub+zip');
            res.add(sampleEpub());
          case '/old/':
            send('application/atom+xml;profile=opds-catalog',
                '<feed xmlns="http://www.w3.org/2005/Atom"><title>Old Library</title>'
                '<entry><id>n</id><title>New books</title>'
                '<link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/old/new"/></entry></feed>');
          default:
            res.statusCode = HttpStatus.notFound;
        }
        await res.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('browses, pages on and searches, as an Atom catalogue is', () async {
      final client = OpdsClient(base.resolve('/opds/'));
      final root = await client.feed(base.resolve('/opds/'));
      expect(root.title, 'Small Library');
      final page1 = await client.feed(root.entries.single.feed!.href);
      expect(page1.entries.single.title, 'The Test Book');
      expect(page1.entries.single.downloads.single.href, base.resolve('/books/1.epub'));
      final page2 = await client.feed(page1.next!);
      expect(page2.entries.single.title, 'Book 3');
      expect(page2.next, isNull);
      final found = await client.search(root, 'pride & joy');
      expect(found.entries.single.title, 'Found: pride & joy');
      expect(requests, contains('/opds/search?query=pride+%26+joy'));
      client.close();
    });

    test('a book is added from it through the normal import', () async {
      final tmp = Directory.systemTemp.createTempSync('tomevoice_opds2');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // Best effort.
        }
      });
      final store = LibraryStore(tmp);
      final client = OpdsClient(base.resolve('/opds/'));
      final book = (await client.feed(base.resolve('/opds/new'))).entries.single;
      final added = await addFromCatalogue(store, client, book, book.downloads.single);
      client.close();
      expect(added.title, 'The Test Book');
      expect((await store.index()).entries, hasLength(1));
    });

    test("the older feed is read when the front page cannot be, and only for the front page", () async {
      final client = OpdsClient(base.resolve('/gone/'), fallback: base.resolve('/old/'));
      final root = await client.feed(base.resolve('/gone/'));
      expect(root.title, 'Old Library', reason: 'Atom still reads, from the same client');
      expect(root.entries.single.feed!.href, base.resolve('/old/new'));
      await expectLater(client.feed(base.resolve('/gone/elsewhere')), throwsA(isA<HttpException>()));
      client.close();

      final none = OpdsClient(base.resolve('/gone/'));
      await expectLater(none.feed(base.resolve('/gone/')), throwsA(isA<HttpException>()));
      none.close();

      final both = OpdsClient(base.resolve('/gone/'), fallback: base.resolve('/also-gone/'));
      await expectLater(both.feed(base.resolve('/gone/')),
          throwsA(isA<HttpException>().having((e) => e.uri, 'the first trouble told', base.resolve('/gone/'))));
      both.close();
    });
  });

  test("Gutenberg's built-in entry opens its OPDS 2 front page and keeps its older feed to fall back on", () {
    expect(Catalogue.gutenberg.url, 'https://www.gutenberg.org/opds/');
    expect(Catalogue.gutenberg.fallback, 'https://www.gutenberg.org/ebooks.opds/');
    expect(Catalogue.gutenberg.withUser('me').fallback, Catalogue.gutenberg.fallback);
    expect(Catalogue.gutenberg.toJson(), isNot(contains('fallback')), reason: 'built-in ones are kept by id');
  });
}

/// A page of books, each with an EPUB, and its next page.
String _page(List<(String, String)> books, {String? next}) => jsonEncode({
      'metadata': {'title': 'Books'},
      'links': [
        if (next != null) {'rel': 'next', 'href': next, 'type': 'application/opds+json'},
      ],
      'publications': [
        for (final (title, file) in books)
          {
            'metadata': {'title': title, 'author': 'Ann Author'},
            'links': [
              {'rel': 'http://opds-spec.org/acquisition/open-access', 'href': file, 'type': 'application/epub+zip'},
            ],
          },
      ],
    });
