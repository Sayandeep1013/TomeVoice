// Book-file sources (GitHub build): a source's book and its files read from
// what the plugin hands back; a file downloaded with the source's own
// cookies, its name as the site gives it; a site that turns the reader away
// says so.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/net.dart';

void main() {
  test("a book and its files, from the plugin's answer; files with no address left out", () {
    final b = SourceBook.fromJs({
      'name': ' The Keeper of the Light ',
      'author': 'Pagebound Press',
      'year': 2026,
      'files': [
        {'format': 'EPUB', 'url': 'https://example.org/dl/1.epub', 'size': 2951},
        {'format': 'pdf', 'url': '', 'size': 10},
        {'url': 'https://example.org/dl/1.bin'},
      ],
    }, path: 'book/2');
    expect(b.name, 'The Keeper of the Light');
    expect(b.year, '2026');
    expect(b.files.map((f) => f.format), ['epub', 'file']);
    expect(b.files.first.size, 2951);
    expect(SourceBook.fromJs(null, path: 'x').files, isEmpty);
  });

  group('a book file downloaded', () {
    late HttpServer server;
    late Directory tmp;
    late String site;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tv_book_dl');
      Net.allowPrivateAddresses = true;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      site = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final signedIn = req.cookies.any((c) => c.name == 'pb_session' && c.value == 'ok');
        if (req.uri.path == '/go') {
          req.response
            ..statusCode = 302
            ..headers.set('Location', '/dl/keeper.epub');
        } else if (!signedIn) {
          req.response.statusCode = 401;
        } else {
          req.response.headers
            ..contentType = ContentType('application', 'epub+zip')
            ..set('Content-Disposition', 'attachment; filename="keeper.epub"');
          req.response.add(List.filled(5000, 7));
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    test("with the source's sign-in: through a redirect, whole, named as the site names it", () async {
      final jar = Net.instance.jar;
      jar.take(Uri.parse('$site/'), [Cookie('pb_session', 'ok')..path = '/'], partition: 'pagebound');
      final to = File('${tmp.path}/part');
      var seen = 0;
      final got = await Net.instance.download('$site/go', to, partition: 'pagebound', onProgress: (d, _) => seen = d);
      expect(got.name, 'keeper.epub');
      expect(got.type, 'application/epub+zip');
      expect(to.lengthSync(), 5000);
      expect(seen, 5000);
    });

    test('signed out: the site turning it away is an error, nothing kept as the book', () async {
      final to = File('${tmp.path}/part');
      await expectLater(Net.instance.download('$site/dl/keeper.epub', to, partition: 'someone-else'),
          throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('HTTP 401'))));
    });
  });
}
