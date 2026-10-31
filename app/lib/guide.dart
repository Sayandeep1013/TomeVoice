import 'dart:io';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'theme.dart';
import 'ui.dart';

/// Show the guide over the app (Settings asks for it again).
Future<void> showGuide(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GuideScreen()));

/// A short guide to TomeVoice: bringing books in, pressing play, the
/// phone's voices and the natural ones, and the page's taps, holds and
/// bars. Four cards, swiped or stepped through, and skipped at any one.
/// Shown by itself once, on a new install's first launch (see HomeShell),
/// and from Settings whenever asked.
///
/// Drawn from the app's own pieces (its ground, type, icons and accent):
/// nothing to download or unpack. Each card is read by TalkBack as it
/// arrives: its title is a live heading, and the steps through it are
/// buttons with names.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});

  /// Whether a first launch shows the guide by itself. Off in tests, as the
  /// starter shelf is: a test's empty library is not someone new.
  static bool onFirstLaunch = !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

/// One card: what it is about, in a line, and the few things to know.
class _Card {
  const _Card(this.icon, this.title, this.lede, this.points);

  final IconData icon;
  final String title;
  final String lede;
  final List<(IconData, String)> points;
}

const _cards = [
  _Card(
    Icons.library_add_outlined,
    'Bring your books',
    'EPUB, PDF, Word, MOBI, FB2 and plain text, read aloud on your phone.',
    [
      (Icons.add_rounded, 'Add books, at the top of the library: books on this phone, or a link.'),
      (Icons.local_library_outlined, 'Catalogues, in the menu: free classics to download.'),
      (Icons.travel_explore_rounded, 'Browse, in the menu: web novels from their sites.'),
    ],
  ),
  _Card(
    Icons.play_arrow_rounded,
    'Press play',
    'Open a book and press play. The page follows the voice, the sentence lit as it is read.',
    [
      (Icons.speed_rounded, 'The speed, the voice and the sleep timer are on the player.'),
      (Icons.swipe_up_rounded, 'Swipe the player up for Now Playing.'),
      (Icons.notifications_none_rounded, 'Leave the book and it reads on: pause it from the library or the notification.'),
    ],
  ),
  _Card(
    Icons.record_voice_over_rounded,
    'Two kinds of voice',
    'Any book can be read by either, and each book keeps its own.',
    [
      (Icons.phone_android_rounded, "Your phone's voices: there already, and offline."),
      (Icons.auto_awesome_rounded, 'Natural voices sound like people: download one once, and it reads offline too.'),
      (Icons.tune_rounded, 'Tap the voice on the player to change it, or to try a natural one.'),
    ],
  ),
  _Card(
    Icons.touch_app_outlined,
    'Taps, holds and bars',
    'The page keeps out of the way while you read.',
    [
      (Icons.touch_app_outlined, 'Tap the page to put the bars away, and again to bring them back. In pages, tap the sides to turn.'),
      (Icons.back_hand_outlined, 'Press and hold a sentence to read from there, keep it as a quote or look a word up.'),
      (Icons.text_fields_rounded, 'Reading settings, at the top: the type, the light and auto-scroll.'),
    ],
  ),
];

class _GuideScreenState extends State<GuideScreen> {
  final _pages = PageController();
  int _at = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  bool get _last => _at == _cards.length - 1;

  void _go(int to) {
    final d = Motion.of(context, Motion.page);
    if (d == Duration.zero) {
      _pages.jumpToPage(to);
    } else {
      _pages.animateToPage(to, duration: d, curve: Motion.emphasized);
    }
  }

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.s, 0),
                  child: Row(
                    children: [
                      const ExcludeSemantics(child: BrandMark(size: 32)),
                      const SizedBox(width: Gap.m),
                      Expanded(child: Text('TomeVoice', style: Skin.title(context, size: 20))),
                      TextButton(onPressed: _close, child: const Text('Skip')),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _cards.length,
                    onPageChanged: (i) => setState(() => _at = i),
                    itemBuilder: (context, i) => _card(context, i),
                  ),
                ),
                ExcludeSemantics(child: _dots(context)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.s, Gap.m, Gap.page, Gap.l),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Its room kept on the first card too, where it is
                      // neither shown nor tapped nor read out, so the
                      // buttons stay where they are as the cards go by.
                      Visibility(
                        visible: _at > 0,
                        maintainState: true,
                        maintainAnimation: true,
                        maintainSize: true,
                        child: TextButton(onPressed: () => _go(_at - 1), child: const Text('Back')),
                      ),
                      Flexible(
                        child: FilledButton(
                          onPressed: _last ? _close : () => _go(_at + 1),
                          child: Text(_last ? 'Start reading' : 'Next'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _card(BuildContext context, int i) {
    final card = _cards[i];
    final ink = Skin.accentInkOf(context);
    return Center(
      // A large text size still fits: the card scrolls.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.page + Gap.s, Gap.l, Gap.page + Gap.s, Gap.l),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(color: Skin.accentOf(context).withValues(alpha: 0.16), shape: BoxShape.circle),
                  child: Icon(card.icon, size: 34, color: ink),
                ),
              ),
              const SizedBox(height: Gap.xl),
              Eyebrow('${i + 1} of ${_cards.length}'),
              const SizedBox(height: Gap.xs),
              // Read out as the card arrives, swiped to or stepped to.
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(card.title, style: Skin.title(context, size: 32, weight: FontWeight.w500)),
              ),
              const SizedBox(height: Gap.m),
              Text(
                card.lede,
                style: Skin.ui(size: 16, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45),
              ),
              const SizedBox(height: Gap.xl),
              for (final (icon, text) in card.points)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.l),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(child: Icon(icon, size: 22, color: ink)),
                      const SizedBox(width: Gap.l),
                      Expanded(
                        child: Text(
                          text,
                          style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context))
                              .copyWith(height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Where the cards stand: the one shown drawn long, in the accent.
  Widget _dots(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < _cards.length; i++)
            AnimatedContainer(
              duration: Motion.of(context, Motion.standard),
              curve: Motion.out,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _at ? 22 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == _at ? Skin.accentMarkOf(context) : Skin.inkFaintOn(context).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
            ),
        ],
      );
}
