// Read anything: a link or words shared to TomeVoice, or pasted, read as
// an article on the Articles shelf, as the book file a link leads to, or as
// a book of the words; each one once. Pages come from a local server.
//
// No test binding here: with one, every HttpClient answers 400.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/article.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/shared_text.dart';

import 'article_pages.dart';

/// windows-1251 for "Пример текста", a few times over: Russian bytes no UTF-8
/// reader could take for UTF-8.
List<int> _cp1251(String ascii, int times) {
  const word = [0xCF, 0xF0, 0xE8, 0xEC, 0xE5, 0xF0, 0x20, 0xF2, 0xE5, 0xEA, 0xF1, 0xF2, 0xE0];
  return [
    ...latin1.encode('<html><head><title>T</title></head><body><article>'),
    for (var i = 0; i < times; i++) ...[...latin1.encode('<p>'), for (var k = 0; k < 4; k++) ...[...word, 0x2E, 0x20], ...latin1.encode('$ascii</p>')],
    ...latin1.encode('</article></body></html>'),
  ];
}

class _Site {
  late HttpServer server;
  final hits = <String, int>{};
  late Uint8List epub;

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    epub = File('assets/starter/pride-and-prejudice.epub').readAsBytesSync();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final res = req.response;
      switch (path) {
        case '/news' || '/news/':
          res.headers.contentType = ContentType.html;
          res.write(newsPage);
        case '/medium':
          res.headers.contentType = ContentType.html;
          res.write(mediumPage);
        case '/short':
          res.statusCode = 302;
          res.headers.set('location', '/news');
        case '/cookies':
          res.statusCode = 302;
          res.cookies.add(Cookie('gate', 'open')..path = '/');
          res.headers.set('location', '/cookies/ok');
        case '/cookies/ok':
          final gate = req.cookies.where((c) => c.name == 'gate').firstOrNull?.value;
          if (gate != 'open') {
            res.statusCode = 403;
          } else {
            res.headers.contentType = ContentType.html;
            res.write(blogPage);
          }
        case '/cf':
          res.statusCode = 403;
          res.headers.set('cf-mitigated', 'challenge');
          res.headers.set('server', 'cloudflare');
          res.headers.contentType = ContentType.html;
          res.write('<!DOCTYPE html><html><head><title>Just a moment...</title></head><body></body></html>');
        case '/missing':
          res.statusCode = 404;
        case '/photo.jpg':
          res.headers.contentType = ContentType('image', 'jpeg');
          res.add([0xFF, 0xD8, 0xFF, 0xE0]);
        case '/login':
          res.headers.contentType = ContentType.html;
          res.write('<html><body><form><input name="u"><input type="password"></form>'
              '<p>Log in to keep reading this story.</p></body></html>');
        case '/books/pride.epub':
          res.headers.contentType = ContentType('application', 'epub+zip');
          res.add(epub);
        case '/download':
          res.headers.contentType = ContentType('application', 'octet-stream');
          res.headers.set('content-disposition', 'attachment; filename="Pride.epub"');
          res.add(epub);
        case '/paper':
          res.headers.contentType = ContentType('application', 'pdf');
          res.add(latin1.encode('%PDF-1.4\n%fake\n'));
        case '/russian':
          res.headers.set('content-type', 'text/html; charset=windows-1251');
          res.add(_cp1251(' and so on.', 4));
        case '/latin':
          res.headers.set('content-type', 'text/html');
          res.add(latin1.encode('<html><head><meta charset="iso-8859-1"><title>Café</title></head><body><article>'
              '${'<p>Un café crème, s’il vous plaît, avec un croissant et le journal.</p>'.replaceAll('’', "'") * 4}'
              '</article></body></html>'));
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  }
}

