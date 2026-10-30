import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, BoxParentData, RenderShiftedBox;
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;

import 'contrast.dart';

/// The visual language, in one place.
///
/// The ground is the forest-to-amber diagonal the app has always had; the
/// type is a fashion-magazine set (docs/10 ADR-018):
///
/// * Bodoni Moda for titles, the wordmark and chapter openings: a Didone with
///   optical sizes, so it is crisp at 15 px in a list and elegant at 40 px.
/// * Figtree for everything you tap or read as interface. Small labels are
///   uppercase with gentle tracking and tabular numbers.
/// * Newsreader (or Literata, a sans, or the phone's serif) for the page.
///
/// One accent, amber, used sparingly. Spacing comes from [Gap], corners from
/// [Radii], durations and curves from [Motion]; nothing else should invent
/// its own.
class Skin {
  const Skin._();

  /// The colour theme in use (Forest, Lavender, Ocean, Black, Paper, the
  /// reader's own or the wallpaper's). The colours below read from it, so
  /// every screen follows a change.
  static Palette palette = Palette.forest;

  /// The cover colour of the book being read, which the whole app follows
  /// when book colours are on (set by the shell, read by the app's theme).
  static int? followTint;

  /// The palette for [c]: a book's own inside its [TintScope], otherwise
  /// the app's.
  static Palette paletteOf(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<TintScope>()?.palette ?? palette;

  /// The accent where [c] is: the book's on its screens.
  static Color accentOf(BuildContext c) => paletteOf(c).accent;
  static Color accentSoftOf(BuildContext c) => paletteOf(c).accentSoft;
  static Color accentDeepOf(BuildContext c) => paletteOf(c).accentDeep;
  static Color onAccentOf(BuildContext c) => paletteOf(c).onAccent;

  /// The accent as text or an icon: the deep one on a light ground, the soft
  /// one on a dark ground, where the full one (a fill) would not read.
  static Color accentInkOf(BuildContext c) => isDark(c) ? accentSoftOf(c) : accentDeepOf(c);

  /// The accent as a control's mark (a bar's fill, a switch that is on): the
  /// deep one by day, where the full one is too pale on white.
  static Color accentMarkOf(BuildContext c) => isDark(c) ? accentOf(c) : accentDeepOf(c);

  // ---- ground ----------------------------------------------------------
  static Color get mint => palette.day[0];
  static Color get mintDeep => palette.day[1];
  static Color get cream => palette.day[2];
  static Color get peach => palette.day[3];

  // ---- ink -------------------------------------------------------------
  // The soft and faint inks are just dark enough for small text at 4.5:1
  // on every light ground here, deepest band and a chosen row's wash
  // included (see contrast.dart), so the two now meet; the faint one stays
  // quiet by its size, capitals and tracking.
  static const ink = Color(0xFF14170F);
  static const inkSoft = Color(0xFF464E41);
  static const inkFaint = Color(0xFF464E41);

  // ---- warning ---------------------------------------------------------
  // Errors and what cannot be undone, in red; by day and by night each just
  // strong enough for small text at 4.5:1.
  static const danger = Color(0xFF8C2713);
  static const nightDanger = Color(0xFFFF8F77);

  /// The warning red where [c] is.
  static Color dangerOn(BuildContext c) => paletteOf(c).dangerFor(Theme.of(c).brightness);

  /// A gentler warning in amber (a voice that may not be sold with), at the
  /// red's tone a shade further from the ground, so it reads wherever the
  /// red does.
  static Color cautionOn(BuildContext c) {
    final red = Hct.fromInt(dangerOn(c).toARGB32());
    final amber = Hct.fromInt(0xFFC98A2B);
    return Color(Hct.from(amber.hue, amber.chroma, red.tone + (isDark(c) ? 0.5 : -0.5)).toInt());
  }

  // ---- chrome ----------------------------------------------------------
  static Color get capsule => palette.dayCapsule;
  static const capsuleEdge = Color(0x1A14170F);
  static const dark = Color(0xFF1C1F17);
  static const darkSoft = Color(0xFF2A2E24);

  // ---- accent ----------------------------------------------------------
  // The accent is amber in Forest; the names stay for every palette.
  static Color get amber => palette.accent;
  static Color get amberSoft => palette.accentSoft;

  /// Text on an accent fill.
  static Color get onAmber => palette.onAccent;

  // ---- dark theme ------------------------------------------------------
  //
  // Not an inversion. The light ground travels mint -> cream, so the dark one
  // travels deep forest -> warm ember through the same diagonal.
  static Color get nightTop => palette.night[0];
  static Color get nightMid => palette.night[1];
  static Color get nightWarm => palette.night[2];
  static Color get nightBottom => palette.night[3];
  // By night the faint ink is just light enough for small text at 4.5:1 on
  // a capsule, and the ink on the word read aloud in Lavender's wash.
  static const nightInk = Color(0xFFF8EFDF);
  static const nightInkSoft = Color(0xFFB9B2A0);
  static const nightInkFaint = Color(0xFFB4AE9F);
  static Color get nightCapsule => palette.nightCapsule;

  /// Sheets, the player, the Continue card: the deepest surface.
  static Color get nightSheet => palette.nightSheet;

  static bool isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  /// The diagonal wash everything sits on.
  static LinearGradient ground(BuildContext c) => groundFor(Theme.of(c).brightness);

  static LinearGradient groundFor(Brightness b, [Palette? p]) {
    final pal = p ?? palette;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: b == Brightness.dark ? pal.night : pal.day,
      stops: b == Brightness.dark ? const [0.0, 0.30, 0.72, 1.0] : const [0.0, 0.28, 0.72, 1.0],
    );
  }

