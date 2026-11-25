// Premium colour themes contributed to TomeVoice as an isolated palette file.
//
// This is a `part` of theme.dart on purpose: it reuses [Palette] and
// [readable] without adding a second import path or a registry API. Every
// colour a theme owns is declared here; no screen, widget or app logic reads
// a colour directly from this file.

part of 'theme.dart';

/// Seven contributor themes, fitted with [readable] exactly like the
/// built-in designer themes. Add `...PremiumThemes.all` to [Palette.all] to
/// register them; selection, persistence and previews are already generic.
class PremiumThemes {
  const PremiumThemes._();

  /// OLED black, graphite and champagne gold: a restrained evening theme.
  /// Dark-only, so the OLED ground is never replaced by a light one.
  static final obsidianLuxe = readable(const Palette(
    id: 'obsidian-luxe',
    label: 'Obsidian Luxe',
    day: [
      Color(0xFF2A2A28),
      Color(0xFF3A3A36),
      Color(0xFFE8DFC9),
      Color(0xFFD8C9A8),
    ],
    night: [
      Color(0xFF000000),
      Color(0xFF070707),
      Color(0xFF11100E),
      Color(0xFF1A1815),
    ],
    accent: Color(0xFFD9B45E),
    accentSoft: Color(0xFFE8CE91),
    accentDeep: Color(0xFF8A651F),
    onAccent: Color(0xFF1A1408),
    nightCapsule: Color(0xF2161616),
    nightSheet: Color(0xFF080808),
    dayCapsule: Color(0xF2FFFFFF),
    daySheet: Color(0xFFF8F3E7),
    only: Brightness.dark,
    dayInk: Color(0xFF17150F),
    dayInkSoft: Color(0xFF4A463C),
    dayInkFaint: Color(0xFF4A463C),
    nightInk: Color(0xFFF6EFE1),
    nightInkSoft: Color(0xFFC6BCAB),
    nightInkFaint: Color(0xFFBEB3A2),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF9A80),
  ));

  /// Midnight navy, sapphire blue and silver: a cool, legible classic.
  static final midnightSapphire = readable(const Palette(
    id: 'midnight-sapphire',
    label: 'Midnight Sapphire',
    day: [
      Color(0xFFD9E3F2),
      Color(0xFFC7D6EC),
      Color(0xFFE8EAF0),
      Color(0xFFDDE3EA),
    ],
    night: [
      Color(0xFF080F1F),
      Color(0xFF0F1D38),
      Color(0xFF172A4A),
      Color(0xFF1D2E4A),
    ],
    accent: Color(0xFF789BE0),
    accentSoft: Color(0xFFA9C2F2),
    accentDeep: Color(0xFF3557A8),
    onAccent: Color(0xFF08122B),
    nightCapsule: Color(0xF2182439),
    nightSheet: Color(0xFF070C18),
    dayCapsule: Color(0xF2FBFDFF),
    daySheet: Color(0xFFF3F6FB),
    dayInk: Color(0xFF111827),
    dayInkSoft: Color(0xFF3E4A60),
    dayInkFaint: Color(0xFF465268),
    nightInk: Color(0xFFF2F6FF),
    nightInkSoft: Color(0xFFC2CCE0),
    nightInkFaint: Color(0xFFBAC6DA),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF9687),
  ));

  /// Burgundy, wine, rose gold and ivory: a library-at-dusk theme.
  static final royalBurgundy = readable(const Palette(
    id: 'royal-burgundy',
    label: 'Royal Burgundy',
    day: [
      Color(0xFFEFDFE0),
      Color(0xFFE6CCD0),
      Color(0xFFF3E8E2),
      Color(0xFFEEDCD6),
    ],
    night: [
      Color(0xFF1F0C12),
      Color(0xFF2C121A),
      Color(0xFF3A1E25),
      Color(0xFF43232B),
    ],
    accent: Color(0xFFE0A08D),
    accentSoft: Color(0xFFEFC0AF),
    accentDeep: Color(0xFF9B4E42),
    onAccent: Color(0xFF24100B),
    nightCapsule: Color(0xF2361E26),
    nightSheet: Color(0xFF15090D),
    dayCapsule: Color(0xF2FFFBF8),
    daySheet: Color(0xFFFBF3EE),
    dayInk: Color(0xFF211417),
    dayInkSoft: Color(0xFF554148),
    dayInkFaint: Color(0xFF5A444B),
    nightInk: Color(0xFFFBF0EE),
    nightInkSoft: Color(0xFFDCC5C6),
    nightInkFaint: Color(0xFFD3BCBD),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF9787),
  ));

  /// Forest green, jade, muted gold and cream: a heritage-study theme.
  static final emeraldHeritage = readable(const Palette(
    id: 'emerald-heritage',
    label: 'Emerald Heritage',
    day: [
      Color(0xFFDCE8D8),
      Color(0xFFC9DCC8),
      Color(0xFFEFEAD8),
      Color(0xFFE6DEC5),
    ],
    night: [
      Color(0xFF08180F),
      Color(0xFF10281A),
      Color(0xFF193424),
      Color(0xFF1E3828),
    ],
    accent: Color(0xFF54BFA0),
    accentSoft: Color(0xFF8CDCC0),
    accentDeep: Color(0xFF1F7A5E),
    onAccent: Color(0xFF0A1F16),
    nightCapsule: Color(0xF2142A1D),
    nightSheet: Color(0xFF060F0A),
    dayCapsule: Color(0xF2FBFFF8),
    daySheet: Color(0xFFF6F4E6),
    dayInk: Color(0xFF122117),
    dayInkSoft: Color(0xFF3E5044),
    dayInkFaint: Color(0xFF44564A),
    nightInk: Color(0xFFF0F7EF),
    nightInkSoft: Color(0xFFBFCEC0),
    nightInkFaint: Color(0xFFB7C7B8),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF9582),
  ));

  /// Cool white, silver, ice blue and charcoal: a quiet, airy theme.
  static final arcticSilver = readable(const Palette(
    id: 'arctic-silver',
    label: 'Arctic Silver',
    day: [
      Color(0xFFF2F6F8),
      Color(0xFFE4ECF2),
      Color(0xFFF4F7F8),
      Color(0xFFE8EFF3),
    ],
    night: [
      Color(0xFF0A1015),
      Color(0xFF131D26),
      Color(0xFF1E2B36),
      Color(0xFF24313C),
    ],
    accent: Color(0xFF5FA8C9),
    accentSoft: Color(0xFF94CBE1),
    accentDeep: Color(0xFF2D718F),
    onAccent: Color(0xFF06151F),
    nightCapsule: Color(0xF218232D),
    nightSheet: Color(0xFF060B10),
    dayCapsule: Color(0xF2FFFFFF),
    daySheet: Color(0xFFF5F8FA),
    dayInk: Color(0xFF101820),
    dayInkSoft: Color(0xFF3C4A56),
    dayInkFaint: Color(0xFF42505C),
    nightInk: Color(0xFFFFFFFF),
    nightInkSoft: Color(0xFFD3DEE7),
    nightInkFaint: Color(0xFFCBD8E2),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF978A),
  ));

  /// Espresso, caramel, bronze and parchment: a warm atelier theme.
  static final mochaAtelier = readable(const Palette(
    id: 'mocha-atelier',
    label: 'Mocha Atelier',
    day: [
      Color(0xFFEDE2D3),
      Color(0xFFDFCFB9),
      Color(0xFFF2E8D8),
      Color(0xFFEADBC6),
    ],
    night: [
      Color(0xFF1B120C),
      Color(0xFF281A11),
      Color(0xFF352619),
      Color(0xFF3D2C1E),
    ],
    accent: Color(0xFFC98A4B),
    accentSoft: Color(0xFFE2B27A),
    accentDeep: Color(0xFF8A5421),
    onAccent: Color(0xFF1E1208),
    nightCapsule: Color(0xF22E2118),
    nightSheet: Color(0xFF100A06),
    dayCapsule: Color(0xF2FFFCF6),
    daySheet: Color(0xFFF8F1E5),
    dayInk: Color(0xFF1E160F),
    dayInkSoft: Color(0xFF504236),
    dayInkFaint: Color(0xFF564638),
    nightInk: Color(0xFFF7EEE0),
    nightInkSoft: Color(0xFFD2C0A9),
    nightInkFaint: Color(0xFFC9B7A0),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF9A84),
  ));

  /// Violet-black, amethyst, lavender and silver: a nocturnal jewel theme.
  /// Dark-only, so the violet-black ground keeps its depth.
  static final amethystNoir = readable(const Palette(
    id: 'amethyst-noir',
    label: 'Amethyst Noir',
    day: [
      Color(0xFFE4DDF0),
      Color(0xFFD3C8E8),
      Color(0xFFF0ECF6),
      Color(0xFFE7DDEE),
    ],
    night: [
      Color(0xFF0D0814),
      Color(0xFF170F24),
      Color(0xFF241833),
      Color(0xFF2C1E3D),
    ],
    accent: Color(0xFFB994EA),
    accentSoft: Color(0xFFD4C0F5),
    accentDeep: Color(0xFF6F48B8),
    onAccent: Color(0xFF160C27),
    nightCapsule: Color(0xF2211830),
    nightSheet: Color(0xFF090612),
    dayCapsule: Color(0xF2FDFBFF),
    daySheet: Color(0xFFF6F2FA),
    only: Brightness.dark,
    dayInk: Color(0xFF171125),
    dayInkSoft: Color(0xFF453B58),
    dayInkFaint: Color(0xFF4A405D),
    nightInk: Color(0xFFF5F0FA),
    nightInkSoft: Color(0xFFCFC2E0),
    nightInkFaint: Color(0xFFC7BAD8),
    dayDanger: Color(0xFF8C2713),
    nightDanger: Color(0xFFFF9A90),
  ));

  /// Registration order, matching the order in the contribution README.
  static final all = [
    obsidianLuxe,
    midnightSapphire,
    royalBurgundy,
    emeraldHeritage,
    arcticSilver,
    mochaAtelier,
    amethystNoir,
  ];
}
