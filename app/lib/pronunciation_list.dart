import 'dart:convert';
import 'dart:io';

import 'reading_rules.dart';

/// A word and how it is said, as a list carries it.
typedef Pronunciation = ({String word, String say});

/// Pronunciations to pass on: one book's, several books' (a series), or
/// every book's, as a small file another phone adds to its own (see
/// [planImport]). The file is JSON; plain text, a word and how it is said
/// on each line, is read too.
class PronunciationList {
  const PronunciationList({required this.name, required this.words, this.books = const []});

  /// What it is for: a book's or a series' name.
  final String name;
  final List<Pronunciation> words;

  /// The books it was made from: their ids (the same book on another phone
  /// has the same one) and titles.
  final List<({String id, String title})> books;

  /// What the file says it is.
  static const kind = 'tomevoice-pronunciations';

  /// The most words a list is read with, and the longest word and saying.
  static const mostWords = 5000;
  static const longestWord = 80;
  static const longestSaying = 200;

  /// The longest file read as a list.
  static const largestFile = 2 * 1024 * 1024;

  /// The list as a file: JSON, two spaces in, its words in alphabetical
  /// order so it reads as a glossary.
  String encode() => const JsonEncoder.withIndent('  ').convert({
        'kind': kind,
        'version': 1,
        'name': name,
        if (books.isNotEmpty)
          'books': [
            for (final b in books) {'id': b.id, 'title': b.title},
          ],
        'words': [
          for (final w in _sorted(words)) {'word': w.word, 'say': w.say},
        ],
      });

  /// The list as plain text: "Zorian = Zor-ee-an", a word a line.
  String encodeText() => [
        '# TomeVoice pronunciations: $name',
        for (final w in _sorted(words)) '${w.word} = ${w.say}',
      ].join('\n');

  static List<Pronunciation> _sorted(List<Pronunciation> words) =>
      [...words]..sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));

  /// The list in [text]: TomeVoice's own file, a rules.json, a map of
  /// words to how they are said, or plain text with a word and its saying
  /// on each line ("Zorian = Zor-ee-an", "Zorian → Zor-ee-an", or a tab
  /// between). [fileName] names a list that does not name itself. Null
  /// when nothing in it is a pronunciation.
  static PronunciationList? decode(String text, {String? fileName}) {
    final source = text.startsWith(_bom) ? text.substring(1) : text;
    Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      json = null;
    }
    final (name, books, raw) = json == null ? _fromText(source) : _fromJson(json);
    final words = _clean(raw);
    if (words.isEmpty) return null;
    return PronunciationList(
      name: name == null || name.trim().isEmpty ? _nameFrom(fileName) : name.trim(),
      words: words,
      books: books,
    );
  }

  /// The list in [file] (see [decode]), [name] its name as it was picked;
  /// null when there is none in it, or it is too large to be one.
  static Future<PronunciationList?> read(File file, {String? name}) async {
    try {
      if (await file.length() > largestFile) return null;
      return decode(utf8.decode(await file.readAsBytes(), allowMalformed: true), fileName: name ?? file.path);
    } on FileSystemException {
      return null;
    }
  }

  /// [lists] as one: the first saying of a word kept, the books of each.
  static PronunciationList join(List<PronunciationList> lists) {
    if (lists.length == 1) return lists.single;
    final seen = <String>{};
    return PronunciationList(
      name: lists.map((l) => l.name).toSet().join(', '),
      words: [
        for (final l in lists)
          for (final w in l.words)
            if (seen.add(w.word.toLowerCase())) w,
      ],
      books: [for (final l in lists) ...l.books],
    );
  }

  static final _bom = String.fromCharCode(0xFEFF);

  static (String?, List<({String id, String title})>, List<Pronunciation>) _fromJson(Object json) {
    if (json is List) return (null, const [], _pairs(json));
    if (json is! Map) return (null, const [], const []);
    final name = json['name'] is String ? (json['name'] as String).trim() : null;
    final books = [
      if (json['books'] case final List list)
        for (final b in list)
          if (b is Map && b['id'] is String && b['title'] is String) (id: b['id'] as String, title: b['title'] as String),
    ];
    if (json['words'] is List) return (name, books, _pairs(json['words'] as List));
    // A rules.json, from this app's library folder.
    if (json['say'] is List) return (name, books, _pairs(json['say'] as List));
    // {"Zorian": "Zor-ee-an", ...}
    return (
      name,
      books,
      [
        for (final e in json.entries)
          if (e.key is String && e.value is String) (word: e.key as String, say: e.value as String),
      ],
    );
  }

  /// [{"word": …, "say": …}] (or "from" and "to", as rules.json has them),
  /// or [[word, say]].
  static List<Pronunciation> _pairs(List list) {
    final out = <Pronunciation>[];
    for (final item in list) {
      if (item is Map) {
        final word = item['word'] ?? item['from'];
        final say = item['say'] ?? item['to'];
        if (word is String && say is String) out.add((word: word, say: say));
      } else if (item is List && item.length >= 2 && item[0] is String && item[1] is String) {
        out.add((word: item[0] as String, say: item[1] as String));
      }
      if (out.length > mostWords) break;
    }
    return out;
  }

  /// "# TomeVoice pronunciations: Mother of Learning" names a text list.
  static final _textName = RegExp(r'^#\s*tomevoice pronunciations?\s*[:–—-]\s*(.+)$', caseSensitive: false);

  /// A word, then = or → or -> or => or a tab, then how it is said.
  static final _line = RegExp(r'^(.+?)\s*(?:=>|->|→|=|\t)\s*(.+)$');

  static (String?, List<({String id, String title})>, List<Pronunciation>) _fromText(String text) {
    String? name;
    final words = <Pronunciation>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#') || line.startsWith('//')) {
        name ??= _textName.firstMatch(line)?.group(1)?.trim();
        continue;
      }
      final m = _line.firstMatch(line);
      if (m != null) words.add((word: m.group(1)!, say: m.group(2)!));
      if (words.length > mostWords) break;
    }
    return (name, const [], words);
  }

  static final _space = RegExp(r'\s+');
  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// [words] as rules can hold them: spaces made one, quotes around taken
  /// off, the first of a word kept (in any case), and nothing kept that has
  /// no letter in it, says nothing, says the word as it is, or is too long
  /// to be a word.
  static List<Pronunciation> _clean(List<Pronunciation> words) {
    final seen = <String>{};
    final out = <Pronunciation>[];
    for (final w in words) {
      final word = _unquoted(w.word.replaceAll(_space, ' ').trim());
      final say = _unquoted(w.say.replaceAll(_space, ' ').trim());
      if (word.isEmpty || say.isEmpty || word == say) continue;
      if (word.length > longestWord || say.length > longestSaying || !_letterOrDigit.hasMatch(word)) continue;
      if (!seen.add(word.toLowerCase())) continue;
      out.add((word: word, say: say));
      if (out.length == mostWords) break;
    }
    return out;
  }

  static String _unquoted(String s) {
    if (s.length >= 2) {
      final first = s[0], last = s[s.length - 1];
      if ((first == '"' && last == '"') || (first == '“' && last == '”') || (first == "'" && last == "'")) {
        return s.substring(1, s.length - 1).trim();
      }
    }
    return s;
  }

  /// "Mother of Learning pronunciations.json" names Mother of Learning.
  static String _nameFrom(String? fileName) {
    var n = (fileName ?? '').replaceAll('\\', '/').split('/').last;
    final dot = n.lastIndexOf('.');
    if (dot > 0) n = n.substring(0, dot);
    n = n.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'\s*pronunciations?\s*$', caseSensitive: false), '').trim();
    return n.isEmpty ? 'Pronunciations' : n;
  }

  /// The list for [books] (ids; null for every book) out of [rules]: the
  /// first saying of a word kept, in the order [books] are given, when two
  /// of them say it differently. [titles] names the books.
  static PronunciationList of(
    List<SayRule> rules, {
    required String name,
    required List<String?> books,
    Map<String, String> titles = const {},
  }) {
    final seen = <String>{};
    return PronunciationList(
      name: name,
      words: [
        for (final b in books)
          for (final r in rules)
            if (r.book == b && seen.add(r.from.toLowerCase())) (word: r.from, say: r.to),
      ],
      books: [
        for (final b in books)
          if (b != null) (id: b, title: titles[b] ?? ''),
      ],
    );
  }

  /// A name for the file: [name] with what a file's name cannot hold taken
  /// out, then "pronunciations.json".
  static String fileNameFor(String name) {
    final printable = String.fromCharCodes(name.codeUnits.where((c) => c >= 0x20));
    var n = printable.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').replaceAll(_space, ' ').trim();
    if (n.length > 60) n = n.substring(0, 60).trim();
    return n.isEmpty ? 'pronunciations.json' : '$n pronunciations.json';
  }
}