  /// The colour at the foot of the ground: the navigation bar sits on it, so
  /// the bottom of the screen has no seam.
  static Color groundFoot(BuildContext c) => isDark(c) ? nightBottom : peach;

  // The type is the palette's: the same in every palette here, a reader's
  // own colours and the wallpaper's fitted to their grounds.
  static Color inkOn(BuildContext c) => paletteOf(c).inkFor(Theme.of(c).brightness);
  static Color inkSoftOn(BuildContext c) => paletteOf(c).inkSoftFor(Theme.of(c).brightness);
  static Color inkFaintOn(BuildContext c) => paletteOf(c).inkFaintFor(Theme.of(c).brightness);
  static Color capsuleOn(BuildContext c) => isDark(c) ? nightCapsule : capsule;
  static Color darkOn(BuildContext c) => darkFor(paletteOf(c), Theme.of(c).brightness);
  static Color onDark(BuildContext c) => onDarkFor(paletteOf(c), Theme.of(c).brightness);

  /// The dark bar under a player or a scroller's bubble, in [p] and [b], and
  /// what is written on it (and on a snack bar).
  static Color darkFor(Palette p, Brightness b) => b == Brightness.dark ? p.nightSheet : dark;
  static Color onDarkFor(Palette p, Brightness b) => b == Brightness.dark ? p.nightInk : p.day[2];

  /// A snack bar or a tooltip in [p] and [b].
  static Color snackFor(Palette p, Brightness b) =>
      b == Brightness.dark ? Color.lerp(p.nightSheet, Colors.white, 0.12)! : dark2;

  /// A hairline: borders of rows, fields and dividers.
  static Color outlineOn(BuildContext c) =>
      isDark(c) ? Colors.white.withValues(alpha: 0.09) : capsuleEdge;

  /// Something raised on a sheet (a choice, a voice row).
  static Color raisedOn(BuildContext c) => raised;
  static final raised = Colors.white.withValues(alpha: 0.07);

  /// The cream discs the reference uses for the prev/next pair.
  static Color disc(BuildContext c) =>
      isDark(c) ? const Color(0x2EF2EADA) : const Color(0xFFF0E6D6);

  // ---- type ------------------------------------------------------------

  static const titleFamily = 'BodoniModa';
  static const uiFamily = 'Figtree';

  /// Bodoni Moda: titles, the wordmark, chapter openings. Its optical size
  /// follows the point size, which is what keeps the hairlines readable small.
  static TextStyle title(BuildContext c,
          {double size = 22, Color? color, FontWeight? weight, bool italic = false}) {
    final w = weight ?? (size < 24 ? FontWeight.w600 : FontWeight.w500);
    return TextStyle(
      fontFamily: titleFamily,
      fontSize: size,
      height: 1.12,
      letterSpacing: -size * 0.004,
      fontWeight: w,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      fontVariations: [
        FontVariation('wght', w.value.toDouble()),
        FontVariation('opsz', size.clamp(6, 96).toDouble()),
      ],
      color: color ?? inkOn(c),
    );
  }

  /// Interface text: buttons, rows, settings.
  static TextStyle label(BuildContext c,
          {Color? color, double size = 14, FontWeight? weight}) =>
      ui(size: size, weight: weight ?? FontWeight.w500, color: color ?? inkSoftOn(c));

  /// Instrumentation: format, language, time left, positions. Written in
  /// capitals by the caller; quiet, tracked and with tabular figures.
  static TextStyle meta(BuildContext c, {Color? color, double size = 11}) => ui(
        size: size,
        weight: FontWeight.w600,
        color: color ?? inkFaintOn(c),
        tracking: 0.07,
        tabular: true,
      ).copyWith(height: 1.45);