void main() {
  late Directory tmp;
  late LibraryStore store;
  final site = _Site();

  setUpAll(site.start);
  tearDownAll(() => site.server.close(force: true));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_shared');
    store = LibraryStore(tmp);
    site.hits.clear();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Category> shelfOf(LibraryEntry e) async {
    final idx = await store.index(all: true);
    return idx.categories.firstWhere((c) => c.id == e.categoryIn(idx.categories, idx.defaultCategory));
  }

  group('what was shared', () {
    test('a link, alone or with a little around it', () {
      expect(sharedLink('https://news.example/a/b'), Uri.parse('https://news.example/a/b'));
      expect(sharedLink('Rice news\nhttps://news.example/a'), Uri.parse('https://news.example/a'));
      expect(sharedLink('"The surprise was how little the plants cared"\nhttps://news.example/a#:~:text=The%20surprise')?.path,
          '/a', reason: "Chrome's share of chosen text");
      expect(sharedLink('Read this: https://news.example/a.'), Uri.parse('https://news.example/a'));
      expect(sharedLink('(https://en.wikipedia.org/wiki/Python_(programming_language))')?.path,
          '/wiki/Python_(programming_language)');
      expect(sharedLink('www.news.example/a'), Uri.parse('https://www.news.example/a'));
      expect(sharedLink('https://news.example/a and again https://news.example/a/'), isNotNull,
          reason: 'one page, twice');
    });

    test('words, not a link: none, two, or a passage that mentions one', () {
      expect(sharedLink('Buy seeds before the frost.'), isNull);
      expect(sharedLink('https://a.example/x https://b.example/y'), isNull);
      expect(sharedLink('${'A long passage about gardens and the weather in spring. ' * 8} See https://a.example/x'), isNull);
      expect(sharedLink('ftp://files.example/book.epub'), isNull);
    });

    test('one page however its address is written', () {
      final id = articleIdOf(Uri.parse('https://www.news.example/a/story'));
      for (final same in [
        'http://news.example/a/story',
        'https://news.example/a/story/',
        'https://m.news.example/a/story?utm_source=share&utm_medium=x',
        'https://news.example/a/story?fbclid=123#comments',
      ]) {
        expect(articleIdOf(Uri.parse(same)), id, reason: same);
      }
      expect(articleIdOf(Uri.parse('https://news.example/a/story?page=2')), isNot(id));
      expect(articleIdOf(Uri.parse('https://news.example/a/other')), isNot(id));
    });

    test('a book of words is named from the first line', () {
      expect(titleOfText('\n\n# Shopping list\n- eggs\n- flour'), 'Shopping list');
      expect(titleOfText('AC/DC_live notes\nmore'), 'AC${String.fromCharCode(0x2215)}DC live notes');
      final long = titleOfText('${'word ' * 40}end');
      expect(long.length, lessThanOrEqualTo(61));
      expect(long, endsWith(String.fromCharCode(0x2026)));
      // The title survives as the file name a parse takes it from again.
      expect(titleFromFilename('${titleOfText('Notes: v2.0 / final_draft')}.txt'), titleOfText('Notes: v2.0 / final_draft'));
    });
  });

  group('a shared link', () {
    test('becomes an article on the Articles shelf, made for it, and comes once', () async {
      final got = await readShared(store, 'Rice\n${site.base}/news?utm_source=share');
      expect(got, isA<SharedBook>().having((b) => b.existing, 'existing', false));
      final e = (got as SharedBook).entry;
      expect(e.title, 'Scientists find a quieter way to grow rice');
      expect(e.authors, ['Jane Doe']);
      expect(e.formatLabel, 'HTML');
      final shelf = await shelfOf(e);
      expect(shelf.name, 'Articles');
      expect(shelf.secret, isFalse);
      final layout = await store.loadLayout(e.id);
      expect(layout.book.metadata.description, 'From The Daily Planet · 3 March 2026\n${site.base}/news',
          reason: 'the address kept without its tracking tags');
      expect(layout.book.metadata.publisher, 'The Daily Planet');

      // Shared again (another way of writing it): the same book, not fetched.
      for (final again in ['${site.base}/news', '${site.base}/news/', 'Look ${site.base}/news#top']) {
        final second = await readShared(store, again);
        expect(second, isA<SharedBook>().having((b) => b.existing, 'existing', true), reason: again);
        expect((second as SharedBook).entry.id, e.id);
      }
      expect(site.hits['/news'], 1);
      expect(await store.list(all: true), hasLength(1));
      final idx = await store.index(all: true);
      expect(idx.categories.where((c) => c.name == 'Articles'), hasLength(1), reason: 'the shelf is made once');
    });

    test('that redirects is the article where it lands', () async {
      final first = await readShared(store, '${site.base}/short') as SharedBook;
      expect(first.entry.id, articleIdOf(Uri.parse('${site.base}/news')));
      final second = await readShared(store, '${site.base}/news') as SharedBook;
      expect(second.existing, isTrue);
      expect(site.hits['/news'], 1, reason: 'known by its own address, no fetch');
      // The short link again: fetched to learn where it goes, then known.
      final third = await readShared(store, '${site.base}/short') as SharedBook;
      expect(third.existing, isTrue);
      expect(await store.list(all: true), hasLength(1));
    });

    test('sends back the cookies a redirect set', () async {
      final got = await readShared(store, '${site.base}/cookies') as SharedBook;
      // From 127.0.0.1 nothing says "Jane's Allotment" is the site's name,
      // so it stays in the title.
      expect(got.entry.title, startsWith('Notes from a slow garden'));
      expect(Directory('${tmp.path}/incoming').existsSync() ? Directory('${tmp.path}/incoming').listSync() : const [],
          isEmpty);
    });

    test('never goes to a secret shelf, even one called Articles', () async {
      final secret = await store.addCategory('Articles', secret: true);
      final got = await readShared(store, '${site.base}/medium') as SharedBook;
      final shelf = await shelfOf(got.entry);
      expect(shelf.id, isNot(secret.id));
      expect(shelf.name, 'Articles');
      expect(shelf.secret, isFalse);
      expect(store.isSecret(got.entry.id), isFalse);

      // The store itself will not put a made book on a secret shelf.
      final made = await store.importMade(
        id: bookIdOf(Uint8List.fromList(utf8.encode('x'))),
        name: 'Words.txt',
        bytes: Uint8List.fromList(utf8.encode('Words for a book that asked for the secret shelf.')),
        category: secret.id,
      );
      expect(made.category, isNot(secret.id));
      expect(store.isSecret(made.id), isFalse);
    });

    test('to a book file imports that book', () async {
      final got = await readShared(store, '${site.base}/books/pride.epub');
      expect(got, isA<SharedFile>());
      final file = (got as SharedFile).file;
      expect(file.name, 'pride.epub');
      expect(file.path, contains('/incoming/'));
      final e = await store.importFile(file);
      expect(e.title, 'Pride and Prejudice');
      expect(File(file.path).existsSync(), isFalse, reason: 'the download goes once imported');

      final named = await readShared(store, '${site.base}/download?id=7') as SharedFile;
      expect(named.file.name, 'Pride.epub', reason: "the server's name for it");
      final pdf = await readShared(store, '${site.base}/paper') as SharedFile;
      expect(pdf.file.name, 'paper.pdf', reason: 'named for its type');
      expect(pdf.file.mime, 'application/pdf');
    });

    test('that will not be read says why', () async {
      Future<ArticleProblem> problem(String path) async {
        try {
          await readShared(store, '${site.base}$path');
        } on ArticleProblem catch (e) {
          return e;
        }
        fail('$path was read');
      }

      final cf = await problem('/cf');
      expect(cf.message, browserCheckMessage);
      expect(cf.message, 'This site wants a browser check; open it in your browser instead.');
      expect(cf.browse, isTrue);
      expect((await problem('/missing')).message, 'That page was not found (error 404).');
      expect((await problem('/photo.jpg')).message, 'That link is a picture, not a page to read.');
      expect((await problem('/login')).message, startsWith('That page asks you to sign in first'));
      expect((await problem('/login')).browse, isTrue);
      expect(await store.list(all: true), isEmpty);
      final idx = await store.index(all: true);
      expect(idx.categories.where((c) => c.name == 'Articles'), isEmpty, reason: 'no shelf for nothing');
    });

    test('is read in the encoding the page is in', () async {
      final ru = await readShared(store, '${site.base}/russian') as SharedBook;
      final ruText = (await store.loadLayout(ru.entry.id)).units.map((u) => u.text).join(' ');
      expect(ruText, contains('Пример текста'));
      final fr = await readShared(store, '${site.base}/latin') as SharedBook;
      expect(fr.entry.title, 'Café', reason: 'its meta charset, no header');
      final frText = (await store.loadLayout(fr.entry.id)).units.map((u) => u.text).join(' ');
      expect(frText, contains('Un café crème'));
    });

    test('keeps its site and address when the book is parsed again', () async {
      final got = await readShared(store, '${site.base}/medium') as SharedBook;
      final parsed = File('${store.bookDir(got.entry.id)}/parsed.json');
      final raw = Map<String, Object?>.from(jsonDecode(parsed.readAsStringSync()) as Map);
      // As an older TomeVoice wrote it: parsed again from its file on open.
      parsed.writeAsStringSync(jsonEncode({...raw, 'v': 1}));
      final layout = await LibraryStore(tmp).loadLayout(got.entry.id);
      final m = layout.book.metadata;
      expect(m.title, 'The quiet joy of reading aloud');
      expect(m.authors, ['Sam Rivera']);
      expect(m.description, startsWith('From Medium · 14 February 2026\n'));
      expect(m.identifier, '${site.base}/medium');
      expect((jsonDecode(parsed.readAsStringSync()) as Map)['v'], isNot(1), reason: 'it was parsed again');
    });
  });

  group('shared words', () {
    const note = 'A note to self\n\nBuy seeds before the frost comes. The beans want sowing in March, '
        'and the sweet peas want a cane to climb.';

    test('become a book named from the first line, on the shelf new books go to, once', () async {
      final got = await readShared(store, note) as SharedBook;
      expect(got.existing, isFalse);
      expect(got.entry.title, 'A note to self');
      expect(got.entry.category, (await store.index()).defaultCategory);
      final again = await readShared(store, '\r\n$note\r\n') as SharedBook;
      expect(again.existing, isTrue, reason: 'the same words, whatever the line ends');
      expect(again.entry.id, got.entry.id);
      expect(await store.list(all: true), hasLength(1));
      expect(site.hits, isEmpty);
    });

    test('that only mention a link are read, not fetched', () async {
      final passage = '${'The garden in spring is a busy place, with work for every dry day. ' * 6}'
          'More at ${site.base}/news';
      final got = await readShared(store, passage) as SharedBook;
      expect(got.entry.title, startsWith('The garden in spring'));
      expect(site.hits, isEmpty);
    });

    test('with nothing in them are refused', () async {
      await expectLater(readShared(store, ' \n\t '), throwsA(isA<ArticleProblem>()));
    });
  });
}
