import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A mono 16-bit WAV of [seconds] at [rate]: a tone for each of [sounds]
/// (from, to, in seconds), silence between them, like a narrator who
/// pauses between sentences.
Uint8List toneWav(double seconds, List<(double, double)> sounds, {int rate = 8000}) {
  final n = (seconds * rate).round();
  final data = ByteData(44 + n * 2);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (final (from, to) in sounds) {
    final a = (from * rate).round();
    final b = math.min(n, (to * rate).round());
    for (var i = a; i < b; i++) {
      final v = 0.4 * math.sin(2 * math.pi * 220 * i / rate) * math.sin(math.pi * (i - a) / (b - a));
      data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

/// Where each narrated sound is in [narratedEpub]'s files, in seconds.
const oneSounds = [(0.1, 1.1), (1.3, 2.9), (3.1, 5.4), (5.9, 7.9)];
const twoSounds = [(0.6, 3.2), (3.6, 6.4), (7.3, 9.4)];
const threeSounds = [(0.1, 1.4), (1.6, 3.5), (3.7, 5.7), (6.1, 7.8)];

/// A small EPUB 3 with its own narration (media overlays), each chapter's
/// SMIL in another way of writing times:
///
/// - a title page with none;
/// - Chapter One, a clip a sentence (and its heading), in full clock
///   values ("0:00:01.200"), with a pause between two of its clips;
/// - Chapter Two, a clip a paragraph, in partial clocks and timecounts
///   ("00:00.5", "7.25s", "9500ms"): its first paragraph is two sentences,
///   a line between its paragraphs is not narrated, nor is its heading;
/// - Chapter Three, in nested seqs that name their document by
///   `epub:textref`, its texts given as "#id" alone, its times bare
///   seconds, "ms", "min" and "h", a sentence said in two clips, and a
///   last clip that runs to the end of its file.
///
/// The audio is a tone where each line is said: Chapter One's and Two's
/// stored in the zip, Chapter Three's compressed.
Uint8List narratedEpub() {
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
    <dc:title>The Tin Box</dc:title><dc:language>en</dc:language><dc:identifier id="id">tin-box</dc:identifier>
    <meta property="media:duration" refines="#mo1">0:00:08.500</meta>
    <meta property="media:duration" refines="#mo2">0:00:10.000</meta>
    <meta property="media:duration" refines="#mo3">0:00:08.000</meta>
    <meta property="media:duration">0:00:26.500</meta>
    <meta property="media:active-class">-epub-media-overlay-active</meta>
  </metadata>
  <manifest>
    <item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml" media-overlay="mo1"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml" media-overlay="mo2"/>
    <item id="c3" href="text/ch3.xhtml" media-type="application/xhtml+xml" media-overlay="mo3"/>
    <item id="mo1" href="smil/ch1.smil" media-type="application/smil+xml"/>
    <item id="mo2" href="smil/ch2.smil" media-type="application/smil+xml"/>
    <item id="mo3" href="smil/ch3.smil" media-type="application/smil+xml"/>
    <item id="a1" href="audio/one.wav" media-type="audio/wav"/>
    <item id="a2" href="audio/two.wav" media-type="audio/wav"/>
    <item id="a3" href="audio/three.wav" media-type="audio/wav"/>
  </manifest>
  <spine>
    <itemref idref="title"/>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="c3"/>
  </spine>
</package>''');
  String page(String body) => '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>x</title></head><body>$body</body></html>';
  text('OEBPS/title.xhtml', page('<h1>The Tin Box</h1><p>A story read aloud, with its own recording.</p>'));
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

  String smil(String body, {String textref = ''}) => '<?xml version="1.0" encoding="UTF-8"?>'
      '<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">'
      '<body$textref>$body</body></smil>';
  String par(String text, String audio, String begin, [String? end]) =>
      '<par><text src="$text"/><audio src="$audio" clipBegin="$begin"${end == null ? '' : ' clipEnd="$end"'}/></par>';
  text('OEBPS/smil/ch1.smil', smil(
    '<seq epub:textref="../text/ch1.xhtml" epub:type="chapter">'
    '${par('../text/ch1.xhtml#h1', '../audio/one.wav', '0:00:00.000', '0:00:01.200')}'
    '${par('../text/ch1.xhtml#s1', '../audio/one.wav', '0:00:01.200', '0:00:03.000')}'
    '${par('../text/ch1.xhtml#s2', '../audio/one.wav', '0:00:03.000', '0:00:05.500')}'
    '${par('../text/ch1.xhtml#s3', '../audio/one.wav', '0:00:05.800', '0:00:08.000')}'
    '</seq>',
  ));
  text('OEBPS/smil/ch2.smil', smil(
    '${par('../text/ch2.xhtml#q1', '../audio/two.wav', '00:00.5', '00:06.500')}'
    '${par('../text/ch2.xhtml#q2', '../audio/two.wav', '7.25s', '9500ms')}',
  ));
  text('OEBPS/smil/ch3.smil', smil(
    textref: ' epub:textref="../text/ch3.xhtml"',
    '${par('#t3', '../audio/three.wav', '0', '1.5')}'
    '<seq epub:textref="../text/ch3.xhtml#r1">'
    '${par('#r1a', '../audio/three.wav', '1500ms', '0.06min')}'
    '${par('#r1b', '../audio/three.wav', '3.6s', '0.0016h')}'
    '</seq>'
    '${par('#r2', '../audio/three.wav', '6s')}',
  ));
  stored('OEBPS/audio/one.wav', toneWav(8.5, oneSounds));
  stored('OEBPS/audio/two.wav', toneWav(10, twoSounds));
  archive.addFile(ArchiveFile.bytes('OEBPS/audio/three.wav', toneWav(8, threeSounds)));
  return ZipEncoder().encodeBytes(archive);
}
