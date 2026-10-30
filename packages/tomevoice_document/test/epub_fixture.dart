import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A tiny valid EPUB 2 for tests. Two spine chapters, a heading, a footnote.
Uint8List minimalEpub({
  String title = 'Fox Book',
  String author = 'Aesop',
  String language = 'en',
  String? description,
  bool encrypted = false,
}) {
  final archive = Archive();

  void add(String name, String body, {bool raw = false}) {
    final encoded = utf8.encode(body);
    archive.addFile(
      raw
          ? ArchiveFile.noCompress(name, encoded.length, encoded)
          : ArchiveFile.bytes(name, encoded),
    );
  }

  add('mimetype', 'application/epub+zip', raw: true);
  add(
    'META-INF/container.xml',
    '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
  );
  if (encrypted) {
    // What Adobe's DRM writes: the chapters themselves encrypted with AES.
    add('META-INF/encryption.xml', '''<?xml version="1.0"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>''');
  }
  add(
    'OEBPS/content.opf',
    '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:creator>$author</dc:creator>
    <dc:language>$language</dc:language>
    <dc:identifier id="BookId">urn:uuid:tomevoice-test</dc:identifier>
    ${description == null ? '' : '<dc:description>$description</dc:description>'}
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
''',
  );
  add(
    'OEBPS/toc.ncx',
    '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1"><navLabel><text>The fox</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2"><navLabel><text>The jugs</text></navLabel><content src="ch2.xhtml"/></navPoint>
  </navMap>
</ncx>
''',
  );
  add(
    'OEBPS/ch1.xhtml',
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body>
<h1>The fox</h1>
<p>The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.</p>
<p epub:type="footnote">A footnote that should be skipped by default.</p>
</body>
</html>
''',
  );
  add(
    'OEBPS/ch2.xhtml',
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<body>
<h1>The jugs</h1>
<p>Dr. Smith saw Mr. Jones. They agreed it was fine.</p>
</body>
</html>
''',
  );

  return ZipEncoder().encodeBytes(archive);
}

/// An EPUB from its parts: [files] by path (a String is stored as UTF-8,
/// a List<int> as it is), with the mimetype and a container pointing at
/// [opfPath] added.
Uint8List epubOf(Map<String, Object> files, {String opfPath = 'OEBPS/content.opf'}) {
  final archive = Archive();
  archive.addFile(ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')));
  archive.addFile(ArchiveFile.bytes(
    'META-INF/container.xml',
    utf8.encode('<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>'),
  ));
  for (final e in files.entries) {
    final v = e.value;
    archive.addFile(ArchiveFile.bytes(e.key, v is String ? utf8.encode(v) : v as List<int>));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// A package document: [items] are (id, href, media type, properties),
/// [spine] the ids in order ("id|no" for linear="no"); [meta] goes into its
/// metadata as it is.
String opfOf(
  List<(String, String, String, String?)> items,
  List<String> spine, {
  String title = 'Test Book',
  String? toc,
  String meta = '',
}) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title><dc:language>en</dc:language><dc:identifier id="id">x</dc:identifier>
    $meta
  </metadata>
  <manifest>
${[for (final (id, href, type, props) in items) '    <item id="$id" href="$href" media-type="$type"${props == null ? '' : ' properties="$props"'}/>'].join('\n')}
  </manifest>
  <spine${toc == null ? '' : ' toc="$toc"'}>
${[for (final s in spine) s.endsWith('|no') ? '    <itemref idref="${s.substring(0, s.length - 3)}" linear="no"/>' : '    <itemref idref="$s"/>'].join('\n')}
  </spine>
</package>''';

/// An XHTML document with [body].
String xhtml(String body, {String title = ''}) => '<?xml version="1.0" encoding="UTF-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>$title</title></head><body>$body</body></html>';

/// A chapter long enough to count as one.
String chapterText(String name) =>
    '<p>$name begins here, and goes on for long enough that it is a chapter worth reading aloud.</p>'
    '<p>A second paragraph of $name follows the first.</p>';
