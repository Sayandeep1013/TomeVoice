// Focused contract for the contributed premium palette file: registration,
// id lookup, brightness locks and the mapping from a Palette to the real
// ThemeData the rest of the app consumes. The repository's colours_test.dart
// already checks every registered palette for WCAG contrast; this test makes
// sure the seven contributed ones are actually registered and wired in.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/contrast.dart';
import 'package:tomevoice_spike/theme.dart';

void main() {
  group('premium themes', () {
    test('all seven are registered by id and resolvable through Palette.byId',
        () {
      expect(PremiumThemes.all.length, 7);
      expect(
        PremiumThemes.all.map((p) => p.id).toSet().length,
        7,
        reason: 'ids must be unique',
      );
      for (final p in PremiumThemes.all) {
        expect(
          Palette.all.where((registered) => registered.id == p.id),
          hasLength(1),
          reason: '${p.label} must be in Palette.all',
        );
        expect(Palette.byId(p.id), same(p), reason: p.label);
      }
    });

    test('each palette meets the app contrast contract', () {
      for (final p in PremiumThemes.all) {
        expect(unmetNeeds(p), isEmpty, reason: p.label);
      }
    });

    test('brightness locks use the existing modeFor behaviour', () {
      for (final p in PremiumThemes.all) {
        if (p.only != null) {
          expect(p.modeFor(ThemeMode.system),
              p.only == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
              reason: p.label);
          expect(p.modeFor(ThemeMode.light), p.modeFor(ThemeMode.dark),
              reason: p.label);
        } else {
          expect(p.modeFor(ThemeMode.system), ThemeMode.system,
              reason: p.label);
        }
      }
      expect(PremiumThemes.obsidianLuxe.only, Brightness.dark);
      expect(PremiumThemes.amethystNoir.only, Brightness.dark);
    });

    test('Skin.themeFor maps every palette onto the real ThemeData fields', () {
      for (final p in PremiumThemes.all) {
        for (final b in Brightness.values) {
          if (p.only != null && p.only != b) continue;
          final theme = Skin.themeFor(p, b);
          final dark = b == Brightness.dark;
          final sheet = dark ? p.nightSheet : p.daySheet;
          final foot = dark ? p.night[3] : p.day[3];
          final reason = '${p.label} ${b.name}';

          expect(theme.scaffoldBackgroundColor, foot, reason: reason);
          expect(theme.colorScheme.primary, p.accent, reason: reason);
          expect(theme.colorScheme.surface, sheet, reason: reason);
          expect(theme.bottomSheetTheme.backgroundColor, sheet, reason: reason);
          expect(theme.dialogTheme.backgroundColor, sheet, reason: reason);
          expect(theme.navigationBarTheme.backgroundColor, foot,
              reason: reason);
          expect(theme.progressIndicatorTheme.color,
              dark ? p.accent : p.accentDeep,
              reason: reason);
          expect(
            theme.filledButtonTheme.style?.backgroundColor
                ?.resolve(<WidgetState>{}),
            p.accent,
            reason: reason,
          );
          expect(theme.snackBarTheme.backgroundColor, Skin.snackFor(p, b),
              reason: reason);
        }
      }
    });
  });
}
