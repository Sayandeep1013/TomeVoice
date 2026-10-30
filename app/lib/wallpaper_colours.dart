import 'package:flutter/material.dart';

import 'contrast.dart';
import 'speech_service.dart';
import 'theme.dart';

/// The colours Android 12 and later make from the wallpaper for every app
/// (Material You): five families of tones, each from shade 0 (white) to
/// 1000 (black).
@immutable
class SystemColours {
  const SystemColours(this.families);

  /// accent1 (the main colour), accent2 and accent3 (its companions),
  /// neutral1 and neutral2 (greys leaning to it), each a tone per shade.
  final Map<String, List<Color>> families;

  /// The shades Android names, lightest first.
  static const shades = [0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000];
  static const names = ['accent1', 'accent2', 'accent3', 'neutral1', 'neutral2'];

  /// The families as the platform sends them (a list of ARGB values each),
  /// or null when any is missing or short.
  static SystemColours? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final out = <String, List<Color>>{};
    for (final name in names) {
      final tones = raw[name];
      if (tones is! List || tones.length != shades.length || tones.any((t) => t is! int)) return null;
      out[name] = [for (final t in tones.cast<int>()) Color(t & 0xFFFFFFFF)];
    }
    return SystemColours(out);
  }

  Color _at(String family, int shade) => families[family]![shades.indexOf(shade)];
  Color accent1(int shade) => _at('accent1', shade);
  Color accent2(int shade) => _at('accent2', shade);
  Color accent3(int shade) => _at('accent3', shade);
  Color neutral1(int shade) => _at('neutral1', shade);
  Color neutral2(int shade) => _at('neutral2', shade);

  String get key => [
        for (final name in names)
          for (final c in families[name]!) (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0'),
      ].join();

  @override
  bool operator ==(Object other) => other is SystemColours && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The phone's wallpaper colours, asked for when the app is shown and each
/// time it comes back (a new wallpaper brings new colours).
class WallpaperColours {
  WallpaperColours._();

  /// Null until read, and on phones older than Android 12, which have none.
  static final current = ValueNotifier<SystemColours?>(null);

  /// The palette they make, or null where there are none.
  static Palette? get palette {
    final c = current.value;
    return c == null ? null : wallpaperPalette(c);
  }

  static Future<void> refresh([SpeechService svc = const SpeechService()]) async {
    final c = SystemColours.fromPlatform(await svc.systemColours());
    if (c != current.value) current.value = c;
  }

  @visibleForTesting
  static void reset() => current.value = null;
}

/// A palette from the wallpaper's colours, laid out as the others are: the
/// ground travels from the main colour's companion through a grey of it to
/// the third colour, the accent is the main colour, and the type is in its
/// greys; then each is moved as little as it takes to read (see [readable]).
Palette wallpaperPalette(SystemColours s) => _made[s.key] ??= readable(Palette(
      id: 'wallpaper.${s.key}',
      label: 'Wallpaper',
      day: [s.accent2(100), s.accent2(200), s.neutral2(100), s.accent3(100)],
      night: [s.accent2(900), s.accent2(800), s.neutral2(900), s.accent3(800)],
      accent: s.accent1(400),
      accentSoft: s.accent1(200),
      accentDeep: s.accent1(700),
      onAccent: s.accent1(900),
      nightCapsule: s.neutral2(700).withAlpha(0xF2),
      nightSheet: Color.lerp(s.neutral1(900), s.neutral1(1000), 0.5)!,
      daySheet: s.neutral1(10),
      dayInk: s.neutral1(900),
      dayInkSoft: s.neutral2(700),
      dayInkFaint: s.neutral2(600),
      nightInk: s.neutral1(100),
      nightInkSoft: s.neutral2(200),
      nightInkFaint: s.neutral2(300),
    ));

final _made = <String, Palette>{};
