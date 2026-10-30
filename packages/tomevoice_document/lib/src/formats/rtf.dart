import 'dart:typed_data';

import '../build.dart';
import '../encoding.dart';
import '../model.dart';
import '../segment.dart';
import 'text.dart';

/// Rich Text Format. A small tokeniser rather than a full reader: it keeps the
/// text, paragraph breaks and `\uN` / `\'hh` characters, and drops the font
/// tables, pictures, headers and other destinations nobody wants read aloud.
/// Footnotes are notes, as in a Word document: each after the paragraph that
/// points at it (endnotes at the end), shown and not read, its mark shown
/// and not said. The title and author in `\info` name the book.
Book parseRtf(Uint8List bytes, {required String id, String? filename, LegacyDecoder? legacy}) {
  final rtf = readRtf(String.fromCharCodes(bytes), legacy: legacy);
  final book = parseTextString(
    rtf.text,
    id: id,
    filename: filename,
    kind: SourceKind.rtf,
    title: rtf.title,
    author: rtf.author,
    marked: true,
  );
  return rtf.notes.isEmpty ? book : _withNotes(book, rtf.notes);
}

/// One note of an RTF file: its paragraphs (the first opened by its own
/// mark, silent), whether it is an endnote, and whether a mark in the text
/// points at it.
typedef RtfNote = ({List<String> paragraphs, bool end, bool marked});

/// What an RTF file holds: its text, a blank line between paragraphs, with
/// the marks of its notes silent (see [silentMark]); its notes, in the order
/// they come; and the title and author its `\info` gives.
typedef RtfText = ({String text, List<RtfNote> notes, String? title, String? author});

/// [book] with [notes] as footnotes: each after the block that holds the
/// mark pointing at it, the marks counted in order; endnotes, and notes no
/// mark points at, at the end.
Book _withNotes(Book book, List<RtfNote> notes) {
  List<Block> blocksOf(RtfNote n) => [for (final p in n.paragraphs) makeBlock(role: BlockRole.footnote, text: p)];
  var next = 0;
  final atEnd = <RtfNote>[];
  final sections = <Section>[];
  for (final s in book.sections) {
    final blocks = <Block>[];
    for (final b in s.blocks) {
      blocks.add(b);
      var marks = b.sentences.fold<int>(0, (n, x) => n + x.silent.length);
      while (marks > 0 && next < notes.length) {
        final n = notes[next++];
        if (!n.marked) {
          atEnd.add(n);
          continue;
        }
        marks--;
        if (n.end) {
          atEnd.add(n);
        } else {
          blocks.addAll(blocksOf(n));
        }
      }
    }
    sections.add(Section(id: s.id, index: s.index, title: s.title, href: s.href, blocks: blocks));
  }
  atEnd.addAll(notes.skip(next));
  if (sections.isNotEmpty) sections.last.blocks.addAll([for (final n in atEnd) ...blocksOf(n)]);
  final out = book.copyWith(sections: sections);
  return out.copyWith(wordCount: wordCountOf(out));
}

const _skipDestinations = {
  'fonttbl', 'colortbl', 'stylesheet', 'pict', 'header', 'footer',
  'headerl', 'headerr', 'headerf', 'footerl', 'footerr', 'footerf',
  'listtable', 'listoverridetable', 'rsidtbl', 'generator', 'themedata',
  'colorschememapping', 'datastore', 'latentstyles', 'xmlnstbl', 'object',
  'fldinst', 'annotation', 'shp', 'shpinst', 'nonshppict',
  'filetbl', 'revtbl', 'pgdsctbl', 'bkmkstart', 'bkmkend',
};

// Where a group's text goes: the book's text, nowhere, a note, the \info
// group (nowhere, but its title and author are kept), its title, its author.
const _text = 0, _nowhere = 1, _note = 2, _info = 3, _title = 4, _author = 5;

/// Noncharacters TomeVoice uses inside its own pipeline; never book text.
final _ownMarks = RegExp('[${String.fromCharCode(0xFDD0)}-${String.fromCharCode(0xFDD2)}]');

/// `\fcharsetN` of a font -> the code page its `\'hh` bytes are in.
const _fontCharsets = {
  0: 1252, 77: 10000, 128: 932, 129: 949, 130: 949, 134: 936, 136: 950,
  161: 1253, 162: 1254, 163: 1258, 177: 1255, 178: 1256, 186: 1257,
  204: 1251, 222: 874, 238: 1250,
};

/// A Windows code page number as an encoding name [decodeBytes] knows.
String _charsetOfPage(int page) => switch (page) {
      >= 1250 && <= 1258 || 874 => 'windows-$page',
      10000 => 'macintosh',
      866 => 'ibm866',
      20866 => 'koi8-r',
      21866 => 'koi8-u',
      932 => 'Shift_JIS',
      936 || 54936 => 'GB18030',
      949 => 'EUC-KR',
      950 => 'Big5',
      65001 => 'utf-8',
      >= 28592 && <= 28605 => charsetOf('iso-8859-${page - 28590}') ?? 'windows-1252',
      _ => 'windows-1252',
    };

