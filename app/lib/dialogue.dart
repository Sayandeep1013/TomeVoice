import 'dart:io';
import 'dart:typed_data';

import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'neural_voices.dart' show wavBytes;
import 'speech_service.dart';

/// A stretch of a sentence: narration, or words inside quotation marks.
typedef Part = ({String text, bool spoken});

const _open = {'“': '”', '"': '"', '«': '»', '「': '」', '„': '“'};
const _closes = {'”', '"', '»', '」', '“'};

/// [text] cut into narration and dialogue at its quotation marks.
///
/// A quote can run over several sentences, and each sentence is said on
/// its own: a sentence that closes a quote it never opened began inside
/// one, and one that opens a quote it never closes ends inside one.
/// Single quotes are left alone; they are too often apostrophes.
List<Part> splitDialogue(String text) {
  final parts = <Part>[];
  final buf = StringBuffer();
  String? closing;
  // Opened before this sentence: a closing mark with no opening one first.
  final firstOpen = text.indexOf(RegExp('[“"«「„]'));
  final firstClose = text.indexOf(RegExp('[”»」]'));
  var inside = firstClose >= 0 && (firstOpen < 0 || firstClose < firstOpen);
  if (inside) closing = text[firstClose];

  void flush() {
    final s = buf.toString();
    if (s.trim().isNotEmpty) parts.add((text: s, spoken: inside));
    buf.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (!inside && _open.containsKey(c)) {
      flush();
      inside = true;
      closing = _open[c];
      buf.write(c);
    } else if (inside && (c == closing || (closing == null && _closes.contains(c)))) {
      buf.write(c);
      flush();
      inside = false;
      closing = null;
    } else {
      buf.write(c);
    }
  }
  flush();
  return parts;
}

/// [audio] at [rate], by straight-line interpolation (voices from different
/// engines can differ: 22050 and 24000 Hz).
Float32List resample(Float32List audio, int from, int to) {
  if (from == to || audio.isEmpty) return audio;
  final n = (audio.length * to / from).round();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final x = i * from / to;
    final a = x.floor().clamp(0, audio.length - 1);
    final b = (a + 1).clamp(0, audio.length - 1);
    final t = x - a;
    out[i] = audio[a] * (1 - t) + audio[b] * t;
  }
  return out;
}

/// Say [text] with its dialogue in [dialogueVoice] and the rest in
/// [narrator]: each stretch made on its own and joined, with no gap, into
/// one WAV like a single voice returns. Word positions are estimated over
/// the whole sentence, as for voices that report none.
Future<Map<String, Object?>> speakWithDialogue({
  required SpeechService svc,
  required String text,
  required String? narrator,
  required String dialogueVoice,
  String? engineId,
  double rate = 1.0,
  double pitch = 1.0,
}) async {
  final parts = splitDialogue(text);
  if (parts.length == 1) {
    return svc.synthesise(
      text: text,
      engineId: engineId,
      voiceName: parts.single.spoken ? dialogueVoice : narrator,
      rate: rate,
      pitch: pitch,
    );
  }
  final pieces = <AudioBuffer>[];
  for (final p in parts) {
    final native = await svc.synthesise(
      text: p.text,
      engineId: engineId,
      voiceName: p.spoken ? dialogueVoice : narrator,
      rate: rate,
      pitch: pitch,
    );
    final file = File(native['wavPath']! as String);
    pieces.add(WavCodec.decode(await file.readAsBytes()));
    await file.delete();
  }
  final rate0 = pieces.first.sampleRate;
  final joined = <double>[
    for (final p in pieces) ...resample(p.samples, p.sampleRate, rate0),
  ];
  final out = File('${Directory.systemTemp.path}/dialogue-${DateTime.now().microsecondsSinceEpoch}.wav');
  await out.writeAsBytes(wavBytes(Float32List.fromList(joined), rate0));
  return {'wavPath': out.path, 'engineId': 'tomevoice.dialogue', 'rangeEvents': const []};
}
