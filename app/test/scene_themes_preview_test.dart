// Opt-in renderer for the two contributor scene themes. Unlike the colour
// previews, these load the real WebP backdrops through SceneGround, so the
// pictures and the scene's own marks are what the PNG actually shows.
//
//   TOMEVOICE_PREVIEW_DIR=<dir> flutter test test/scene_themes_preview_test.dart
//
// Without the environment variable every test is a no-op and no image is
// written into the repository.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/brand.dart';
import 'package:tomevoice_spike/scene.dart';
import 'package:tomevoice_spike/theme.dart';

void main() {
  for (final palette in [
    Palette.gothicScene,
    Palette.classicRenaissanceScene
  ]) {
    final scene = palette.scene!;
    testWidgets('render ${palette.id}-dark with its real painting',
        (tester) async {
      final out = Platform.environment['TOMEVOICE_PREVIEW_DIR'];
      if (out == null) return;
      final dir = Directory(out)..createSync(recursive: true);
      final key = GlobalKey();
      await tester.binding.setSurfaceSize(const ui.Size(720, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final wasArt = sceneArt;
      final wasPalette = Skin.palette;
      sceneArt = true;
      // Skin.themeFor() builds the ThemeData but restores its temporary
      // palette; groundDecoration() reads Skin.palette, as it does in the
      // running app. Put this scene there so the real backdrop is painted.
      Skin.palette = palette;
      addTearDown(() {
        sceneArt = wasArt;
        Skin.palette = wasPalette;
      });

      await tester.pumpWidget(MaterialApp(
        theme: Skin.themeFor(palette, Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 720,
              height: 1080,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Builder(
                      builder: (c) =>
                          DecoratedBox(decoration: Skin.groundDecoration(c)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(34),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const BrandMark(size: 46),
                            const SizedBox(width: 14),
                            Text(
                              'TOMEVOICE  /  SCENE PREVIEW',
                              style: Skin.ui(
                                  size: 11,
                                  weight: FontWeight.w700,
                                  color: palette.accentSoft,
                                  tracking: 0.14),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Builder(
                          builder: (c) => Text(
                            palette.label,
                            style: Skin.heading(c,
                                size: 44, color: palette.accentSoft),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Container(
                          width: 520,
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                            color: palette.nightSheet,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            'A place to settle into',
                            style: Skin.ui(
                                size: 18,
                                weight: FontWeight.w600,
                                color: palette.accentSoft),
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            SceneEmptyArt(scene, size: 92),
                            const SizedBox(width: 28),
                            SceneOrnament(scene,
                                foot: false, width: 104, height: 104),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SceneDivider(scene),
                        const SizedBox(height: 10),
                        SceneOrnament(scene,
                            foot: true, width: 180, height: 46),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));

      // The painting is fetched and decoded on the real async queue. Wait for
      // it rather than a guess, then let its repaint notification settle.
      for (var i = 0; i < 200 && !sceneArtLoaded(scene); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(sceneArtLoaded(scene), isTrue,
          reason:
              '${scene.name}.webp must load and decode; ${sceneArtError(scene) ?? 'still waiting'}');
      await tester.pumpAndSettle();

      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image =
          await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
      final byteData = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      File('${dir.path}/${palette.id}-dark.png')
          .writeAsBytesSync(byteData!.buffer.asUint8List());
      image!.dispose();
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}