  /// Figtree at any weight; the building block of [label] and [meta].
  static TextStyle ui({
    double size = 14,
    FontWeight weight = FontWeight.w500,
    Color? color,
    double tracking = 0,
    bool tabular = false,
  }) =>
      TextStyle(
        fontFamily: uiFamily,
        fontSize: size,
        fontWeight: weight,
        fontVariations: [FontVariation('wght', weight.value.toDouble())],
        letterSpacing: size * tracking,
        fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
        color: color,
      );

  /// The page. [family] is the reader's choice (see [BookFont]).
  static TextStyle page(BuildContext c,
      {double size = 19, BookFont font = BookFont.newsreader, double height = 1.6}) {
    final variable = font == BookFont.newsreader || font == BookFont.literata;
    return TextStyle(
      fontFamily: font.family,
      fontSize: size,
      height: height,
      letterSpacing: font == BookFont.sans ? 0.05 : 0.1,
      fontWeight: FontWeight.w400,
      fontVariations: variable
          ? [
              const FontVariation('wght', 400),
              FontVariation('opsz', size.clamp(7, 72).toDouble()),
            ]
          : font == BookFont.sans
              ? const [FontVariation('wght', 420)]
              : null,
      color: inkOn(c),
    );
  }

  /// Wash behind the sentence being spoken.
  static Color sentenceWash(BuildContext c) => sentenceWashOf(paletteOf(c), Theme.of(c).brightness);

  /// Stronger wash behind the word being spoken.
  static Color wordWash(BuildContext c) => wordWashOf(paletteOf(c), Theme.of(c).brightness);

  static Color sentenceWashOf(Palette p, Brightness b) =>
      p.accent.withValues(alpha: b == Brightness.dark ? 0.20 : 0.16);

  static Color wordWashOf(Palette p, Brightness b) =>
      p.accent.withValues(alpha: b == Brightness.dark ? 0.55 : 0.45);

  // ---- shape -----------------------------------------------------------
  static const capsuleRadius = BorderRadius.all(Radius.circular(Radii.pill));

