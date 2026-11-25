// Opt-in renderer for the contribution's preview images. Each preview is its
// own widget test, so the binding is fresh for every image. The widgets are
// drawn through the same Skin.themeFor / Skin.groundFor APIs the app uses.
//
//   TOMEVOICE_PREVIEW_DIR=<dir> flutter test test/premium_themes_preview_test.dart
//
// Without the environment variable every test is a no-op, so the normal suite
// never writes into the repository.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/theme.dart';

void main() {
  for (final p in PremiumThemes.all) {
    for (final b in Brightness.values) {
      if (p.only != null && p.only != b) continue;
      final palette = p;
      final brightness = b;
      testWidgets('render ${palette.id}-${brightness.name}', (tester) async {
        final out = Platform.environment['TOMEVOICE_PREVIEW_DIR'];
        if (out == null) return;
        final dir = Directory(out)..createSync(recursive: true);
        final key = GlobalKey();
        final dark = brightness == Brightness.dark;
        final ink = palette.inkFor(brightness);
        final soft = palette.inkSoftFor(brightness);
        final sheet = dark ? palette.nightSheet : palette.daySheet;
        final capsule = dark ? palette.nightCapsule : palette.dayCapsule;

        await tester.pumpWidget(MaterialApp(
          theme: Skin.themeFor(palette, brightness),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: Container(
                  width: 720,
                  height: 440,
                  decoration: BoxDecoration(
                      gradient: Skin.groundFor(brightness, palette)),
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TOMEVOICE  /  THEME PREVIEW',
                        style: Skin.ui(
                            size: 11,
                            weight: FontWeight.w700,
                            color: soft,
                            tracking: 0.12),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        palette.label,
                        style: TextStyle(
                          fontFamily: Skin.titleFamily,
                          fontSize: 40,
                          fontWeight: FontWeight.w500,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: sheet,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'A page to settle into',
                              style: Skin.ui(
                                  size: 17,
                                  weight: FontWeight.w700,
                                  color: ink),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'The ink, the accents and the surfaces stay readable '
                              'together, from the first chapter to the last.',
                              style: Skin.ui(
                                  size: 14,
                                  weight: FontWeight.w400,
                                  color: soft),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: palette.accent.withValues(alpha: 0.20),
                                borderRadius:
                                    const BorderRadius.all(Radius.circular(3)),
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  width: 280,
                                  decoration: BoxDecoration(
                                    color: palette.accentDeep,
                                    borderRadius: const BorderRadius.all(
                                        Radius.circular(3)),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 12),
                            decoration: BoxDecoration(
                              color: palette.accent,
                              borderRadius:
                                  const BorderRadius.all(Radius.circular(22)),
                            ),
                            child: Text(
                              'Continue listening',
                              style: Skin.ui(
                                  size: 14,
                                  weight: FontWeight.w700,
                                  color: palette.onAccent),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: capsule,
                              borderRadius:
                                  const BorderRadius.all(Radius.circular(20)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.play_arrow_rounded,
                                    size: 18, color: palette.accent),
                                const SizedBox(width: 6),
                                Text(
                                  'Player',
                                  style: Skin.ui(
                                      size: 13,
                                      weight: FontWeight.w600,
                                      color: ink),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pump();

        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        // toImage/toByteData complete on the engine's real async queue; the
        // test binding must track that work via runAsync so postTest can finish.
        final image = await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1),
        );
        final byteData = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.png),
        );
        File('${dir.path}/${palette.id}-${brightness.name}.png')
            .writeAsBytesSync(byteData!.buffer.asUint8List());
        image!.dispose();
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }
}
