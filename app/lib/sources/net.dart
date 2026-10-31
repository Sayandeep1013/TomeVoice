import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'bridge.dart';
import 'cookies.dart';

/// [e] in words a reader understands: no "SocketException" on screen.
String friendlyError(Object e) {
  if (e is BlockedAddressException) return e.message;
  if (e is SocketException) return 'Could not reach the site. Check the internet connection.';
  if (e is HandshakeException || e is TlsException) return "The site's secure connection failed.";
  if (e is TimeoutException) return 'The site took too long to answer.';
  if (e is HttpException) return 'The site answered with an error (${e.message}).';
  final s = '$e';
  return s.startsWith('FormatException: ') ? s.substring(17) : s;
}

/// An address the app will not ask: not a web page (http or https), or one
/// on the phone itself or the network it is on (a source plugin reaching
/// for the router, or another app's local server).
class BlockedAddressException implements Exception {
  BlockedAddressException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A page as the phone's web view got it: its HTML, and the address it
/// ended at (the web view follows redirects and scripts).
typedef BrowserPage = ({String html, String url});

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

  /// The body as text, in the charset the server named (UTF-8 otherwise),
  /// read here: UTF-8 and Latin-1 only (see [decode] for the rest).
  String text([String? charset]) {
    final named = (charset ?? _charsetOf(headers['content-type']))?.toLowerCase();
    if (named == 'iso-8859-1' || named == 'latin1' || named == 'windows-1252') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// The body as text, in its charset: as [charset] says (a plugin's
  /// fetchText), else the server, else the page itself (a byte order mark,
  /// `<meta charset>`, an XML declaration), else UTF-8. UTF-8 and Latin-1
  /// are read here; every other (GBK, Big5, Shift_JIS, windows-1251, EUC-KR
  /// and the rest) by the phone, which knows them all (SourcesBridge.decode).
  /// Without it (tests), UTF-8.
  Future<String> decode([String? charset]) async {
    final name = (charset ?? _charsetOf(headers['content-type']) ?? _sniffed())?.toLowerCase().trim();
    if (name == null || name == 'utf-8' || name == 'utf8') {
      final skip = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
      return utf8.decode(skip == 0 ? bytes : bytes.sublist(skip), allowMalformed: true);
    }
    if (name == 'iso-8859-1' || name == 'latin1' || name == 'us-ascii' || name == 'ascii') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return await SourcesBridge.decode(bytes, name) ??
        (name == 'windows-1252' ? latin1.decode(bytes, allowInvalid: true) : utf8.decode(bytes, allowMalformed: true));
  }

  /// The charset a page names for itself near its start.
  String? _sniffed() {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) return 'utf-16le';
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) return 'utf-16be';
    final head = latin1.decode(bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes, allowInvalid: true);
    final m = RegExp(r'''<meta[^>]+charset\s*=\s*["']?\s*([\w.:-]+)''', caseSensitive: false).firstMatch(head) ??
        RegExp(r'''<\?xml[^>]+encoding\s*=\s*["']([\w.:-]+)''', caseSensitive: false).firstMatch(head);
    return m?.group(1);
  }

  /// A Cloudflare "checking your browser" page instead of the site: said by
  /// its cf-mitigated header, or a 403 or 503 from Cloudflare carrying a
  /// challenge's own markup (its title is in the reader's language, so it
  /// is not looked at). A plain 403 from Cloudflare (a page that is gone,
  /// a blocked country) is the site's answer, not a check.
  bool get isChallenge {
    if (headers['cf-mitigated']?.toLowerCase() == 'challenge') return true;
    if (status != 403 && status != 503) return false;
    final server = headers['server']?.toLowerCase() ?? '';
    if (!server.contains('cloudflare') && !headers.containsKey('cf-ray')) return false;
    final head = latin1.decode(bytes.length > 65536 ? bytes.sublist(0, 65536) : bytes, allowInvalid: true);
    return challengeMarkup.hasMatch(head);
  }

  /// What every Cloudflare challenge page carries, whatever its language:
  /// the challenge platform's script and options, or the old check's form.
  static final challengeMarkup = RegExp(
    r'/cdn-cgi/challenge-platform/|_cf_chl_opt|id="challenge-(form|running|stage|error-text)"|'
    r'cf-browser-verification|id="cf-please-wait"|challenges\.cloudflare\.com',
    caseSensitive: false,
  );

  static String? _charsetOf(String? contentType) {
    if (contentType == null) return null;
    final m = RegExp(r'charset=([^;\s]+)', caseSensitive: false).firstMatch(contentType);
    return m?.group(1)?.replaceAll('"', '');
  }
}

