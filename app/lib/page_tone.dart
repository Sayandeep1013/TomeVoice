import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'contrast.dart' show groundOf;
import 'prefs.dart' show ListeningPrefs;
import 'theme.dart';

/// The page under the text: the app's own colours, or a reader's paper —
/// ink on matte white, papyrus, or a dim warm dusk for reading in the dark.
/// Only the page takes it; the bars and the player keep the app's colours.
@immutable
class PageTone {
  const PageTone(
    this.id,
    this.label, {
    this.paper,
    this.ink,
    this.inkSoft,
    this.accent,
    this.dark = false,
    this.vignette,
    this.grid,
  });

  final String id;
  final String label;

  /// The paper, top to bottom; null for the app's own ground.
  final List<Color>? paper;
  final Color? ink;
  final Color? inkSoft;

  /// The sentence read aloud, chapter openings and the voice's word.
  final Color? accent;

  /// A dark page (light text): the phone's bars are drawn light on it.
  final bool dark;

  /// The page's edges darkened a little, as paper in lamplight.
  final Color? vignette;

  /// Squared paper: the colour of its lines (a field notebook's).
  final Color? grid;

  bool get isApp => paper == null;

  /// The app's colours, as before there were page tones.
  static const app = PageTone('app', 'Theme');

  /// An e-reader's page: matte white, black ink, grey for the voice.
  static const eink = PageTone(
    'ink',
    'Ink',
    paper: [Color(0xFFF5F4F0), Color(0xFFECEBE6)],
    ink: Color(0xFF1A1A1A),
    inkSoft: Color(0xFF55544F),
    accent: Color(0xFF5A5A57),
  );

  /// Old paper: warm, a brown ink, a sienna voice.
  ///
  /// The soft ink and the sienna set the 10 and 11 px labels (the chapter
  /// above the page, the time left, "CHAPTER 3"), so each is just dark
  /// enough to read at 4.5:1 on the paper; the soft ink also where the top
  /// bar's chapter line sits, on the darkened edge of the scroll.
  static const papyrus = PageTone(
    'papyrus',
    'Papyrus',
    paper: [Color(0xFFF2E4C4), Color(0xFFE5D0A3)],
    ink: Color(0xFF3B2B19),
    inkSoft: Color(0xFF654F31),
    accent: Color(0xFF8C471A),
    vignette: Color(0x38734A1A),
  );

  /// For the dark: a dim warm grey, soft low-contrast text, nothing glaring.
  /// Its soft ink is only just light enough for small labels (4.5:1).
  static const dusk = PageTone(
    'dusk',
    'Dusk',
    paper: [Color(0xFF27231F), Color(0xFF1C1A17)],
    ink: Color(0xFFB9AD9C),
    inkSoft: Color(0xFF95897B),
    accent: Color(0xFFC6A06A),
    dark: true,
    vignette: Color(0x73000000),
  );

  /// A field notebook's squared page: cream, blue-grey squares, ink like a
  /// fountain pen's and a red pen for the voice.
  static const notebook = PageTone(
    'notebook',
    'Notebook',
    paper: [Color(0xFFFAF7EE), Color(0xFFF2EEE1)],
    ink: Color(0xFF1E2533),
    inkSoft: Color(0xFF4B5263),
    accent: Color(0xFFA8322A),
    grid: Color(0x2E4A78A8),
  );

  /// Designer: pale calfskin, warm and even, for long reading by day.
  static const vellum = PageTone(
    'vellum',
    'Vellum',
    paper: [Color(0xFFF4EDDF), Color(0xFFEDE3CF)],
    ink: Color(0xFF3A2F22),
    inkSoft: Color(0xFF5E5040),
    accent: Color(0xFF8A4E1C),
    vignette: Color(0x22735A30),
  );

  /// Designer: a warm dark page, between Dusk and Black, as under a lamp.
  static const lamplight = PageTone(
    'lamplight',
    'Lamplight',
    paper: [Color(0xFF1E1A14), Color(0xFF26211A)],
    ink: Color(0xFFE8DCC4),
    inkSoft: Color(0xFFB8AA92),
    accent: Color(0xFFE0A050),
    dark: true,
    vignette: Color(0x66000000),
  );

  static const all = [app, eink, papyrus, notebook, dusk, vellum, lamplight];

  static PageTone byId(String? id) => all.where((t) => t.id == id).firstOrNull ?? app;