/// What taking a list in for some books would do: the rules it adds, the
/// words this phone already says that way, and those it says its own way
/// there, which stay as they are (this phone wins).
class ImportPlan {
  const ImportPlan({required this.add, required this.same, required this.kept});

  final List<SayRule> add;
  final List<Pronunciation> same;
  final List<({Pronunciation theirs, String mine})> kept;

  /// The words added, each once (to every book it went to).
  List<Pronunciation> get added {
    final seen = <String>{};
    return [
      for (final r in add)
        if (seen.add(r.from.toLowerCase())) (word: r.from, say: r.to),
    ];
  }

  bool get changesNothing => add.isEmpty;
}

/// What adding [words] for [books] (ids; null for every book) does to
/// [have], this phone's rules. A word this phone says some way where it
/// would go (that book's own rule, or every book's) is not changed: this
/// phone wins, and the word is [ImportPlan.kept] unless it is said the same
/// way ([ImportPlan.same]).
ImportPlan planImport(List<SayRule> have, List<Pronunciation> words, Iterable<String?> books) {
  final targets = books.toSet();
  final add = <SayRule>[];
  final same = <Pronunciation>[];
  final kept = <({Pronunciation theirs, String mine})>[];
  for (final w in words) {
    var added = false;
    var already = false;
    String? mine;
    for (final book in targets) {
      final here = _sayingIn(have, w.word, book);
      if (here == null) {
        add.add(SayRule(from: w.word, to: w.say, book: book));
        added = true;
      } else if (here.toLowerCase() == w.say.toLowerCase()) {
        already = true;
      } else {
        mine ??= here;
      }
    }
    if (mine != null) {
      kept.add((theirs: w, mine: mine));
    } else if (already && !added) {
      same.add(w);
    }
  }
  return ImportPlan(add: add, same: same, kept: kept);
}

/// How [have] says [word] in [book]: its own rule, else every book's; in
/// every book (null), every book's rule alone.
String? _sayingIn(List<SayRule> have, String word, String? book) {
  final w = word.toLowerCase();
  String? find(String? b) => have.where((r) => r.book == b && r.from.toLowerCase() == w).firstOrNull?.to;
  return find(book) ?? (book == null ? null : find(null));
}
