import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart'
    show
        BlockRole,
        Book,
        BookMetadata,
        Section,
        SourceKind,
        SpeechHintKind,
        Speakable,
        TextStretch,
        makeBlock,
        speechHints;

import 'safe_file.dart';
import 'skip_presets.dart';

export 'skip_presets.dart' show SkipPreset, defaultPresets, quietStretches;

/// "Say Zorian as Zor-ee-an": what the voice is told, never what the page
/// shows. [book] limits it to one book; null is every book.
class SayRule {
  const SayRule({required this.from, required this.to, this.book});

  final String from;
  final String to;
  final String? book;

  Map<String, Object?> toJson() => {'from': from, 'to': to, if (book != null) 'book': book};

  static SayRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final from = json['from'] as String? ?? '';
    final to = json['to'] as String? ?? '';
    if (from.trim().isEmpty) return null;
    return SayRule(from: from.trim(), to: to.trim(), book: json['book'] as String?);
  }
}

/// "Don't read lines containing 'Patreon'" in web novels from [plugin] (one
/// site), or from every site when null.
class SkipRule {
  const SkipRule({required this.text, this.plugin});

  final String text;
  final String? plugin;

  Map<String, Object?> toJson() => {'text': text, if (plugin != null) 'plugin': plugin};

  static SkipRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = (json['text'] as String? ?? '').trim();
    if (text.isEmpty) return null;
    return SkipRule(text: text, plugin: json['plugin'] as String?);
  }
}

/// The presets the reader switched on or off, for every book or for one.
/// One not here is as it comes ([SkipPreset.byDefault]).
typedef PresetChoices = Map<SkipPreset, bool>;

/// What rules.json holds.
typedef _Stored = ({
  List<SayRule> say,
  List<SkipRule> skip,
  PresetChoices presets,
  Map<String, PresetChoices> bookPresets,
});

/// The reader's own rules for reading aloud, kept in `rules.json` at the
/// library root (so a backup carries them).
class ReadingRules {
  ReadingRules._();

  static final instance = ReadingRules._();

  /// Bumped on every change, so a reader can say the sentence again.
  final changes = ValueNotifier<int>(0);

  File? _file;
  List<SayRule> say = const [];
  List<SkipRule> skip = const [];

  /// What the voice passes over in every book (see [SkipPreset]).
  PresetChoices presets = const {};

  /// Books with choices of their own, in place of every book's.
  Map<String, PresetChoices> bookPresets = const {};

  static File fileIn(String root) => File('$root/rules.json');

  Future<void> attach(Directory root) async {
    _file = fileIn(root.path);
    final raw = _read(_file!);
    say = raw.say;
    skip = raw.skip;
    presets = raw.presets;
    bookPresets = raw.bookPresets;
  }

  static _Stored _read(File f) {
    try {
      if (f.existsSync()) {
        final json = jsonDecode(f.readAsStringSync()) as Map;
        final stored = json['presets'] is Map ? json['presets'] as Map : const {};
        final books = stored['books'] is Map ? stored['books'] as Map : const {};
        return (
          say: (json['say'] as List? ?? const []).map(SayRule.fromJson).whereType<SayRule>().toList(),
          skip: (json['skip'] as List? ?? const []).map(SkipRule.fromJson).whereType<SkipRule>().toList(),
          presets: _choicesFrom(stored['every']),
          bookPresets: {
            for (final e in books.entries)
              if (e.key is String && e.value is Map) e.key as String: _choicesFrom(e.value),
          },
        );
      }
    } on Object {
      // Start with none, keeping the unreadable file as rules.json.broken
      // (the next save would write over a person's pronunciations).
      try {
        if (f.existsSync()) f.renameSync('${f.path}.broken');
      } on Object {
        // Nothing to keep.
      }
    }
    return (say: const [], skip: const [], presets: const {}, bookPresets: const {});
  }

  static PresetChoices _choicesFrom(Object? json) => {
        if (json is Map)
          for (final e in json.entries)
            if (SkipPreset.byName(e.key) case final p? when e.value is bool) p: e.value as bool,
      };

