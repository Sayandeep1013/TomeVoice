import 'dart:async';

import 'sources/models.dart';
import 'sources/source_engine.dart';

/// A link to a web novel on the site of a source the reader has installed:
/// that source, and the novel's path on it, so a shared or pasted link
/// opens the novel's page there (to add it, download it, read it) rather
/// than one web page read as an article.
typedef NovelLink = ({PluginInfo plugin, String path, String name});

String _host(String h) => h.toLowerCase().startsWith('www.') ? h.toLowerCase().substring(4) : h.toLowerCase();

/// The sources of [installed] whose site [link] is on.
List<PluginInfo> sourcesFor(Uri link, List<PluginInfo> installed) {
  final host = _host(link.host);
  if (host.isEmpty) return const [];
  return [
    for (final p in installed)
      if (Uri.tryParse(p.site) case final s? when _host(s.host) == host) p,
  ];
}

/// The paths on [site] that [link] could be a novel's, most likely first:
/// the link itself; for a chapter's link, the novel's above it
/// (".../fiction/21220/mother-of-learning/chapter/301778/..." →
/// "fiction/21220/mother-of-learning"; "shadow-slave/chapter-1.html" →
/// "shadow-slave", "shadow-slave.html").
List<String> novelPathsOf(Uri link, String site) {
  final base = Uri.tryParse(site)?.path ?? '/';
  var path = link.path;
  final prefix = base.endsWith('/') ? base : '$base/';
  if (path.startsWith(prefix)) path = path.substring(prefix.length - 1);
  final rel = (path.startsWith('/') ? path.substring(1) : path) + (link.hasQuery ? '?${link.query}' : '');
  final out = <String>[];
  void add(String p) {
    final t = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  final segments = rel.split('?').first.split('/');
  final at = segments.indexWhere((s) => _chapterSegment.hasMatch(s));
  if (at > 0) {
    final above = segments.take(at).join('/');
    add(above);
    if (rel.split('?').first.endsWith('.html')) add('$above.html');
  }
  add(rel);
  return out;
}

final _chapterSegment = RegExp(r'^(chapters?|ch|c)$|^(chapter|ch|c)[-_]?\d', caseSensitive: false);

/// The novel [link] is on an installed source, found by asking that source
/// for each likely path in turn; null when no source's site is the link's,
/// or none of its paths is a novel there.
Future<NovelLink?> novelOfLink(
  Uri link, {
  Future<List<PluginInfo>> Function()? installed,
  Future<String?> Function(PluginInfo plugin, String path)? nameOf,
}) async {
  final sources = sourcesFor(link, await (installed ?? SourceEngine.instance.store.installed)());
  final name = nameOf ?? _nameOf;
  for (final p in sources) {
    for (final path in novelPathsOf(link, p.site)) {
      final n = await name(p, path);
      if (n != null) return (plugin: p, path: path, name: n);
    }
  }
  return null;
}

/// The novel's name at [path] on [p], when it is one with chapters.
Future<String?> _nameOf(PluginInfo p, String path) async {
  try {
    final n = await SourceEngine.instance.novel(p, path).timeout(const Duration(seconds: 25));
    return n.name.trim().isNotEmpty && n.chapters.isNotEmpty ? n.name.trim() : null;
  } on Object {
    return null;
  }
}
