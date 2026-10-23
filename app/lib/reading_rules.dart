import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'safe_file.dart';

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

  static File fileIn(String root) => File('$root/rules.json');

  Future<void> attach(Directory root) async {
    _file = fileIn(root.path);
    final raw = _read(_file!);
    say = raw.$1;
    skip = raw.$2;
  }

  static (List<SayRule>, List<SkipRule>) _read(File f) {
    try {
      if (f.existsSync()) {
        final json = jsonDecode(f.readAsStringSync()) as Map;
        return (
          (json['say'] as List? ?? const []).map(SayRule.fromJson).whereType<SayRule>().toList(),
          (json['skip'] as List? ?? const []).map(SkipRule.fromJson).whereType<SkipRule>().toList(),
        );
      }
    } on Object {
      // Start with none.
    }
    return (const [], const []);
  }

  /// The skip texts for a web novel from [plugin]; synchronous, for the
  /// isolate that loads a novel.
  static List<String> skipTextsSync(String root, String? plugin) => [
        for (final r in _read(fileIn(root)).$2)
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

  Future<void> _save() async {
    changes.value++;
    try {
      await writeSafely(_file, jsonEncode({
        'say': [for (final r in say) r.toJson()],
        'skip': [for (final r in skip) r.toJson()],
      }));
    } on Object {
      // Kept in memory until the next change.
    }
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

/// [text] with [rules] applied: each rule's word, whole and in any case,
/// replaced by how it should sound. The longest words are tried first, so
/// "Kael Ardent" wins over "Kael".
Respelled respell(String text, List<SayRule> rules) {
  if (rules.isEmpty) return Respelled.same(text);
  final ordered = [...rules]..sort((a, b) => b.from.length.compareTo(a.from.length));
  final hits = <(int, int, String)>[];
  for (final r in ordered) {
    final pattern = RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(r.from)}(?![\\p{L}\\p{N}])',
        caseSensitive: false, unicode: true);
    for (final m in pattern.allMatches(text)) {
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
