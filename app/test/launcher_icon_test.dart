// Every theme has a launcher icon of its own (tools/brand/make_theme_icons.py)
// under the key lib/launcher_icon.dart asks Android for.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/launcher_icon.dart';
import 'package:tomevoice_spike/theme.dart';

void main() {
  const res = 'android_overlay/app/src/main/res';

  test('every theme in every brightness it has has an icon', () {
    final missing = <String>[];
    for (final p in Palette.all) {
      for (final b in Brightness.values) {
        if (p.only != null && p.only != b) continue;
        final key = LauncherIcon.keyFor(p, b)!;
        for (final f in ['$res/mipmap-anydpi-v26/ic_launcher_t_$key.xml', '$res/drawable/ic_fg_t_$key.xml']) {
          if (!File(f).existsSync()) missing.add(f);
        }
      }
    }
    expect(missing, isEmpty, reason: 'run python tools/brand/make_theme_icons.py');
  });

  test('a theme with both brightnesses has a day and a night icon, a one-brightness theme one', () {
    expect(LauncherIcon.keyFor(Palette.paper, Brightness.light), 'paper_day');
    expect(LauncherIcon.keyFor(Palette.paper, Brightness.dark), 'paper_night');
    expect(LauncherIcon.keyFor(Palette.marble, Brightness.dark), 'scene_marble');
    expect(LauncherIcon.keyFor(Palette.topo, Brightness.dark), 'scene_topo_night');
  });

  test('the two layers every icon is tinted from are there', () {
    for (final f in ['ic_launcher_page.png', 'ic_launcher_spine.png']) {
      expect(File('$res/drawable-xxxhdpi/$f').existsSync(), isTrue, reason: f);
    }
  });
}
