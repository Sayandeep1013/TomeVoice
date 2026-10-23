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
  return Section(id: 'ch$index', index: index, title: title, blocks: blocks);
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