/// The text, notes and \info of RTF (see [RtfText]). `\'hh` bytes are in the
/// document's code page (`\ansicpgN`) or, after a font switch, that font's
/// (`\fcharsetN`): a Russian document from a Western Windows says
/// `\ansicpg1252` and sets its Cyrillic fonts to charset 204. Double-byte
/// code pages (932, 936, 949, 950) go through [legacy].
///
/// A note's mark is Word's `\chftn` (the note's number) or, for a mark of
/// the writer's own ("*"), the raised run right before the note.
RtfText readRtf(String rtf, {LegacyDecoder? legacy}) {
  final text = StringBuffer();
  var note = StringBuffer();
  final title = StringBuffer();
  final author = StringBuffer();
  // Per group: where its text goes, how many chars follow \uN (\ucN), the
  // font, and whether it is set raised (\super).
  final dest = <int>[_text];
  final uc = <int>[1];
  final font = <int>[-1];
  final raised = <bool>[false];
  final fontPages = <int, int>{};
  var page = 1252;
  var defining = -1;
  var pendingSkip = 0;
  // Bytes waiting to be decoded together (a double-byte character is two).
  final bytes = <int>[];
  // The notes, the marks in the text that point at them, and the last run
  // of the text set raised: a note's mark when the note comes right after.
  final notes = <RtfNote>[];
  final marks = <({int start, int end})>[];
  var raisedFrom = -1, raisedTo = -1;
  var endnote = false;
  var noteMarked = false;
  var i = 0;
  final n = rtf.length;

  StringBuffer? sink() => switch (dest.last) {
        _text => text,
        _note => note,
        _title => title,
        _author => author,
        _ => null,
      };

  void write(String s) {
    final to = sink();
    if (to == null || s.isEmpty) return;
    if (to != text) {
      to.write(s.replaceAll(_ownMarks, ''));
      return;
    }
    if (raised.last && raisedTo != text.length) raisedFrom = text.length;
    text.write(s.replaceAll(_ownMarks, ''));
    if (raised.last) raisedTo = text.length;
  }

  void flush() {
    if (bytes.isEmpty) return;
    final charset = _charsetOfPage(fontPages[font.last] ?? page);
    final data = Uint8List.fromList(bytes);
    bytes.clear();
    write(legacyCharsets.contains(charset)
        ? decodeBytes(data, declared: charset, legacy: legacy)
        : charset == 'utf-8'
            ? decodeBytes(data, declared: charset)
            : decodeSingleByte(data, charset));
  }

  bool skipped() {
    if (sink() == null) return true;
    if (pendingSkip > 0) {
      pendingSkip--;
      return true;
    }
    return false;
  }

  void emit(int code) {
    if (skipped()) return;
    flush();
    write(String.fromCharCode(code));
  }

  void emitByte(int b) {
    if (!skipped()) bytes.add(b);
  }

  void endNote() {
    final paragraphs = [
      for (final p in note.toString().split(_blankLine))
        if (collapseWhitespace(p).isNotEmpty) collapseWhitespace(p),
    ];
    if (paragraphs.isNotEmpty) notes.add((paragraphs: paragraphs, end: endnote, marked: noteMarked));
    note = StringBuffer();
    endnote = false;
  }

  while (i < n) {
    final c = rtf.codeUnitAt(i);
    if (c == 0x7B) {
      // {
      flush();
      dest.add(dest.last == _info ? _info : dest.last);
      uc.add(uc.last);
      font.add(font.last);
      raised.add(raised.last);
      i++;
      // {\* ...} is an ignorable destination.
      if (i + 1 < n && rtf.codeUnitAt(i) == 0x5C && rtf.codeUnitAt(i + 1) == 0x2A) {
        if (dest.last != _info) dest[dest.length - 1] = _nowhere;
      }
      continue;
    }
    if (c == 0x7D) {
      // }
      flush();
      if (dest.length > 1) {
        if (dest.last == _note && dest[dest.length - 2] != _note) endNote();
        dest.removeLast();
        uc.removeLast();
        font.removeLast();
        raised.removeLast();
      }
      i++;
      continue;
    }
    if (c == 0x5C) {
      // backslash
      i++;
      if (i >= n) break;
      final d = rtf.codeUnitAt(i);
      if (d == 0x27) {
        // \'hh
        final hex = i + 2 < n ? rtf.substring(i + 1, i + 3) : '';
        final v = int.tryParse(hex, radix: 16);
        if (v != null) emitByte(v);
        i += 3;
        continue;
      }
      if (!_isAlpha(d)) {
        // Control symbol: \\ \{ \} \~ \- \_
        if (d == 0x5C || d == 0x7B || d == 0x7D) emit(d);
        if (d == 0x7E) emit(0xA0);
        if (d == 0x5F) emit(0x2D);
        if (d == 0x0A || d == 0x0D) emit(0x0A);
        i++;
        continue;
      }
      final start = i;
      while (i < n && _isAlpha(rtf.codeUnitAt(i))) {
        i++;
      }
      final word = rtf.substring(start, i);
      final numStart = i;
      if (i < n && rtf.codeUnitAt(i) == 0x2D) i++;
      while (i < n && _isDigit(rtf.codeUnitAt(i))) {
        i++;
      }
      final param = i > numStart ? int.tryParse(rtf.substring(numStart, i)) : null;
      if (i < n && rtf.codeUnitAt(i) == 0x20) i++;

      if (_skipDestinations.contains(word)) {
        dest[dest.length - 1] = dest.last == _info ? _info : _nowhere;
        continue;
      }
      // The group's parent: where its text would go but for this word.
      final parent = dest.length > 1 ? dest[dest.length - 2] : _text;
      switch (word) {
        case 'info':
          dest[dest.length - 1] = _info;
        case 'title':
          if (parent == _info) dest[dest.length - 1] = _title;
        case 'author':
          if (parent == _info) dest[dest.length - 1] = _author;
        case 'footnote':
          flush();
          if (parent == _text) {
            dest[dest.length - 1] = _note;
            // Its mark is the run set raised right before it, if any.
            noteMarked = raisedFrom >= 0 && raisedTo == text.length;
            if (noteMarked) marks.add((start: raisedFrom, end: raisedTo));
            raisedFrom = raisedTo = -1;
          } else {
            dest[dest.length - 1] = _nowhere;
          }
        case 'ftnalt':
          if (dest.last == _note) endnote = true;
        case 'chftn':
          // The note's number, here or in the note itself.
          flush();
          if (dest.last == _text) {
            raisedFrom = text.length;
            text.write(superscriptNumber(notes.length + 1));
            raisedTo = text.length;
          } else if (dest.last == _note) {
            note.write(silentMark(superscriptNumber(notes.length + 1)));
          }
        case 'super':
          raised[raised.length - 1] = true;
        case 'up':
          raised[raised.length - 1] = (param ?? 6) > 0;
        case 'nosupersub':
        case 'sub':
        case 'dn':
        case 'plain':
          raised[raised.length - 1] = false;
        case 'par':
        case 'line':
        case 'sect':
        case 'page':
          flush();
          final to = sink();
          if (to == text || to == note) to!.write('\n\n');
          if (to == title || to == author) to!.write(' ');
        case 'tab':
        case 'cell':
          emit(0x20);
        case 'emdash':
          emit(0x2014);
        case 'endash':
          emit(0x2013);
        case 'lquote':
          emit(0x2018);
        case 'rquote':
          emit(0x2019);
        case 'ldblquote':
          emit(0x201C);
        case 'rdblquote':
          emit(0x201D);
        case 'bullet':
          emit(0x2022);
        case 'uc':
          uc[uc.length - 1] = param ?? 1;
        case 'u':
          if (param != null) {
            emit(param < 0 ? param + 65536 : param);
            pendingSkip = uc.last;
          }
        case 'ansicpg':
          if (param != null && param > 0) page = param;
        case 'mac':
          page = 10000;
        case 'pc':
        case 'pca':
          page = 437;
        case 'f':
          // In the font table \fN starts a font's definition; elsewhere it
          // switches to that font.
          flush();
          if (param != null) {
            font[font.length - 1] = param;
            defining = param;
          }
        case 'fcharset':
          final p = _fontCharsets[param];
          if (defining >= 0 && p != null) fontPages[defining] = p;
      }
      continue;
    }
    if (c == 0x0A || c == 0x0D) {
      i++;
      continue;
    }
    if (c >= 0x80) {
      // A raw byte: in the code page, like \'hh.
      emitByte(c);
    } else {
      emit(c);
    }
    i++;
  }
  flush();
  if (note.isNotEmpty) endNote();

  // The marks, silent.
  final all = text.toString();
  final out = StringBuffer();
  var at = 0;
  for (final m in marks) {
    out
      ..write(all.substring(at, m.start))
      ..write(silentMark(all.substring(m.start, m.end)));
    at = m.end;
  }
  out.write(all.substring(at));
  String? named(StringBuffer b) {
    final t = collapseWhitespace(b.toString());
    return t.isEmpty ? null : t;
  }

  return (text: out.toString(), notes: notes, title: named(title), author: named(author));
}

final _blankLine = RegExp(r'\n\s*\n');

bool _isAlpha(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
bool _isDigit(int c) => c >= 48 && c <= 57;
