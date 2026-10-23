import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// [e] in words a reader understands: no "SocketException" on screen.
String friendlyError(Object e) {
  if (e is SocketException) return 'Could not reach the site. Check the internet connection.';
  if (e is HandshakeException || e is TlsException) return 'The site's secure connection failed.';
  if (e is TimeoutException) return 'The site took too long to answer.';
  if (e is HttpException) return 'The site answered with an error (${e.message}).';
  final s = '$e';
  return s.startsWith('FormatException: ') ? s.substring(17) : s;
}

/// What a source plugin gets back from a request.
class NetResponse {
  const NetResponse({
    required this.status,
    required this.url,
    required this.headers,
    required this.bytes,
  });

  final int status;

  /// The address after redirects.
  final String url;
  final Map<String, String> headers;
  final Uint8List bytes;

  bool get ok => status >= 200 && status < 300;

  /// The body as text, in the charset the server named (UTF-8 otherwise).
  String text([String? charset]) {
    final named = (charset ?? _charsetOf(headers['content-type']))?.toLowerCase();
    if (named == 'iso-8859-1' || named == 'latin1' || named == 'windows-1252') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// A Cloudflare "checking your browser" page instead of the site.
  bool get isChallenge =>
      (status == 403 || status == 503) &&
      (headers['cf-mitigated'] == 'challenge' || headers['server']?.toLowerCase() == 'cloudflare');

  static String? _charsetOf(String? contentType) {
    if (contentType == null) return null;
    final m = RegExp(r'charset=([^;\s]+)', caseSensitive: false).firstMatch(contentType);
    return m?.group(1)?.replaceAll('"', '');
  }
}

/// HTTP for sources: one client, a phone browser's User-Agent, and cookies
/// kept per site (and on disk), so a site that set a cookie once, such as
/// Cloudflare's clearance, keeps working.
class Net {
  Net._();

  static final instance = Net._();

  /// A current Chrome on Android. Many novel sites refuse unknown agents.
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/129.0.0.0 Mobile Safari/537.36';

  final _client = HttpClient()
    ..userAgent = userAgent
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = true;

  /// host -> cookie name -> value.
  final _cookies = <String, Map<String, String>>{};
  File? _cookieFile;

  /// Keep cookies in [dir] across launches.
  Future<void> attach(Directory dir) async {
    final f = File('${dir.path}/cookies.json');
    _cookieFile = f;
    try {
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString()) as Map;
        for (final e in raw.entries) {
          _cookies[e.key as String] = Map<String, String>.from(e.value as Map);
        }
      }
    } on Object {
      // A broken cookie file only costs a fresh login.
    }
  }

  /// [attach] by path, for background isolates.
  Future<void> attachPath(String dir) => attach(Directory(dir));

  Future<void> _saveCookies() async {
    final f = _cookieFile;
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode(_cookies));
    } on Object {
      // Next request saves again.
    }
  }

  /// Cookies for [host] and its parent domains, as a Cookie header.
  String? cookieHeader(String host) {
    final parts = <String>[];
    for (final e in _cookies.entries) {
      if (host == e.key || host.endsWith('.${e.key}')) {
        for (final c in e.value.entries) {
          parts.add('${c.key}=${c.value}');
        }
      }
    }
    return parts.isEmpty ? null : parts.join('; ');
  }

  /// Remember cookies a browser view collected for [host].
  Future<void> setCookies(String host, Map<String, String> cookies) async {
    (_cookies[_bareHost(host)] ??= {}).addAll(cookies);
    await _saveCookies();
  }

  /// Forget every cookie ("Clear cookies" in settings).
  Future<void> clearCookies() async {
    _cookies.clear();
    await _saveCookies();
  }

  static String _bareHost(String host) => host.startsWith('www.') ? host.substring(4) : host;

  /// Make a request. [body] is a String, bytes, or null.
  Future<NetResponse> request(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    var uri = Uri.parse(url);
    // Follow redirects ourselves so cookies set along the way are kept and
    // POSTs that redirect become GETs, the way browsers do it.
    for (var hop = 0; hop < 8; hop++) {
      final req = await _client.openUrl(method, uri).timeout(timeout);
      req.followRedirects = false;
      final cookie = cookieHeader(uri.host);
      if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
      req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
        req.headers.set(HttpHeaders.acceptHeader,
            'text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7');
      }
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'cookie' || cookie == null) {
          req.headers.set(k, v);
        } else {
          req.headers.set(HttpHeaders.cookieHeader, '$cookie; $v');
        }
      });
      if (body is String) {
        req.write(body);
      } else if (body is List<int>) {
        req.add(body);
      }
      final res = await req.close().timeout(timeout);
      final set = <String, String>{};
      for (final c in res.cookies) {
        set[c.name] = c.value;
      }
      if (set.isNotEmpty) await setCookies(uri.host, set);
      final location = res.headers.value(HttpHeaders.locationHeader);
      if (res.isRedirect && location != null) {
        await res.drain<void>();
        uri = uri.resolve(location);
        if (res.statusCode != 307 && res.statusCode != 308) {
          method = 'GET';
          body = null;
        }
        continue;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        builder.add(chunk);
      }
      final out = <String, String>{};
      res.headers.forEach((name, values) => out[name.toLowerCase()] = values.join(', '));
      return NetResponse(status: res.statusCode, url: uri.toString(), headers: out, bytes: builder.takeBytes());
    }
    throw HttpException('Too many redirects', uri: uri);
  }

  /// GET [url] as text; throws on an HTTP error.
  Future<String> text(String url) async {
    final r = await request(url);
    if (!r.ok) throw HttpException('HTTP ${r.status}', uri: Uri.parse(url));
    return r.text();
  }
}
