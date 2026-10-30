// A small WebDAV server for the sync tests, and for trying sync on a phone
// (see sync_servers.dart): folders, PROPFIND (depth 0 and 1), MKCOL, GET,
// PUT with If-Match and If-None-Match, DELETE, ETags, and Basic sign-in.
// Plain dart:io and dart:convert, so it runs with the Dart SDK alone.

import 'dart:convert';
import 'dart:io';

class WebDavTestServer {
  WebDavTestServer._(this._server, this.user, this.password, this.keepIn);

  final HttpServer _server;
  final String user;
  final String password;

  /// Where the files are kept on disk as well, if anywhere (the phone
  /// runner); the tests keep them in memory only.
  final Directory? keepIn;

  /// Path -> file text, under /dav/.
  final files = <String, String>{};
  final _versions = <String, int>{};
  final folders = <String>{'/dav/'};

  /// Every request, as method and path.
  final requests = <String>[];

  /// Called once a file has been read (a test changes it then, as another
  /// phone writing between a read and a write).
  void Function(String path)? afterGet;

  static Future<WebDavTestServer> start({
    String user = 'reader',
    String password = 'secret',
    int port = 0,
    Directory? keepIn,
    InternetAddress? address,
  }) async {
    final server = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    final s = WebDavTestServer._(server, user, password, keepIn);
    s._load();
    server.listen(s._handle);
    return s;
  }

  Uri get root => Uri.parse('http://127.0.0.1:${_server.port}/dav/');
  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  String _etag(String path) => '"${_versions[path] ?? 0}-${files[path]!.length}"';

  bool _signedIn(HttpRequest r) =>
      r.headers.value(HttpHeaders.authorizationHeader) == 'Basic ${base64.encode(utf8.encode('$user:$password'))}';

  static String _parent(String path) {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    return '${trimmed.substring(0, trimmed.lastIndexOf('/'))}/';
  }

  Future<void> _handle(HttpRequest r) async {
    final path = Uri.decodeFull(r.uri.path);
    requests.add('${r.method} $path');
    final res = r.response;
    final body = await utf8.decoder.bind(r).join();
    if (!_signedIn(r)) {
      res.statusCode = HttpStatus.unauthorized;
      res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="TomeVoice test"');
      await res.close();
      return;
    }
    if (!path.startsWith('/dav/')) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    switch (r.method) {
      case 'PROPFIND':
        _propfind(res, path, r.headers.value('depth') ?? '1');
      case 'MKCOL':
        final dir = path.endsWith('/') ? path : '$path/';
        if (folders.contains(dir) || files.containsKey(path)) {
          res.statusCode = HttpStatus.methodNotAllowed;
        } else if (!folders.contains(_parent(dir))) {
          res.statusCode = HttpStatus.conflict;
        } else {
          folders.add(dir);
          _save(dir, null);
          res.statusCode = HttpStatus.created;
        }
      case 'GET':
        final text = files[path];
        if (text == null) {
          res.statusCode = HttpStatus.notFound;
        } else {
          final etag = _etag(path);
          // Changed (by a test) once it has been read, before it arrives.
          afterGet?.call(path);
          res.headers.set(HttpHeaders.etagHeader, etag);
          res.headers.contentType = ContentType.json;
          res.write(text);
        }
      case 'PUT':
        final ifMatch = r.headers.value('if-match');
        final ifNone = r.headers.value('if-none-match');
        if (!folders.contains(_parent(path))) {
          res.statusCode = HttpStatus.conflict;
        } else if (ifMatch != null && (!files.containsKey(path) || _etag(path) != ifMatch)) {
          res.statusCode = HttpStatus.preconditionFailed;
        } else if (ifNone == '*' && files.containsKey(path)) {
          res.statusCode = HttpStatus.preconditionFailed;
        } else {
          final fresh = !files.containsKey(path);
          files[path] = body;
          _versions[path] = (_versions[path] ?? 0) + 1;
          _save(path, body);
          res.statusCode = fresh ? HttpStatus.created : HttpStatus.noContent;
          res.headers.set(HttpHeaders.etagHeader, _etag(path));
        }
      case 'DELETE':
        res.statusCode = files.remove(path) == null ? HttpStatus.notFound : HttpStatus.noContent;
      default:
        res.statusCode = HttpStatus.methodNotAllowed;
    }
    await res.close();
  }

  void _propfind(HttpResponse res, String path, String depth) {
    final dir = path.endsWith('/') ? path : '$path/';
    final isFolder = folders.contains(dir);
    if (!isFolder && !files.containsKey(path)) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    String entry(String href, {String? etag, bool folder = false}) => '<d:response><d:href>${Uri.encodeFull(href)}</d:href>'
        '<d:propstat><d:prop>'
        '${folder ? '<d:resourcetype><d:collection/></d:resourcetype>' : '<d:resourcetype/>'}'
        '${etag == null ? '' : '<d:getetag>$etag</d:getetag>'}'
        '<d:getlastmodified>${HttpDate.format(DateTime.utc(2026))}</d:getlastmodified>'
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
    final out = StringBuffer('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">');
    if (!isFolder) {
      out.write(entry(path, etag: _etag(path)));
    } else {
      out.write(entry(dir, folder: true));
      if (depth != '0') {
        for (final f in folders) {
          if (f != dir && _parent(f) == dir) out.write(entry(f, folder: true));
        }
        for (final f in files.keys) {
          if (_parent(f) == dir) out.write(entry(f, etag: _etag(f)));
        }
      }
    }
    out.write('</d:multistatus>');
    res.statusCode = 207;
    res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
    res.write(out);
  }

  /// Kept on disk too, when [keepIn] is given.
  void _save(String path, String? text) {
    final dir = keepIn;
    if (dir == null) return;
    final local = '${dir.path}${path.substring('/dav'.length)}';
    if (text == null) {
      Directory(local).createSync(recursive: true);
    } else {
      File(local)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
    }
  }

  void _load() {
    final dir = keepIn;
    if (dir == null || !dir.existsSync()) return;
    for (final e in dir.listSync(recursive: true)) {
      final rel = e.path.substring(dir.path.length).replaceAll(r'\', '/');
      if (e is Directory) folders.add('/dav$rel/');
      if (e is File) {
        files['/dav$rel'] = e.readAsStringSync();
        _versions['/dav$rel'] = 1;
      }
    }
  }
}
