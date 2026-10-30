import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;

import 'contrast.dart';
import 'prefs.dart';
import 'theme.dart';

/// The reader's own colours: a page and an accent, and the text if they
/// chose it. They are made into a palette that always reads (see
/// [OwnColours.made]): what cannot is moved, as little as it takes.
@immutable
class OwnColours {
  const OwnColours({required this.page, required this.accent, this.ink});

  final Color page;
  final Color accent;

  /// Null for text made to suit the page.
  final Color? ink;

  /// Where a reader starts: Paper's page and Forest's amber.
  static const start = OwnColours(page: Color(0xFFF3EBDD), accent: Color(0xFFE07B39));

  /// The colours kept in [prefs], or where a reader starts.
  static OwnColours of(ListeningPrefs prefs) => OwnColours(
        page: prefs.ownPage == null ? start.page : Color(prefs.ownPage!),
        accent: prefs.ownAccent == null ? start.accent : Color(prefs.ownAccent!),
        ink: prefs.ownInk == null ? null : Color(prefs.ownInk!),
      );

  void saveTo(ListeningPrefs prefs) {
    prefs.ownPage = page.toARGB32();
    prefs.ownAccent = accent.toARGB32();
    prefs.ownInk = ink?.toARGB32();
  }

  OwnColours withPage(Color c) => OwnColours(page: c, accent: accent, ink: ink);
  OwnColours withAccent(Color c) => OwnColours(page: page, accent: c, ink: ink);
  OwnColours withInk(Color? c) => OwnColours(page: page, accent: accent, ink: c);

  /// The page is light (the palette is shown by day), or dark.
  bool get light => Hct.fromInt(page.toARGB32()).tone >= 50;

  String get key => [page, accent, ink].map((c) => c == null ? 'auto' : colourToHex(c.toARGB32()).substring(1)).join('.');

  /// What these colours make, worked out once each.
  OwnPalette get made {
    final known = _made[key];
    if (known != null) return known;
    // A drag along a bar makes new colours on every frame: only the latest
    // are worth keeping.
    if (_made.length > 64) _made.clear();
    return _made[key] = _make(this);
  }

  static final _made = <String, OwnPalette>{};

  @override
  bool operator ==(Object other) => other is OwnColours && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The palette the reader's colours make, and what had to give for it to
/// read, for the editor to say so.
@immutable
class OwnPalette {
  const OwnPalette(this.palette, {this.page, this.ink, this.accent});

  final Palette palette;

  /// The page used when the chosen one cannot be read on: the nearest shade
  /// of it that can.
  final Color? page;

  /// The text as made to read, when the chosen text had to move.
  final Color? ink;

  /// The accent as made to show on a dark page, when the chosen one had to
  /// move.
  final Color? accent;

  bool get adjusted => page != null || ink != null || accent != null;
}

OwnPalette _make(OwnColours c) {
  var p = readable(_palette(c));
  Color? page;
  if (unmetNeeds(p).isNotEmpty) {
    // Text cannot read on this page at any tone: the nearest shade of it
    // that it can, lighter or darker.
    page = _nearestReadablePage(c);
    p = readable(_palette(c.withPage(page)));
  }
  final b = p.only ?? Brightness.light;
  final ink = c.ink;
  return OwnPalette(
    p,
    page: page,
    ink: ink != null && p.inkFor(b) != ink ? p.inkFor(b) : null,
    accent: p.accent != c.accent ? p.accent : null,
  );
}

/// The page of [c]'s hue at the tone nearest its own on which everything
/// reads: lighter pages read better by day, darker ones by night.
Color _nearestReadablePage(OwnColours c) {
  final hct = Hct.fromInt(c.page.toARGB32());
  Color at(double tone) => Color(Hct.from(hct.hue, hct.chroma, tone).toInt());
  bool reads(double tone) => unmetNeeds(readable(_palette(c.withPage(at(tone))))).isEmpty;
  // From the page's tone towards white, and towards black, the first tone
  // that reads: each way, once one does, every one beyond it does too.
  double? toward(double end) {
    if (!reads(end)) return null;
    var near = hct.tone, far = end;
    while ((far - near).abs() > 0.5) {
      final mid = (near + far) / 2;
      if (reads(mid)) {
        far = mid;
      } else {
        near = mid;
      }
    }
    return far;
  }

  final up = toward(100), down = toward(0);
  if (up == null && down == null) return OwnColours.start.page;
  if (up == null) return at(down!);
  if (down == null) return at(up);
  return at(up - hct.tone <= hct.tone - down ? up : down);
}

/// [c] as a palette, before it is made to read: the reader's page as the
/// ground (with a little light across it, as every palette has), sheets and
/// capsules from it, their accent as the fill, and the type and the
/// accent's text near where they would be.
Palette _palette(OwnColours c) {
  final page = Hct.fromInt(c.page.toARGB32());
  final light = page.tone >= 50;
  Color at(Hct h, double tone, [double? chroma]) =>
      Color(Hct.from(h.hue, chroma ?? h.chroma, tone.clamp(0, 100).toDouble()).toInt());
  final ground = light
      ? [at(page, page.tone + 3), c.page, at(page, page.tone + 2), at(page, page.tone - 2)]
      : [at(page, page.tone - 2), c.page, at(page, page.tone + 1), at(page, page.tone + 3)];
  final paleSheet = Color.lerp(c.page, Colors.white, 0.6)!;
  final deepSheet = Color.lerp(c.page, Colors.black, 0.45)!;
  // The type: the reader's, or the page's own hue all but grey; the softer
  // inks lean towards the page.
  final chosen = c.ink == null ? null : Hct.fromInt(c.ink!.toARGB32());
  final hue = chosen?.hue ?? page.hue;
  final chroma = chosen?.chroma ?? math.min(page.chroma, 8.0);
  final strong = chosen?.tone ?? (light ? 8.0 : 94.0);
  Color ink(double toward) => toward == 0 && c.ink != null
      ? c.ink!
      : Color(Hct.from(hue, chroma, strong + (page.tone - strong) * toward).toInt());
  final a = Hct.fromInt(c.accent.toARGB32());
  return Palette(
    id: 'own.${c.key}',
    label: 'Your own',
    day: ground,
    night: ground,
    accent: c.accent,
    accentSoft: at(a, math.max(a.tone, 78)),
    accentDeep: at(a, math.min(a.tone, 40)),
    onAccent: a.tone >= 50 ? at(a, 10, math.min(a.chroma, 16)) : at(a, 98, math.min(a.chroma, 8)),
    nightCapsule: Color.lerp(c.page, Colors.white, 0.12)!.withAlpha(0xF2),
    nightSheet: deepSheet,
    daySheet: paleSheet,
    only: light ? Brightness.light : Brightness.dark,
    dayInk: ink(0),
    dayInkSoft: ink(0.3),
    dayInkFaint: ink(0.42),
    nightInk: ink(0),
    nightInkSoft: ink(0.3),
    nightInkFaint: ink(0.42),
  );
}

/// The palette [prefs] choose: one of [Palette.all], or the reader's own
/// colours.
Palette chosenPalette(ListeningPrefs? prefs) => switch (prefs?.paletteId) {
      'own' => OwnColours.of(prefs!).made.palette,
      final id => Palette.byId(id),
    };
