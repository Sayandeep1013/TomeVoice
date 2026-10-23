import 'package:flutter/material.dart';

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
/// [Radii]; nothing else should invent its own.
class Skin {
  const Skin._();

  // ---- ground ----------------------------------------------------------
  static const mint = Color(0xFFBFD8C6);
  static const mintDeep = Color(0xFFA9CBB6);
  static const cream = Color(0xFFEBE0CE);
  static const peach = Color(0xFFE7D3BF);

  // ---- ink -------------------------------------------------------------
  static const ink = Color(0xFF14170F);
  static const inkSoft = Color(0xFF4A5245);
  static const inkFaint = Color(0xFF6B7466);

  // ---- chrome ----------------------------------------------------------
  static const capsule = Color(0xF2FFFFFF);
  static const capsuleEdge = Color(0x1A14170F);
  static const dark = Color(0xFF1C1F17);
  static const darkSoft = Color(0xFF2A2E24);

  // ---- accent ----------------------------------------------------------
  static const amber = Color(0xFFE07B39);
  static const amberSoft = Color(0xFFF2A05B);

  /// Text on an amber fill.
  static const onAmber = Color(0xFF1A120B);

  // ---- dark theme ------------------------------------------------------
  //
  // Not an inversion. The light ground travels mint -> cream, so the dark one
  // travels deep forest -> warm ember through the same diagonal.
  static const nightTop = Color(0xFF16241C);
  static const nightMid = Color(0xFF1F3128);
  static const nightWarm = Color(0xFF33291F);
  static const nightBottom = Color(0xFF3D2E1F);
  static const nightInk = Color(0xFFF2EADA);
  static const nightInkSoft = Color(0xFFB9B2A0);
  static const nightInkFaint = Color(0xFF948E80);
  static const nightCapsule = Color(0xF23A4238);

  /// Sheets, the player, the Continue card: the deepest surface.
  static const nightSheet = Color(0xFF0E120C);

  static bool isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  /// The diagonal wash everything sits on.
  static LinearGradient ground(BuildContext c) => groundFor(Theme.of(c).brightness);

  static LinearGradient groundFor(Brightness b) => b == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [nightTop, nightMid, nightWarm, nightBottom],
          stops: [0.0, 0.30, 0.72, 1.0],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [mint, mintDeep, cream, peach],
          stops: [0.0, 0.28, 0.72, 1.0],
        );

  /// The colour at the foot of the ground: the navigation bar sits on it, so
  /// the bottom of the screen has no seam.
  static Color groundFoot(BuildContext c) => isDark(c) ? nightBottom : peach;

  static Color inkOn(BuildContext c) => isDark(c) ? nightInk : ink;
  static Color inkSoftOn(BuildContext c) => isDark(c) ? nightInkSoft : inkSoft;
  static Color inkFaintOn(BuildContext c) => isDark(c) ? nightInkFaint : inkFaint;
  static Color capsuleOn(BuildContext c) => isDark(c) ? nightCapsule : capsule;
  static Color darkOn(BuildContext c) => isDark(c) ? nightSheet : dark;
  static Color onDark(BuildContext c) => isDark(c) ? nightInk : cream;

  /// A hairline: borders of rows, fields and dividers.
  static Color outlineOn(BuildContext c) =>
      isDark(c) ? Colors.white.withValues(alpha: 0.09) : capsuleEdge;

  /// Something raised on a sheet (a choice, a voice row).
  static Color raisedOn(BuildContext c) => Colors.white.withValues(alpha: 0.07);

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
  static Color sentenceWash(BuildContext c) =>
      amber.withValues(alpha: isDark(c) ? 0.20 : 0.16);

  /// Stronger wash behind the word being spoken.
  static Color wordWash(BuildContext c) =>
      amber.withValues(alpha: isDark(c) ? 0.55 : 0.45);

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
  static ThemeData theme(Brightness b) {
    final dark = b == Brightness.dark;
    final inkColor = dark ? nightInk : ink;
    final soft = dark ? nightInkSoft : inkSoft;
    final faint = dark ? nightInkFaint : inkFaint;
    final sheet = dark ? nightSheet : const Color(0xFFF7F1E6);
    final outline = dark ? Colors.white.withValues(alpha: 0.10) : capsuleEdge;
    final scheme = ColorScheme.fromSeed(seedColor: amber, brightness: b).copyWith(
      primary: amber,
      onPrimary: onAmber,
      secondary: amberSoft,
      onSecondary: onAmber,
      surface: sheet,
      onSurface: inkColor,
      onSurfaceVariant: soft,
      surfaceContainerHighest: dark ? const Color(0xFF26302A) : const Color(0xFFEFE6D6),
      surfaceContainerHigh: dark ? const Color(0xFF1C241F) : const Color(0xFFF3EBDD),
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
        cursorColor: amber,
        selectionColor: amber.withValues(alpha: 0.32),
        selectionHandleColor: amber,
      ),
      iconTheme: IconThemeData(color: inkColor, size: 22),
      dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: amber,
        inactiveTrackColor: inkColor.withValues(alpha: 0.14),
        thumbColor: amberSoft,
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
          (s) => s.contains(WidgetState.selected) ? amber : soft,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? amber.withValues(alpha: 0.42)
              : inkColor.withValues(alpha: 0.14),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? amber : faint,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? amber : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(onAmber),
        side: BorderSide(color: faint, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: amber,
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
        backgroundColor: dark ? const Color(0xFF26302A) : dark2,
        contentTextStyle: uiStyle(14, FontWeight.w500, dark ? nightInk : cream),
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
          borderSide: const BorderSide(color: amber, width: 1.4),
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
            color: s.contains(WidgetState.selected) ? (dark ? amberSoft : const Color(0xFFB4561C)) : soft,
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
          foregroundColor: dark ? amberSoft : const Color(0xFFB4561C),
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
          color: dark ? const Color(0xFF26302A) : dark2,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        textStyle: uiStyle(12.5, FontWeight.w500, dark ? nightInk : cream),
      ),
    );
  }

  static const dark2 = Color(0xFF232820);
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
/// the bottom bar are all this with different padding.
class Capsule extends StatelessWidget {
  const Capsule({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 10),
    this.color,
    this.border = true,
    this.radius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final Color? color;
  final bool border;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? Skin.capsuleRadius;
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        border: border ? Border.all(color: Skin.outlineOn(context), width: 1) : null,
      ),
      child: child,
    );
    return Material(
      color: color ?? Skin.capsuleOn(context),
      borderRadius: r,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      // Only wrap a well when this capsule is itself a target. Nested InkWells
      // (play inside the bottom bar, Remove inside a row) steal or swallow taps.
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// Circular icon button — the reader's top bar and the library header.
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 44,
    this.color,
    this.iconColor,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color? color;
  final Color? iconColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: Capsule(
        onTap: onTap,
        padding: EdgeInsets.zero,
        color: color,
        child: Icon(
          icon,
          size: size * 0.46,
          color: iconColor ?? Skin.inkOn(context),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
