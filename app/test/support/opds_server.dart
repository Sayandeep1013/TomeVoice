// A small OPDS catalogue on this computer, for the tests: a navigation
// feed, a paged acquisition feed, OpenSearch, a book's EPUB and PDF, and
// sign-in by Basic or Digest (as Calibre's content server does). Plain
// dart:io, no Flutter.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// A small EPUB with one chapter, as a catalogue would send.
Uint8List sampleEpub({String title = 'The Test Book', String author = 'Ann Author'}) {
  final a = Archive();
  void text(String name, String body) => a.addFile(ArchiveFile.bytes(name, utf8.encode(body)));
  a.addFile(ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')));
  text('META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>');
  text('OEBPS/content.opf', '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>$title</dc:title><dc:creator>$author</dc:creator><dc:language>en</dc:language></metadata>
  <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>''');
  // Stored, not deflated, so the file is big enough to arrive in pieces.
  final chapter = utf8.encode('<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter One</h1>'
      '${'<p>The test book goes on for a while, so that it reads as a chapter of its own and not a cover.</p>' * 120}'
      '</body></html>');
  a.addFile(ArchiveFile.noCompress('OEBPS/c1.xhtml', chapter.length, chapter));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

class OpdsTestServer {
  OpdsTestServer._(this._server, this.user, this.password, this.digest);

  final HttpServer _server;
  final String? user;
  final String? password;
  final bool digest;

  /// Every request, as method and path with query.
  final requests = <String>[];

  /// Authorization headers received, by path.
  final authorizations = <String, String>{};

  /// Where /away sends the client (another server, for the redirect test).
  Uri? redirectTo;

  final _epub = sampleEpub();

  static Future<OpdsTestServer> start({String? user, String? password, bool digest = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = OpdsTestServer._(server, user, password, digest);
    server.listen(s._handle);
    return s;
  }

  Uri get root => Uri.parse('http://127.0.0.1:${_server.port}/opds');
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  static const _realm = 'calibre';
  static const _nonce = 'b1946ac92492d2347c6235b4d2611184';

  bool _signedIn(HttpRequest r) {
    if (user == null) return true;
    final auth = r.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!digest) {
      return auth == 'Basic ${base64.encode(utf8.encode('$user:${password ?? ''}'))}';
    }
    if (!auth.startsWith('Digest ')) return false;
    final f = <String, String>{
      for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]*))').allMatches(auth.substring(7)))
        m[1]!: m[2] ?? m[3] ?? '',
    };
    String md5hex(String s) => md5.convert(utf8.encode(s)).toString();
    final ha1 = md5hex('$user:$_realm:${password ?? ''}');
    final ha2 = md5hex('${r.method}:${f['uri']}');
    final want = f['qop'] == null
        ? md5hex('$ha1:$_nonce:$ha2')
        : md5hex('$ha1:$_nonce:${f['nc']}:${f['cnonce']}:${f['qop']}:$ha2');
    return f['username'] == user && f['nonce'] == _nonce && f['response'] == want;
  }

  Future<void> _handle(HttpRequest r) async {
    final path = r.uri.path;
    requests.add('${r.method} ${r.uri}');
    final auth = r.headers.value(HttpHeaders.authorizationHeader);
    if (auth != null) authorizations[path] = auth;
    final res = r.response;
    if (path == '/away') {
      // Off to another host: a client must not take the password along.
      res.statusCode = HttpStatus.found;
      res.headers.set(HttpHeaders.locationHeader, redirectTo.toString());
      await res.close();
      return;
    }
    if (!_signedIn(r)) {
      res.statusCode = HttpStatus.unauthorized;
      res.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        digest ? 'Digest realm="$_realm", nonce="$_nonce", qop="auth", algorithm="MD5"' : 'Basic realm="$_realm"',
      );
      await res.close();
      return;
    }
    switch (path) {
      case '/opds':
        _xml(res, _navigation());
      case '/opds/new':
        _xml(res, r.uri.queryParameters['page'] == '2' ? _page2() : _page1());
      case '/osd.xml':
        res.headers.contentType = ContentType('application', 'opensearchdescription+xml', charset: 'utf-8');
        res.write('<?xml version="1.0" encoding="UTF-8"?>'
            '<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">'
            '<ShortName>Test</ShortName>'
            '<Url type="text/html" template="/search.html?q={searchTerms}"/>'
            '<Url type="application/atom+xml;profile=opds-catalog" template="/opds/search?q={searchTerms}&amp;start={startPage?}"/>'
            '</OpenSearchDescription>');
      case '/opds/search':
        final q = r.uri.queryParameters['q'] ?? '';
        _xml(res, _feed('Search: $q', [if (q.toLowerCase().contains('test')) _book(1)]));
      case '/books/1.epub':
        res.headers.contentType = ContentType('application', 'epub+zip');
        res.headers.set('content-disposition', 'attachment; filename="The Test Book - Ann Author.epub"');
        res.contentLength = _epub.length;
        // In pieces, a moment apart, so progress has something to say.
        for (var i = 0; i < _epub.length; i += 4096) {
          res.add(_epub.sublist(i, i + 4096 > _epub.length ? _epub.length : i + 4096));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }

  static void _xml(HttpResponse res, String body) {
    res.headers.contentType = ContentType('application', 'atom+xml', charset: 'utf-8');
    res.write(body);
  }

  static const _thumb =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==';

  String _feed(String title, List<String> entries, {String? next}) => '<?xml version="1.0" encoding="UTF-8"?>'
      '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">'
      '<id>urn:test</id><title>$title</title>'
      '<link rel="search" type="application/opensearchdescription+xml" href="/osd.xml"/>'
      '${next == null ? '' : '<link rel="next" type="application/atom+xml;profile=opds-catalog;kind=acquisition" href="$next"/>'}'
      '${entries.join()}</feed>';

  String _navigation() => _feed('Test Library', [
        '<entry><title>New books</title><id>new</id>'
            '<content type="text">The newest first</content>'
            '<link rel="subsection" type="application/atom+xml;profile=opds-catalog;kind=acquisition" href="/opds/new"/>'
            '<link rel="http://opds-spec.org/image/thumbnail" type="image/png" href="$_thumb"/></entry>',
      ]);

  String _book(int n) => '<entry><title>${n == 1 ? 'The Test Book' : 'Book $n'}</title><id>urn:book:$n</id>'
      '<author><name>Ann Author</name></author>'
      '<summary type="text">A short one.</summary>'
      '<content type="html">&lt;p&gt;A &lt;b&gt;longer&lt;/b&gt; description &amp;amp; more.&lt;/p&gt;&lt;p&gt;Second paragraph.&lt;/p&gt;</content>'
      '<link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/books/$n.pdf"/>'
      '<link rel="http://opds-spec.org/acquisition/buy" type="application/epub+zip" href="/shop/$n"/>'
      '<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/books/$n.epub" title="EPUB"/>'
      '<link rel="http://opds-spec.org/image" type="image/png" href="$_thumb"/>'
      '<link rel="related" type="application/atom+xml;profile=opds-catalog" href="/opds/author/1" title="By Ann Author"/>'
      '</entry>';

  String _page1() => _feed('New books', [_book(1), _book(2)], next: '/opds/new?page=2');

  String _page2() => _feed('New books', [_book(3)]);
}
