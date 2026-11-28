import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud_voices.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// Cloud voices on the reader's own key: OpenAI, Google Cloud or Microsoft
/// Azure. One service at a time: its key, what it costs, and its voices in
/// the book's language.
class CloudVoicesScreen extends StatefulWidget {
  const CloudVoicesScreen({super.key, this.selected, this.onChoose, this.language = 'en'});

  /// The voice in use, to mark.
  final String? selected;

  /// Use this voice ("cloud:<service>:<id>"); null shows the lists only.
  final ValueChanged<String>? onChoose;

  /// The book's language ("en"): the voices shown first.
  final String language;

  @override
  State<CloudVoicesScreen> createState() => _CloudVoicesScreenState();
}

class _CloudVoicesScreenState extends State<CloudVoicesScreen> {
  final _cloud = CloudVoices.instance;
  final _key = TextEditingController();
  final _region = TextEditingController();
  late final _style = TextEditingController(text: _cloud.openAiStyle);
  late CloudService _service = _cloud.byVoiceName(widget.selected)?.service ??
      CloudService.values.where(_cloud.hasKey).firstOrNull ??
      CloudService.openai;
  bool _busy = false;
  bool _allLanguages = false;
  String? _problem;
  String _query = '';
  ({int sentences, int bytes})? _kept;

  @override
  void initState() {
    super.initState();
    _cloud.addListener(_refresh);
    unawaited(_loadKept());
  }

