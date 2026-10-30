import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;

import 'theme.dart';

// Contrast as WCAG 2.2 measures it, and what every palette keeps readable
// with it: text at 4.5:1 (3:1 from 18 px, or 14 px bold), icons and the
// parts of a control at 3:1, on each surface it is drawn on.

/// Small text: under 18 px, or 14 px bold.
const smallText = 4.5;

/// Large text, icons and the parts of a control.
const largeText = 3.0;

/// WCAG's relative luminance of [c], its alpha aside: each sRGB channel made
/// linear (with 2.2's knee at 0.04045), then weighted as the eye weighs them.
double luminance(Color c) {
  double linear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

double _ratio(double la, double lb) => (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);

/// The contrast of [a] on [b], from 1 to 21. A translucent [a] is laid over
/// [b] first, as it is drawn; [b] is taken as opaque.
double contrast(Color a, Color b) => _ratio(luminance(a.a < 1 ? Color.alphaBlend(a, b) : a), luminance(b));

/// Whether [c] (opaque) reads at [needs]:1 on every one of [on].
bool readsOn(Color c, Iterable<Color> on, double needs) {
  final l = luminance(c);
  return on.every((s) => _ratio(l, luminance(s)) >= needs);
}

/// [c] (opaque) at the nearest tone that reads at [needs]:1 on every one of
/// [on]: the same hue and colourfulness, as near as a screen can show them,
/// only darker when [darker], else lighter. [c] itself when it reads
/// already; black or white when no tone that way does.
Color readableOn(Color c, Iterable<Color> on, double needs, {required bool darker}) {
  final under = [for (final s in on) luminance(s)];
  bool reads(Color x) {
    final l = luminance(x);
    return under.every((s) => _ratio(l, s) >= needs);
  }

  if (reads(c)) return c;
  final hct = Hct.fromInt(c.toARGB32());
  Color at(double tone) => Color(Hct.from(hct.hue, hct.chroma, tone).toInt());
  final end = darker ? 0.0 : 100.0;
  if (!reads(at(end))) return darker ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  // Halved down to a twentieth of a step of L*.
  var near = hct.tone, far = end;
  while ((far - near).abs() > 0.05) {
    final mid = (near + far) / 2;
    if (reads(at(mid))) {
      far = mid;
    } else {
      near = mid;
    }
  }
  return at(far);
}

double _tone(Color c) => Hct.fromInt(c.toARGB32()).tone;

/// [c] made at least as strong as [than]: as far from the ground (darker
/// by day, lighter by night), keeping its own hue.
Color _noWeaker(Color c, {required Color than, required bool dark}) {
  final t = _tone(than);
  if (dark ? _tone(c) >= t : _tone(c) <= t) return c;
  final hct = Hct.fromInt(c.toARGB32());
  return Color(Hct.from(hct.hue, hct.chroma, t).toInt());
}

/// One thing a palette keeps readable: [what], drawn on [on], at [needs]:1
/// or more.
@immutable
class ContrastNeed {
  const ContrastNeed(this.what, this.colour, this.on, this.surface, this.needs);

  final String what;
  final Color colour;
  final String on;
  final Color surface;
  final double needs;

  double get ratio => contrast(colour, surface);

  bool get met => ratio >= needs;

  @override
  String toString() => '$what on $on: ${ratio.toStringAsFixed(2)}:1, needs $needs';
}

/// The ground of [p] in [b] as its gradient draws it: each stop, and three
/// points between each two.
List<Color> groundOf(Palette p, Brightness b) {
  final g = b == Brightness.dark ? p.night : p.day;
  return [
    for (var i = 0; i < g.length; i++) ...[
      if (i > 0)
        for (final t in const [0.25, 0.5, 0.75]) Color.lerp(g[i - 1], g[i], t)!,
      g[i],
    ],
  ];
}

/// Where [p]'s inks and its accent's ink are drawn in [b], by name: the
/// ground, a capsule on it (a row, a card, a button), a row chosen or being
/// read (the accent's wash), a sheet or dialog, a choice raised on a sheet,
/// and one chosen on a sheet.
Map<String, List<Color>> surfacesOf(Palette p, Brightness b) {
  final dark = b == Brightness.dark;
  final ground = groundOf(p, b);
  final sheet = dark ? p.nightSheet : p.daySheet;
  final capsule = dark ? p.nightCapsule : p.dayCapsule;
  return {
    'the ground': ground,
    'a capsule': [for (final g in ground) Color.alphaBlend(capsule, g)],
    'a chosen row': [for (final g in ground) Color.alphaBlend(p.accent.withValues(alpha: 0.14), g)],
    'a sheet': [sheet],
    'a choice on a sheet': [Color.alphaBlend(Skin.raised, sheet)],
    'a choice chosen on a sheet': [Color.alphaBlend(p.accent.withValues(alpha: 0.14), sheet)],
  };
}

/// A row picked out of a list (chapters picked to download): the accent's
/// strongest wash, on which a row's text is in the ink.
List<Color> pickedRowsOf(Palette p, Brightness b) => [
      for (final g in groundOf(p, b)) Color.alphaBlend(p.accent.withValues(alpha: 0.26), g),
    ];

/// The sentence and the word being read aloud, washed over the ground of a
/// page in the app's own colours.
List<Color> readAloudOf(Palette p, Brightness b) => [
      for (final g in groundOf(p, b)) ...[
        Color.alphaBlend(Skin.sentenceWashOf(p, b), g),
        Color.alphaBlend(Skin.wordWashOf(p, b), g),
      ],
    ];

/// Everything [p] draws text, icons and a control's marks with in [b], on
/// every surface each is drawn on, with the contrast each needs there.
List<ContrastNeed> needsOf(Palette p, Brightness b) {
  final dark = b == Brightness.dark;
  final surfaces = surfacesOf(p, b);
  final picked = {'a picked row': pickedRowsOf(p, b)};
  final out = <ContrastNeed>[];
  void on(String what, Color c, Map<String, List<Color>> where, double needs) {
    for (final e in where.entries) {
      for (final s in e.value) {
        out.add(ContrastNeed(what, c, e.key, s, needs));
      }
    }
  }

  // The type wherever there is text; on a picked row only the ink, with
  // icons in the others beside it.
  on('the ink', p.inkFor(b), {...surfaces, ...picked}, smallText);
  on('the soft ink', p.inkSoftFor(b), surfaces, smallText);
  on('the faint ink', p.inkFaintFor(b), surfaces, smallText);
  on('the soft ink as an icon', p.inkSoftFor(b), picked, largeText);
  on('the faint ink as an icon', p.inkFaintFor(b), picked, largeText);
  on('the ink read aloud', p.inkFor(b), {'the words read aloud': readAloudOf(p, b)}, smallText);
  on('the warning red', p.dangerFor(b), surfaces, smallText);
  // The accent as text and as an icon: the deep one by day, the soft one by
  // night.
  final ink = dark ? p.accentSoft : p.accentDeep;
  on('the accent as text', ink, surfaces, smallText);
  on('the accent as an icon', ink, {...surfaces, ...picked}, largeText);
  // A control's mark (a switch that is on, a bar's fill, a slider's thumb):
  // the deep accent by day, the full one by night. A slider by day is also
  // on the player's dark bar: a tone between.
  on('the accent as a mark', dark ? p.accent : p.accentDeep, surfaces, largeText);
  if (!dark) on('a slider by day', sliderMarkOf(p), _sliderGroundsOf(p), largeText);
  // Labels on the accent's fill: a button, the chosen segment.
  on('text on the accent', p.onAccent, {'the accent': [p.accent]}, smallText);
  // The dark bar under a player (in the book's colour on its side) and a
  // scroller's bubble, with the soft accent lit on it; a snack bar and its
  // action.
  final onDark = Skin.onDarkFor(p, b);
  final bars = {'the dark bar': darkBarsOf(p, b)};
  on('text on the dark bar', onDark, bars, smallText);
  on('the soft accent on the dark bar', p.accentSoft, bars, smallText);
  on('text on a snack bar', onDark, {'a snack bar': [Skin.snackFor(p, b)]}, smallText);
  on("a snack bar's action", p.accentSoft, {'a snack bar': [Skin.snackFor(p, b)]}, smallText);
  return out;
}

/// The dark bar under a player, plain and in the accent's tint (the dock).
List<Color> darkBarsOf(Palette p, Brightness b) {
  final bar = Skin.darkFor(p, b);
  return [bar, Color.lerp(bar, p.accent, 0.16)!];
}

/// What a slider sits on by day: light sheets and capsules, and the dark bar
/// under a player (whose slider takes the app's).
Map<String, List<Color>> _sliderGroundsOf(Palette p) => {
      'a light sheet or capsule': [
        p.daySheet,
        Color.alphaBlend(Skin.raised, p.daySheet),
        for (final g in groundOf(p, Brightness.light)) Color.alphaBlend(p.dayCapsule, g),
      ],
      'the dark bar': [Skin.darkFor(p, Brightness.light)],
    };

/// A slider's mark by day: the accent at a tone that shows at 3:1 both on
/// the light sheets and capsules it sits on and on the player's dark bar.
Color sliderMarkOf(Palette p) {
  final on = _sliderGroundsOf(p);
  final light = readableOn(p.accent, on['a light sheet or capsule']!, largeText, darker: true);
  return readableOn(light, on['the dark bar']!, largeText, darker: false);
}

/// What [needsOf] finds short, in every brightness [p] shows in.
List<ContrastNeed> unmetNeeds(Palette p) => [
      for (final b in Brightness.values)
        if (p.only == null || p.only == b)
          for (final n in needsOf(p, b))
            if (!n.met) n,
    ];

/// [p] with its type and its accent's tones each moved as little as it
/// takes for every need in [needsOf] to be met, in each brightness it shows
/// in. Its grounds, sheets and capsules stay as they are, and its accent's
/// fill too, unless it is too dark to mark a control by night.
Palette readable(Palette p) {
  var out = p;
  // A change for one brightness can move a wash the other reads on: a few
  // rounds settle it.
  for (var round = 0; round < 3; round++) {
    for (final b in Brightness.values) {
      if (p.only == null || p.only == b) out = _readableIn(out, b);
    }
    if (unmetNeeds(out).isEmpty) break;
  }
  return out;
}

Palette _readableIn(Palette p, Brightness b) {
  final dark = b == Brightness.dark;
  // The fill first: every wash below is made of it.
  final night = [for (final s in surfacesOf(p, b).values) ...s];
  final accent = dark ? readableOn(p.accent, night, largeText, darker: false) : p.accent;
  final q = p.copyWith(accent: accent);
  final surfaces = [for (final s in surfacesOf(q, b).values) ...s];
  final picked = pickedRowsOf(q, b);
  final chrome = [Skin.snackFor(q, b), ...darkBarsOf(q, b)];
  // Text is dark by day and light by night: each moves away from its ground.
  Color fit(Color c, List<Color> on, [double needs = smallText]) => readableOn(c, on, needs, darker: !dark);
  final faint = fit(fit(q.inkFaintFor(b), surfaces), picked, largeText);
  final soft = _noWeaker(fit(fit(q.inkSoftFor(b), surfaces), picked, largeText), than: faint, dark: dark);
  var ink = fit(fit(q.inkFor(b), [...surfaces, ...picked]), readAloudOf(q, b));
  // By night the ink is also what the dark bar and a snack bar say.
  if (dark) ink = fit(ink, chrome);
  ink = _noWeaker(ink, than: soft, dark: dark);
  final danger = fit(q.dangerFor(b), surfaces);
  final text = fit(fit(dark ? q.accentSoft : q.accentDeep, surfaces), picked, largeText);
  // The soft accent is also lit on the dark bar and a snack bar's action,
  // by day and by night.
  final accentSoft = readableOn(dark ? text : q.accentSoft, chrome, smallText, darker: false);
  return q.copyWith(
    accentDeep: dark ? null : text,
    accentSoft: accentSoft,
    onAccent: _onFill(q.onAccent, accent),
    dayInk: dark ? null : ink,
    dayInkSoft: dark ? null : soft,
    dayInkFaint: dark ? null : faint,
    nightInk: dark ? ink : null,
    nightInkSoft: dark ? soft : null,
    nightInkFaint: dark ? faint : null,
    dayDanger: dark ? null : danger,
    nightDanger: dark ? danger : null,
  );
}

/// [on] as a label on [fill]: dark or light, whichever reads, as near its
/// own tone as it can be.
Color _onFill(Color on, Color fill) {
  final darker = _tone(on) < _tone(fill);
  final same = readableOn(on, [fill], smallText, darker: darker);
  if (contrast(same, fill) >= smallText) return same;
  final other = readableOn(on, [fill], smallText, darker: !darker);
  return contrast(other, fill) > contrast(same, fill) ? other : same;
}
