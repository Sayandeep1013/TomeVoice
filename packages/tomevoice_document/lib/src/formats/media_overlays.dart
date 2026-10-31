import 'package:xml/xml.dart';

import '../model.dart';
import '../narration.dart';
import 'html_blocks.dart' show textsOfIds;

/// A SMIL clock value in milliseconds: a full clock ("0:00:24.500",
/// "1:02:03"), a partial one ("02:33", "00:10.5") or a timecount ("12.5s",
/// "500ms", "1.5h", "3min", or "12.467", seconds); SMIL 2's "npt=" before
/// it is let be. Null for anything else, and for a time no recording runs
/// to (a damaged file's "99999999999999999999:00:00", or one of a thousand
/// digits): it overflowed, or came to Infinity, and the whole book failed.
double? parseClockValue(String raw) {
  var s = raw.trim();
  if (s.startsWith('npt=')) s = s.substring(4).trim();
  if (s.isEmpty) return null;
  final double? ms;
  final clock = _clock.firstMatch(s);
  if (clock != null) {
    final hours = double.tryParse(clock.group(1) ?? '0');
    final minutes = double.tryParse(clock.group(2)!);
    final seconds = double.tryParse(clock.group(3)!);
    ms = hours == null || minutes == null || seconds == null ? null : ((hours * 60 + minutes) * 60 + seconds) * 1000;
  } else {
    final count = _timecount.firstMatch(s);
    if (count == null) return null;
    final n = double.tryParse(count.group(1)!);
    ms = n == null
        ? null
        : switch (count.group(2)) {
            'h' => n * 3600000,
            'min' => n * 60000,
            'ms' => n,
            _ => n * 1000,
          };
  }
  return ms != null && ms.isFinite && ms <= _longestClockMs ? ms : null;
}

/// No recording runs longer than this (a year): a time past it is a damaged
/// file's.
const _longestClockMs = 366 * 24 * 3600000.0;

final _clock = RegExp(r'^(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$');
final _timecount = RegExp(r'^(\d+(?:\.\d+)?|\.\d+)\s*(h|min|s|ms)?$');

/// One `<par>` of a SMIL file: the document and element id of the text it
/// says (no id: the whole document), and where in which audio file.
typedef SmilPar = ({String text, String? fragment, String audio, double beginMs, double? endMs});

/// The pars of [smil] (the file at [smilPath]), in order, through any
/// nesting of `<seq>`. Paths are resolved from the SMIL file's folder by
/// [resolve], as the package resolves its own. A text given only as
/// "#id" is in the document an enclosing `epub:textref` names, else in
/// [textDoc] (the document the SMIL is the overlay of). A par with no audio,
/// audio outside the book, or a text it names some other way than by id
/// (an EPUB CFI) is left out.
List<SmilPar> smilPars(
  String smil, {
  required String smilPath,
  required String Function(String dir, String href) resolve,
  String? textDoc,
}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(smil);
  } on XmlException {
    return const [];
  }
  final dir = _dirOf(smilPath);
  final out = <SmilPar>[];
  void walk(XmlElement e, String? context) {
    final ref = _attr(e, 'textref').trim();
    final path = ref.split('#').first;
    final here = path.isEmpty || path.contains(':') ? context : resolve(dir, path);
    if (e.localName.toLowerCase() == 'par') {
      final par = _par(e, dir, resolve, here);
      if (par != null) out.add(par);
      return;
    }
    for (final c in e.childElements) {
      walk(c, here);
    }
  }

  walk(doc.rootElement, textDoc);
  return out;
}

