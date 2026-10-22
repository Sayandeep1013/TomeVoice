import 'dart:typed_data';

import '../model.dart';
import 'text.dart';

/// Rich Text Format. A small tokeniser rather than a full reader: it keeps the
/// text, paragraph breaks and `\uN` / `\'hh` characters, and drops the font
/// tables, pictures, headers and other destinations nobody wants read aloud.
Book parseRtf(Uint8List bytes, {required String id, String? filename}) =>
    parseTextString(
      rtfToText(String.fromCharCodes(bytes)),
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

String rtfToText(String rtf) {
  final out = StringBuffer();
  // Per group: is it skipped, and how many chars follow \uN (\ucN).
  final skip = <bool>[false];
  final uc = <int>[1];
  var pendingSkip = 0;
  var i = 0;
  final n = rtf.length;

  void emit(int code) {
    if (skip.last) return;
    if (pendingSkip > 0) {
      pendingSkip--;
      return;
    }
    out.writeCharCode(code);
  }

  while (i < n) {
    final c = rtf.codeUnitAt(i);
    if (c == 0x7B) {
      // {
      skip.add(skip.last);
      uc.add(uc.last);
      i++;
      // {\* ...} is an ignorable destination.
      if (i + 1 < n && rtf.codeUnitAt(i) == 0x5C && rtf.codeUnitAt(i + 1) == 0x2A) {
        skip[skip.length - 1] = true;
      }
      continue;
    }
    if (c == 0x7D) {
      // }
      if (skip.length > 1) {
        skip.removeLast();
        uc.removeLast();
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
        if (v != null) emit(decodeCp1252([v]).codeUnitAt(0));
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
      }
      continue;
    }
    if (c == 0x0A || c == 0x0D) {
      i++;
      continue;
    }
    emit(c);
    i++;
  }
  return out.toString();
}

bool _isAlpha(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
bool _isDigit(int c) => c >= 48 && c <= 57;
