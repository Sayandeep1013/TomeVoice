import 'dart:async';

import 'package:flutter/material.dart';

import 'eleven_labs.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// ElevenLabs voices on the reader's own key: the key, the model, this
/// month's credits, and the account's voices to read with.
class ElevenLabsScreen extends StatefulWidget {
  const ElevenLabsScreen({super.key, this.selected, this.onChoose});

  /// The voice in use, to mark.
  final String? selected;

  /// Use this voice (its voice name, "eleven:<id>"); null shows the list
  /// without choosing.
  final ValueChanged<String>? onChoose;

  @override
  State<ElevenLabsScreen> createState() => _ElevenLabsScreenState();
}

class _ElevenLabsScreenState extends State<ElevenLabsScreen> {
  final _eleven = ElevenLabs.instance;
  final _key = TextEditingController();
  bool _busy = false;
  String? _problem;
  ElevenUsage? _usage;
  bool _usageAsked = false;
  ({int sentences, int bytes})? _kept;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _eleven.addListener(_refresh);
    unawaited(_loadUsage());
  }

  @override
  void dispose() {
    _eleven.removeListener(_refresh);
    _key.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadUsage() async {
    final kept = await _eleven.kept();
    final usage = _eleven.hasKey ? await _eleven.usage() : null;
    if (!mounted) return;
    setState(() {
      _usage = usage;
      _usageAsked = true;
      _kept = kept;
    });
  }

  Future<void> _saveKey() async {
    final key = _key.text.trim();
    if (key.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await _eleven.setKey(key);
      _key.clear();
      await _loadUsage();
    } on ElevenError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetKey() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove the ElevenLabs key?'),
        content: const Text(
            'Its voices leave the voice list, and a book read in one goes back to the phone\'s voice. '
            'Sentences kept on the phone stay until you clear them.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await _eleven.setKey(null);
    if (mounted) setState(() => _usage = null);
  }

  Future<void> _refreshVoices() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await _eleven.refreshVoices();
    } on ElevenError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearKept() async {
    await _eleven.clearKept();
    await _loadUsage();
  }

  static String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _usageLine(ElevenUsage u) {
    final resets = u.resets == null ? '' : ' · renews ${u.resets!.day} ${_months[u.resets!.month - 1]}';
    return '${_thousands(u.left)} of ${_thousands(u.limit)} credits left this month$resets';
  }

  @override
  Widget build(BuildContext context) {
    final soft = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    final faint = Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)).copyWith(height: 1.4);
    final model = _eleven.model;
    // A chapter of 4,000 words is about 22,000 characters.
    final chapter = (22000 * model.creditsPerChar).round();
    final q = _query.trim().toLowerCase();
    final voices = [
      for (final v in _eleven.voices)
        if (q.isEmpty || '${v.name} ${v.description} ${v.language}'.toLowerCase().contains(q)) v,
    ];
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'ElevenLabs voices', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    Text(
                      'Read in the voices of your own ElevenLabs account, paid from its credits. '
                      'TomeVoice has no account of its own: the sentences being read go from your phone '
                      'straight to ElevenLabs, with your key, and nowhere else. Each sentence is made once '
                      'and kept on the phone, so hearing it again, at any speed, costs nothing more.',
                      style: soft,
                    ),
                    const SizedBox(height: Gap.l),
                    const SectionTitle('Your key'),
                    if (_eleven.hasKey)
                      Row(
                        children: [
                          Expanded(child: Text('Key ${_eleven.keyHint} is set', style: Skin.label(context, size: 15))),
                          TextButton(onPressed: _forgetKey, child: const Text('Remove')),
                        ],
                      )
                    else ...[
                      TextField(
                        controller: _key,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(hintText: 'Paste your ElevenLabs API key'),
                        onSubmitted: (_) => unawaited(_saveKey()),
                      ),
                      const SizedBox(height: Gap.s),
                      Text(
                        'On elevenlabs.io: your profile, API keys, Create. Give it Text to Speech, and Voices '
                        'and User (read) so the voices and credits can be shown here.',
                        style: faint,
                      ),
                      const SizedBox(height: Gap.s),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => unawaited(const SpeechService().openUrl('https://elevenlabs.io/app/settings/api-keys')),
                            child: const Text('Open elevenlabs.io'),
                          ),
                          const Spacer(),
                          FilledButton(
                            onPressed: _busy ? null : () => unawaited(_saveKey()),
                            child: Text(_busy ? 'Checking…' : 'Save'),
                          ),
                        ],
                      ),
                    ],
                    if (_problem != null) ...[
                      const SizedBox(height: Gap.s),
                      Text(_problem!, style: faint.copyWith(color: Skin.dangerOn(context))),
                    ],
                    if (_eleven.hasKey) ...[
                      const SizedBox(height: Gap.s),
                      Text(
                        _usage != null
                            ? _usageLine(_usage!)
                            : _usageAsked
                                ? 'Credits not shown: this key may not read them (User, read).'
                                : 'Asking ElevenLabs for your credits…',
                        style: Skin.meta(context),
                      ),
                      const SizedBox(height: Gap.xl),
                      const SectionTitle('Model'),
                      ChoiceRow<ElevenModel>(
                        options: [for (final m in ElevenModel.all) (m, m.label)],
                        value: model,
                        onChanged: (m) => unawaited(_eleven.setModel(m)),
                      ),
                      const SizedBox(height: Gap.s),
                      Text(
                        '${model.note}. A chapter of about 4,000 words takes about ${_thousands(chapter)} credits '
                        'the first time it is read.',
                        style: faint,
                      ),
                      const SizedBox(height: Gap.xl),
                      Row(
                        children: [
                          const Expanded(child: SectionTitle('Voices')),
                          TextButton.icon(
                            onPressed: _busy ? null : () => unawaited(_refreshVoices()),
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Refresh'),
                          ),
                        ],
                      ),
                      if (_eleven.voices.length > 6) ...[
                        SearchField(hint: 'Find a voice', onChanged: (v) => setState(() => _query = v)),
                        const SizedBox(height: Gap.m),
                      ],
                      if (_eleven.voices.isEmpty)
                        Text('No voices yet. Add some in your ElevenLabs account, then Refresh.', style: faint),
                      for (final v in voices) _voiceRow(context, v),
                      if (_kept != null && _kept!.sentences > 0) ...[
                        const SizedBox(height: Gap.xl),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Kept on the phone: ${_thousands(_kept!.sentences)} sentences · '
                                '${(_kept!.bytes / 1048576).round()} MB',
                                style: Skin.meta(context),
                              ),
                            ),
                            TextButton(onPressed: () => unawaited(_clearKept()), child: const Text('Clear')),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _voiceRow(BuildContext context, ElevenVoice v) {
    final chosen = v.voiceName == widget.selected;
    final choose = widget.onChoose;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Material(
        color: chosen ? Skin.accentOf(context).withValues(alpha: 0.14) : Skin.capsuleOn(context),
        shape: Skin.cardShape(context, Radii.row),
        child: InkWell(
          customBorder: Skin.cardShape(context, Radii.row),
          onTap: choose == null
              ? null
              : () {
                  choose(v.voiceName);
                  Navigator.of(context).maybePop();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
            child: Row(
              children: [
                Icon(chosen ? Icons.check_circle_rounded : Icons.graphic_eq_rounded,
                    size: 20, color: chosen ? Skin.accentInkOf(context) : Skin.inkSoftOn(context)),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v.name, style: Skin.label(context, size: 15, color: Skin.inkOn(context))),
                      if (v.description.isNotEmpty)
                        Text(v.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: Skin.meta(context, size: 10.5)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
