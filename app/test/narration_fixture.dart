import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_spike/narration.dart';

/// A mono 16-bit WAV of [seconds] at [rate]: a tone where each of [sounds]
/// (from, to, in seconds) is said, silence between them, as a narrator
/// pauses between sentences.
Uint8List toneWav(double seconds, List<(double, double)> sounds, {int rate = 8000}) {
  final samples = Float32List((seconds * rate).round());
  for (final (from, to) in sounds) {
    final a = (from * rate).round();
    final b = math.min(samples.length, (to * rate).round());
    for (var i = a; i < b; i++) {
      samples[i] = 0.4 * math.sin(2 * math.pi * 220 * i / rate) * math.sin(math.pi * (i - a) / (b - a));
    }
  }
  return WavCodec.encodePcm16(AudioBuffer(samples, rate));
}

/// Where each line is said in [narratedEpub]'s files, in seconds.
const oneSounds = [(0.1, 1.1), (1.3, 2.9), (3.1, 5.4), (5.9, 7.9)];
const twoSounds = [(0.6, 3.2), (3.6, 6.4), (7.3, 9.4)];
const threeSounds = [(0.1, 1.4), (1.6, 3.5), (3.7, 5.7), (6.1, 7.8)];

/// A small EPUB 3 with its own narration (media overlays): a title page
/// with none; Chapter One a clip a sentence, with a pause between two of
/// them; Chapter Two a clip a paragraph (its first two sentences), a line
/// between its paragraphs and its heading not narrated; Chapter Three a
/// sentence said in two clips and a last clip that runs to the end of its
/// file. Chapter One's and Two's audio is stored in the zip, Three's
/// compressed. Without [overlays], the same book whose package names no
/// narration.
Uint8List narratedEpub({String title = 'The Tin Box', bool overlays = true}) {
  String overlay(String id) => overlays ? ' media-overlay="$id"' : '';
  final archive = Archive();
  void text(String name, String body) => archive.addFile(ArchiveFile.bytes(name, utf8.encode(body)));
  void stored(String name, List<int> bytes) => archive.addFile(ArchiveFile.noCompress(name, bytes.length, bytes));

  stored('mimetype', utf8.encode('application/epub+zip'));
  text('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
      '</rootfiles></container>');
  text('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title><dc:language>en</dc:language><dc:identifier id="id">tin-box</dc:identifier>
    <meta property="media:active-class">-epub-media-overlay-active</meta>
  </metadata>
  <manifest>
    <item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"${overlay('mo1')}/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"${overlay('mo2')}/>
    <item id="c3" href="text/ch3.xhtml" media-type="application/xhtml+xml"${overlay('mo3')}/>
    <item id="mo1" href="smil/ch1.smil" media-type="application/smil+xml"/>
    <item id="mo2" href="smil/ch2.smil" media-type="application/smil+xml"/>
    <item id="mo3" href="smil/ch3.smil" media-type="application/smil+xml"/>
    <item id="a1" href="audio/one.wav" media-type="audio/wav"/>
    <item id="a2" href="audio/two.wav" media-type="audio/wav"/>
    <item id="a3" href="audio/three.wav" media-type="audio/wav"/>
  </manifest>
  <spine>
    <itemref idref="title"/><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>
  </spine>
</package>''');
  String page(String body) => '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>x</title></head><body>$body</body></html>';
  text('OEBPS/title.xhtml', page('<h1>$title</h1><p>A story read aloud, with its own recording.</p>'));
  text('OEBPS/text/ch1.xhtml', page('<h1 id="h1">Chapter One</h1>'
      '<p id="p1"><span id="s1">The box was made of tin.</span> <span id="s2">It sat on a shelf by the door.</span></p>'
      '<p id="p2"><span id="s3">Nobody had opened it for years.</span></p>'));
  text('OEBPS/text/ch2.xhtml', page('<h1>Chapter Two</h1>'
      '<p id="q1">She lifted the lid. Inside lay a key.</p>'
      '<p>A line the narrator leaves out.</p>'
      '<p id="q2">The key was cold.</p>'));
  text('OEBPS/text/ch3.xhtml', page('<h1 id="t3">Chapter Three</h1>'
      '<p id="r1"><span id="r1a">When she turned it,</span> <span id="r1b">the box began to sing.</span></p>'
      '<p id="r2">It sang until morning.</p>'));
  String smil(String body) => '<?xml version="1.0" encoding="UTF-8"?>'
      '<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">'
      '<body>$body</body></smil>';
  String par(String text, String audio, String begin, [String? end]) =>
      '<par><text src="$text"/><audio src="$audio" clipBegin="$begin"${end == null ? '' : ' clipEnd="$end"'}/></par>';
  text('OEBPS/smil/ch1.smil', smil(
    '${par('../text/ch1.xhtml#h1', '../audio/one.wav', '0:00:00.000', '0:00:01.200')}'
    '${par('../text/ch1.xhtml#s1', '../audio/one.wav', '0:00:01.200', '0:00:03.000')}'
    '${par('../text/ch1.xhtml#s2', '../audio/one.wav', '0:00:03.000', '0:00:05.500')}'
    '${par('../text/ch1.xhtml#s3', '../audio/one.wav', '0:00:05.800', '0:00:08.000')}',
  ));
  text('OEBPS/smil/ch2.smil', smil(
    '${par('../text/ch2.xhtml#q1', '../audio/two.wav', '00:00.5', '00:06.500')}'
    '${par('../text/ch2.xhtml#q2', '../audio/two.wav', '7.25s', '9500ms')}',
  ));
  text('OEBPS/smil/ch3.smil', smil(
    '${par('../text/ch3.xhtml#t3', '../audio/three.wav', '0', '1.5')}'
    '${par('../text/ch3.xhtml#r1a', '../audio/three.wav', '1500ms', '0.06min')}'
    '${par('../text/ch3.xhtml#r1b', '../audio/three.wav', '3.6s', '0.0016h')}'
    '${par('../text/ch3.xhtml#r2', '../audio/three.wav', '6s')}',
  ));
  stored('OEBPS/audio/one.wav', toneWav(8.5, oneSounds));
  stored('OEBPS/audio/two.wav', toneWav(10, twoSounds));
  archive.addFile(ArchiveFile.bytes('OEBPS/audio/three.wav', toneWav(8, threeSounds)));
  return ZipEncoder().encodeBytes(archive);
}

/// A zip of [files] by path, each stored as it is.
Uint8List zipOf(Map<String, List<int>> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.noCompress(e.key, e.value.length, e.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// What the platform's decoder (NarrationAudio.kt) gives, from a WAV in a
/// file: everything from a little before the stretch asked for (where a
/// seek lands) to a little after it, as two channels, with the time of the
/// first sample. Each call is kept.
class WavDecoder {
  final calls = <({String path, int offset, int length, int beginUs, int endUs})>[];

  Future<DecodedAudio> call({
    required String path,
    required int offset,
    required int length,
    required int beginUs,
    required int endUs,
  }) async {
    calls.add((path: path, offset: offset, length: length, beginUs: beginUs, endUs: endUs));
    final f = File(path).openSync();
    final Uint8List bytes;
    try {
      f.setPositionSync(offset);
      bytes = f.readSync(length);
    } finally {
      f.closeSync();
    }
    final wav = WavCodec.decode(bytes);
    final rate = wav.sampleRate;
    final first = (math.max(0, beginUs - 200000) * rate / 1000000).floor();
    final last = endUs < 0 ? wav.frameCount : math.min(wav.frameCount, ((endUs + 100000) * rate / 1000000).ceil());
    final out = Int16List(math.max(0, last - first) * 2);
    for (var i = first; i < last; i++) {
      final v = (wav.samples[i] * 32767).round().clamp(-32768, 32767);
      out[(i - first) * 2] = v;
      out[(i - first) * 2 + 1] = v;
    }
    return (
      pcm: out.buffer.asUint8List(),
      channels: 2,
      sampleRate: rate,
      firstUs: (first * 1000000 / rate).round(),
      durationUs: (wav.frameCount * 1000000 / rate).round(),
    );
  }
}