  static List<BoxShadow> lift(BuildContext c) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark(c) ? 0.35 : 0.07),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];

  // ---- the Flutter theme -----------------------------------------------

  /// Everything Material draws by itself (sliders, switches, sheets, dialogs,
  /// snack bars, menus, fields, the navigation bar) takes its look from here,
  /// so no screen has to restyle a widget by hand.
  static final _themes = <String, ThemeData>{};

  /// The Flutter theme for [p] in [b], built once.
  static ThemeData themeFor(Palette p, Brightness b) => _themes.putIfAbsent('${p.id}/${b.name}', () {
        final previous = palette;
        palette = p;
        try {
          return theme(b);
        } finally {
          palette = previous;
        }
      });

  static ThemeData theme(Brightness b) {
    final dark = b == Brightness.dark;
    final deep = palette.accentDeep;
    // A control's mark (a switch that is on, a bar's fill): the full accent
    // is too pale on a light ground, so by day it is the deep one. A slider
    // by day is on light sheets and on the player's dark bar: a tone between.
    final mark = dark ? amber : deep;
    final slide = dark ? amber : sliderMarkOf(palette);
    final inkColor = palette.inkFor(b);
    final soft = palette.inkSoftFor(b);
    final faint = palette.inkFaintFor(b);
    final sheet = dark ? nightSheet : palette.daySheet;
    final outline = dark ? Colors.white.withValues(alpha: 0.10) : capsuleEdge;
    final scheme = ColorScheme.fromSeed(seedColor: amber, brightness: b).copyWith(
      primary: amber,
      onPrimary: onAmber,
      secondary: amberSoft,
      onSecondary: onAmber,
      surface: sheet,
      onSurface: inkColor,
      onSurfaceVariant: soft,
      surfaceContainerHighest: Color.lerp(sheet, dark ? Colors.white : inkColor, dark ? 0.12 : 0.05),
      surfaceContainerHigh: Color.lerp(sheet, dark ? Colors.white : inkColor, dark ? 0.07 : 0.03),
      surfaceContainer: sheet,
      surfaceContainerLow: sheet,
      surfaceContainerLowest: sheet,
      outline: faint,
      outlineVariant: outline,
      surfaceTint: Colors.transparent,
    );
    TextStyle uiStyle(double size, FontWeight w, [Color? color]) =>
        ui(size: size, weight: w, color: color ?? inkColor);
    final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.pill));

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      fontFamily: uiFamily,
      scaffoldBackgroundColor: dark ? nightBottom : peach,
      splashFactory: InkSparkle.splashFactory,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: mark,
        selectionColor: amber.withValues(alpha: 0.32),
        selectionHandleColor: mark,
      ),
      iconTheme: IconThemeData(color: inkColor, size: 22),
      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: slide,
        inactiveTrackColor: inkColor.withValues(alpha: 0.14),
        thumbColor: dark ? amberSoft : slide,
        overlayColor: amber.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        activeTickMarkColor: Colors.transparent,
        inactiveTickMarkColor: Colors.transparent,
        valueIndicatorColor: sheet,
        valueIndicatorTextStyle: uiStyle(13, FontWeight.w600),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? mark : soft,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? mark.withValues(alpha: 0.42)
              : inkColor.withValues(alpha: 0.14),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? mark : faint,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? mark : Colors.transparent,
        ),
        // The deep accent by day takes a light tick.
        checkColor: WidgetStatePropertyAll(dark ? onAmber : palette.daySheet),
        side: BorderSide(color: faint, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: mark,
        linearTrackColor: inkColor.withValues(alpha: 0.12),
        circularTrackColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: sheet,
        modalBackgroundColor: sheet,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: inkColor.withValues(alpha: 0.22),
        dragHandleSize: const Size(36, 4),
        modalBarrierColor: Colors.black.withValues(alpha: 0.45),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
        titleTextStyle: TextStyle(
          fontFamily: titleFamily,
          fontSize: 24,
          fontWeight: FontWeight.w500,
          fontVariations: const [FontVariation('wght', 500), FontVariation('opsz', 24)],
          color: inkColor,
        ),
        contentTextStyle: uiStyle(15, FontWeight.w400, soft),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: snackFor(palette, b),
        contentTextStyle: uiStyle(14, FontWeight.w500, onDarkFor(palette, b)),
        actionTextColor: amberSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.row)),
        elevation: 0,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.row)),
        textStyle: uiStyle(15, FontWeight.w500),
        labelTextStyle: WidgetStatePropertyAll(uiStyle(15, FontWeight.w500)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: dark ? Colors.white.withValues(alpha: 0.07) : capsule,
        hintStyle: uiStyle(15, FontWeight.w400, faint),
        prefixIconColor: faint,
        suffixIconColor: faint,
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
          borderSide: BorderSide(color: mark, width: 1.4),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? nightBottom : peach,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        height: 66,
        indicatorColor: amber.withValues(alpha: dark ? 0.20 : 0.22),
        indicatorShape: pill,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            size: 24,
            color: s.contains(WidgetState.selected) ? (dark ? amberSoft : deep) : soft,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => uiStyle(
            12,
            s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            s.contains(WidgetState.selected) ? inkColor : soft,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: amber,
          foregroundColor: onAmber,
          shape: pill,
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: 14),
          textStyle: uiStyle(15, FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: dark ? amberSoft : deep,
          shape: pill,
          textStyle: uiStyle(15, FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: inkColor,
          side: BorderSide(color: outline),
          shape: pill,
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: 14),
          textStyle: uiStyle(15, FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: inkColor),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: soft,
        titleTextStyle: uiStyle(16, FontWeight.w500),
        subtitleTextStyle: uiStyle(13.5, FontWeight.w400, faint),
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.xl),
        minVerticalPadding: Gap.m,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: sheet,
        surfaceTintColor: Colors.transparent,
        width: 300,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(Radii.card)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: snackFor(palette, b),
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        textStyle: uiStyle(12.5, FontWeight.w500, onDarkFor(palette, b)),
      ),
      // One way of arriving on a screen, everywhere.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CalmPageTransitionsBuilder(),
          TargetPlatform.iOS: CalmPageTransitionsBuilder(),
          TargetPlatform.macOS: CalmPageTransitionsBuilder(),
          TargetPlatform.windows: CalmPageTransitionsBuilder(),
          TargetPlatform.linux: CalmPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CalmPageTransitionsBuilder(),
        },
      ),
    );
  }

  static const dark2 = Color(0xFF232820);
}

/// A colour theme: the ground the app sits on by day and by night, its
/// surfaces, and its one accent. Type, spacing and shape stay the same in
/// every palette here; a reader's own colours and the wallpaper's have the
/// type's tones fitted to their grounds. Each keeps what it draws text and
/// icons with readable on every surface it is drawn on (see contrast.dart).
class Palette {
  const Palette({
    required this.id,
    required this.label,
    required this.day,
    required this.night,
    required this.accent,
    required this.accentSoft,
    required this.accentDeep,
    required this.onAccent,
    required this.nightCapsule,
    required this.nightSheet,
    this.dayCapsule = const Color(0xF2FFFFFF),
    this.daySheet = const Color(0xFFF7F1E6),
    this.only,
    this.dayInk = Skin.ink,
    this.dayInkSoft = Skin.inkSoft,
    this.dayInkFaint = Skin.inkFaint,
    this.nightInk = Skin.nightInk,
    this.nightInkSoft = Skin.nightInkSoft,
    this.nightInkFaint = Skin.nightInkFaint,
    this.dayDanger = Skin.danger,
    this.nightDanger = Skin.nightDanger,
  });

