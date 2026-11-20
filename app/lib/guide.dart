import 'dart:io';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'theme.dart';
import 'ui.dart';
import 'store_build.dart';

/// Show the guide over the app (Settings asks for it again).
Future<void> showGuide(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GuideScreen()));

/// Show the guide to the AI and the memory: on the AI page's first opening,
/// and from its "How the AI works" button.
Future<void> showAiGuide(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const GuideScreen(cards: aiGuideCards, heading: 'AI and memory', finish: 'Got it')));

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
  const GuideScreen({super.key, this.cards = _cards, this.heading = 'TomeVoice', this.finish = 'Start reading'});

  /// The cards, in order.
  final List<GuideCard> cards;

  /// The line beside the mark, at the top.
  final String heading;

  /// The last card's button.
  final String finish;

  /// Whether a first launch shows the guide by itself. Off in tests, as the
  /// starter shelf is: a test's empty library is not someone new.
  static bool onFirstLaunch = !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

/// One card: what it is about, in a line, and the few things to know.
class GuideCard {
  const GuideCard(this.icon, this.title, this.lede, this.points);

  final IconData icon;
  final String title;
  final String lede;
  final List<(IconData, String)> points;
}

const _cards = <GuideCard>[
  GuideCard(
    Icons.library_add_outlined,
    'Bring your books',
    'EPUB, PDF, DjVu, Word, MOBI, FB2 and plain text, read aloud on your phone.',
    [
      (Icons.add_rounded, 'Add books, at the top of the library: books on this phone, or a link.'),
      (Icons.local_library_outlined, 'Catalogues, in the menu: free classics to download.'),
      if (playBuild)
        (Icons.travel_explore_rounded, 'Browse, in the menu: web novels, from the source lists you add.')
      else
        (Icons.travel_explore_rounded, 'Browse, in the menu: web novels from their sites.'),
    ],
  ),
  GuideCard(
    Icons.play_arrow_rounded,
    'Press play',
    'Open a book and press play. The page follows the voice, the sentence lit as it is read.',
    [
      (Icons.speed_rounded, 'The speed, the voice and the sleep timer are on the player.'),
      (Icons.swipe_up_rounded, 'Swipe the player up for Now Playing.'),
      (Icons.notifications_none_rounded, 'Leave the book and it reads on: pause it from the library or the notification.'),
    ],
  ),
  GuideCard(
    Icons.record_voice_over_rounded,
    'Two kinds of voice',
    'Any book can be read by either, and each book keeps its own.',
    [
      (Icons.phone_android_rounded, "Your phone's voices: there already, and offline."),
      (Icons.auto_awesome_rounded, 'Natural voices sound like people: download one once, and it reads offline too.'),
      (Icons.tune_rounded, 'Tap the voice on the player to change it, or to try a natural one.'),
    ],
  ),
  GuideCard(
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

  bool get _last => _at == widget.cards.length - 1;

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
                      Expanded(child: Text(widget.heading, style: Skin.title(context, size: 20))),
                      TextButton(onPressed: _close, child: const Text('Skip')),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: widget.cards.length,
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
                          child: Text(_last ? widget.finish : 'Next'),
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
    final card = widget.cards[i];
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
              Eyebrow('${i + 1} of ${widget.cards.length}'),
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
          for (var i = 0; i < widget.cards.length; i++)
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

/// The guide to the AI and the memory: six cards, from a key to a sequel.
const aiGuideCards = <GuideCard>[
  GuideCard(
    Icons.key_rounded,
    'Your own AI',
    'TomeVoice talks to an AI with your own key, straight from this phone. There is no TomeVoice server.',
    [
      (Icons.add_rounded, 'Add a key on this page: Google Gemini, OpenRouter, Groq, Inception, OpenAI or any service like them. Free tiers work.'),
      (Icons.sync_rounded, 'Add as many keys as you like. When one has used its quota it rests, and the next takes over.'),
      (Icons.lock_outline_rounded, 'Nothing of a book is sent until you add a key, and never a book on a secret shelf.'),
    ],
  ),
  GuideCard(
    Icons.auto_awesome_rounded,
    'A memory for each book',
    'The AI reads a book once, chapter by chapter, and keeps notes: who is who, what happened, and where.',
    [
      (Icons.menu_book_rounded, "On a book's page, open Memory and press Build memory."),
      (Icons.schedule_rounded, 'A long book takes hours on a free key. It goes on in the background, and with TomeVoice closed if you allow it on this page.'),
      (Icons.download_rounded, 'A web novel fetches its missing chapters first. Once the memory has read them, Free the space deletes them again.'),
    ],
  ),
  GuideCard(
    Icons.forum_outlined,
    'Talk about the book',
    'Ask anything about the story. The answer says which chapters it comes from.',
    [
      (Icons.auto_awesome_outlined, 'In a book, tap the sparkle above the player. Talk opens over the page, and the book reads on.'),
      (Icons.record_voice_over_rounded, 'Answers can be said in the voice reading the book.'),
      (Icons.edit_outlined, "Each talk is kept in the book's journal, beside your own writing."),
    ],
  ),
  GuideCard(
    Icons.back_hand_outlined,
    'Hold to ask',
    'Press and hold a sentence on the page, and pick:',
    [
      (Icons.help_outline_rounded, 'Explain this: what the sentence means at this point in the story.'),
      (Icons.badge_outlined, 'Who or what is it: a card of all that is known of the name, so far.'),
      (Icons.history_rounded, 'Back after a few days away? Previously… tells you what happened just before.'),
    ],
  ),
  GuideCard(
    Icons.hub_outlined,
    "Who's who and the graph",
    'Everyone and everything the memory has met, and how they link.',
    [
      (Icons.groups_outlined, "Who's who lists people, places and things. Press and hold one to rename it, or to join two that are the same."),
      (Icons.hub_outlined, 'The graph draws the web round anyone. Tap a dot to centre it; slide to a chapter to see the story as it stood then.'),
      (Icons.lightbulb_outline_rounded, 'Theories: write down a guess, and the memory tells you when the book settles it.'),
    ],
  ),
  GuideCard(
    Icons.shield_outlined,
    'You stay in charge',
    'Spoilers, privacy and series are up to you, book by book.',
    [
      (Icons.visibility_off_outlined, 'Spoiler guard, on a book\'s Memory: the AI keeps to what you have read. It is off until you turn it on.'),
      (Icons.block_rounded, "Keep this book away from the AI, in the Memory's menu: nothing of it is sent."),
      (Icons.link_rounded, 'A sequel can carry on from the book before it, so its people come along.'),
      (Icons.flag_outlined, 'Report any answer from Talk; AI > What was sent lists every call made with your keys.'),
    ],
  ),
];
