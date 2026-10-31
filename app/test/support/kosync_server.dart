// A KOReader sync server for the tests, and for trying sync on a phone (see
// sync_servers.dart), answering as koreader-sync-server does: users made
// with POST /users/create, checked with GET /users/auth (x-auth-user and
// x-auth-key, the MD5 of the password), places kept with PUT
// /syncs/progress and read with GET /syncs/progress/:document. Error codes
// and statuses as its own (2001 unauthorized: 401; 2002 user exists: 402;
// 2003 bad request: 403). Plain dart:io and dart:convert.

import 'dart:convert';
import 'dart:io';

class KosyncTestServer {
  KosyncTestServer._(this._server, this.keepIn);

  final HttpServer _server;
  final File? keepIn;

  /// User -> key (the MD5 of the password, as the client sends it).
  final users = <String, String>{};

  /// User -> document -> what was last sent for it.
  final progress = <String, Map<String, Map<String, Object?>>>{};

  /// Every request, as method and path.
  final requests = <String>[];

  /// The server's clock, in seconds (the tests set it).
  int Function() clock = () => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Future<KosyncTestServer> start({int port = 0, File? keepIn, InternetAddress? address}) async {
    final server = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    final s = KosyncTestServer._(server, keepIn);
    s._load();
    server.listen(s._handle);
    return s;
  }

  Uri get root => Uri.parse('http://127.0.0.1:${_server.port}');
  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  void _json(HttpResponse res, int status, Object body) {
    res.statusCode = status;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.write(jsonEncode(body));
  }

  Future<void> _handle(HttpRequest r) async {
    final path = r.uri.path;
    requests.add('${r.method} $path');
    final res = r.response;
    final text = await utf8.decoder.bind(r).join();
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = null;
    }
    final u = r.headers.value('x-auth-user');
    final k = r.headers.value('x-auth-key');
    final signedIn = u != null && k != null && users[u] == k;
    if (r.method == 'GET' && path == '/healthcheck') {
      _json(res, 200, {'state': 'OK'});
    } else if (!(r.headers.value(HttpHeaders.acceptHeader) ?? '').contains('application/vnd.koreader.v1+json')) {
      // The server routes by this version header.
      _json(res, 406, {'message': 'Not Acceptable'});
    } else if (r.method == 'POST' && path == '/users/create') {
      final name = body is Map ? body['username'] : null;
      final key = body is Map ? body['password'] : null;
      if (name is! String || key is! String || name.isEmpty || key.isEmpty) {
        _json(res, 403, {'code': 2003, 'message': 'Invalid request'});
      } else if (users.containsKey(name)) {
        _json(res, 402, {'code': 2002, 'message': 'Username is already registered.'});
      } else {
        users[name] = key;
        _save();
        _json(res, 201, {'username': name});
      }
    } else if (!signedIn) {
      _json(res, 401, {'code': 2001, 'message': 'Unauthorized'});
    } else if (r.method == 'GET' && path == '/users/auth') {
      _json(res, 200, {'authorized': 'OK'});
    } else if (r.method == 'PUT' && path == '/syncs/progress') {
      final doc = body is Map ? body['document'] : null;
      if (doc is! String || doc.isEmpty) {
        _json(res, 403, {'code': 2004, 'message': "Field 'document' not provided."});
      } else {
        final at = clock();
        // Said in the log, for whoever plays the other device by hand.
        requests.add('  document $doc at ${(body as Map)['percentage']} (${body['progress']}) from ${body['device']}');
        (progress[u] ??= {})[doc] = {
          'percentage': body['percentage'],
          'progress': body['progress'],
          'device': body['device'],
          'device_id': body['device_id'],
          'timestamp': at,
        };
        _save();
        _json(res, 200, {'document': doc, 'timestamp': at});
      }
    } else if (r.method == 'GET' && path.startsWith('/syncs/progress/')) {
      final doc = Uri.decodeComponent(path.substring('/syncs/progress/'.length));
      final p = progress[u]?[doc];
      _json(res, 200, p == null ? <String, Object?>{} : {'document': doc, ...p});
    } else {
      _json(res, 404, {'message': 'Not found'});
    }
    await res.close();
  }

  void _save() {
    final f = keepIn;
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({'users': users, 'progress': progress}));
  }

  void _load() {
    final f = keepIn;
    if (f == null || !f.existsSync()) return;
    final j = jsonDecode(f.readAsStringSync()) as Map;
    users.addAll(Map<String, String>.from(j['users'] as Map));
    for (final e in (j['progress'] as Map).entries) {
      progress['${e.key}'] = {
        for (final d in (e.value as Map).entries) '${d.key}': Map<String, Object?>.from(d.value as Map),
      };
    }
  }
}
