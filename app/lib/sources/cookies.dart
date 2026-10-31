import 'dart:io' show Cookie;
import 'dart:math' as math;

/// One cookie as a site set it (RFC 6265): kept with its domain, path,
/// expiry and Secure flag, so it goes back only where the site meant it to.
class StoredCookie {
  StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.hostOnly = true,
    this.path = '/',
    this.expires,
    this.secure = false,
    int? updated,
  }) : updated = updated ?? DateTime.now().microsecondsSinceEpoch;

  final String name;
  final String value;

  /// The host it came from (host-only), or the domain it was set for.
  final String domain;

  /// Sent to [domain] alone, not to its subdomains (no Domain attribute).
  final bool hostOnly;
  final String path;

  /// Null: kept until cleared (a session cookie; the app's "session" lasts
  /// as long as the site's own does).
  final DateTime? expires;

  /// Only over https.
  final bool secure;

  /// When it was set, in microseconds: the newer of two copies wins a merge.
  final int updated;

  /// A cookie is the same cookie when these are (RFC 6265 5.3 step 11).
  String get key => '$domain|$path|$name';

  bool expiredAt(DateTime now) => expires != null && !expires!.isAfter(now);

  /// Whether it goes with a request to [uri] (RFC 6265 5.4).
  bool matches(Uri uri, DateTime now) {
    if (expiredAt(now)) return false;
    if (secure && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (hostOnly ? host != domain : !domainMatches(host, domain)) return false;
    return pathMatches(uri.path.isEmpty ? '/' : uri.path, path);
  }

  Map<String, Object?> toJson() => {
        'n': name,
        'v': value,
        'd': domain,
        if (!hostOnly) 'sub': true,
        if (path != '/') 'p': path,
        if (expires != null) 'x': expires!.millisecondsSinceEpoch,
        if (secure) 's': true,
        'u': updated,
      };

  static StoredCookie? fromJson(Object? o) {
    if (o is! Map) return null;
    final name = o['n'], value = o['v'], domain = o['d'];
    if (name is! String || value is! String || domain is! String) return null;
    final x = o['x'];
    return StoredCookie(
      name: name,
      value: value,
      domain: domain,
      hostOnly: o['sub'] != true,
      path: o['p'] as String? ?? '/',
      expires: x is int ? DateTime.fromMillisecondsSinceEpoch(x) : null,
      secure: o['s'] == true,
      updated: o['u'] as int? ?? 0,
    );
  }
}

/// Whether [host] is [domain] or one of its subdomains (RFC 6265 5.1.3).
bool domainMatches(String host, String domain) =>
    host == domain || (host.endsWith('.$domain') && InternetAddressCheck.notIp(host));

/// Whether [requestPath] is within [cookiePath] (RFC 6265 5.1.4).
bool pathMatches(String requestPath, String cookiePath) {
  if (requestPath == cookiePath) return true;
  if (!requestPath.startsWith(cookiePath)) return false;
  return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
}

/// The default path of a cookie set by a response to [uri] (RFC 6265 5.1.4).
String defaultCookiePath(Uri uri) {
  final p = uri.path;
  if (p.isEmpty || !p.startsWith('/')) return '/';
  final last = p.lastIndexOf('/');
  return last <= 0 ? '/' : p.substring(0, last);
}

/// No IP literal is a domain to share cookies under.
class InternetAddressCheck {
  static bool notIp(String host) => !RegExp(r'^[\d.]+$').hasMatch(host) && !host.contains(':');
}

/// Cookies kept apart for each source (a [partition], its plugin id; '' for
/// the app's own requests), so no plugin sends, sees or overwrites another
/// site's cookies by asking for its pages.
class CookieJar {
  final _parts = <String, Map<String, StoredCookie>>{};

  /// When everything (or one partition) was last cleared, in microseconds: a
  /// copy written elsewhere before then must not bring cookies back.
  final _cleared = <String, int>{};

  bool get isEmpty => _parts.values.every((p) => p.isEmpty);

