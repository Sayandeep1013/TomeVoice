import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'theme.dart';

/// The launcher icon in the theme's colours (Settings > Appearance).
///
/// Every theme has an icon of its own, the logo in its ground, type and
/// accent colours (tools/brand/make_theme_icons.py), one launcher entry each
/// (LauncherIcon.kt). This says which the theme on screen wants; Android
/// changes it as the reader leaves the app. The icons are a few KB in all:
/// two white layers, tinted per theme in XML.
class LauncherIcon {
  LauncherIcon._();

  static const _channel = MethodChannel('tomevoice/tts');
  static String? _told;
  static bool _first = true;

  /// The icon's key for [p] shown in [b]: the palette's id with `-` as `_`,
  /// and `_day` or `_night` for one that has both. Null (the classic icon)
  /// for the reader's own colours and the wallpaper's, which have none.
  static String? keyFor(Palette p, Brightness b) {
    if (p.id.startsWith('own') || p.id == 'wallpaper') return null;
    final base = p.id.replaceAll('-', '_');
    if (p.only != null) return base;
    return '${base}_${b == Brightness.dark ? 'night' : 'day'}';
  }

  /// Tells Android the icon wanted: [p] in [b] when [follow], else the
  /// classic one. Only a change is sent.
  static void follow(Palette p, Brightness b, {required bool follow}) {
    final key = follow ? keyFor(p, b) : null;
    if (!_first && key == _told) return;
    _first = false;
    _told = key;
    _channel.invokeMethod('setLauncherIcon', {'key': key}).catchError((_) => null);
  }
}