/// Whether [a] is an address on the open internet: not this phone
/// (loopback), not its own network (private, link-local, carrier-grade
/// NAT), not multicast, broadcast, reserved or documentation ranges, in
/// IPv4 or IPv6 (and IPv4 inside IPv6, mapped, translated or 6to4).
bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length == 4) return _publicV4(b);
  if (b.length != 16) return false;
  bool zeros(int from, int to) {
    for (var i = from; i < to; i++) {
      if (b[i] != 0) return false;
    }
    return true;
  }

  // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible), the latter also
  // covering :: and ::1.
  if (zeros(0, 10) && b[10] == 0xff && b[11] == 0xff) return _publicV4(b.sublist(12));
  if (zeros(0, 12)) return false;
  // 64:ff9b::/96, NAT64: the IPv4 address it translates to.
  if (b[0] == 0 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && zeros(4, 12)) return _publicV4(b.sublist(12));
  // 2002::/16, 6to4: the IPv4 address it tunnels to.
  if (b[0] == 0x20 && b[1] == 0x02) return _publicV4(b.sublist(2, 6));
  if (b[0] == 0xff) return false; // multicast
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // link-local fe80::/10
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0xc0) return false; // site-local fec0::/10
  if ((b[0] & 0xfe) == 0xfc) return false; // unique local fc00::/7
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return false; // documentation
  if (b[0] == 0x01 && b[1] == 0x00 && zeros(2, 8)) return false; // discard 100::/64
  return true;
}

bool _publicV4(List<int> b) {
  final x = b[0], y = b[1];
  if (x == 0 || x == 10 || x == 127) return false;
  if (x == 100 && (y & 0xc0) == 64) return false; // 100.64/10, carrier-grade NAT
  if (x == 169 && y == 254) return false; // link-local
  if (x == 172 && (y & 0xf0) == 16) return false; // 172.16/12
  if (x == 192 && y == 168) return false;
  if (x == 192 && y == 0 && (b[2] == 0 || b[2] == 2)) return false; // 192.0.0/24, 192.0.2/24
  if (x == 198 && (y == 18 || y == 19)) return false; // benchmarking
  if (x == 198 && y == 51 && b[2] == 100) return false; // documentation
  if (x == 203 && y == 0 && b[2] == 113) return false; // documentation
  if (x >= 224) return false; // multicast, reserved, broadcast
  return true;
}

/// HTTP for sources: one client, a phone browser's User-Agent, and cookies
/// kept per source (and on disk), so a site that set a cookie once, such as
/// Cloudflare's clearance, keeps working.
///
/// Only web pages are asked for: http and https, on the open internet. The
/// address a name resolves to is checked when the connection is made, on
/// every redirect, and connected to as checked (a name that answers with a
/// public address and then a private one gets nowhere).
///
/// Limits: a response is at most [maxBody] unpacked, a request (redirects
/// and all) at most [maxTime], and at most [perHost] requests go to one
/// site at a time (more wait their turn).
class Net {
  Net._() {
    _client
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = true
      ..maxConnectionsPerHost = perHost
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = _connect;
  }

  /// Requests to one site at a time, from one isolate (each source's
  /// requests all come from the one isolate it runs in).
  static const perHost = 2;

  /// The longest a request may take, from asking to the last byte.
  static const maxTime = Duration(seconds: 60);

  static final instance = Net._();

  /// A current Chrome on Android. Many novel sites refuse unknown agents.
  static const fallbackUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/129.0.0.0 Mobile Safari/537.36';

  /// The agent every request sends. Set at launch to the phone's own web
  /// view's, so a browser check passed there holds here too.
  static String userAgent = fallbackUserAgent;

  /// Tests run their sites on this machine; the app never sets this (the
  /// source workers are handed it, so tests reach them too).
  static bool allowPrivateAddresses = false;

  final _client = HttpClient();

  /// Cookies by source (see [CookieJar]).
  final jar = CookieJar();
  File? _cookieFile;
  DateTime? _cookieStamp;

  /// Whether [url] is one the app will ask for: http or https.
  static bool isWebAddress(String url) {
    final u = Uri.tryParse(url);
    return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
  }

  /// The addresses [host] stands for, if every one is on the open internet.
  static Future<List<InternetAddress>> vet(String host) async {
    final literal = InternetAddress.tryParse(host);
    final addresses = literal != null
        ? [literal]
        : await InternetAddress.lookup(host).timeout(const Duration(seconds: 20));
    if (addresses.isEmpty) throw SocketException('No address for $host');
    if (!allowPrivateAddresses && !addresses.every(isPublicAddress)) {
      throw BlockedAddressException('$host is not on the open internet, so it is not asked.');
    }
    return addresses;
  }

