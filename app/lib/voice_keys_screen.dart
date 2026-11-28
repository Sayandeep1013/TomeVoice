import 'package:flutter/material.dart';

import 'cloud_screen.dart';
import 'cloud_voices.dart';
import 'eleven_labs.dart';
import 'eleven_screen.dart';
import 'theme.dart';
import 'ui.dart';

/// Voices on your own key, in one place (Settings › Listening, and the foot
/// of every book's voice list): ElevenLabs, OpenAI, Google Cloud and
/// Microsoft Azure, each with its key and what it costs. A key is added
/// once; its voices then show in every book's voice list, under "On your own
/// key", to pick for that book.
class VoiceKeysScreen extends StatefulWidget {
  const VoiceKeysScreen({super.key, this.selected, this.onChoose, this.language = 'en'});

  /// The voice in use, when opened from a book.
  final String? selected;

  /// Use a voice for the book it was opened from; null from Settings.
  final ValueChanged<String>? onChoose;

  /// The book's language, for the voices shown first.
  final String language;

  @override
  State<VoiceKeysScreen> createState() => _VoiceKeysScreenState();
}

class _VoiceKeysScreenState extends State<VoiceKeysScreen> {
  final _eleven = ElevenLabs.instance;
  final _cloud = CloudVoices.instance;

  @override
  void initState() {
    super.initState();
    _eleven.addListener(_refresh);
    _cloud.addListener(_refresh);
  }

  @override
  void dispose() {
    _eleven.removeListener(_refresh);
    _cloud.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  // A voice picked on a service's screen: used, and back to the book.
  ValueChanged<String>? get _choose {
    final choose = widget.onChoose;
    if (choose == null) return null;
    return (name) {
      choose(name);
      Navigator.of(context).maybePop();
    };
  }

  Widget _row({
    required IconData icon,
    required String title,
    required bool has,
    required String set,
    required String unset,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Material(
          color: Skin.capsuleOn(context),
          shape: Skin.cardShape(context, Radii.row),
          child: InkWell(
            customBorder: Skin.cardShape(context, Radii.row),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
              child: Row(
                children: [
                  Icon(has ? Icons.check_circle_rounded : icon,
                      size: 22, color: has ? Skin.accentInkOf(context) : Skin.inkSoftOn(context)),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Skin.label(context, size: 15.5, color: Skin.inkOn(context))),
                        const SizedBox(height: 2),
                        Text(has ? set : unset, style: Skin.meta(context, size: 11)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
                ],
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final soft = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    String cloudSet(CloudService s) {
      final n = _cloud.voicesOf(s).length;
      return 'Key ${_cloud.keyHint(s)} · $n voices';
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Voices on your own key', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    Text(
                      'Add a key once, here. Its voices then show in every book\'s voice list, under '
                      '"On your own key", to pick for that book. You pay the service, never TomeVoice: '
                      'the sentences go from your phone straight to it, and each is made once and kept.',
                      style: soft,
                    ),
                    const SizedBox(height: Gap.l),
                    _row(
                      icon: Icons.graphic_eq_rounded,
                      title: 'ElevenLabs',
                      has: _eleven.hasKey,
                      set: 'Key ${_eleven.keyHint} · ${_eleven.voices.length} voices',
                      unset: 'The most lifelike, from your account\'s credits',
                      onTap: () => _open(ElevenLabsScreen(selected: widget.selected, onChoose: _choose)),
                    ),
                    for (final (s, unset) in const [
                      (CloudService.openai, 'About \$15 a million characters; told how to narrate'),
                      (CloudService.google, '\$4 to \$30 a million characters, some free each month; each word lit exactly'),
                      (CloudService.azure, 'About \$15 a million characters, half a million free each month'),
                    ])
                      _row(
                        icon: Icons.cloud_outlined,
                        title: s.label,
                        has: _cloud.hasKey(s),
                        set: cloudSet(s),
                        unset: unset,
                        onTap: () => _open(CloudVoicesScreen(
                          service: s,
                          selected: widget.selected,
                          language: widget.language,
                          onChoose: _choose,
                        )),
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
}
