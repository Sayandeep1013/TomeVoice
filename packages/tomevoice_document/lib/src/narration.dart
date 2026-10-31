/// A book's own recorded narration: an EPUB 3's media overlays, its SMIL
/// files read into clips of audio, each with the stretch of text it says.
library;

/// A place in a book's text: block [block] of section [section], at
/// character [offset] of its text.
typedef TextPlace = ({int section, int block, int offset});

/// [a] before (negative), at (0) or after (positive) [b].
int compareTextPlaces(TextPlace a, TextPlace b) {
  if (a.section != b.section) return a.section - b.section;
  if (a.block != b.block) return a.block - b.block;
  return a.offset - b.offset;
}

/// One clip of a narration: the text from [start] to [end] (exclusive, and
/// perhaps in a later block), said in audio file [audio] from [beginMs] to
/// [endMs] (null: to the end of the file).
class NarrationClip {
  const NarrationClip({
    required this.start,
    required this.end,
    required this.audio,
    required this.beginMs,
    this.endMs,
  });

  final TextPlace start;
  final TextPlace end;

  /// Its file, an index into [Narration.audio].
  final int audio;
  final int beginMs;
  final int? endMs;

  @override
  String toString() => 'NarrationClip($start..$end, audio $audio $beginMs..${endMs ?? 'end'} ms)';
}

/// A book's own recorded narration: its audio files (paths inside the
/// book's file) and its clips, in the order the book's SMIL gives them,
/// which is the order they are heard in.
class Narration {
  const Narration({required this.audio, required this.clips});

  final List<String> audio;
  final List<NarrationClip> clips;

  Map<String, Object?> toJson() => {
        'audio': audio,
        // Nine numbers a clip, flat: its start's section, block and offset,
        // its end's, its file, and where it begins and ends in ms (-1: at
        // the end of the file).
        'clips': [
          for (final c in clips) ...[
            c.start.section,
            c.start.block,
            c.start.offset,
            c.end.section,
            c.end.block,
            c.end.offset,
            c.audio,
            c.beginMs,
            c.endMs ?? -1,
          ],
        ],
      };

  /// The narration in [json], or null for none (or one that cannot be read).
  static Narration? fromJson(Object? json) {
    if (json is! Map) return null;
    final audio = [for (final a in json['audio'] is List ? json['audio'] as List : const []) '$a'];
    final flat = json['clips'];
    if (audio.isEmpty || flat is! List) return null;
    final clips = <NarrationClip>[];
    for (var i = 0; i + 9 <= flat.length; i += 9) {
      final v = [for (var k = 0; k < 9; k++) flat[i + k] is num ? (flat[i + k] as num).toInt() : -1];
      if (v[6] < 0 || v[6] >= audio.length) continue;
      clips.add(NarrationClip(
        start: (section: v[0], block: v[1], offset: v[2]),
        end: (section: v[3], block: v[4], offset: v[5]),
        audio: v[6],
        beginMs: v[7] < 0 ? 0 : v[7],
        endMs: v[8] < 0 ? null : v[8],
      ));
    }
    return clips.isEmpty ? null : Narration(audio: audio, clips: clips);
  }
}