SmilPar? _par(XmlElement par, String dir, String Function(String dir, String href) resolve, String? context) {
  XmlElement? text;
  XmlElement? audio;
  for (final c in par.childElements) {
    final name = c.localName.toLowerCase();
    if (name == 'text') text ??= c;
    if (name == 'audio') audio ??= c;
  }
  if (text == null || audio == null) return null;
  final src = (text.getAttribute('src') ?? '').trim();
  final sound = (audio.getAttribute('src') ?? '').split('#').first.trim();
  if (src.isEmpty || sound.isEmpty || sound.contains(':')) return null;
  final hash = src.indexOf('#');
  final path = hash < 0 ? src : src.substring(0, hash);
  final fragment = hash < 0 || hash == src.length - 1 ? null : _decode(src.substring(hash + 1));
  if (fragment != null && fragment.contains('(')) return null;
  if (path.contains(':')) return null;
  final document = path.isEmpty ? context : resolve(dir, path);
  if (document == null) return null;
  final begin = parseClockValue(audio.getAttribute('clipBegin') ?? audio.getAttribute('clip-begin') ?? '0') ?? 0;
  final endText = audio.getAttribute('clipEnd') ?? audio.getAttribute('clip-end');
  final end = endText == null ? null : parseClockValue(endText);
  if (endText != null && (end == null || end <= begin)) return null;
  return (text: document, fragment: fragment, audio: resolve(dir, sound), beginMs: begin, endMs: end);
}

/// The narration an EPUB 3 brings: its media overlays (the SMIL file the
/// manifest names for a document in its `media-overlay`), each par found
/// in the text of [sections] (section i read from document
/// [sectionPaths][i]). Null when the package names none, before anything
/// else is read, so a book without one costs a look through its manifest;
/// null too when nothing it says can be found in the text.
///
/// [read] gives a file of the book as text (a document as the parser
/// decoded it, so its text is the same); [resolve] a path in the book from
/// a folder and an href, as the package's own are resolved.
Narration? readMediaOverlays({
  required XmlDocument opf,
  required Map<String, ({String href, String media, String properties})> manifest,
  required String Function(String dir, String href) resolve,
  required String? Function(String path) read,
  required List<Section> sections,
  required List<String> sectionPaths,
}) {
  final overlayOf = <String, String>{};
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() != 'item') continue;
    final overlay = el.getAttribute('media-overlay')?.trim();
    if (overlay == null || overlay.isEmpty) continue;
    final text = manifest[el.getAttribute('id') ?? '']?.href;
    final smil = manifest[overlay]?.href;
    if (text != null && smil != null) overlayOf[text] = smil;
  }
  if (overlayOf.isEmpty) return null;

  // The SMIL files in the order their documents are read; one file may be
  // the overlay of several.
  final pars = <SmilPar>[];
  final seen = <String>{};
  for (final path in sectionPaths) {
    final smil = overlayOf[path];
    if (smil == null || !seen.add(smil)) continue;
    final text = read(smil);
    if (text != null) pars.addAll(smilPars(text, smilPath: smil, resolve: resolve, textDoc: path));
  }
  if (pars.isEmpty) return null;

  final found = List<(TextPlace, TextPlace)?>.filled(pars.length, null);
  final byDocument = <String, List<int>>{};
  for (var i = 0; i < pars.length; i++) {
    (byDocument[pars[i].text] ??= []).add(i);
  }
  for (final MapEntry(key: path, value: indexes) in byDocument.entries) {
    final blocks = [
      for (var s = 0; s < sections.length && s < sectionPaths.length; s++)
        if (sectionPaths[s] == path)
          for (var b = 0; b < sections[s].blocks.length; b++) (section: s, block: b, text: sections[s].blocks[b].text),
    ];
    if (blocks.isEmpty) continue;
    final html = read(path);
    if (html == null) continue;
    final texts = textsOfIds(html, {
      for (final i in indexes)
        if (pars[i].fragment case final id?) id,
    });
    final places = locateTexts(blocks, [
      for (final i in indexes) pars[i].fragment == null ? null : texts[pars[i].fragment] ?? '',
    ]);
    for (var k = 0; k < indexes.length; k++) {
      found[indexes[k]] = places[k];
    }
  }

  final audio = <String>[];
  final audioIndex = <String, int>{};
  final clips = <NarrationClip>[];
  for (var i = 0; i < pars.length; i++) {
    final at = found[i];
    if (at == null) continue;
    final p = pars[i];
    clips.add(NarrationClip(
      start: at.$1,
      end: at.$2,
      audio: audioIndex.putIfAbsent(p.audio, () {
        audio.add(p.audio);
        return audio.length - 1;
      }),
      beginMs: p.beginMs.round(),
      endMs: p.endMs?.round(),
    ));
  }
  return clips.isEmpty ? null : Narration(audio: audio, clips: clips);
}

