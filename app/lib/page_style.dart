import 'package:flutter/material.dart';

import 'contrast.dart' show readAloudInks;
import 'page_tone.dart';
import 'paged_view.dart' show PageLook;
import 'prefs.dart';
import 'theme.dart';

/// How a book's page is set, in every view of it: the scrolling page and
/// the pages take their type and colours from one of these, made once each
/// time the reader is built, and so do the bars over them, a PDF's real
/// pages and Now Playing. Each used to work its own out, and they drifted
/// apart: the scroll once kept the app's ink on a page tone's paper (near
/// white on Papyrus with the phone gone dark) while pages had the tone's.
@immutable
class PageStyle {
  const PageStyle._({
    required this.tone,
    required this.dark,
    required this.look,
    required this.ink,
    required this.ornamentInk,
    required this.paper,
    required this.paperTop,
    required this.paperFoot,
    required this.pdfPaper,
    required this.emptyText,
  });

  /// The page as [prefs] set it: its tone, type, size, spacing and margins.
  factory PageStyle.of(BuildContext context, ListeningPrefs prefs) {
    final scale = prefs.textSize / 19;
    final tone = PageTone.byId(prefs.pageTone);
    final ink = tone.inkOf(context);
    final accent = tone.accentOf(context);
    final dark = tone.dark || (tone.isApp && Skin.isDark(context));
    // Dusk's word was washed at half strength, where only a near-white ink
    // read on it: there, as on the light papers, at a little over a third.
    final sentenceWash = tone.isApp ? Skin.sentenceWash(context) : accent.withValues(alpha: tone.dark ? 0.22 : 0.16);
    final wordWash = tone.isApp ? Skin.wordWash(context) : accent.withValues(alpha: 0.36);
    // The word being read, and a chapter's heading (read on the sentence's
    // wash), in inks that read on what lies under them.
    final inks = readAloudInks(
      shades: tone.shadesOf(context),
      ink: ink,
      accent: accent,
      sentenceWash: sentenceWash,
      wordWash: wordWash,
      dark: dark,
    );
    return PageStyle._(
      tone: tone,
      dark: dark,
      look: PageLook(
        text: Skin.page(context, size: prefs.textSize, font: prefs.bookFont, height: prefs.lineHeight)
            .copyWith(color: ink),
        heading: Skin.title(context, size: 22 * scale, weight: FontWeight.w500).copyWith(height: 1.2, color: ink),
        chapterHeading:
            Skin.title(context, size: 30 * scale, weight: FontWeight.w500).copyWith(height: 1.2, color: inks.heading),
        title: Skin.title(context, size: 30 * scale, weight: FontWeight.w500).copyWith(color: accent),
        label: Skin.meta(context, size: 11, color: accent).copyWith(fontWeight: FontWeight.w600),
        status: Skin.meta(context, size: 10, color: tone.inkSoft),
        accent: accent,
        sentenceWash: sentenceWash,
        wordWash: wordWash,
        wordInk: inks.word,
        textScaler: MediaQuery.textScalerOf(context),
        justify: prefs.justify,
        indent: prefs.indent,
        margin: prefs.margin,
      ),
      ink: ink,
      ornamentInk: tone.inkSoft ?? Skin.inkSoftOn(context),
      paper: tone.paperOf(context),
      paperTop: tone.paper?.first ?? Skin.ground(context).colors.first,
      paperFoot: tone.paper?.last ?? Skin.groundFoot(context),
      pdfPaper: tone.paper?.first ?? Skin.darkOn(context),
      emptyText: Skin.page(context, size: 20).copyWith(color: ink),
    );
  }

  final PageTone tone;

  /// A dark page (light text): Dusk, or the app's own tone in the dark.
  final bool dark;

  /// The book's type and colours, alike on the scroll and in pages.
  final PageLook look;

  /// The page's ink: the tone's, or the app's.
  final Color ink;

  /// A printer's ornament, drawn in the page's soft ink with its white
  /// taken out.
  final Color ornamentInk;

  /// The paper under pages (a turning page hides the one under it).
  final BoxDecoration paper;

  /// The paper at the top and at the foot, which the bars over pages fade
  /// into.
  final Color paperTop;
  final Color paperFoot;

  /// What a PDF's white turns into on a dark page.
  final Color pdfPaper;

  /// "This file has no text that can be read aloud."
  final TextStyle emptyText;

  /// The top bar's title, in the tone's ink: the app's (cream in a dark
  /// theme) vanished on Ink's white. Null keeps the app's own.
  Color? get barInk => tone.ink;

  /// The top bar's chapter line and the like, in the tone's soft ink.
  Color? get barSoftInk => tone.inkSoft;

  /// The binding between two open pages: the page's own ink, black on a
  /// dark page.
  Color get crease => dark ? Colors.black : ink;

  /// The phone's bars drawn light on a dark page, dark on a light one.
  Brightness get barIcons => dark ? Brightness.light : Brightness.dark;

  /// On a dark page, a PDF's real page drawn in the page's paper and ink,
  /// so a white page is no lamp at night. Null on a light one: the page as
  /// it was printed.
  ({Color paper, Color ink})? get pdfInk => dark ? (paper: pdfPaper, ink: ink) : null;

  /// Now Playing's passage: the book in the reader's text size, in its own
  /// face whatever the page's font, in [color] on its dark backdrop; a
  /// heading in the title face. (It reads the size from the prefs as it is
  /// built, as it stays open over the reader while a sheet changes them.)
  static TextStyle passage(BuildContext context, ListeningPrefs prefs, {required bool heading, required Color color}) {
    final size = prefs.textSize;
    return heading
        ? Skin.title(context, size: size * 21 / 19, color: color)
        : TextStyle(fontFamily: 'Newsreader', fontSize: size, height: 1.5, color: color);
  }
}