  static Map<String, bool> _choicesJson(PresetChoices c) => {for (final e in c.entries) e.key.name: e.value};

  /// The skip texts for a web novel from [plugin]; synchronous, for the
  /// isolate that loads a novel.
  static List<String> skipTextsSync(String root, String? plugin) => [
        for (final r in _read(fileIn(root)).skip)
          if (r.plugin == null || r.plugin == plugin) r.text,
      ];

  /// The say rules that apply to [bookId]: its own first, then every book's.
  List<SayRule> sayFor(String bookId) => [
        for (final r in say)
          if (r.book == bookId) r,
        for (final r in say)
          if (r.book == null) r,
      ];

  Future<void> addSay(SayRule rule) async {
    say = [
      for (final r in say)
        if (!(r.from.toLowerCase() == rule.from.toLowerCase() && r.book == rule.book)) r,
      rule,
    ];
    await _save();
  }

  /// [rules] added at once (a list of pronunciations taken in), each that
  /// is not here already for its word and book; this phone's own stay.
  Future<void> addAll(List<SayRule> rules) async {
    final have = {for (final r in say) '${r.from.toLowerCase()}|${r.book ?? ''}'};
    final fresh = [
      for (final r in rules)
        if (have.add('${r.from.toLowerCase()}|${r.book ?? ''}')) r,
    ];
    if (fresh.isEmpty) return;
    say = [...say, ...fresh];
    await _save();
  }

  Future<void> removeSay(SayRule rule) async {
    say = [for (final r in say) if (!identical(r, rule)) r];
    await _save();
  }

  Future<void> addSkip(SkipRule rule) async {
    skip = [
      for (final r in skip)
        if (!(r.text.toLowerCase() == rule.text.toLowerCase() && r.plugin == rule.plugin)) r,
      rule,
    ];
    await _save();
  }

  Future<void> removeSkip(SkipRule rule) async {
    skip = [for (final r in skip) if (!identical(r, rule)) r];
    await _save();
  }

  /// Whether [p] is on in [book] (its own choice, when it has its own),
  /// or in every book when [book] is null.
  bool presetOn(SkipPreset p, {String? book}) =>
      (book == null ? null : bookPresets[book]?[p]) ?? presets[p] ?? p.byDefault;

  /// The presets on in [book]: what its voice passes over.
  Set<SkipPreset> presetsFor(String? book) => {
        for (final p in SkipPreset.values)
          if (presetOn(p, book: book)) p,
      };

  /// Whether [book] has its presets of its own, rather than every book's.
  bool hasOwnPresets(String book) => bookPresets.containsKey(book);

  /// Switch [p]: for [book] when it has its own presets, else for every
  /// book (as a book's speed is set).
  Future<void> setPreset(SkipPreset p, bool on, {String? book}) async {
    final own = book == null ? null : bookPresets[book];
    if (own != null) {
      bookPresets = {...bookPresets, book!: {...own, p: on}};
    } else {
      presets = {...presets, p: on};
    }
    await _save();
  }

  /// Give [book] presets of its own, starting from every book's; or, not
  /// [own], back to every book's.
  Future<void> setOwnPresets(String book, bool own) async {
    if (own == hasOwnPresets(book)) return;
    bookPresets = own
        ? {
            ...bookPresets,
            book: {for (final p in SkipPreset.values) p: presetOn(p)},
          }
        : {
            for (final e in bookPresets.entries)
              if (e.key != book) e.key: e.value,
          };
    await _save();
  }

  Future<void> _save() async {
    changes.value++;
    // Not over the rules a restore is adding (see RestoreGate).
    if (RestoreGate.shut) return;
    try {
      await writeSafely(_file, jsonEncode({
        'say': [for (final r in say) r.toJson()],
        'skip': [for (final r in skip) r.toJson()],
        if (presets.isNotEmpty || bookPresets.isNotEmpty)
          'presets': {
            if (presets.isNotEmpty) 'every': _choicesJson(presets),
            if (bookPresets.isNotEmpty) 'books': {for (final e in bookPresets.entries) e.key: _choicesJson(e.value)},
          },
      }));
    } on Object {
      // Kept in memory until the next change.
    }
  }

