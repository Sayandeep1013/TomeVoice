/// What web-novel sources hand back, in the shapes LNReader plugins use
/// (lnreader-plugins `src/types/plugin.ts`), so a plugin's results map onto
/// these one to one.
library;

/// One source plugin, as listed in a repository's index.
class PluginInfo {
  const PluginInfo({
    required this.id,
    required this.name,
    required this.site,
    required this.lang,
    required this.version,
    required this.url,
    this.iconUrl,
    this.repo,
    this.sha256,
  });

  final String id;
  final String name;

  /// The site's home page, "https://www.royalroad.com".
  final String site;

  /// The language as the index names it ("English", "Русский").
  final String lang;
  final String version;

  /// Where the plugin's code is downloaded from.
  final String url;
  final String? iconUrl;

  /// The repository index it came from. An installed plugin is updated
  /// from this list only.
  final String? repo;

  /// For an installed plugin: the SHA-256 of its code as it was installed,
  /// checked each time it is loaded.
  final String? sha256;

  PluginInfo withRepo(String repo) => _copy(repo: repo);

  PluginInfo withHash(String sha256) => _copy(sha256: sha256);

  PluginInfo _copy({String? repo, String? sha256}) => PluginInfo(
        id: id,
        name: name,
        site: site,
        lang: lang,
        version: version,
        url: url,
        iconUrl: iconUrl,
        repo: repo ?? this.repo,
        sha256: sha256 ?? this.sha256,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'site': site,
        'lang': lang,
        'version': version,
        'url': url,
        if (iconUrl != null) 'iconUrl': iconUrl,
        if (repo != null) 'repo': repo,
        if (sha256 != null) 'sha256': sha256,
      };

  static PluginInfo? fromJson(Map<String, Object?> j) {
    final id = j['id'] as String?;
    final url = j['url'] as String?;
    if (id == null || url == null) return null;
    return PluginInfo(
      id: id,
      name: j['name'] as String? ?? id,
      site: j['site'] as String? ?? '',
      lang: j['lang'] as String? ?? 'Other',
      version: '${j['version'] ?? '0'}',
      url: url,
      iconUrl: j['iconUrl'] as String?,
      repo: j['repo'] as String?,
      sha256: j['sha256'] as String?,
    );
  }

  /// True when [other] is a newer release of the same plugin.
  bool olderThan(PluginInfo other) => compareVersions(version, other.version) < 0;
}

/// "1.2.10" vs "1.2.9", numerically.
int compareVersions(String a, String b) {
  final pa = a.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final pb = b.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// A novel in a list: popular, latest, or search results.
class NovelItem {
  const NovelItem({required this.name, required this.path, this.cover});

  final String name;

  /// The novel's address on its site, relative or absolute.
  final String path;
  final String? cover;

  static NovelItem? fromJs(Object? o) {
    if (o is! Map) return null;
    final name = o['name']?.toString();
    final path = o['path']?.toString();
    if (name == null || path == null) return null;
    final cover = o['cover']?.toString();
    return NovelItem(name: name.trim(), path: path, cover: cover == null || cover.isEmpty ? null : cover);
  }
}

/// One chapter of a web novel.
class ChapterItem {
  const ChapterItem({required this.name, required this.path, this.releaseTime, this.number});

  final String name;
  final String path;
  final String? releaseTime;
  final double? number;

  static ChapterItem? fromJs(Object? o) {
    if (o is! Map) return null;
    final name = o['name']?.toString();
    final path = o['path']?.toString();
    if (path == null) return null;
    return ChapterItem(
      name: (name == null || name.trim().isEmpty) ? path : name.trim(),
      path: path,
      releaseTime: o['releaseTime']?.toString(),
      number: (o['chapterNumber'] as num?)?.toDouble(),
    );
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'path': path,
        if (releaseTime != null) 'releaseTime': releaseTime,
        if (number != null) 'number': number,
      };

  static ChapterItem fromJson(Map<String, Object?> j) => ChapterItem(
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? '',
        releaseTime: j['releaseTime'] as String?,
        number: (j['number'] as num?)?.toDouble(),
      );
}

/// A novel with its details and chapters, as a source describes it.
class SourceNovel {
  const SourceNovel({
    required this.path,
    required this.name,
    this.cover,
    this.author,
    this.summary,
    this.status,
    this.genres = const [],
    this.chapters = const [],
    this.totalPages,
    this.complete = true,
  });

  final String path;
  final String name;
  final String? cover;
  final String? author;
  final String? summary;
  final String? status;
  final List<String> genres;
  final List<ChapterItem> chapters;

  /// Plugins whose chapter list is paged say how many pages there are.
  final int? totalPages;

  /// False when a page of a paged chapter list failed or came back empty:
  /// [chapters] is then only part of the list, and must never replace a
  /// stored one (its downloads would lose their places).
  final bool complete;

  /// "AdventureFantasyMystery", as some sites' tag links read when their
  /// text is joined, as the words it was. Only when every part is a word
  /// of four letters or more, so "LitRPG" and "GameLit" stay whole.
  static List<String> unglue(String genre) {
    if (genre.contains(' ')) return [genre];
    final parts = genre.split(RegExp(r'(?<=[a-z])(?=[A-Z])'));
    if (parts.length < 2 || parts.any((p) => p.length < 4)) return [genre];
    return parts;
  }

  static SourceNovel fromJs(Object? o, {required String path}) {
    final m = o is Map ? o : const {};
    final genres = m['genres'];
    return SourceNovel(
      path: m['path']?.toString() ?? path,
      name: (m['name']?.toString() ?? '').trim(),
      cover: m['cover']?.toString(),
      author: _clean(m['author']),
      summary: _clean(m['summary']),
      status: _clean(m['status']),
      genres: genres is String
          ? [
              for (final g in genres.split(RegExp(r'\s*,\s*')))
                if (g.isNotEmpty) ...unglue(g),
            ]
          : genres is List
              ? [for (final g in genres) g.toString()]
              : const [],
      chapters: [
        for (final c in (m['chapters'] as List? ?? const []))
          if (ChapterItem.fromJs(c) case final chapter?) chapter,
      ],
      totalPages: (m['totalPages'] as num?)?.toInt(),
    );
  }

  static String? _clean(Object? v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }
}
