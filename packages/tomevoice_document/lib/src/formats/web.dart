import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';

/// One chapter of a web novel, from the HTML its site serves, as a section
/// the reader can show and speak.
///
/// Novel sites wrap the story in things that should never be read aloud:
/// "Read the latest chapters at…" watermarks, translator and editor credits,
/// Previous/Next links, rows of dashes. Those blocks are dropped.
Section webChapterSection({
  required int index,
  required String title,
  required String html,
  String? language,
}) {
  final blocks = [
    for (final b in blocksFromHtml(html, language: language))
      if (!isWebJunk(b.text)) b,
  ];
  return cleanWebChapter(Section(id: 'ch$index', index: index, title: title, blocks: blocks));
}

/// A chapter made ready to read, when it is fetched and again whenever it is
/// opened (so chapters downloaded before a rule existed follow it too):
///
/// * a first line that only repeats the chapter's title ("Chapter 044 A Show
///   of Trust" under "44. A Show of Trust") becomes the chapter's heading:
///   heard once and shown once, not under a title row of its own;
/// * lines containing any of [skip], the reader's own "don't read lines like
///   this", are dropped (ignoring case).
Section cleanWebChapter(Section s, {Iterable<String> skip = const []}) {
  var blocks = s.blocks;
  final rules = [
    for (final k in skip)
      if (k.trim().isNotEmpty) k.trim().toLowerCase(),
  ];
  if (rules.isNotEmpty) {
    blocks = [
      for (final b in blocks)
        if (!rules.any((r) => b.text.toLowerCase().contains(r))) b,
    ];
  }
  final first = blocks.indexWhere((b) => b.speakable);
  if (first >= 0 && blocks[first].role != BlockRole.heading && sameChapterTitle(blocks[first].text, s.title)) {
    blocks = [...blocks]..[first] = blocks[first].withRole(BlockRole.heading);
  }
  if (identical(blocks, s.blocks)) return s;
  return Section(id: s.id, index: s.index, title: s.title, blocks: blocks);
}

/// Whether [line] says what [title] says: the same words once "Chapter" and
/// punctuation are set aside, and the same numbers (44 = 044).
bool sameChapterTitle(String line, String? title) {
  if (title == null || line.length > 200) return false;
  String words(String t) => t
      .toLowerCase()
      .replaceAll(RegExp(r'\b(chapter|chap|ch)\b\.?'), ' ')
      .replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
  List<int> numbers(String t) => [for (final m in RegExp(r'\d+').allMatches(t)) int.parse(m.group(0)!)];
  final a = words(line);
  if (a != words(title)) return false;
  final na = numbers(line);
  final nb = numbers(title);
  if (a.isEmpty && (na.isEmpty || nb.isEmpty)) return false;
  if (na.isEmpty || nb.isEmpty) return true;
  return na.length == nb.length && [for (var i = 0; i < na.length; i++) na[i] == nb[i]].every((x) => x);
}

/// A section for a chapter that has not been fetched yet: no text, so the
/// reader skips it, but its place (and so every saved position) is kept.
Section pendingWebChapter({required int index, required String title}) =>
    Section(id: 'ch$index', index: index, title: title, blocks: const []);

final _junk = [
  // Watermarks and calls to visit the site.
  RegExp(r'(read|find|visit|continue)\b.{0,40}\b(at|on)\b.{0,30}\.(com|net|org|me|site|co|io|xyz)\b', caseSensitive: false),
  RegExp(r'(latest|newest|faster|first)\b.{0,25}\b(chapters?|releases?|updates?)\b.{0,30}\b(at|on|visit)\b',
      caseSensitive: false),
  RegExp(r'\b(novelbin|novelfull|lightnovelworld|webnovel|wuxiaworld|royalroad|freewebnovel|novelfire)\b.{0,12}\.(com|net|me|site|co)',
      caseSensitive: false),
  RegExp(r'please (support|read).{0,40}(original|official|translator|website|site)', caseSensitive: false),
  RegExp(r'if you find any errors', caseSensitive: false),
  RegExp(r'report (this )?chapter', caseSensitive: false),
  // Credits and navigation.
  RegExp(r'^(translator|translated by|editor|edited by|proofreader|tl|tl note|t/n|ed|pr)\s*[:\-–]', caseSensitive: false),
  RegExp(r'^(previous|prev|next)( chapter)?\s*([|/·•-]\s*(index|toc|next|previous|prev)( chapter)?)*$', caseSensitive: false),
  RegExp(r'^(table of contents|index|toc)$', caseSensitive: false),
];

/// A line that is site furniture, not story. Kept deliberately narrow: a
/// sentence that merely mentions a chapter or a website stays.
bool isWebJunk(String text) {
  final t = text.trim();
  if (t.isEmpty) return true;
  // Dividers: "----", "* * *", "~~~~", "═════".
  if (t.length >= 3 && RegExp(r'^[\s\-–—_*~=•·#.═─]+$').hasMatch(t)) return true;
  if (t.length > 260) return false;
  for (final r in _junk) {
    if (r.hasMatch(t)) return true;
  }
  return false;
}

/// A whole web novel as a book: every chapter has a section in order, and
/// only the downloaded ones have text. Positions are chapter numbers, so they
/// stay valid as more chapters arrive.
Book webNovelBook({
  required String id,
  required String title,
  List<String> authors = const [],
  String? language,
  String? cover,
  String? description,
  required List<Section> sections,
}) =>
    Book(
      id: id,
      metadata: BookMetadata(
        title: title,
        authors: authors,
        language: language,
        cover: cover,
        description: description,
      ),
      sections: sections,
      toc: [
        for (final s in sections) TocEntry(title: s.title ?? 'Chapter ${s.index + 1}', sectionIndex: s.index),
      ],
      source: SourceKind.web,
      wordCount: sections.fold(0, (n, s) => n + s.blocks.fold(0, (m, b) => m + countWords(b.text))),
    );