  /// Back to nothing, as a library with no rules.json starts.
  @visibleForTesting
  void reset() {
    _file = null;
    say = const [];
    skip = const [];
    presets = const {};
    bookPresets = const {};
  }
}

/// A sentence as the voice is to say it, with the way back to the page's
/// text: the voice reports word positions in what it was given, and the
/// highlight belongs on the page's words.
class Respelled {
  const Respelled(this.text, this._spans);

  /// Unchanged text.
  const Respelled.same(this.text) : _spans = const [];

  final String text;

  /// Replaced stretches, in order: (start in [text], end in [text],
  /// start in the original, end in the original).
  final List<(int, int, int, int)> _spans;

  bool get changed => _spans.isNotEmpty;

  /// What was said differently, in order: a stretch of the original and
  /// what is said in its place ('' for nothing).
  List<({int start, int end, String said})> get changes => [
        for (final (s, e, os, oe) in _spans) (start: os, end: oe, said: text.substring(s, e)),
      ];

  /// Position [o] in [text] as a position in the original. Inside a
  /// replacement it maps to the replaced word's start, or its end if [end].
  int toOriginal(int o, {bool end = false}) {
    var shift = 0;
    for (final (s, e, os, oe) in _spans) {
      if (o < s) break;
      if (o < e || (end && o == e)) return end ? oe : os;
      shift = oe - e;
    }
    return o + shift;
  }
}

/// [unit] as its voice says it: its silent stretches (a footnote's marker,
/// shown on the page but not read) left out, and what the reader's
/// [presets] pass over ([quiet]: an author's note, a row of symbols; see
/// quietStretches), a web address said as its site while [presets] say so
/// (spelled out, a link went on letter by letter), a bracketed citation
/// left out, then the reader's own [rules]. Positions map back to the page
/// as for [respell]. A sentence the presets leave with nothing to say is
/// said as nothing, and so passed over; one left so by its marks and
/// citations alone is left as it is, for the lines-with-nothing-to-say rule
/// to pass over.
Respelled respellUnit(
  Speakable unit,
  List<SayRule> rules, {
  Set<SkipPreset> presets = defaultPresets,
  List<TextStretch> quiet = const [],
}) {
  final text = unit.text;
  bool fits(TextStretch s) => s.start >= 0 && s.end <= text.length && s.start < s.end;
  final left = quiet.where(fits).toList();
  final hits = <(int, int, String)>[
    for (final s in mergeStretches([...unit.silent.where(fits), ...left])) (s.start, s.end, ''),
  ];
  for (final h in speechHints(text)) {
    // A citation left out takes the space before it ("before [12], it").
    final start = h.kind == SpeechHintKind.citation && h.start > 0 && text[h.start - 1] == ' ' ? h.start - 1 : h.start;
    if (_overlaps(hits, start, h.end)) continue;
    final say = switch (h.kind) {
      SpeechHintKind.url => presets.contains(SkipPreset.links) ? _siteOf(text.substring(h.start, h.end)) : null,
      SpeechHintKind.citation => '',
      SpeechHintKind.email || SpeechHintKind.symbols => null,
    };
    if (say != null) hits.add((start, h.end, say));
  }
  final said = _respell(text, hits, rules);
  if (said.text.contains(_sayable) || left.isNotEmpty) return said;
  return _respell(text, const [], rules);
}

/// Letters or digits in any script: something to say.
final _sayable = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _overlaps(List<(int, int, String)> hits, int s, int e) => hits.any((h) => s < h.$2 && e > h.$1);

/// How a web address is said: its site ("youtu.be" for
/// https://youtu.be/Vg_HBVOvVWk?t=44). A bare name in a sentence, such as
/// Amazon.com, is said as written (null).
String? _siteOf(String url) {
  final m = RegExp(r'^(?:[a-z][a-z0-9+.-]*://)?(www\.)?([^/?#\s]+)(.*)$', caseSensitive: false).firstMatch(url);
  if (m == null) return null;
  final bare = !url.contains('://') && m.group(1) == null && (m.group(3) ?? '').isEmpty;
  return bare ? null : m.group(2);
}