  /// The Cookie header for a request to [uri] from [partition], or null.
  String? headerFor(Uri uri, {String partition = ''}) {
    final now = DateTime.now();
    final found = [
      for (final c in (_parts[partition] ?? const <String, StoredCookie>{}).values)
        if (c.matches(uri, now)) c,
    ]
      // Longer paths first, then older (RFC 6265 5.4 step 2).
      ..sort((a, b) {
        final byPath = b.path.length.compareTo(a.path.length);
        return byPath != 0 ? byPath : a.updated.compareTo(b.updated);
      });
    if (found.isEmpty) return null;
    return found.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Take the cookies a response to [uri] set, for [partition]. Returns the
  /// ones kept (or, expired, removed), to hand on to the jar's owner.
  List<StoredCookie> take(Uri uri, List<Cookie> cookies, {String partition = ''}) {
    final host = uri.host.toLowerCase();
    final now = DateTime.now();
    final changed = <StoredCookie>[];
    for (final c in cookies) {
      var domain = (c.domain ?? '').toLowerCase();
      if (domain.startsWith('.')) domain = domain.substring(1);
      final hostOnly = domain.isEmpty;
      if (hostOnly) {
        domain = host;
      } else if (!domainMatches(host, domain) || !domain.contains('.')) {
        // A site may not set cookies for another, nor for a whole top-level
        // domain ("com").
        continue;
      }
      if (c.secure && uri.scheme != 'https') continue;
      final path = (c.path ?? '').startsWith('/') ? c.path! : defaultCookiePath(uri);
      DateTime? expires = c.expires;
      if (c.maxAge != null) expires = now.add(Duration(seconds: c.maxAge!));
      final cookie = StoredCookie(
        name: c.name,
        value: c.value,
        domain: domain,
        hostOnly: hostOnly,
        path: path,
        expires: expires,
        secure: c.secure,
      );
      changed.add(cookie);
    }
    merge(changed, partition: partition);
    return changed;
  }

  /// Cookies a browser view collected on [host] (name to value), for
  /// [partition]: kept for the site and its subdomains, as a browser's
  /// cookie for that site would be.
  List<StoredCookie> takeFromBrowser(String host, Map<String, String> cookies, {String partition = ''}) {
    final domain = siteDomain(host);
    final changed = [
      for (final e in cookies.entries) StoredCookie(name: e.key, value: e.value, domain: domain, hostOnly: false),
    ];
    merge(changed, partition: partition);
    return changed;
  }

  /// Add [cookies] to [partition], each replacing an older copy of itself;
  /// an expired one removes it.
  void merge(Iterable<StoredCookie> cookies, {String partition = ''}) {
    final part = _parts.putIfAbsent(partition, () => {});
    final cleared = math.max(_cleared[partition] ?? 0, _cleared['*'] ?? 0);
    final now = DateTime.now();
    for (final c in cookies) {
      if (c.updated < cleared) continue;
      final have = part[c.key];
      if (have != null && have.updated > c.updated) continue;
      if (c.expiredAt(now)) {
        part.remove(c.key);
      } else {
        part[c.key] = c;
      }
    }
  }

  /// Forget the cookies of [partition], or every one.
  void clear({String? partition}) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    if (partition == null) {
      _parts.clear();
      _cleared
        ..clear()
        ..['*'] = stamp;
    } else {
      _parts.remove(partition);
      _cleared[partition] = stamp;
    }
  }

  Map<String, Object?> toJson() {
    final now = DateTime.now();
    return {
      'v': 2,
      'cleared': _cleared,
      'parts': {
        for (final e in _parts.entries)
          if (e.value.isNotEmpty)
            e.key: [
              for (final c in e.value.values)
                if (!c.expiredAt(now)) c.toJson(),
            ],
      },
    };
  }

