import 'dart:typed_data';

import '../encoding.dart';
import '../model.dart';
import 'text.dart';

/// Rich Text Format. A small tokeniser rather than a full reader: it keeps the
/// text, paragraph breaks and `\uN` / `\'hh` characters, and drops the font
/// tables, pictures, headers and other destinations nobody wants read aloud.
Book parseRtf(Uint8List bytes, {required String id, String? filename, LegacyDecoder? legacy}) =>
    parseTextString(
      rtfToText(String.fromCharCodes(bytes), legacy: legacy),
      id: id,
      filename: filename,
      kind: SourceKind.rtf,
    );

const _skipDestinations = {
  'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'header', 'footer',
  'headerl', 'headerr', 'headerf', 'footerl', 'footerr', 'footerf',
  'listtable', 'listoverridetable', 'rsidtbl', 'generator', 'themedata',
  'colorschememapping', 'datastore', 'latentstyles', 'xmlnstbl', 'object',
  'fldinst', 'footnote', 'annotation', 'shp', 'shpinst', 'nonshppict',
  'filetbl', 'revtbl', 'pgdsctbl', 'bkmkstart', 'bkmkend',
};

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

/// Text out of RTF. `\'hh` bytes are in the document's code page
/// (`\ansicpgN`) or, after a font switch, that font's (`\fcharsetN`): a
/// Russian document from a Western Windows says `\ansicpg1252` and sets its
/// Cyrillic fonts to charset 204. Double-byte code pages (932, 936, 949,
/// 950) go through [legacy].
String rtfToText(String rtf, {LegacyDecoder? legacy}) {
  final out = StringBuffer();
  // Per group: is it skipped, how many chars follow \uN (\ucN), the font.
  final skip = <bool>[false];
  final uc = <int>[1];
  final font = <int>[-1];
  final fontPages = <int, int>{};
  var page = 1252;
  var defining = -1;
  var pendingSkip = 0;
  // Bytes waiting to be decoded together (a double-byte character is two).
  final bytes = <int>[];
  var i = 0;
  final n = rtf.length;

  void flush() {
    if (bytes.isEmpty) return;
    final charset = _charsetOfPage(fontPages[font.last] ?? page);
    final data = Uint8List.fromList(bytes);
    bytes.clear();
    out.write(legacyCharsets.contains(charset)
        ? decodeBytes(data, declared: charset, legacy: legacy)
        : charset == 'utf-8'
            ? decodeBytes(data, declared: charset)
            : decodeSingleByte(data, charset));
  }

  bool skipped() {
    if (skip.last) return true;
    if (pendingSkip > 0) {
      pendingSkip--;
      return true;
    }
    return false;
  }

  void emit(int code) {
    if (skipped()) return;
    flush();
    out.writeCharCode(code);
  }

  void emitByte(int b) {
    if (!skipped()) bytes.add(b);
  }

  while (i < n) {
    final c = rtf.codeUnitAt(i);
    if (c == 0x7B) {
      // {
      flush();
      skip.add(skip.last);
      uc.add(uc.last);
      font.add(font.last);
      i++;
      // {\* ...} is an ignorable destination.
      if (i + 1 < n && rtf.codeUnitAt(i) == 0x5C && rtf.codeUnitAt(i + 1) == 0x2A) {
        skip[skip.length - 1] = true;
      }
      continue;
    }
    if (c == 0x7D) {
      // }
      flush();
      if (skip.length > 1) {
        skip.removeLast();
        uc.removeLast();
        font.removeLast();
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
        skip[skip.length - 1] = true;
        continue;
      }
      switch (word) {
        case 'par':
        case 'line':
        case 'sect':
        case 'page':
          flush();
          if (!skip.last) out.write('\n\n');
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
  return out.toString();
}

bool _isAlpha(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
bool _isDigit(int c) => c >= 48 && c <= 57;