  final String id;
  final String label;

  /// The light ground, top left to bottom right.
  final List<Color> day;

  /// The dark ground, top left to bottom right.
  final List<Color> night;

  /// Buttons, the spoken word, the selected choice.
  final Color accent;

  /// The accent on dark surfaces, where the full one is too heavy.
  final Color accentSoft;

  /// The accent as text on a light ground, where the full one is too pale.
  /// Each palette's is just deep enough for small text at 4.5:1 on its
  /// deepest band (see contrast.dart).
  final Color accentDeep;

  /// Text on an accent fill.
  final Color onAccent;
  final Color nightCapsule;
  final Color nightSheet;
  final Color dayCapsule;
  final Color daySheet;

  /// A palette that only exists in one brightness (Black, Paper).
  final Brightness? only;

  /// The type by day and by night: the same in every palette here, a
  /// reader's own and the wallpaper's fitted to their grounds.
  final Color dayInk;
  final Color dayInkSoft;
  final Color dayInkFaint;
  final Color nightInk;
  final Color nightInkSoft;
  final Color nightInkFaint;

  /// The warning red by day and by night.
  final Color dayDanger;
  final Color nightDanger;

  Color inkFor(Brightness b) => b == Brightness.dark ? nightInk : dayInk;
  Color inkSoftFor(Brightness b) => b == Brightness.dark ? nightInkSoft : dayInkSoft;
  Color inkFaintFor(Brightness b) => b == Brightness.dark ? nightInkFaint : dayInkFaint;
  Color dangerFor(Brightness b) => b == Brightness.dark ? nightDanger : dayDanger;

  static const forest = Palette(
    id: 'forest',
    label: 'Forest',
    day: [Color(0xFFBFD8C6), Color(0xFFA9CBB6), Color(0xFFEBE0CE), Color(0xFFE7D3BF)],
    night: [Color(0xFF16241C), Color(0xFF1F3128), Color(0xFF33291F), Color(0xFF3D2E1F)],
    accent: Color(0xFFE07B39),
    accentSoft: Color(0xFFF2A05B),
    accentDeep: Color(0xFF803500),
    onAccent: Color(0xFF1A120B),
    nightCapsule: Color(0xF23A4238),
    nightSheet: Color(0xFF0E120C),
  );

  static const lavender = Palette(
    id: 'lavender',
    label: 'Lavender',
    day: [Color(0xFFDCD3F2), Color(0xFFCFC3EC), Color(0xFFEDE3F0), Color(0xFFEAD7E4)],
    night: [Color(0xFF1C1830), Color(0xFF28213F), Color(0xFF35263F), Color(0xFF3D2A40)],
    accent: Color(0xFFB48CF2),
    accentSoft: Color(0xFFCBAEFF),
    accentDeep: Color(0xFF5B37B3),
    onAccent: Color(0xFF1A1229),
    nightCapsule: Color(0xF2403A55),
    nightSheet: Color(0xFF120F1D),
    daySheet: Color(0xFFF6F2FB),
  );

  static const ocean = Palette(
    id: 'ocean',
    label: 'Ocean',
    day: [Color(0xFFC9DFE6), Color(0xFFB5D3DE), Color(0xFFE3E4DA), Color(0xFFE6D8C8)],
    night: [Color(0xFF0E1D25), Color(0xFF15303C), Color(0xFF1C2B33), Color(0xFF25303A)],
    accent: Color(0xFFE8805E),
    accentSoft: Color(0xFFF2A385),
    accentDeep: Color(0xFF8E3715),
    onAccent: Color(0xFF1F0F0A),
    nightCapsule: Color(0xF2324650),
    nightSheet: Color(0xFF0A151B),
    daySheet: Color(0xFFF3F5F2),
  );

  /// True black for OLED screens: the pixels are off.
  static const black = Palette(
    id: 'black',
    label: 'Black',
    day: [Color(0xFF000000), Color(0xFF000000), Color(0xFF050505), Color(0xFF0A0A0A)],
    night: [Color(0xFF000000), Color(0xFF000000), Color(0xFF050505), Color(0xFF0A0A0A)],
    accent: Color(0xFFE07B39),
    accentSoft: Color(0xFFF2A05B),
    accentDeep: Color(0xFFB4561C),
    onAccent: Color(0xFF1A120B),
    nightCapsule: Color(0xF21A1A1A),
    nightSheet: Color(0xFF121212),
    only: Brightness.dark,
  );

