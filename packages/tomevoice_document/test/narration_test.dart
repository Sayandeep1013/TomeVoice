import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'epub_fixture.dart';
import 'narration_fixture.dart';

/// The text of a book from [start] to [end].
String textOf(Book book, TextPlace start, TextPlace end) {
  final out = StringBuffer();
  for (var s = start.section; s <= end.section; s++) {
    final blocks = book.sections[s].blocks;
    for (var b = s == start.section ? start.block : 0; b < blocks.length; b++) {
      if (s == end.section && b > end.block) break;
      final t = blocks[b].text;
      final from = s == start.section && b == start.block ? start.offset : 0;
      final to = s == end.section && b == end.block ? end.offset : t.length;
      if (out.isNotEmpty) out.write(' ');
      out.write(t.substring(from, to));
    }
  }
  return out.toString();
}

void main() {
  group('SMIL clock values', () {
    test('every way of writing one', () {
      expect(parseClockValue('0:00:24.500'), 24500);
      expect(parseClockValue('1:02:03'), 3723000);
      expect(parseClockValue('124:00:00'), 124 * 3600000);
      expect(parseClockValue('02:33'), 153000);
      expect(parseClockValue('00:10.5'), 10500);
      expect(parseClockValue('12.5s'), 12500);
      expect(parseClockValue('500ms'), 500);
      expect(parseClockValue('1.5h'), 5400000);
      expect(parseClockValue('3min'), 180000);
      expect(parseClockValue('12.467'), closeTo(12467, 1e-6));
      expect(parseClockValue('.5s'), 500);
      expect(parseClockValue(' 7s '), 7000);
      expect(parseClockValue('npt=12.5s'), 12500);
    });

    test('nothing else is one', () {
      for (final bad in ['', 'abc', '12x', '1:2:3:4', '-3s', 'NaN', 'Infinity', '1e3', '12.s']) {
        expect(parseClockValue(bad), isNull, reason: bad);
      }
    });

    test('nor a time no recording runs to, which overflowed or came to Infinity', () {
      final huge = '9' * 400;
      for (final bad in ['99999999999999999999:00:00', '0:99999999999999999999:00', '${huge}s', '${huge}h', '$huge:00']) {
        expect(parseClockValue(bad), isNull, reason: bad);
      }
      expect(parseClockValue('8760:00:00'), 8760 * 3600000, reason: 'a year of audio is a time still');
    });
  });

  group('a damaged narration', () {
    /// [narratedEpub] with its SMIL files changed by [change].
    Uint8List damaged(String Function(String smil) change) {
      final out = Archive();
      for (final f in ZipDecoder().decodeBytes(narratedEpub())) {
        if (f.name.endsWith('.smil')) {
          out.addFile(ArchiveFile.bytes(f.name, utf8.encode(change(utf8.decode(f.content)))));
        } else {
          out.addFile(f);
        }
      }
      return ZipEncoder().encodeBytes(out);
    }

    test('a clock value that overflows, or comes to Infinity, leaves its clip out; the book is read', () {
      // Each refused the whole book: "int.parse" threw, and Infinity would
      // not round.
      for (final value in ['99999999999999999999:00:00', '${'9' * 400}s']) {
        final book = ingestBytes(
          damaged((smil) => smil.replaceFirst(RegExp('clipEnd="[^"]*"'), 'clipEnd="$value"')),
          filename: 'tin-box.epub',
        );
        expect(book.sections.expand((s) => s.blocks).map((b) => b.text).join(' '), contains('The box was made of tin'));
        expect(book.narration!.clips, hasLength(lessThan(10)), reason: value);
      }
    });
  });

  group('SMIL pars', () {
    String resolve(String dir, String href) => zipJoin(dir, Uri.decodeComponent(href));

    test('in order, through nested seqs, "#id" in the document its textref names', () {
      final pars = smilPars(
        '<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '<seq epub:textref="../t/a.xhtml"><par><text src="#x1"/><audio src="../s/a.mp3" clipBegin="1s" clipEnd="2s"/></par>'
        '<seq epub:textref="../t/b.xhtml#part"><par><text src="#y1"/><audio src="../s/b.mp3" clipEnd="00:03"/></par></seq>'
        '<par><text src="../t/a.xhtml#x2"/><audio src="../s/a.mp3" clipBegin="2s" clipEnd="3s"/></par></seq>'
        '</body></smil>',
        smilPath: 'OEBPS/smil/a.smil',
        resolve: resolve,
      );
      expect([for (final p in pars) '${p.text}#${p.fragment} ${p.audio} ${p.beginMs}-${p.endMs}'], [
        'OEBPS/t/a.xhtml#x1 OEBPS/s/a.mp3 1000.0-2000.0',
        'OEBPS/t/b.xhtml#y1 OEBPS/s/b.mp3 0.0-3000.0',
        'OEBPS/t/a.xhtml#x2 OEBPS/s/a.mp3 2000.0-3000.0',
      ]);
    });

    test('pars that cannot be played from the book are left out', () {
      final pars = smilPars(
        '<smil xmlns="http://www.w3.org/ns/SMIL"><body>'
        '<par><text src="a.xhtml#t"/></par>'
        '<par><text src="a.xhtml#epubcfi(/4/2)"/><audio src="a.mp3"/></par>'
        '<par><text src="a.xhtml#u"/><audio src="https://example.com/a.mp3"/></par>'
        '<par><text src="a.xhtml#v"/><audio src="a.mp3" clipBegin="3s" clipEnd="2s"/></par>'
        '<par><text src="a.xhtml#w"/><audio src="a.mp3" clipBegin="3s" clipEnd="later"/></par>'
        '<par><text src="a.xhtml#ok"/><audio src="a.mp3" clipBegin="3s"/></par>'
        '</body></smil>',
        smilPath: 'a.smil',
        resolve: resolve,
      );
      expect([for (final p in pars) '${p.fragment} ${p.endMs}'], ['ok null']);
    });

    test('a file that is not XML has none', () {
      expect(smilPars('<smil><body><par>', smilPath: 'a.smil', resolve: resolve), isEmpty);
    });
  });

  group('an EPUB with its own narration', () {
    final book = ingestBytes(narratedEpub(), filename: 'tin-box.epub');
    final narration = book.narration!;

    test('every clip is found where its text is', () {
      expect(narration.audio, ['OEBPS/audio/one.wav', 'OEBPS/audio/two.wav', 'OEBPS/audio/three.wav']);
      expect([for (final c in narration.clips) textOf(book, c.start, c.end)], [
        'Chapter One',
        'The box was made of tin',
        'It sat on a shelf by the door',
        'Nobody had opened it for years',
        'She lifted the lid. Inside lay a key',
        'The key was cold',
        'Chapter Three',
        'When she turned it',
        'the box began to sing',
        'It sang until morning',
      ]);
      expect([for (final c in narration.clips) '${c.audio} ${c.beginMs}-${c.endMs}'], [
        '0 0-1200',
        '0 1200-3000',
        '0 3000-5500',
        '0 5800-8000',
        '1 500-6500',
        '1 7250-9500',
        '2 0-1500',
        '2 1500-3600',
        '2 3600-5760',
        '2 6000-null',
      ]);
    });

    test('is kept with the book', () {
      final again = Book.fromJson(jsonDecode(jsonEncode(book.toJson())) as Map<String, Object?>);
      expect(jsonEncode(again.narration!.toJson()), jsonEncode(narration.toJson()));
      expect(again.narration!.clips.last.endMs, isNull);
    });

    test('the text is read as it would be without one', () {
      final plain = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('title', 'title.xhtml', 'application/xhtml+xml', null),
            ('c1', 'text/ch1.xhtml', 'application/xhtml+xml', null),
          ], ['title', 'c1']),
          'OEBPS/title.xhtml': xhtml('<h1>The Tin Box</h1><p>A story read aloud, with its own recording.</p>'),
          'OEBPS/text/ch1.xhtml': xhtml('<h1 id="h1">Chapter One</h1>'
              '<p id="p1"><span id="s1">The box was made of tin.</span> <span id="s2">It sat on a shelf by the door.</span></p>'
              '<p id="p2"><span id="s3">Nobody had opened it for years.</span></p>'),
        }),
        filename: 'plain.epub',
      );
      expect(plain.narration, isNull);
      expect(plain.toJson().containsKey('narration'), isFalse);
      String texts(Book b, int sections) =>
          [for (final s in b.sections.take(sections)) for (final x in s.blocks) x.text].join('|');
      expect(texts(book, 2), texts(plain, 2));
    });
  });

  group('the narration laid over the units', () {
    final book = ingestBytes(narratedEpub(), filename: 'tin-box.epub');
    final layout = ReadingLayout.build(book);
    final plan = NarrationPlan.of(layout)!;
    int unit(String starts) => layout.units.indexWhere((u) => u.text.startsWith(starts));
    String roleOf(String starts) => plan.roles[unit(starts)].name;

    test('a clip a sentence gives each its own, whole', () {
      for (final (text, clip) in [('Chapter One', 0), ('The box', 1), ('It sat', 2), ('Nobody', 3)]) {
        final p = plan.pieces[unit(text)];
        expect(p, hasLength(1), reason: text);
        expect((p.single.clip, p.single.from, p.single.to), (clip, 0.0, 1.0), reason: text);
      }
    });

    test('a clip a paragraph is shared by its sentences, by their letters', () {
      final a = plan.pieces[unit('She lifted')].single;
      final b = plan.pieces[unit('Inside lay')].single;
      expect(a.clip, 4);
      expect(b.clip, 4);
      // "She lifted the lid." has 15 letters, "Inside lay a key." 13.
      expect(a.from, 0);
      expect(a.to, closeTo(15 / 28, 1e-9));
      expect(b.from, closeTo(15 / 28, 1e-9));
      expect(b.to, 1);
      expect(plan.cuts[4], [closeTo(15 / 28, 1e-9)]);
      expect(plan.cuts.keys, [4]);
    });

    test('a sentence said in two clips gets both, where each falls in it', () {
      final u = unit('When she turned');
      final text = layout.units[u].text;
      final p = plan.pieces[u];
      expect([for (final x in p) x.clip], [7, 8]);
      expect([for (final x in p) text.substring(x.start, x.end)], ['When she turned it', 'the box began to sing']);
      expect([for (final x in p) (x.from, x.to)], [(0.0, 1.0), (0.0, 1.0)]);
    });

    test('lines it leaves out are passed over; what is outside it is read by the voice', () {
      expect(roleOf('Chapter One'), 'recorded');
      expect(roleOf('A line the narrator'), 'passed');
      expect(roleOf('Chapter Two'), 'voiced');
      expect(roleOf('The key was cold'), 'recorded');
      expect(roleOf('It sang until'), 'recorded');
      final title = unit('A story read aloud');
      if (title >= 0) expect(plan.roles[title], NarrationRole.voiced);
    });

    test('a book without one has no plan', () {
      expect(NarrationPlan.of(ReadingLayout.build(ingestBytes(minimalEpub(), filename: 'fox.epub'))), isNull);
    });
  });

  group('finding what a clip says', () {
    final blocks = [
      (section: 0, block: 0, text: 'The first one. The second, “quoted” one!'),
      (section: 0, block: 1, text: 'A third, much longer sentence that goes on.'),
    ];

    test('by its letters, whatever its spaces and marks', () {
      final found = locateTexts(blocks, ['The  first one.', 'The second "quoted" one', 'a third']);
      expect([for (final f in found) f == null ? null : '${f.$1.block}:${f.$1.offset}-${f.$2.block}:${f.$2.offset}'],
          ['0:0-0:13', '0:15-0:39', '1:0-1:7']);
    });

    test('one not found takes the text between its neighbours', () {
      final found = locateTexts(blocks, ['The first one', 'something else entirely', 'a third, much longer sentence that goes on']);
      expect(found[1], isNotNull);
      expect('${found[1]!.$1.offset}-${found[1]!.$2.block}:${found[1]!.$2.offset}', '15-0:39');
    });

    test('a short text far from where the last one was is not taken', () {
      final found = locateTexts([
        (section: 0, block: 0, text: 'One. ${'Words that go on. ' * 300}Yes.'),
      ], ['One', 'yes']);
      expect(found[0], isNotNull);
      expect(found[1], isNull);
    });

    test('no text is the whole document', () {
      final found = locateTexts(blocks, [null]);
      expect('${found.single!.$1.block}:${found.single!.$1.offset}-${found.single!.$2.block}:${found.single!.$2.offset}',
          '0:0-1:42');
    });
  });
}
