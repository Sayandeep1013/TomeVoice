import 'dart:convert';
import 'dart:typed_data';

/// A print of a book's text: what another copy of the same text shares most
/// of (another format, another file of the same edition), and a different
/// book almost none of. Of every run of five words in the book, the
/// [printSize] whose hashes are smallest (a bottom-k sketch, as MinHash
/// keeps one), stored as base64. Only letters and digits count, in lower
/// case: punctuation, quotes, line breaks and hyphens put in by a PDF do
/// not change it. Null for a text too short to say anything by.
String? textPrint(Iterable<String> texts) {
  final kept = <int>[];
  final window = List<int>.filled(_run, 0);
  var words = 0;
  for (final text in texts) {
    for (final w in text.toLowerCase().split(_notWord)) {
      if (w.isEmpty) continue;
      window[words % _run] = _hashWord(w);
      words++;
      if (words < _run) continue;
      // The run of words ending here, in order.
      var h = 0x811c9dc5;
      for (var i = words - _run; i < words; i++) {
        h = ((h ^ window[i % _run]) * 0x01000193) & 0xffffffff;
      }
      _keep(kept, _mix(h));
    }
  }
  if (words < 200) return null;
  final bytes = ByteData(kept.length * 4);
  for (var i = 0; i < kept.length; i++) {
    bytes.setUint32(i * 4, kept[i]);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

/// How alike two prints are, from 0 (no run of words in common) to 1 (the
/// same text): the share of the smallest hashes of both together that both
/// have.
double printLikeness(String a, String b) {
  final x = _hashes(a), y = _hashes(b);
  if (x.isEmpty || y.isEmpty) return 0;
  final both = {...x, ...y}.toList()..sort();
  final k = both.length < printSize ? both.length : printSize;
  var shared = 0;
  for (final h in both.take(k)) {
    if (x.contains(h) && y.contains(h)) shared++;
  }
  return shared / k;
}

/// The hashes a print keeps.
const printSize = 16;

/// Words in a run.
const _run = 5;

final _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// The hashes [print] keeps (none for no print).
Set<int> printHashes(String? print) => print == null ? const {} : _hashes(print);

Set<int> _hashes(String print) {
  try {
    final bytes = ByteData.sublistView(base64.decode(print));
    return {for (var i = 0; i + 4 <= bytes.lengthInBytes; i += 4) bytes.getUint32(i)};
  } on FormatException {
    return const {};
  }
}

/// FNV-1a of a word's characters.
int _hashWord(String w) {
  var h = 0x811c9dc5;
  for (final c in w.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// The last step of MurmurHash3's 32-bit hash: every bit of [h] moves every
/// bit of the result, so the smallest are spread over the whole text.
int _mix(int h) {
  h = ((h ^ (h >> 16)) * 0x85ebca6b) & 0xffffffff;
  h = ((h ^ (h >> 13)) * 0xc2b2ae35) & 0xffffffff;
  return h ^ (h >> 16);
}

/// [h] among the [printSize] smallest in [kept] (sorted, no two the same).
void _keep(List<int> kept, int h) {
  if (kept.length == printSize && h >= kept.last) return;
  var lo = 0, hi = kept.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (kept[mid] < h) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo < kept.length && kept[lo] == h) return;
  kept.insert(lo, h);
  if (kept.length > printSize) kept.removeLast();
}