  /// Warm sepia, for reading by day. Its sienna is just deep enough for the
  /// cream on a button to read at 4.5:1.
  static const paper = Palette(
    id: 'paper',
    label: 'Paper',
    day: [Color(0xFFF3EBDD), Color(0xFFEFE4D1), Color(0xFFF2E7D5), Color(0xFFEADBC3)],
    night: [Color(0xFF16241C), Color(0xFF1F3128), Color(0xFF33291F), Color(0xFF3D2E1F)],
    accent: Color(0xFFA95B22),
    accentSoft: Color(0xFFD98B4E),
    accentDeep: Color(0xFF884517),
    onAccent: Color(0xFFFBF3E6),
    nightCapsule: Color(0xF23A4238),
    nightSheet: Color(0xFF0E120C),
    dayCapsule: Color(0xF2FFFDF7),
    daySheet: Color(0xFFFBF6EC),
    only: Brightness.light,
  );

  static const all = [forest, lavender, ocean, black, paper];

  static Palette byId(String? id) => all.where((p) => p.id == id).firstOrNull ?? forest;

  /// This palette with its accent taken from [seed], a book cover's colour:
  /// the same grounds, and an accent of the seed's hue at the tones the
  /// palettes use, each moved as little as it takes for text on it and it
  /// on the ground to read (see [readable]). A pale seed is given enough
  /// colour to be an accent.
  Palette withTint(int seed) {
    final key = '${id.split('~').first}~${seed.toRadixString(16)}';
    return _tinted[key] ??= () {
      final hct = Hct.fromInt(seed);
      final chroma = math.max(hct.chroma, 36.0);
      Color tone(double t) => Color(Hct.from(hct.hue, chroma, t).toInt());
      return readable(copyWith(
        id: key,
        accent: tone(66),
        accentSoft: tone(78),
        accentDeep: tone(40),
        onAccent: tone(10),
      ));
    }();
  }

  /// Tinted palettes, worked out once each: every book's card asks.
  static final _tinted = <String, Palette>{};

  /// This palette with the colours given in place of its own.
  Palette copyWith({
    String? id,
    String? label,
    List<Color>? day,
    List<Color>? night,
    Color? accent,
    Color? accentSoft,
    Color? accentDeep,
    Color? onAccent,
    Color? nightCapsule,
    Color? nightSheet,
    Color? dayCapsule,
    Color? daySheet,
    Color? dayInk,
    Color? dayInkSoft,
    Color? dayInkFaint,
    Color? nightInk,
    Color? nightInkSoft,
    Color? nightInkFaint,
    Color? dayDanger,
    Color? nightDanger,
  }) =>
      Palette(
        id: id ?? this.id,
        label: label ?? this.label,
        day: day ?? this.day,
        night: night ?? this.night,
        accent: accent ?? this.accent,
        accentSoft: accentSoft ?? this.accentSoft,
        accentDeep: accentDeep ?? this.accentDeep,
        onAccent: onAccent ?? this.onAccent,
        nightCapsule: nightCapsule ?? this.nightCapsule,
        nightSheet: nightSheet ?? this.nightSheet,
        dayCapsule: dayCapsule ?? this.dayCapsule,
        daySheet: daySheet ?? this.daySheet,
        only: only,
        dayInk: dayInk ?? this.dayInk,
        dayInkSoft: dayInkSoft ?? this.dayInkSoft,
        dayInkFaint: dayInkFaint ?? this.dayInkFaint,
        nightInk: nightInk ?? this.nightInk,
        nightInkSoft: nightInkSoft ?? this.nightInkSoft,
        nightInkFaint: nightInkFaint ?? this.nightInkFaint,
        dayDanger: dayDanger ?? this.dayDanger,
        nightDanger: nightDanger ?? this.nightDanger,
      );

  /// The brightness this palette is shown in, given the reader's choice.
  ThemeMode modeFor(ThemeMode chosen) => switch (only) {
        Brightness.dark => ThemeMode.dark,
        Brightness.light => ThemeMode.light,
        null => chosen,
      };
}

/// The only spacings the interface uses.
class Gap {
  const Gap._();
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Side margin of every screen.
  static const double page = 20;
}

/// The only corner radii the interface uses.
class Radii {
  const Radii._();

  /// Small chips, covers, badges.
  static const double chip = 10;

  /// Rows, fields, menus, snack bars.
  static const double row = 16;

  /// Cards and sheets.
  static const double card = 24;

  /// Buttons and pills.
  static const double pill = 999;
}

/// The only durations and curves the interface moves with: quick, calm and
/// never bouncy. Things settle (ease out) rather than spring.
class Motion {
  const Motion._();

  /// A press, a check appearing, a colour changing.
  static const quick = Duration(milliseconds: 150);

  /// A control changing state: a segment sliding, a header swapping.
  static const standard = Duration(milliseconds: 220);

