import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'prefs.dart';
import 'theme.dart';

/// Whether book colours are on (Settings → Appearance).
bool get bookColoursOn => ListeningPrefs.loaded?.bookColours ?? true;

/// A book's colour, taken from its cover the way Android takes a wallpaper's:
/// the cover shrunk to 112 px, its pixels grouped into at most 128 colours
/// (Material's Celebi quantizer), and the one that would make the best accent
/// chosen (Material's scoring: colourful and common enough). 0 when the cover
/// is too grey to give one, or cannot be read.
Future<int> coverTint(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 112);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return 0;
    return await compute(seedFromRgba, data.buffer.asUint8List());
  } on Object {
    return 0;
  }
}

/// The accent seed of an RGBA picture; see [coverTint].
@visibleForTesting
Future<int> seedFromRgba(Uint8List rgba) async {
  final pixels = <int>[
    for (var i = 0; i + 3 < rgba.length; i += 4)
      if (rgba[i + 3] == 255) 0xFF000000 | rgba[i] << 16 | rgba[i + 1] << 8 | rgba[i + 2],
  ];
  if (pixels.isEmpty) return 0;
  final quantized = await QuantizerCelebi().quantize(pixels, 128);
  final seed = Score.score(quantized.colorToCount, desired: 1, fallbackColorARGB: 0).first;
  if (seed == 0 || Hct.fromInt(seed).chroma < 12) return 0;
  return seed;
}

/// Book colours, worked out once per cover and kept in `tints.json`.
///
/// Keyed by the cover's path, so a new cover (or a restored library in
/// another folder) simply gets a new entry; and by book, so a screen knows
/// its book's colour on its first frame, before it has looked up the cover.
class TintCache {
  TintCache._();

  static final instance = TintCache._();

  /// Bumped whenever a book's colour is learnt or changes.
  final changes = ValueNotifier<int>(0);

  File? _file;
  final _covers = <String, int>{};
  final _books = <String, int>{};
  final _pending = <String, Future<int>>{};
  Future<void> _queue = Future<void>.value();
  Timer? _saveTimer;

  Future<void> attach(Directory root) async {
    _file = File('${root.path}/tints.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString()) as Map;
        for (final e in (raw['covers'] as Map? ?? const {}).entries) {
          _covers[e.key as String] = e.value as int;
        }
        for (final e in (raw['books'] as Map? ?? const {}).entries) {
          _books[e.key as String] = e.value as int;
        }
      }
    } on Object {
      // Worked out again as covers are shown.
    }
  }

  /// The colour last known for [bookId]: null when not yet worked out, 0
  /// when it has none (a drawn or grey cover).
  int? forBook(String bookId) => _books[bookId];

  /// Work out [bookId]'s colour from [cover] (its shown picture; null for a
  /// drawn cover). Covers are read one at a time, so a shelf of new books
  /// does not decode twenty pictures at once.
  Future<int> resolve(String bookId, String? cover) async {
    if (cover == null) {
      _setBook(bookId, 0);
      return 0;
    }
    final known = _covers[cover];
    if (known != null) {
      _setBook(bookId, known);
      return known;
    }
    final tint = await (_pending[cover] ??= _enqueue(cover));
    _pending.remove(cover);
    _covers[cover] = tint;
    _setBook(bookId, tint);
    return tint;
  }

  Future<int> _enqueue(String cover) {
    final done = Completer<int>();
    _queue = _queue.then((_) async => done.complete(await coverTint(cover)));
    return done.future;
  }

  void _setBook(String id, int tint) {
    if (_books[id] == tint) return;
    _books[id] = tint;
    changes.value++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        await _file?.writeAsString(jsonEncode({'covers': _covers, 'books': _books}));
      } on Object {
        // Saved with the next change.
      }
    });
  }
}

/// [child] in the colours of book [bookId]: its accent everywhere below,
/// through [Skin.accentOf] and the Material theme (sliders, switches,
/// buttons). [cover] is its shown picture, when known; the colour is worked
/// out from it the first time.
class BookTint extends StatefulWidget {
  const BookTint({super.key, required this.bookId, this.cover, required this.child});

  final String bookId;
  final String? cover;
  final Widget child;

  @override
  State<BookTint> createState() => _BookTintState();
}

class _BookTintState extends State<BookTint> {
  final _cache = TintCache.instance;

  @override
  void initState() {
    super.initState();
    _cache.changes.addListener(_changed);
    _resolve();
  }

  @override
  void didUpdateWidget(BookTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover || oldWidget.bookId != widget.bookId) _resolve();
  }

  @override
  void dispose() {
    _cache.changes.removeListener(_changed);
    super.dispose();
  }

  void _resolve() {
    // Without a cover path the book may still be loading; keep what is known.
    final cover = widget.cover;
    if (cover != null) unawaited(_cache.resolve(widget.bookId, cover));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => tinted(context, _cache.forBook(widget.bookId), widget.child);
}

/// [child] with the accent of [tint] (a cover colour), or as it is when
/// there is none or book colours are off.
Widget tinted(BuildContext context, int? tint, Widget child) {
  if (tint == null || tint == 0 || !bookColoursOn) return child;
  final palette = Skin.palette.withTint(tint);
  return TintScope(
    palette: palette,
    child: Theme(data: Skin.themeFor(palette, Theme.of(context).brightness), child: child),
  );
}

/// [child] in the colours of the screen at [from]. For sheets and dialogs:
/// they open above the screen, outside its [BookTint].
Widget carryTint(BuildContext from, Widget child) {
  final scope = from.getInheritedWidgetOfExactType<TintScope>();
  if (scope == null) return child;
  return TintScope(palette: scope.palette, child: Theme(data: Theme.of(from), child: child));
}
