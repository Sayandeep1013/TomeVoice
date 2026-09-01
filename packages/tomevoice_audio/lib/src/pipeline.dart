import 'types.dart';

/// Maps a frame position in a stage's input to its position in that stage's
/// output.
///
/// Every stage must supply one. Composing them is what keeps word highlighting
/// aligned with the audio the user actually hears — see docs/02 section 2.6.
typedef FrameRemap = int Function(int oldFrame);

/// Identity remap, for stages that do not change frame positions.
int identityRemap(int frame) => frame;

class StageResult {
  const StageResult(this.audio, this.remap);

  final AudioBuffer audio;
  final FrameRemap remap;

  /// A stage that changed nothing.
  static StageResult unchanged(AudioBuffer audio) =>
      StageResult(audio, identityRemap);
}

abstract class PipelineStage {
  String get name;

  /// [timings] are the word positions *in the incoming buffer*. A stage may
  /// read them (word gap needs the boundaries) but must not mutate them; the
  /// [Pipeline] remaps them using the returned [StageResult.remap].
  StageResult process(AudioBuffer input, List<WordTiming> timings);
}

/// Runs stages in order, remapping timings through each one.
///
/// Order is not arbitrary. Word-gap injection must run *after* any time
/// stretching, or the inserted silence is scaled by the speed setting and a
/// 120 ms gap becomes 60 ms at 2x. `ordering_test.dart` pins this.
class Pipeline {
  const Pipeline(this.stages);

  final List<PipelineStage> stages;

  SynthesisResult run(SynthesisResult input) {
    var audio = input.audio;
    var timings = input.wordTimings;

    for (final stage in stages) {
      final result = stage.process(audio, timings);
      audio = result.audio;
      timings = [
        for (final t in timings)
          t.copyWithFrames(
            result.remap(t.frameStart),
            result.remap(t.frameEnd),
          ),
      ];
    }

    return input.copyWith(audio: audio, wordTimings: timings);
  }

  /// Runs the pipeline and reports what each stage did. Used by the spike's
  /// debug panel and by the ordering tests.
  ({SynthesisResult result, List<StageTrace> trace}) runTraced(
    SynthesisResult input,
  ) {
    var audio = input.audio;
    var timings = input.wordTimings;
    final trace = <StageTrace>[];

    for (final stage in stages) {
      final before = audio.frameCount;
      final result = stage.process(audio, timings);
      audio = result.audio;
      timings = [
        for (final t in timings)
          t.copyWithFrames(
            result.remap(t.frameStart),
            result.remap(t.frameEnd),
          ),
      ];
      trace.add(StageTrace(stage.name, before, audio.frameCount));
    }

    return (
      result: input.copyWith(audio: audio, wordTimings: timings),
      trace: trace,
    );
  }
}

class StageTrace {
  const StageTrace(this.stageName, this.framesIn, this.framesOut);

  final String stageName;
  final int framesIn;
  final int framesOut;

  int get delta => framesOut - framesIn;

  @override
  String toString() => '$stageName: $framesIn -> $framesOut (${_signed(delta)})';

  static String _signed(int v) => v >= 0 ? '+$v' : '$v';
}

/// Builds a remap from a sorted list of (position, cumulativeShift) points.
///
/// Insertion stages produce exactly this shape: at each splice point the output
/// shifts forward by the amount inserted so far. Frames before the first splice
/// are unmoved.
FrameRemap remapFromInsertions(List<({int at, int shift})> insertions) {
  if (insertions.isEmpty) return identityRemap;

  final points = List<({int at, int shift})>.from(insertions)
    ..sort((a, b) => a.at.compareTo(b.at));

  return (int frame) {
    var shift = 0;
    for (final p in points) {
      // A frame exactly at a splice point belongs *after* the inserted silence.
      //
      // Source frames [0, split) are copied before the gap and frame `split`
      // itself is the first frame after it, so this is the literally correct
      // mapping of sample positions.
      //
      // It also gives the behaviour highlighting wants: the preceding word's
      // exclusive frameEnd lands at the end of the gap, so the highlight holds
      // through the silence instead of blinking off and on again.
      if (p.at <= frame) {
        shift = p.shift;
      } else {
        break;
      }
    }
    return frame + shift;
  };
}