  /// Every connection the client makes: to the addresses [vet] passed, in
  /// turn, with TLS for https (the host named for its certificate).
  static Future<ConnectionTask<Socket>> _connect(Uri uri, String? proxyHost, int? proxyPort) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw BlockedAddressException('Only web pages can be asked for.');
    }
    final addresses = await vet(uri.host);
    var cancelled = false;
    Future<Socket> open() async {
      Object? last;
      for (final a in addresses) {
        if (cancelled) break;
        try {
          final socket = await Socket.connect(a, uri.port, timeout: const Duration(seconds: 20));
          if (uri.scheme != 'https') return socket;
          return await SecureSocket.secure(socket, host: uri.host);
        } on Object catch (e) {
          last = e;
        }
      }
      throw last ?? SocketException('Could not reach ${uri.host}');
    }

    return ConnectionTask.fromSocket(open(), () => cancelled = true);
  }

  /// Keep cookies in [dir] across launches.
  Future<void> attach(Directory dir) async {
    _cookieFile = File('${dir.path}/cookies.json');
    await _loadCookies();
  }

  Future<void> _loadCookies() async {
    final f = _cookieFile;
    if (f == null) return;
    try {
      if (await f.exists()) {
        _cookieStamp = await f.lastModified();
        jar.mergeJson(jsonDecode(await f.readAsString()));
      }
    } on Object {
      // A broken cookie file only costs a fresh login.
    }
  }

  /// Pick up cookies another isolate saved since (a browser check passed on
  /// the main one, while sources run in workers).
  Future<void> refreshCookies() async {
    final f = _cookieFile;
    if (f == null) return;
    try {
      final stamp = await f.lastModified();
      if (_cookieStamp == null || stamp.isAfter(_cookieStamp!)) await _loadCookies();
    } on FileSystemException {
      // Not written yet.
    }
  }

  /// [attach] by path, for background isolates.
  Future<void> attachPath(String dir) => attach(Directory(dir));

  /// Where a source worker sends the cookies sites set, instead of writing
  /// the file itself: the main isolate is its one writer (four isolates
  /// each rewriting it lost cookies, a fresh clearance among them).
  SendPort? _owner;

  /// Hand cookies to [owner] rather than keep the file (worker isolates).
  void forwardCookiesTo(SendPort owner) => _owner = owner;

  /// Cookies a worker sent ([forwardCookiesTo]): kept, and saved soon.
  void takeForwarded(Object? message) {
    if (message is! Map) return;
    final part = message['part'];
    final list = message['cookies'];
    if (part is! String || list is! List) return;
    jar.merge([
      for (final o in list)
        if (StoredCookie.fromJson(o) case final c?) c,
    ], partition: part);
    _saveSoon();
  }

  Timer? _saveTimer;

  /// Save in a moment: a page that sets ten cookies is one write.
  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () => unawaited(_saveCookies()));
  }

  /// Write the jar, merged with what the file holds now (the background
  /// check's engine may have written since), beside it and renamed over it.
  Future<void> _saveCookies() async {
    _saveTimer?.cancel();
    final f = _cookieFile;
    if (f == null || _owner != null) return;
    try {
      if (await f.exists()) jar.mergeJson(jsonDecode(await f.readAsString()));
    } on Object {
      // Unreadable: ours replaces it.
    }
    try {
      final tmp = File('${f.path}.${identityHashCode(this)}.tmp');
      await tmp.writeAsString(jsonEncode(jar.toJson()), flush: true);
      await tmp.rename(f.path);
      _cookieStamp = await f.lastModified();
    } on Object {
      // Next change saves again.
    }
  }

  /// Cookies a response to [uri] set, for [partition]: to the owner, or
  /// saved soon.
  void _took(Uri uri, List<Cookie> cookies, String partition) {
    final changed = jar.take(uri, cookies, partition: partition);
    if (changed.isEmpty) return;
    final owner = _owner;
    if (owner != null) {
      owner.send({
        'part': partition,
        'cookies': [for (final c in changed) c.toJson()],
      });
    } else {
      _saveSoon();
    }
  }

  /// The Cookie header for a request to [url] from [partition] (a source's
  /// plugin id; '' for the app's own requests).
  String? cookieHeader(String url, {String partition = ''}) {
    final u = Uri.tryParse(url);
    return u == null ? null : jar.headerFor(u, partition: partition);
  }

  /// What the phone's web view is to hold for a visit to [page] made for
  /// source [partition]: that source's own cookies for the site, none of
  /// another's (the web view keeps one store for the whole app; it is
  /// cleared before and after each visit), and the site's domain, under
  /// which it tells a cookie set for the whole site (see [keepFromBrowser]).
  Map<String, Object?> browserSeed(Uri page, {String partition = ''}) {
    final host = page.host.toLowerCase();
    return {
      'cookies': jar.forBrowser(host, partition: partition),
      'domain': InternetAddressCheck.notIp(host) ? siteDomain(host) : null,
    };
  }

  /// Keep, for source [partition] alone, what the phone's web view had for
  /// [page] at the end of a visit made for it ([got]: "cookies", those it
  /// sends [page], "a=1; b=2"; "wide", those it sends anywhere on the site).
  /// Saved, or handed to the isolate that saves them. How many it had.
  Future<int> keepFromBrowser(Uri page, Map<Object?, Object?> got, {String partition = ''}) async {
    final cookies = cookiesOf('${got['cookies'] ?? ''}');
    final wide = cookiesOf('${got['wide'] ?? ''}').keys.toSet();
    final changed = jar.takeFromBrowser(page, cookies, wide: wide, partition: partition);
    if (changed.isNotEmpty) {
      final owner = _owner;
      if (owner != null) {
        owner.send({
          'part': partition,
          'cookies': [for (final c in changed) c.toJson()],
        });
      } else {
        await _saveCookies();
      }
    }
    return cookies.length;
  }

  /// [url] as the phone's web view gets it (see BrowserFetch), for source
  /// [partition], whose own cookies for the site are the only ones it holds
  /// meanwhile; what the site sets there is kept for that source alone.
  /// Null when the web view could not get it (none here: tests, or the
  /// check made with the app closed).
  Future<BrowserPage?> viaWebView(String url, {String method = 'GET', String? body, String partition = ''}) async {
    final page = Uri.tryParse(url);
    if (page == null || !isWebAddress(url)) return null;
    final got = await SourcesBridge.browserFetch(url, userAgent,
        method: method, body: body, seed: browserSeed(page, partition: partition));
    if (got == null) return null;
    await keepFromBrowser(page, got, partition: partition);
    final html = got['html'], at = got['url'];
    if (html is! String) return null;
    return (html: html, url: at is String && at.isNotEmpty ? at : url);
  }

  /// Forget the cookies of [partition], or every one.
  Future<void> clearCookies({String? partition}) async {
    jar.clear(partition: partition);
    await _saveCookies();
  }

  /// The most a response may hold, unpacked: a page that is more is not a
  /// page (and must not fill the phone's memory).
  static const maxBody = 16 << 20;

  /// Make a request. [body] is a String, bytes, or null. [partition]: whose
  /// cookies go with it and keep what it sets (a source's plugin id).
  /// [maxBytes]: a longer response is given up on. [timeout]: the longest
  /// wait for any one step (a connection, the headers, the next piece of
  /// the body); [total]: the longest for the whole, after which the
  /// request is cut off rather than left running.
  Future<NetResponse> request(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    Duration timeout = const Duration(seconds: 30),
    Duration total = maxTime,
    String partition = '',
    int maxBytes = maxBody,
  }) async {
    final deadline = DateTime.now().add(total);
    Duration step() {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('The site took too long to answer.', total);
      return left < timeout ? left : timeout;
    }

    HttpClientRequest? open;
    try {
      return await _request(url, method, headers, body, partition, maxBytes, step, (r) => open = r);
    } on TimeoutException {
      // Cut off, not left to finish in the background.
      open?.abort();
      rethrow;
    }
  }

  Future<NetResponse> _request(
    String url,
    String method,
    Map<String, String> headers,
    Object? body,
    String partition,
    int maxBytes,
    Duration Function() step,
    void Function(HttpClientRequest r) opened,
  ) async {
    var uri = Uri.parse(url);
    // Follow redirects ourselves so cookies set along the way are kept and
    // POSTs that redirect become GETs, the way browsers do it.
    for (var hop = 0; hop < 8; hop++) {
      if (!isWebAddress(uri.toString())) throw BlockedAddressException('Only web pages can be asked for.');
      final req = await _client.openUrl(method, uri).timeout(step());
      opened(req);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      final cookie = jar.headerFor(uri, partition: partition);
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
      final res = await req.close().timeout(step());
      if (res.cookies.isNotEmpty) _took(uri, res.cookies, partition);
      final location = res.headers.value(HttpHeaders.locationHeader);
      if (res.isRedirect && location != null) {
        await res.drain<void>().timeout(step());
        uri = uri.resolve(location);
        if (res.statusCode != 307 && res.statusCode != 308) {
          method = 'GET';
          body = null;
        }
        continue;
      }
      final builder = BytesBuilder(copy: false);
      // Each piece within the step's time, and all of them by the deadline.
      await for (final chunk in res.timeout(step())) {
        builder.add(chunk);
        // Counted as it is unpacked, so a small compressed page that would
        // inflate to gigabytes stops here.
        if (builder.length > maxBytes) throw HttpException('The page is too large', uri: uri);
        step();
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
