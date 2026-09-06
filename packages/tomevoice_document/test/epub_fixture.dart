import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A tiny valid EPUB 2 for tests. Two spine chapters, a heading, a footnote.
Uint8List minimalEpub({
  String title = 'Fox Book',
  String author = 'Aesop',
  String language = 'en',
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
    add('META-INF/encryption.xml', '<encryption/>');
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