  @override
  void dispose() {
    _cloud.removeListener(_refresh);
    _key.dispose();
    _region.dispose();
    _style.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadKept() async {
    final k = await _cloud.kept();
    if (mounted) setState(() => _kept = k);
  }

  static const _sites = {
    CloudService.openai: 'https://platform.openai.com/api-keys',
    CloudService.google: 'https://console.cloud.google.com/apis/credentials',
    CloudService.azure: 'https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices',
  };

  static const _how = {
    CloudService.openai: 'On platform.openai.com: API keys, Create new secret key. OpenAI bills the account it belongs to, '
        'so it needs a payment method or credit there.',
    CloudService.google: 'In the Google Cloud console: turn on the Cloud Text-to-Speech API for a project, then Credentials, '
        'Create credentials, API key (best restricted to that API). Each month the first million or more characters are free.',
    CloudService.azure: 'On portal.azure.com: create a Speech resource (the free F0 tier gives half a million characters a month), '
        'then Keys and Endpoint: copy Key 1 and the Location, as "westeurope".',
  };

  static const _price = {
    CloudService.openai: 'About \$15 for a million characters (a long novel), \$30 with TTS-1 HD.',
    CloudService.google: 'Standard voices about \$4 a million characters, Neural2 and WaveNet about \$16, Chirp HD \$30; '
        'a free allowance every month.',
    CloudService.azure: 'About \$15 a million characters; the free tier covers half a million a month.',
  };

  Future<void> _saveKey() async {
    final key = _key.text.trim();
    if (key.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await _cloud.setKey(_service, key, region: _region.text);
      _key.clear();
    } on CloudError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetKey() async {
    final s = _service;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove the ${s.label} key?'),
        content: const Text("Its voices leave the voice list, and a book read in one goes back to the phone's voice. "
            'Sentences kept on the phone stay until you clear them.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure == true) await _cloud.setKey(s, null);
  }

  Future<void> _refreshVoices() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await _cloud.refreshVoices(_service);
    } on CloudError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _speaks(CloudVoice v) {
    if (v.language.isEmpty) return true;
    final l = v.language.toLowerCase();
    return l == widget.language.toLowerCase() || l.startsWith('${widget.language.toLowerCase()}-') || v.id.contains('Multilingual');
  }

  @override
  Widget build(BuildContext context) {
    final soft = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    final faint = Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)).copyWith(height: 1.4);
    final s = _service;
    final has = _cloud.hasKey(s);
    final q = _query.trim().toLowerCase();
    final all = _cloud.voicesOf(s);
    final ours = s == CloudService.openai || _allLanguages ? all : all.where(_speaks).toList();
    final voices = [
      for (final v in ours)
        if (q.isEmpty || '${v.name} ${v.note} ${v.language} ${v.id}'.toLowerCase().contains(q)) v,
    ];
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Cloud voices', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    Text(
                      'Read in OpenAI, Google or Microsoft voices on your own key, paid by your account with them: '
                      'a tenth of ElevenLabs\' price or less. TomeVoice has no account of its own: the sentences '
                      'being read go from your phone straight to the service, and nowhere else. Each is made once '
                      'and kept on the phone, so hearing it again, at any speed, costs nothing more.',
                      style: soft,
                    ),
                    const SizedBox(height: Gap.l),
                    ChoiceRow<CloudService>(
                      options: [for (final c in CloudService.values) (c, c == CloudService.azure ? 'Azure' : c == CloudService.google ? 'Google' : c.label)],
                      value: s,
                      onChanged: (c) => setState(() {
                        _service = c;
                        _problem = null;
                        _query = '';
                      }),
                    ),
                    const SizedBox(height: Gap.s),
                    Text(_price[s]!, style: faint),
                    const SizedBox(height: Gap.l),
                    SectionTitle('Your ${s.label} key'),
                    if (has)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Key ${_cloud.keyHint(s)} is set${s == CloudService.azure ? ' · ${_cloud.azureRegion}' : ''}',
                              style: Skin.label(context, size: 15),
                            ),
                          ),
                          TextButton(onPressed: _forgetKey, child: const Text('Remove')),
                        ],
                      )
                    else ...[
                      TextField(
                        controller: _key,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(hintText: 'Paste your ${s.label} API key'),
                        onSubmitted: (_) => unawaited(_saveKey()),
                      ),
                      if (s == CloudService.azure) ...[
                        const SizedBox(height: Gap.s),
                        TextField(
                          controller: _region,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(hintText: 'Region, as westeurope or eastus'),
                        ),
                      ],
                      const SizedBox(height: Gap.s),
                      Text(_how[s]!, style: faint),
                      const SizedBox(height: Gap.s),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => unawaited(const SpeechService().openUrl(_sites[s]!)),
                            child: Text('Open ${s == CloudService.openai ? 'OpenAI' : s == CloudService.google ? 'Google Cloud' : 'Azure'}'),
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
                    if (has && s == CloudService.openai) ..._openAi(context, faint),
                    if (has) ...[
                      const SizedBox(height: Gap.xl),
                      Row(
                        children: [
                          const Expanded(child: SectionTitle('Voices')),
                          if (s != CloudService.openai)
                            TextButton.icon(
                              onPressed: _busy ? null : () => unawaited(_refreshVoices()),
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Refresh'),
                            ),
                        ],
                      ),
                      if (s != CloudService.openai) ...[
                        SwitchRow(
                          title: 'Every language',
                          subtitle: _allLanguages
                              ? 'All ${all.length} voices'
                              : '${all.where(_speaks).length} that speak this book\'s language',
                          value: _allLanguages,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => setState(() => _allLanguages = v),
                        ),
                        const SizedBox(height: Gap.s),
                      ],
                      if (ours.length > 8) ...[
                        SearchField(hint: 'Find a voice', onChanged: (v) => setState(() => _query = v)),
                        const SizedBox(height: Gap.m),
                      ],
                      if (s == CloudService.openai)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Gap.s),
                          child: Text(
                              'OpenAI\'s voices read every language; they sound most at home in English. '
                              'The words are lit as measured from the speech, a little less exactly than with other voices.',
                              style: faint),
                        ),
                      if (voices.isEmpty) Text('No voices here.', style: faint),
                      for (final v in voices) _voiceRow(context, v),
                    ],
                    if (_kept != null && _kept!.sentences > 0) ...[
                      const SizedBox(height: Gap.xl),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Kept on the phone: ${_kept!.sentences} sentences · ${(_kept!.bytes / 1048576).round()} MB',
                              style: Skin.meta(context),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              await _cloud.clearKept();
                              await _loadKept();
                            },
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
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

  List<Widget> _openAi(BuildContext context, TextStyle faint) {
    final m = _cloud.openAiModel;
    return [
      const SizedBox(height: Gap.xl),
      const SectionTitle('Model'),
      ChoiceRow<OpenAiModel>(
        options: [for (final x in OpenAiModel.all) (x, x.label)],
        value: m,
        onChanged: (x) => unawaited(_cloud.setOpenAiModel(x)),
      ),
      const SizedBox(height: Gap.s),
      Text('${m.note}.', style: faint),
      if (m == OpenAiModel.mini) ...[
        const SizedBox(height: Gap.l),
        const SectionTitle('Narration style'),
        TextField(
          controller: _style,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: 'How the voice reads'),
          onChanged: (v) => unawaited(_cloud.setOpenAiStyle(v)),
        ),
        const SizedBox(height: Gap.s),
        Text('Told to the voice with each sentence. A sentence already made keeps its first reading until the style changes.',
            style: faint),
      ],
    ];
  }

  Widget _voiceRow(BuildContext context, CloudVoice v) {
    final chosen = v.voiceName == widget.selected;
    final choose = widget.onChoose;
    final detail = [
      if (v.language.isNotEmpty) v.language,
      if (v.note.isNotEmpty) v.note,
    ].join(' · ');
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
                      if (detail.isNotEmpty)
                        Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: Skin.meta(context, size: 10.5)),
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