  /// The page's shades top to foot, what its type is read against: the
  /// tone's paper, or the app's ground as its gradient draws it.
  List<Color> shadesOf(BuildContext context) => paper == null
      ? groundOf(Skin.paletteOf(context), Theme.of(context).brightness)
      : [for (var t = 0.0; t <= 1; t += 0.25) Color.lerp(paper!.first, paper!.last, t)!];

  /// The paper as a decoration: the tone's, or the app's diagonal ground.
  /// Always plain, a scene theme's too: no art is ever behind the words.
  BoxDecoration paperOf(BuildContext context) => paper == null
      ? BoxDecoration(gradient: Skin.ground(context))
      : BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: paper!),
          // Squares over the paper's own shade, wherever the paper is laid
          // (the scroll, each page and a turning leaf, the swatch).
          image: grid == null
              ? null
              : DecorationImage(image: GridPaper(grid!), repeat: ImageRepeat.repeat, scale: GridPaper.scale),
        );

  Color inkOf(BuildContext context) => ink ?? Skin.inkOn(context);

  /// The accent as the page's text: its headings, "CHAPTER 3", its ribbon.
  /// In the app's own colours the accent's ink, which reads on the ground
  /// where the full accent (a fill) is too pale.
  Color accentOf(BuildContext context) => accent ?? Skin.accentInkOf(context);
}

/// [child] in [tone]'s ink and accent: what reads the accent (washes,
/// headings, chapter labels) and the default text colour follow the page.
///
/// The app's own colours are wrapped the same way, in its own palette: a
/// tree of another shape threw [child]'s state away when the tone changed,
/// and the pages (or the scroll) opened again where they were first opened.
Widget toned(BuildContext context, PageTone tone, Widget child) {
  final p = Skin.paletteOf(context);
  if (tone.isApp) {
    return TintScope(palette: p, child: DefaultTextStyle.merge(style: const TextStyle(), child: child));
  }
  final a = tone.accent!;
  return TintScope(
    palette: p.copyWith(
      id: '${p.id}+${tone.id}',
      accent: a,
      accentSoft: a,
      accentDeep: a,
      onAccent: tone.dark ? const Color(0xFF1C1A17) : Colors.white,
    ),
    child: DefaultTextStyle.merge(style: TextStyle(color: tone.ink), child: child),
  );
}

/// The page's ground in [tone], with its vignette, under [child].
class PageGround extends StatelessWidget {
  const PageGround({super.key, required this.tone, required this.child, this.vignette = true});

  final PageTone tone;
  final Widget child;

  /// Without it under pages: their paper covers all but the strips outside
  /// the safe area, where the darkened edge showed against the page.
  final bool vignette;

  @override
  Widget build(BuildContext context) {
    final edge = vignette ? tone.vignette : null;
    // In a scene, with "Scene behind the page" on and the app's own tone:
    // its painting under the words, darkened so they read.
    final scene = tone.paper == null && (ListeningPrefs.loaded?.sceneOnPage ?? false);
    // One shape with or without the vignette: another shape rebuilt [child]
    // afresh when the tone changed (see toned).
    return DecoratedBox(
      decoration: scene ? Skin.groundDecoration(context) : tone.paperOf(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(child: ColoredBox(color: scene && Skin.sceneOf(context) != null ? const Color(0xB8000000) : const Color(0x00000000))),
          IgnorePointer(
            child: DecoratedBox(
              decoration: edge == null
                  ? const BoxDecoration()
                  : BoxDecoration(
                      gradient: RadialGradient(
                        radius: 1.05,
                        colors: [edge.withValues(alpha: 0), edge],
                        stops: const [0.62, 1],
                      ),
                    ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// One square of squared paper, drawn once and repeated: a line along its
/// top and its left in [line], [size] dp a side.
@immutable
class GridPaper extends ImageProvider<GridPaper> {
  const GridPaper(this.line, {this.size = 22});

  final Color line;
  final double size;

  /// Drawn at three pixels a dp: sharp on any phone's screen.
  static const scale = 3.0;

  @override
  Future<GridPaper> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(GridPaper key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(key._draw());

  Future<ImageInfo> _draw() async {
    final px = (size * scale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..color = line
      ..strokeWidth = 2;
    canvas
      ..drawLine(const Offset(0, 1), Offset(px.toDouble(), 1), paint)
      ..drawLine(const Offset(1, 0), Offset(1, px.toDouble()), paint);
    final picture = recorder.endRecording();
    final image = await picture.toImage(px, px);
    picture.dispose();
    return ImageInfo(image: image, scale: scale);
  }

  @override
  bool operator ==(Object other) => other is GridPaper && other.line == line && other.size == size;

  @override
  int get hashCode => Object.hash(line, size);
}
