import 'dart:io';

import 'package:flutter/services.dart';

/// The reader's own fonts: TrueType or OpenType files added from the
/// phone, kept in the library's `fonts` folder (so a backup carries them),
/// and one of them on the page as BookFont.own.
///
/// Flutter learns a font from its bytes at run time (FontLoader); each file
/// gets a family name of its own, so a font changed for another never
/// shows the first one's letters from a cache.
class OwnFonts {
  OwnFonts._();

  /// The family the page uses for BookFont.own: the chosen font, once
  /// loaded. Null until then (the page falls back to the phone's serif).
  static String? family;

  /// The file whose letters [family] holds.
  static String? _loaded;
  static var _next = 0;

  /// The folder in [libraryRoot] the fonts are kept in.
  static Directory dirIn(String libraryRoot) => Directory('$libraryRoot/fonts');

  /// The fonts kept, by file name, in alphabetical order.
  static Future<List<String>> list(String libraryRoot) async {
    final dir = dirIn(libraryRoot);
    if (!await dir.exists()) return const [];
    final names = [
      await for (final f in dir.list())
        if (f is File && isFontName(f.path)) f.uri.pathSegments.last,
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// A font's name as the reader sees it: its file's, without the ending.
  static String label(String file) {
    final dot = file.lastIndexOf('.');
    return (dot > 0 ? file.substring(0, dot) : file).replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

  static bool isFontName(String path) => RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false).hasMatch(path);

  /// Whether [bytes] begin as a font Flutter can draw: TrueType, OpenType
  /// or a collection of them. A web font (WOFF, WOFF2) does not.
  static bool isFont(Uint8List bytes) {
    if (bytes.length < 12) return false;
    final tag = String.fromCharCodes(bytes.sublist(0, 4));
    if (tag == 'OTTO' || tag == 'true' || tag == 'ttcf') return true;
    return bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0;
  }

  /// Keep the font at [path] (a picked file, named [name]) among the
  /// reader's: its file name there, or null when it is not a font.
  static Future<String?> add(String libraryRoot, String path, String name) async {
    final bytes = await File(path).readAsBytes();
    if (!isFont(bytes)) return null;
    final dir = dirIn(libraryRoot);
    await dir.create(recursive: true);
    // Its own name, made safe, ending as what it is.
    var base = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ').trim();
    if (base.isEmpty) base = 'Font';
    if (!isFontName(base)) base = '$base.${String.fromCharCodes(bytes.sublist(0, 4)) == 'OTTO' ? 'otf' : 'ttf'}';
    await File('${dir.path}/$base').writeAsBytes(bytes, flush: true);
    return base;
  }

  /// Forget the font [file].
  static Future<void> remove(String libraryRoot, String file) async {
    final f = File('${dirIn(libraryRoot).path}/$file');
    if (await f.exists()) await f.delete();
    if (_loaded == file) {
      _loaded = null;
      family = null;
    }
  }

  /// Make [file] the font BookFont.own draws with. False when it cannot be
  /// read (gone, or not a font after all): the page then falls back.
  static Future<bool> use(String libraryRoot, String? file) async {
    if (file == null) {
      _loaded = null;
      family = null;
      return false;
    }
    if (file == _loaded && family != null) return true;
    try {
      final bytes = await File('${dirIn(libraryRoot).path}/$file').readAsBytes();
      if (!isFont(bytes)) return false;
      final name = 'TomeVoiceOwn${_next++}';
      final loader = FontLoader(name)..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loaded = file;
      family = name;
      return true;
    } on Object {
      return false;
    }
  }
}