  /// A screen arriving, a sheet's content changing.
  static const page = Duration(milliseconds: 300);

  /// The page following the voice on to the next sentence or page: long
  /// enough to see which way it went, short enough to keep up with speech.
  static const follow = Duration(milliseconds: 360);

  /// A long way travelled in one move (back to a far place in the book):
  /// slower, so the eye can tell where it ended up.
  static const travel = Duration(milliseconds: 520);

  /// Arriving and settling.
  static const Curve out = Curves.easeOutCubic;

  /// Moving from one place to another.
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// Whether the phone is set to remove animations.
  static bool reduced(BuildContext c) => MediaQuery.maybeDisableAnimationsOf(c) ?? false;

  /// [d], or no time at all when the phone is set to remove animations.
  static Duration of(BuildContext c, Duration d) => reduced(c) ? Duration.zero : d;
}

/// A fade-through: the screen below fades away, then the new one fades in
/// while settling from a touch smaller. Every screen shares the same ground,
/// so nothing slides across it; only what is on it changes.
///
/// Android's predictive back still works: during the gesture the screen
/// shrinks and fades with the finger, showing the one below.
class CalmPageTransitionsBuilder extends PageTransitionsBuilder {
  const CalmPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Motion.page;

  // Going back is a beat quicker than arriving: between standard and page,
  // on purpose, so it has no name of its own in Motion.
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 250);

  // Arriving: after the screen below has gone (the first 30%).
  static const _arrive = Interval(0.3, 1, curve: Curves.easeOutCubic);
  // Leaving: gone in the first 30%, so the screen below can come back.
  static const _leave = Interval(0.7, 1);
  static final _arriveScale = Tween<double>(begin: 0.96, end: 1).chain(CurveTween(curve: _arrive));
  static final _leaveScale = Tween<double>(begin: 0.96, end: 1).chain(CurveTween(curve: _leave));
  static final _gestureScale = Tween<double>(begin: 0.9, end: 1);
  // The screen below, while another arrives on top / leaves it.
  static final _makeWay = Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: const Interval(0, 0.3)));
  static final _comeBack =
      Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: const Interval(0, 0.7, curve: Curves.easeInCubic)));

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Called on every frame of either animation, so the choice below follows
    // the gesture and the direction as they change.
    final gesture = route.popGestureInProgress;
    final reduced = Motion.reduced(context);
    final leaving = animation.status == AnimationStatus.reverse;
    final Animation<double> opacity;
    final Animation<double> scale;
    if (gesture) {
      opacity = animation;
      scale = animation.drive(_gestureScale);
    } else if (reduced) {
      // A short cross-fade, nothing moving.
      opacity = animation.drive(CurveTween(curve: leaving ? const Interval(0.5, 1) : const Interval(0, 0.5)));
      scale = kAlwaysCompleteAnimation;
    } else {
      opacity = animation.drive(CurveTween(curve: leaving ? _leave : _arrive));
      scale = animation.drive(leaving ? _leaveScale : _arriveScale);
    }
    final Animation<double> below = gesture || reduced
        ? kAlwaysCompleteAnimation
        : secondaryAnimation.drive(secondaryAnimation.status == AnimationStatus.reverse ? _comeBack : _makeWay);
    return _BackGesture(
      route: route,
      // While this screen has faded for one above it, the ground shows
      // instead of black.
      child: DecoratedBox(
        decoration: below.value < 1 ? BoxDecoration(gradient: Skin.ground(context)) : const BoxDecoration(),
        child: FadeTransition(
          opacity: below,
          child: FadeTransition(
            opacity: opacity,
            child: ScaleTransition(scale: scale, child: child),
          ),
        ),
      ),
    );
  }
}

/// Hands Android's back gesture to [route], so the screen follows the finger
/// and the one below shows before letting go.
class _BackGesture extends StatefulWidget {
  const _BackGesture({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_BackGesture> createState() => _BackGestureState();
}

class _BackGestureState extends State<_BackGesture> with WidgetsBindingObserver {
  bool get _enabled => widget.route.isCurrent && widget.route.popGestureEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !_enabled) return false;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) =>
      widget.route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);

  @override
  void handleCancelBackGesture() => widget.route.handleCancelBackGesture();

  @override
  void handleCommitBackGesture() => widget.route.handleCommitBackGesture();

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The typeface the book's own text is set in.
enum BookFont {
  newsreader('Newsreader', 'Newsreader'),
  literata('Literata', 'Literata'),
  sans('Sans', 'Figtree'),
  system('Phone', 'serif');

  const BookFont(this.label, this.family);

  final String label;
  final String family;

  static BookFont byName(String? name) =>
      BookFont.values.where((f) => f.name == name).firstOrNull ?? BookFont.newsreader;
}

