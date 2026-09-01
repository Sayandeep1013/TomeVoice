import 'package:flutter/material.dart';

/// The visual language, in one place.
///
/// Taken from the reference the developer supplied: a font-specimen app
/// (72pt.app showing Ojuju). See docs/10 ADR-017 for why it fits — a specimen
/// and a reader share a job, which is to present type as the subject rather
/// than as the interface.
///
/// The rules that make it read as that design rather than a generic app:
///
/// * The ground is a soft diagonal gradient, never a flat fill.
/// * Controls float *over* the content as capsules; nothing is a bar pinned to
///   an edge with its own background.
/// * Metadata is monospace, uppercase and letterspaced, and sits quietly at low
///   contrast. It is instrumentation, not headline.
/// * One accent colour, used sparingly, always amber.
/// * The type is the loudest thing on screen by a wide margin.
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
  static const inkFaint = Color(0xFF737C6D);

  // ---- chrome ----------------------------------------------------------
  static const capsule = Color(0xF2FFFFFF);
  static const capsuleEdge = Color(0x1A14170F);
  static const dark = Color(0xFF1C1F17);
  static const darkSoft = Color(0xFF2A2E24);

  // ---- accent ----------------------------------------------------------
  static const amber = Color(0xFFE07B39);
  static const amberSoft = Color(0xFFF2A05B);

  // ---- dark theme ------------------------------------------------------
  static const nightTop = Color(0xFF1B241E);
  static const nightBottom = Color(0xFF2A2621);
  static const nightInk = Color(0xFFEDE7DA);
  static const nightInkSoft = Color(0xFFB3AE9F);
  static const nightCapsule = Color(0xE62F3329);

  static bool isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  /// The diagonal wash everything sits on. Mint into cream by day, two greens
  /// into warm charcoal by night — the same move, not an inversion.
  static LinearGradient ground(BuildContext c) => isDark(c)
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [nightTop, Color(0xFF232A24), nightBottom],
          stops: [0.0, 0.55, 1.0],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [mint, mintDeep, cream, peach],
          stops: [0.0, 0.28, 0.72, 1.0],
        );

  static Color inkOn(BuildContext c) => isDark(c) ? nightInk : ink;
  static Color inkSoftOn(BuildContext c) => isDark(c) ? nightInkSoft : inkSoft;
  static Color inkFaintOn(BuildContext c) =>
      isDark(c) ? const Color(0xFF8A8578) : inkFaint;
  static Color capsuleOn(BuildContext c) => isDark(c) ? nightCapsule : capsule;
  static Color darkOn(BuildContext c) =>
      isDark(c) ? const Color(0xFF0E120C) : dark;
  static Color onDark(BuildContext c) => isDark(c) ? nightInk : cream;

  // ---- type ------------------------------------------------------------

  /// The specimen face. Used for the text being read and nothing else — it is
  /// the subject, so it must not also be the furniture.
  static TextStyle display(BuildContext c, double size) => TextStyle(
        fontFamily: 'Ojuju',
        fontSize: size,
        height: 1.02,
        letterSpacing: -size * 0.02,
        fontWeight: FontWeight.w700,
        color: inkOn(c),
      );

  /// Instrumentation: voice, speed, gap, position. Quiet by design.
  static TextStyle meta(BuildContext c, {Color? color, double size = 9.5}) =>
      TextStyle(
        fontFamily: 'SpaceMono',
        fontSize: size,
        height: 1.7,
        letterSpacing: 1.3,
        color: color ?? inkFaintOn(c),
      );

  static TextStyle label(BuildContext c,
          {Color? color, double size = 11, FontWeight? weight}) =>
      TextStyle(
        fontFamily: 'SpaceMono',
        fontSize: size,
        letterSpacing: 0.9,
        fontWeight: weight ?? FontWeight.w400,
        color: color ?? inkSoftOn(c),
      );

  // ---- shape -----------------------------------------------------------
  static const capsuleRadius = BorderRadius.all(Radius.circular(999));
  static const panelRadius = BorderRadius.only(
    topLeft: Radius.circular(28),
    bottomLeft: Radius.circular(28),
  );

  static List<BoxShadow> lift(BuildContext c) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark(c) ? 0.35 : 0.07),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
}

/// A floating capsule. The single chrome primitive: pills, circular buttons and
/// the bottom bar are all this with different padding.
class Capsule extends StatelessWidget {
  const Capsule({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
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
    return Material(
      color: color ?? Skin.capsuleOn(context),
      borderRadius: r,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: r,
            border: border
                ? Border.all(color: Skin.capsuleEdge, width: 1)
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Circular icon button — the top-right cluster and the ‹ › pair.
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
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
          size: size * 0.44,
          color: iconColor ?? Skin.inkOn(context),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