  /// Read what [toJson] wrote into this jar, merged with what it holds (the
  /// newer copy of each cookie wins; clearing done since stays done).
  void mergeJson(Object? raw) {
    if (raw is! Map) return;
    if (raw['v'] != 2) {
      // Before 1.3: host -> name -> value, all for the app as a whole.
      for (final e in raw.entries) {
        if (e.key is String && e.value is Map) {
          final host = e.key as String;
          merge([
            for (final c in (e.value as Map).entries)
              if (c.key is String && c.value is String)
                StoredCookie(name: c.key as String, value: c.value as String, domain: host, hostOnly: false, updated: 0),
          ], partition: legacyPartition);
        }
      }
      return;
    }
    final cleared = raw['cleared'];
    if (cleared is Map) {
      for (final e in cleared.entries) {
        if (e.key is String && e.value is int && e.value as int > (_cleared[e.key] ?? 0)) {
          _cleared[e.key as String] = e.value as int;
          final stamp = e.value as int;
          if (e.key == '*') {
            for (final p in _parts.values) {
              p.removeWhere((_, c) => c.updated < stamp);
            }
          } else {
            _parts[e.key]?.removeWhere((_, c) => c.updated < stamp);
          }
        }
      }
    }
    final parts = raw['parts'];
    if (parts is! Map) return;
    for (final e in parts.entries) {
      if (e.key is! String || e.value is! List) continue;
      merge([
        for (final c in e.value as List)
          if (StoredCookie.fromJson(c) case final cookie?) cookie,
      ], partition: e.key as String);
    }
  }

  /// Where cookies kept before each source had its own go: the app's own
  /// requests (covers, lists). A source whose site wants a check again
  /// gets one; the phone's web view still holds its cookies.
  static const legacyPartition = '';
}

/// Hosts where everyone has a site of their own ("a.wordpress.com" and
/// "b.wordpress.com" are two sites, two owners): each taken as a public
/// suffix, as the public suffix list would.
const sharedHosts = {
  'wordpress.com', 'blogspot.com', 'github.io', 'gitlab.io', 'netlify.app', 'vercel.app', 'pages.dev',
  'workers.dev', 'neocities.org', 'wixsite.com', 'weebly.com', 'tumblr.com', 'substack.com', 'livejournal.com',
  'dreamwidth.org', 'herokuapp.com', 'firebaseapp.com', 'web.app', 'appspot.com', 'glitch.me', 'carrd.co',
  'notion.site', 'gitbook.io', 'readthedocs.io', 'surge.sh', '000webhostapp.com', 'webflow.io', 'squarespace.com',
};

/// The domain a site's cookies are shared under: its host without "www.",
/// and for a deeper subdomain its registrable part as far as can be told
/// without the public suffix list ("m.site.co.uk" -> "site.co.uk"). On a
/// shared host ([sharedHosts]) that is the reader's or writer's own part
/// ("x.a.wordpress.com" -> "a.wordpress.com").
String siteDomain(String host) {
  final h = host.toLowerCase();
  if (!InternetAddressCheck.notIp(h)) return h;
  for (final shared in sharedHosts) {
    if (h.endsWith('.$shared')) {
      final own = h.substring(0, h.length - shared.length - 1).split('.').last;
      return '$own.$shared';
    }
  }
  final labels = h.split('.');
  if (labels.length <= 2) return h;
  // Second-level suffixes such as co.uk, com.br, or.jp: keep three labels.
  final second = labels[labels.length - 2];
  final short = second.length <= 3 && const {'co', 'com', 'net', 'org', 'gov', 'edu', 'ac', 'or', 'ne', 'go'}.contains(second);
  return labels.sublist(labels.length - (short ? 3 : 2)).join('.');
}

/// Whether [host] belongs to the site whose home page is [site]: the same
/// registrable domain ("www.royalroad.com" and "royalroad.com"; not
/// "a.wordpress.com" and "b.wordpress.com", see [sharedHosts]).
bool sameSite(String host, String site) {
  final siteHost = Uri.tryParse(site)?.host ?? '';
  if (host.isEmpty || siteHost.isEmpty) return false;
  return siteDomain(host) == siteDomain(siteHost);
}
