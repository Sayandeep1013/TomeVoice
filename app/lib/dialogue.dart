import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
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
///
/// [startsInside], when the paragraph is known, says whether a quote is
/// already open where this sentence begins (straight quotes, which open and
/// close with the same mark, can only be told apart that way).
List<Part> splitDialogue(String text, {bool? startsInside}) {
  final parts = <Part>[];
  final buf = StringBuffer();
  String? closing;
  // Opened before this sentence: a closing mark with no opening one first.
  final firstOpen = text.indexOf(RegExp('[“"«「„]'));
  final firstClose = text.indexOf(RegExp('[”»」]'));
  var inside = startsInside ?? (firstClose >= 0 && (firstOpen < 0 || firstClose < firstOpen));
  if (inside) {
    // What closes it: the first closing mark, or a straight quote.
    final close = text.indexOf(RegExp('[”»」"]'));
    closing = close >= 0 ? text[close] : null;
  }

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

/// 16-bit PCM [pcm] at [from] Hz, as 16-bit PCM at [to] Hz.
Uint8List resamplePcm16(Uint8List pcm, int from, int to) {
  if (from == to || pcm.isEmpty) return pcm;
  // A view needs an even offset; a copy has one.
  final bytes = pcm.offsetInBytes.isEven ? pcm : Uint8List.fromList(pcm);
  final ints = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
  final f = Float32List(ints.length);
  for (var i = 0; i < ints.length; i++) {
    f[i] = ints[i] / 32768;
  }
  final r = resample(f, from, to);
  final out = Int16List(r.length);
  for (var i = 0; i < r.length; i++) {
    out[i] = (r[i] * 32768).round().clamp(-32768, 32767);
  }
  return out.buffer.asUint8List();
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
  bool Function()? stale,
  bool? startsInside,
  bool urgent = true,
}) async {
  final parts = splitDialogue(text, startsInside: startsInside);
  if (parts.length == 1) {
    return svc.synthesise(
      urgent: urgent,
      text: text,
      engineId: engineId,
      voiceName: parts.single.spoken ? dialogueVoice : narrator,
      rate: rate,
      pitch: pitch,
    );
  }
  final pieces = <AudioBuffer>[];
  for (final p in parts) {
    // A jump since: stop here, so the new sentence is not kept waiting.
    if (stale?.call() ?? false) throw PlatformException(code: 'TTS_STOPPED');
    final native = await svc.synthesise(
      urgent: urgent,
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
  // At the narrator's rate, so this sentence matches the ones around it
  // (not at whichever voice happened to speak first).
  final narration = [for (var k = 0; k < parts.length; k++) if (!parts[k].spoken) pieces[k]];
  final rate0 = (narration.isEmpty ? pieces.first : narration.first).sampleRate;
  final joined = <double>[
    for (final p in pieces) ...resample(p.samples, p.sampleRate, rate0),
  ];
  // In the folder swept on every start, so none are left behind.
  final out = File('${synthTempDir().path}/dialogue-${DateTime.now().microsecondsSinceEpoch}.wav');
  await out.writeAsBytes(wavBytes(Float32List.fromList(joined), rate0));
  return {'wavPath': out.path, 'engineId': 'tomevoice.dialogue', 'rangeEvents': const []};
}