/// Where each of [texts] is in [blocks] (one document's, in order), as the
/// place it starts and the place it ends: looked for by its letters and
/// digits alone, in lower case, so the spaces, punctuation and footnote
/// marks the parser kept or dropped do not matter. Null texts are the whole
/// document. Each is looked for after the one before (a narration reads in
/// order); one that is not found takes the text between its neighbours
/// when that is about as long as it should be. Null where nothing fits.
List<(TextPlace, TextPlace)?> locateTexts(
  List<({int section, int block, String text})> blocks,
  List<String?> texts,
) {
  final flat = StringBuffer();
  final blockOf = <int>[];
  final offsetOf = <int>[];
  for (var b = 0; b < blocks.length; b++) {
    _letters(blocks[b].text, (run, at) {
      flat.write(run);
      for (var k = 0; k < run.length; k++) {
        blockOf.add(b);
        offsetOf.add(at + k);
      }
    });
  }
  final doc = flat.toString();
  final n = doc.length;
  final spans = List<(int, int)?>.filled(texts.length, null);
  final wanted = [
    for (final t in texts)
      if (t == null) '' else _lettersOf(t),
  ];
  if (n == 0) return List.filled(texts.length, null);

  var cursor = 0;
  for (var i = 0; i < texts.length; i++) {
    if (texts[i] == null) {
      spans[i] = (0, n);
      continue;
    }
    final w = wanted[i];
    if (w.isEmpty) continue;
    // Close after the one before; a long text anywhere after it, or, read
    // out of order, before it.
    var at = doc.indexOf(w, cursor);
    final distinct = w.length >= 12;
    if (at >= 0 && (at - cursor <= 2000 + 4 * w.length || distinct)) {
      cursor = at + w.length;
    } else {
      at = distinct ? doc.indexOf(w) : -1;
      if (at < 0) continue;
      if (at + w.length > cursor) cursor = at + w.length;
    }
    spans[i] = (at, at + w.length);
  }

  // Runs not found between two that were: the text between those, shared
  // by length, when it is about as long as they are together.
  var i = 0;
  while (i < texts.length) {
    if (spans[i] != null || texts[i] == null) {
      i++;
      continue;
    }
    var j = i;
    while (j < texts.length && spans[j] == null && texts[j] != null) {
      j++;
    }
    final before = i > 0 && texts[i - 1] != null ? spans[i - 1] : null;
    final after = j < texts.length && texts[j] != null ? spans[j] : null;
    if (before != null && after != null && after.$1 > before.$2) {
      final gap = after.$1 - before.$2;
      final weights = [for (var k = i; k < j; k++) wanted[k].isEmpty ? 1 : wanted[k].length];
      final total = weights.fold<int>(0, (s, w) => s + w);
      if (gap * 2 >= total && gap <= total * 2 + 20) {
        var from = before.$2;
        var sum = 0;
        for (var k = i; k < j; k++) {
          sum += weights[k - i];
          final to = k == j - 1 ? after.$1 : before.$2 + (gap * sum / total).round();
          if (to > from) spans[k] = (from, to);
          from = to;
        }
      }
    }
    i = j;
  }

  TextPlace place(int k, {bool end = false}) {
    final b = blocks[blockOf[k]];
    return (section: b.section, block: b.block, offset: offsetOf[k] + (end ? 1 : 0));
  }

  return [
    for (final s in spans)
      if (s == null || s.$2 <= s.$1) null else (place(s.$1), place(s.$2 - 1, end: true)),
  ];
}

final _wordRun = RegExp(r'[\p{L}\p{N}\p{M}]+', unicode: true);

/// The runs of letters and digits in [text], lower case where that keeps
/// their length (so each character still has its place), and where each
/// starts.
void _letters(String text, void Function(String run, int at) add) {
  for (final m in _wordRun.allMatches(text)) {
    final run = m.group(0)!;
    final lower = run.toLowerCase();
    add(lower.length == run.length ? lower : run, m.start);
  }
}

String _lettersOf(String text) {
  final out = StringBuffer();
  _letters(text, (run, _) => out.write(run));
  return out.toString();
}

/// An attribute by its local name, whatever its prefix (`epub:textref`).
String _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return '';
}

String _dirOf(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i <= 0 ? '' : path.substring(0, i);
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } on Object {
    return s;
  }
}
