import 'dart:typed_data';

import 'model.dart';
import 'narration.dart';
import 'reading_layout.dart';

/// How a unit of a book read in its own narration is read.
enum NarrationRole {
  /// In the narration's own recording.
  recorded,

  /// Passed over: the narration leaves it out between lines it reads (a
  /// caption, a line it skips), as the narrator passed it over.
  passed,

  /// Read by the book's voice: outside what the narration reads (a chapter
  /// it has nothing of, or before its first line in a chapter or after its
  /// last, where it may simply have stopped).
  voiced,
}

/// The part of clip [clip] that says (part of) a unit: from [from] to [to]
/// of the clip's text, as shares of it (0 its start, 1 its end) counted in
/// letters and digits, so its audio can be cut at about the same share; and
/// the stretch of the unit's own text it says, [start] to [end].
typedef NarrationPiece = ({int clip, double from, double to, int start, int end});

/// A book's narration laid over the units of one of its layouts.
///
/// The narration's clips and the layout's sentences are cut by different
/// hands: a clip is often a sentence, sometimes a paragraph or a phrase.
/// Each unit gets the parts of the clips its text overlaps, in order:
///
/// - a clip that is the unit, or several that are (a sentence said in
///   phrases), give it their audio whole, one after another;
/// - a clip that says several units (a paragraph) is shared between them,
///   each taking the share of its audio its share of the clip's letters
///   is, cut where the audio pauses nearest that (see [cuts]);
/// - a clip whose text only touches a unit with spaces or marks is not
///   the unit's.
class NarrationPlan {
  NarrationPlan._(this.narration, this.pieces, this.roles, this.cuts);

  final Narration narration;

  /// Unit -> the parts of clips that say it, in the order heard; empty for
  /// a unit the narration does not say.
  final List<List<NarrationPiece>> pieces;

  /// Unit -> how it is read.
  final List<NarrationRole> roles;

  /// Clip -> where in it one unit ends and another begins, as shares in
  /// order: the places its audio is cut.
  final Map<int, List<double>> cuts;

  /// The plan for [layout], or null when its book has no narration.
  static NarrationPlan? of(ReadingLayout layout) {
    final narration = layout.book.narration;
    final units = layout.units;
    if (narration == null || units.isEmpty) return null;
    final clips = narration.clips;
    final order = [for (var k = 0; k < clips.length; k++) k]..sort((a, b) {
        final c = compareTextPlaces(clips[a].start, clips[b].start);
        return c != 0 ? c : a - b;
      });
    final letters = _Letters(layout.book);
    final pieces = List<List<NarrationPiece>>.filled(units.length, const []);
    // The first clip (in the text's order) that can still reach a unit.
    var first = 0;
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      final at = layout.unitOffset[u];
      final start = (section: unit.sectionIndex, block: unit.blockIndex, offset: at);
      final end = (section: unit.sectionIndex, block: unit.blockIndex, offset: at + unit.text.length);
      while (first < order.length && compareTextPlaces(clips[order[first]].end, start) <= 0) {
        first++;
      }
      List<NarrationPiece>? found;
      for (var j = first; j < order.length; j++) {
        final k = order[j];
        final c = clips[k];
        if (compareTextPlaces(c.start, end) >= 0) break;
        if (compareTextPlaces(c.end, start) <= 0) continue;
        final from = compareTextPlaces(c.start, start) > 0 ? c.start : start;
        final to = compareTextPlaces(c.end, end) < 0 ? c.end : end;
        final total = letters.between(c.start, c.end);
        if (total > 0 && letters.between(from, to) == 0) continue;
        (found ??= []).add((
          clip: k,
          from: total == 0 ? 0.0 : letters.between(c.start, from) / total,
          to: total == 0 ? 1.0 : letters.between(c.start, to) / total,
          start: from.offset - at,
          end: to.offset - at,
        ));
      }
      if (found != null) pieces[u] = found;
    }

    final cuts = <int, List<double>>{};
    for (final list in pieces) {
      for (final p in list) {
        if (p.from > 0) (cuts[p.clip] ??= []).add(p.from);
        if (p.to < 1) (cuts[p.clip] ??= []).add(p.to);
      }
    }
    for (final list in cuts.values) {
      list.sort();
      for (var i = list.length - 1; i > 0; i--) {
        if (list[i] - list[i - 1] <= 1e-9) list.removeAt(i);
      }
    }

    // What the narration leaves out between two lines it reads in a
    // section is passed over; before its first and after its last, read.
    final roles = List<NarrationRole>.filled(units.length, NarrationRole.voiced);
    var u = 0;
    while (u < units.length) {
      final section = units[u].sectionIndex;
      var v = u;
      int? firstSaid;
      int? lastSaid;
      while (v < units.length && units[v].sectionIndex == section) {
        if (pieces[v].isNotEmpty) {
          firstSaid ??= v;
          lastSaid = v;
        }
        v++;
      }
      for (var w = u; w < v; w++) {
        if (pieces[w].isNotEmpty) {
          roles[w] = NarrationRole.recorded;
        } else if (firstSaid != null && w > firstSaid && w < lastSaid!) {
          roles[w] = NarrationRole.passed;
        }
      }
      u = v;
    }
    return NarrationPlan._(narration, pieces, roles, cuts);
  }
}

/// Letters and digits in stretches of a book's text, from running counts
/// of each block, made as they are first asked for.
class _Letters {
  _Letters(this.book);

  final Book book;
  final _counts = <int, Map<int, Int32List>>{};

  static final _none = Int32List(1);

  Int32List _of(int section, int block) {
    if (section < 0 || section >= book.sections.length) return _none;
    final blocks = book.sections[section].blocks;
    if (block < 0 || block >= blocks.length) return _none;
    return (_counts[section] ??= {}).putIfAbsent(block, () {
      final text = blocks[block].text;
      final out = Int32List(text.length + 1);
      for (var i = 0; i < text.length; i++) {
        out[i + 1] = out[i] + (_said(text.codeUnitAt(i)) ? 1 : 0);
      }
      return out;
    });
  }

  int _at(TextPlace p) {
    final counts = _of(p.section, p.block);
    return counts[p.offset.clamp(0, counts.length - 1)];
  }

  /// Letters and digits from [a] to [b].
  int between(TextPlace a, TextPlace b) {
    if (compareTextPlaces(a, b) >= 0) return 0;
    if (a.section == b.section && a.block == b.block) return _at(b) - _at(a);
    var n = _of(a.section, a.block).last - _at(a);
    var s = a.section;
    var k = a.block + 1;
    while (s < b.section || (s == b.section && k < b.block)) {
      if (s >= book.sections.length) break;
      if (k >= book.sections[s].blocks.length) {
        s++;
        k = 0;
        continue;
      }
      n += _of(s, k).last;
      k++;
    }
    return n + _at(b);
  }

  /// A letter or a digit, near enough: spaces and the usual marks are not.
  static bool _said(int c) {
    if (c < 0x80) return (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A);
    if (c < 0xC0) return false;
    if (c >= 0x2000 && c <= 0x206F) return false;
    if (c >= 0x3000 && c <= 0x303F) return false;
    return c != 0xFEFF;
  }
}