/// A floating capsule. The single chrome primitive: pills, circular buttons and
/// the bottom bar are all this with different padding. One that can be
/// tapped gives a little under the finger.
class Capsule extends StatefulWidget {
  const Capsule({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 10),
    this.color,
    this.border = true,
    this.radius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsets padding;
  final Color? color;
  final bool border;
  final BorderRadius? radius;

  @override
  State<Capsule> createState() => _CapsuleState();
}

class _CapsuleState extends State<Capsule> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.radius ?? Skin.capsuleRadius;
    final body = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        borderRadius: r,
        border: widget.border ? Border.all(color: Skin.outlineOn(context), width: 1) : null,
      ),
      child: widget.child,
    );
    final capsule = Material(
      color: widget.color ?? Skin.capsuleOn(context),
      borderRadius: r,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      // Only wrap a well when this capsule is itself a target. Nested InkWells
      // (play inside the bottom bar, Remove inside a row) steal or swallow taps.
      child: widget.onTap == null
          ? body
          : InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              onHighlightChanged: (down) => setState(() => _down = down),
              child: body,
            ),
    );
    if (widget.onTap == null) return capsule;
    return AnimatedScale(
      scale: _down ? 0.96 : 1,
      duration: Motion.of(context, Motion.quick),
      curve: Motion.out,
      child: capsule,
    );
  }
}

/// Circular icon button — the reader's top bar and the library header.
///
/// The circle is drawn at [size], but it takes a finger's 48 dp, as Android
/// asks of a target: it sits in the middle of a 48 dp square, and a tap
/// anywhere in that square is its own.
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    this.onTap,
    this.onLongPress,
    this.size = 44,
    this.color,
    this.iconColor,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;

  /// Press and hold; the tooltip then shows only to a screen reader.
  final VoidCallback? onLongPress;
  final double size;
  final Color? color;
  final Color? iconColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = _TapTarget(
      child: SizedBox(
        width: size,
        height: size,
        child: Capsule(
          onTap: onTap,
          onLongPress: onLongPress,
          padding: EdgeInsets.zero,
          color: color,
          child: Icon(
            icon,
            size: size * 0.46,
            color: iconColor ?? Skin.inkOn(context),
          ),
        ),
      ),
    );
    // With no tooltip, it is the drawing of another's button (a menu's),
    // which has the node a screen reader finds.
    if (tooltip == null) return button;
    // One node for a screen reader, named by the tooltip, the size of the
    // whole target.
    return Semantics(
      container: true,
      button: onTap != null,
      child: Tooltip(
        message: tooltip!,
        triggerMode: onLongPress == null ? null : TooltipTriggerMode.manual,
        child: button,
      ),
    );
  }
}

/// [child] in the middle of a square at least 48 dp across (a finger's
/// target), with a tap anywhere in that square handed to [child] as if at
/// its centre, as Material pads its own buttons. The drawing keeps its
/// size; only the room it takes and the reach of a tap grow.
class _TapTarget extends SingleChildRenderObjectWidget {
  const _TapTarget({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTapTarget();
}

class _RenderTapTarget extends RenderShiftedBox {
  _RenderTapTarget() : super(null);

  static const _min = kMinInteractiveDimension;

  @override
  double computeMinIntrinsicWidth(double height) => math.max(super.computeMinIntrinsicWidth(height), _min);

  @override
  double computeMaxIntrinsicWidth(double height) => math.max(super.computeMaxIntrinsicWidth(height), _min);

  @override
  double computeMinIntrinsicHeight(double width) => math.max(super.computeMinIntrinsicHeight(width), _min);

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(super.computeMaxIntrinsicHeight(width), _min);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.constrain(const Size(_min, _min));
    final inner = child.getDryLayout(constraints.loosen());
    return constraints.constrain(Size(math.max(inner.width, _min), math.max(inner.height, _min)));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(const Size(_min, _min));
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(Size(math.max(child.size.width, _min), math.max(child.size.height, _min)));
    (child.parentData! as BoxParentData).offset = Alignment.center.alongOffset(size - child.size as Offset);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    final child = this.child;
    // Outside the drawing but inside the square: the drawing's own, at its
    // centre. Outside the square: not this button's.
    if (child == null || !size.contains(position)) return false;
    final centre = child.size.center(Offset.zero);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(centre),
      position: centre,
      hitTest: (result, _) => child.hitTest(result, position: centre),
    );
  }
}

/// A part of the app in one book's colours: [palette] is the app's with the
/// book's accent (see [BookTint]).
class TintScope extends InheritedWidget {
  const TintScope({super.key, required this.palette, required super.child});

  final Palette palette;

  @override
  bool updateShouldNotify(TintScope oldWidget) => oldWidget.palette.id != palette.id;
}