/// [text] with [rules] applied: each rule's word, whole and in any case,
/// replaced by how it should sound. The longest words are tried first, so
/// "Kael Ardent" wins over "Kael".
Respelled respell(String text, List<SayRule> rules) => _respell(text, const [], rules);

/// A rule's word as a pattern, made once (a list taken in from a file can
/// hold hundreds, tried on every sentence).
final _patterns = <String, RegExp>{};

RegExp _patternOf(String word) {
  if (_patterns.length > 20000) _patterns.clear();
  return _patterns[word] ??= RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(word)}(?![\\p{L}\\p{N}])',
      caseSensitive: false, unicode: true);
}

/// [text] with the stretches in [fixed] replaced, then [rules] where they do
/// not overlap those.
Respelled _respell(String text, List<(int, int, String)> fixed, List<SayRule> rules) {
  if (rules.isEmpty && fixed.isEmpty) return Respelled.same(text);
  // Longest first; of the same length, in the order given (a book's own
  // before every book's): a sort that moved them could let either win.
  final ordered = [for (var i = 0; i < rules.length; i++) (i, rules[i])]
    ..sort((a, b) {
      final longer = b.$2.from.length.compareTo(a.$2.from.length);
      return longer != 0 ? longer : a.$1.compareTo(b.$1);
    });
  final hits = [...fixed];
  for (final (_, r) in ordered) {
    for (final m in _patternOf(r.from).allMatches(text)) {
      if (hits.any((h) => m.start < h.$2 && m.end > h.$1)) continue;
      hits.add((m.start, m.end, r.to));
    }
  }
  if (hits.isEmpty) return Respelled.same(text);
  hits.sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  final spans = <(int, int, int, int)>[];
  var at = 0;
  for (final (s, e, to) in hits) {
    out.write(text.substring(at, s));
    final start = out.length;
    out.write(to);
    spans.add((start, out.length, s, e));
    at = e;
  }
  out.write(text.substring(at));
  return Respelled(out.toString(), spans);
}

/// A stretch of a paragraph said otherwise, and what is said there ('' for
/// nothing).
typedef SaidChange = ({int start, int end, String said});

/// What [preset] does to its own example (see [SkipPreset.example]), a
/// paragraph at a time: the paragraph as the page shows it, and what of it
/// is said otherwise. Worked out as a book is read aloud, so it shows what
/// happens.
List<({String text, List<SaidChange> changes})> presetExample(SkipPreset preset) {
  final blocks = [
    for (final p in preset.example)
      p.startsWith('# ')
          ? makeBlock(role: BlockRole.heading, text: p.substring(2))
          : makeBlock(role: BlockRole.paragraph, text: p),
  ];
  final book = Book(
    id: 'example',
    metadata: const BookMetadata(title: 'Example'),
    sections: [Section(id: 's0', index: 0, title: blocks.first.text, blocks: blocks)],
    toc: const [],
    source: SourceKind.unknown,
  );
  return [
    for (final (i, b) in blocks.indexed) (text: b.text, changes: _saidIn(book, i, {preset})),
  ];
}

/// How block [b] of [book]'s first section is said with [on]: its changes,
/// as offsets in the block's text.
List<SaidChange> _saidIn(Book book, int b, Set<SkipPreset> on) {
  final block = book.sections.first.blocks[b];
  final out = <SaidChange>[];
  for (final (i, s) in block.sentences.indexed) {
    final raw = s.of(block.text);
    final text = raw.trim();
    if (text.isEmpty) continue;
    final at = s.startOffset + raw.length - raw.trimLeft().length;
    final unit = Speakable(
      sectionIndex: 0,
      blockIndex: b,
      sentenceIndex: i,
      text: text,
      role: block.role,
      blockId: block.id,
    );
    final said = respellUnit(unit, const [], presets: on, quiet: quietStretches(book, unit, on));
    out.addAll([for (final c in said.changes) (start: c.start + at, end: c.end + at, said: c.said)]);
  }
  return out;
}
