import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'neural_voices.dart';
import 'prefs.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

/// Natural voices, by language, the book's own first: what each costs, what
/// its recordings may be used for, a sample to hear, what is on the phone,
/// and whether this phone keeps up with each (a measured test, not a guess).
class NeuralVoicesScreen extends StatefulWidget {
  const NeuralVoicesScreen({super.key, this.language});

  /// The language shown first: the book's, when opened from a book; the
  /// phone's otherwise.
  final String? language;

  @override
  State<NeuralVoicesScreen> createState() => _NeuralVoicesScreenState();
}

class _NeuralVoicesScreenState extends State<NeuralVoicesScreen> {
  final _voices = NeuralVoices.instance;

  /// The model being tested ([NeuralVoice.modelId]).
  String? _testing;

  /// The voice whose sample is playing.
  String? _hearing;
  StreamSubscription<Map<String, Object?>>? _events;

  /// Other languages opened to show their voices.
  final _open = <String>{};

  String get _language =>
      (widget.language ?? PlatformDispatcher.instance.locale.languageCode).toLowerCase();

  @override
  void initState() {
    super.initState();
    _voices.addListener(_changed);
    unawaited(_voices.ready);
    _events = SpeechService.events.listen((e) {
      final type = e['type'];
      if (type != 'urlSampleDone' && type != 'urlSampleFailed') return;
      if (!mounted) return;
      // Only the sample now playing: an older one's late news is ignored.
      if (e['url'] != neuralVoiceFor('$neuralPrefix$_hearing')?.sampleUrl) return;
      setState(() => _hearing = null);
      if (type == 'urlSampleFailed') {
        showSnack(context, 'The sample could not play. Check the internet connection.');
      }
    });
  }

  @override
  void dispose() {
    _voices.removeListener(_changed);
    unawaited(_events?.cancel());
    if (_hearing != null) unawaited(const SpeechService().stopUrl());
    super.dispose();
  }

  /// Hear [v] before downloading it, or stop.
  Future<void> _hear(NeuralVoice v) async {
    const svc = SpeechService();
    if (_hearing == v.id) {
      setState(() => _hearing = null);
      await svc.stopUrl();
      return;
    }
    setState(() => _hearing = v.id);
    try {
      await svc.playUrl(v.sampleUrl);
    } on Object {
      if (!mounted) return;
      setState(() => _hearing = null);
      showSnack(context, 'The sample could not play. Check the internet connection.');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Asked once, before anything is offered.
    if (_prefs.naturalVoices == null && !_asked) {
      _asked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _askFirst());
    }
  }

  bool _asked = false;

  /// What natural voices cost, before any is downloaded; "No thanks" keeps
  /// the phone's voices and the app stops offering these.
  Future<void> _askFirst() async {
    final yes = await _costs(context, title: 'Before you download a voice');
    if (!mounted) return;
    setState(() => _prefs.naturalVoices = yes);
    _prefs.save();
    if (!yes) Navigator.of(context).maybePop();
  }

  Future<void> _download(NeuralVoice v) async {
    final pack = v.pack;
    final title = pack == null ? 'Download ${v.name}?' : 'Download ${pack.name}?';
    if (!await _costs(context, title: title, size: v.sizeMb, pack: pack)) return;
    if (!mounted) return;
    setState(() => _prefs.naturalVoices = true);
    _prefs.save();
    try {
      await _voices.download(v);
      VoiceCatalog.instance.neuralChanged();
      if (mounted) {
        showSnack(
          context,
          pack == null
              ? '${v.name} is ready. Pick it in a book\'s voices.'
              : '${pack.name} is on the phone. Testing whether this phone keeps up…',
        );
      }
      unawaited(_test(v));
    } on DownloadCancelled {
      if (mounted) showSnack(context, 'Download stopped.');
    } on Object catch (e) {
      debugPrint('Natural voice ${v.modelId}: download failed: $e');
      if (mounted) {
        showSnack(
          context,
          e is SocketException || e is HttpException || e is TimeoutException
              ? 'The download stopped. Check the internet connection and try again: it carries on from where it stopped.'
              : 'The voice could not be set up on this phone. Try again, or pick another voice.',
          long: true,
        );
      }
    }
  }

  /// Measure [v] on this phone, and keep what it measured. A model that
  /// must keep up (Kokoro) is offered for reading only if it does.
  Future<void> _test(NeuralVoice v) async {
    if (_testing != null) return;
    setState(() => _testing = v.modelId);
    try {
      final r = await NeuralEngine.instance.measure(v, Directory.systemTemp.path);
      await _voices.rememberSpeed(v, r);
      VoiceCatalog.instance.neuralChanged();
      final pack = v.pack;
      if (mounted && pack != null && pack.mustKeepUp) {
        showSnack(
          context,
          NeuralVoices.keepsUp(r)
              ? '${pack.name} keeps up on this phone. Its voices are in a book\'s voices.'
              : '${pack.name} is too slow for this phone, so it is not offered for reading. Remove it to free the space.',
          long: true,
        );
      }
    } on Object catch (e) {
      debugPrint('Natural voice ${v.modelId}: speed test failed: $e');
      if (mounted) showSnack(context, 'The voice did not work on this phone. Remove it, or try another.', long: true);
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  Future<void> _remove(NeuralVoice v) async {
    final pack = v.pack;
    final names = {
      for (final x in pack == null ? [v] : _voices.catalog?.speakersOf(pack) ?? [v]) x.voiceName,
    };
    await _voices.remove(v);
    _forgetVoices(names);
    VoiceCatalog.instance.neuralChanged();
  }

  Future<void> _removeAll() async {
    final ok = await confirm(
      context,
      title: 'Remove all natural voices?',
      body: 'Every natural voice is deleted from the phone. Books that used one are read in the '
          'phone\'s own voice again.',
      action: 'Remove all',
    );
    if (!ok) return;
    final names = {for (final v in _voices.installedVoices) v.voiceName};
    await _voices.removeAll();
    _forgetVoices(names);
    VoiceCatalog.instance.neuralChanged();
    if (mounted) showSnack(context, 'Natural voices removed.');
  }

  /// Books and languages set to a removed voice go back to the phone's.
  void _forgetVoices(Set<String> names) {
    final p = _prefs;
    p.voiceByBook.removeWhere((_, v) => names.contains(v));
    p.voiceByLanguage.removeWhere((_, v) => names.contains(v));
    p.dialogueByBook.removeWhere((_, v) => names.contains(v));
    p.save();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: 'Natural voices', onBack: () => Navigator.of(context).maybePop()),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                        Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      Text(
                        'Voices that sound like people, made on your phone with no internet once '
                        'downloaded. They use more battery than the phone\'s own voices. After a download '
                        'TomeVoice tests whether this phone keeps up.',
                        style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                            .copyWith(height: 1.45),
                      ),
                      const SizedBox(height: Gap.l),
                      SwitchRow(
                        title: 'Offer natural voices',
                        subtitle: _prefs.naturalVoices ?? false
                            ? 'On: they appear in the voice picker'
                            : 'Off: only the phone\'s own voices, and nothing to download',
                        value: _prefs.naturalVoices ?? false,
                        padding: EdgeInsets.zero,
                        onChanged: (v) {
                          setState(() => _prefs.naturalVoices = v);
                          _prefs.save();
                        },
                      ),
                      if (_voices.installedVoices.isNotEmpty) ...[
                        const SizedBox(height: Gap.s),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'On this phone: ${_onPhone()} · ${(_voices.bytesUsed / 1048576).round()} MB',
                                style: Skin.meta(context),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _removeAll,
                              icon: const Icon(Icons.delete_outline_rounded, size: 18),
                              label: const Text('Remove all'),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: Gap.m),
                      if (_prefs.naturalVoices ?? false) ..._offer(context),
                      const SizedBox(height: Gap.l),
                      Text(
                        'Piper voices, and Kokoro and Kitten, which hold many voices in one download; '
                        'sherpa-onnx makes them into speech. Each keeps the licence of the recordings it '
                        'learned from, shown with it: tap a licence for what its model card says.',
                        style: Skin.ui(size: 12.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  /// "3 voices", or "31 voices in 3 downloads" when a model holds many.
  String _onPhone() {
    final here = _voices.installedVoices;
    final downloads = {for (final v in here) v.modelId}.length;
    return _count(here.length, 'voice') + (downloads < here.length ? ' in ${_count(downloads, 'download')}' : '');
  }

  /// The voices on offer: the shown language's, those on the phone in
  /// other languages, then every other language, folded.
  List<Widget> _offer(BuildContext context) {
    final catalog = _voices.catalog;
    if (catalog == null) {
      return const [
        Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator())),
      ];
    }
    final language = _language;
    final name = languageName(language);
    final own = catalog.forLanguage(language);
    // On the phone in other languages: so they can be tested and removed. A
    // model that also speaks this language is shown with it already.
    final shown = {for (final v in own) v.pack?.id};
    final elsewhere = [
      for (final v in _voices.installedVoices)
        if (v.language != language && !shown.contains(v.pack?.id ?? '')) v,
    ];
    final others = catalog.languages.where((l) => l != language).toList()
      ..sort((a, b) => languageName(a).compareTo(languageName(b)));
    return [
      SectionTitle('Natural voices for $name'),
      const SizedBox(height: Gap.s),
      if (own.isEmpty)
        Text(
          'None yet for $name; your phone\'s voice is used.',
          style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
        )
      else
        ..._languageVoices(context, own),
      if (elsewhere.isNotEmpty) ...[
        const SizedBox(height: Gap.xl),
        const SectionTitle('On this phone'),
        const SizedBox(height: Gap.s),
        ..._languageVoices(context, elsewhere, regions: false, speakers: false),
      ],
      const SizedBox(height: Gap.xl),
      SectionTitle('Other languages', note: '${others.length}'),
      const SizedBox(height: Gap.s),
      for (final l in others) ...[
        _LanguageFold(
          name: languageName(l),
          count: catalog.forLanguage(l).length,
          open: _open.contains(l),
          onTap: () => setState(() => _open.contains(l) ? _open.remove(l) : _open.add(l)),
        ),
        if (_open.contains(l)) ..._languageVoices(context, catalog.forLanguage(l)),
      ],
    ];
  }

  /// [voices] as rows: Piper's one by one (under their region, when the
  /// language is spoken in more than one), then each bigger model's card,
  /// with its speakers unless [speakers] is false.
  List<Widget> _languageVoices(BuildContext context, List<NeuralVoice> voices,
      {bool regions = true, bool speakers = true}) {
    // Those on the phone first, then the ones TomeVoice first offered (they
    // have a word said about them), then the rest as the catalog has them.
    final piper = [
      for (final pass in [0, 1, 2])
        for (final v in voices)
          if (v.pack == null && pass == (_voices.installed(v) ? 0 : (v.blurb.isNotEmpty ? 1 : 2))) v,
    ];
    final packs = <NeuralPack, List<NeuralVoice>>{};
    for (final v in voices) {
      if (v.pack case final p?) packs.putIfAbsent(p, () => []).add(v);
    }
    final byRegion = <String, List<NeuralVoice>>{};
    for (final v in piper) {
      byRegion.putIfAbsent(regionLabel(v.region), () => []).add(v);
    }
    return [
      for (final group in byRegion.entries) ...[
        if (regions && byRegion.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.s, 0, Gap.xs),
            child: Eyebrow(group.key),
          ),
        for (final v in group.value) _row(context, v),
      ],
      for (final e in packs.entries) _packCard(context, e.key, e.value, showSpeakers: speakers),
    ];
  }

  /// What the speed test found, in words; red when it is too slow.
  (String, bool)? _speedNote(double? speed) {
    if (speed == null) return null;
    final x = speed.toStringAsFixed(1);
    if (speed >= 1.6) return ('Keeps up easily ($x× real time)', false);
    if (NeuralVoices.keepsUp(speed)) return ('Keeps up, just ($x× real time)', false);
    return ('Too slow for this phone ($x× real time)', true);
  }

  Widget _row(BuildContext context, NeuralVoice v) {
    final here = _voices.installed(v);
    final progress = _voices.downloading[v.modelId];
    final testing = _testing == v.modelId;
    final speed = _speedNote(here ? _voices.speedOf(v) : null);
    var status = '';
    var slow = false;
    if (progress != null) {
      status = progress >= 0.9 ? 'Unpacking…' : 'Downloading ${(progress * 100).round()}%';
    } else if (testing) {
      status = 'Testing on this phone…';
    } else if (speed != null) {
      status = speed.$1;
      slow = speed.$2;
    } else if (here) {
      status = 'On the phone';
    }
    final language =
        v.region.isEmpty ? languageName(v.language) : '${languageName(v.language)} (${regionLabel(v.region)})';
    final facts = [language, _quality(v.quality), '${v.sizeMb} MB', if (v.blurb.isNotEmpty) v.blurb];
    return _Capsule(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${v.name}${v.hd ? '  ·  HD' : ''}', style: Skin.title(context, size: 18)),
                Text(facts.join(' · ').toUpperCase(), style: Skin.meta(context, size: 10)),
                const SizedBox(height: 2),
                _LicenceLine(licence: v.licence, onTap: () => _showLicence(context, v.name, v.licence)),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(status,
                      style: Skin.ui(
                          size: 13,
                          weight: FontWeight.w600,
                          color: slow ? const Color(0xFFE5674D) : Skin.accentOf(context))),
                ],
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: progress >= 0.9 ? null : progress / 0.9),
                ],
              ],
            ),
          ),
          ..._actions(context, v, here: here, progress: progress, testing: testing),
        ],
      ),
    );
  }

  /// Stop a download; or the voice's menu once it is here; or a sample and
  /// a download before.
  List<Widget> _actions(BuildContext context, NeuralVoice v,
      {required bool here, required double? progress, required bool testing, String? label}) {
    final name = label ?? v.name;
    if (progress != null) {
      return [
        if (progress < 0.9)
          IconButton(
            tooltip: 'Stop downloading $name',
            icon: Icon(Icons.close_rounded, color: Skin.inkSoftOn(context)),
            onPressed: () => _voices.cancel(v),
          ),
      ];
    }
    if (testing) return const [];
    if (here) {
      return [
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (a) => switch (a) {
            'test' => _test(v),
            'licence' => _showLicence(context, name, v.pack?.licence ?? v.licence),
            _ => _remove(v),
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'test', child: Text('Test speed')),
            PopupMenuItem(value: 'licence', child: Text('Licence')),
            PopupMenuItem(value: 'remove', child: Text('Remove')),
          ],
        ),
      ];
    }
    return [
      if (v.pack == null) _hearButton(context, v),
      IconButton(
        tooltip: 'Download $name',
        icon: Icon(Icons.download_rounded, color: Skin.accentOf(context)),
        onPressed: () => _download(v),
      ),
    ];
  }

  Widget _hearButton(BuildContext context, NeuralVoice v) => IconButton(
        tooltip: _hearing == v.id
            ? 'Stop'
            : v.sampleUrl.isEmpty
                ? 'No sample of ${v.name}'
                : 'Hear ${v.name}',
        icon: Icon(
          _hearing == v.id ? Icons.stop_rounded : Icons.play_arrow_rounded,
          color: Skin.inkSoftOn(context),
        ),
        onPressed: v.sampleUrl.isEmpty ? null : () => _hear(v),
      );

  /// A model with many speakers (Kokoro, Kitten): one download, tested as
  /// one, and its [speakers] in this language, each with a sample (unless
  /// [showSpeakers] is false).
  Widget _packCard(BuildContext context, NeuralPack pack, List<NeuralVoice> speakers, {bool showSpeakers = true}) {
    final first = speakers.first;
    final here = _voices.installed(first);
    final progress = _voices.downloading[pack.id];
    final testing = _testing == pack.id;
    final fits = _voices.fits(pack);
    final measured = here ? _voices.speedOf(first) : null;
    final speed = _speedNote(measured);
    final all = _voices.catalog?.speakersOf(pack) ?? speakers;
    final languages = {for (final v in all) v.language};
    var status = '';
    var slow = false;
    if (!fits && !here) {
      final memory = NeuralEngine.instance.memoryMb;
      status = 'Needs a phone with ${_gb(pack.minMemoryMb)} GB of memory or more'
          '${memory == null ? '.' : '; this one has ${_gb(memory)} GB.'}';
      slow = true;
    } else if (progress != null) {
      status = progress >= 0.9 ? 'Unpacking… this takes a while' : 'Downloading ${(progress * 100).round()}%';
    } else if (testing) {
      status = 'Testing on this phone…';
    } else if (speed != null) {
      status = speed.$1;
      slow = speed.$2;
      if (slow && pack.mustKeepUp) status += ': not offered for reading';
    } else if (here) {
      status = pack.mustKeepUp ? 'Not tested yet: test it to read with it' : 'On the phone';
    } else {
      status = pack.mustKeepUp ? 'Tested after the download; offered only if it keeps up' : '';
    }
    final spoken = {for (final v in speakers) v.language};
    final count = spoken.length == 1
        ? _count(speakers.length, '${languageName(first.language)} voice') +
            (languages.length > 1 ? ' · ${all.length} in ${languages.length} languages' : '')
        : '${_count(all.length, 'voice')} in ${languages.length} languages';
    return _Capsule(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pack.name, style: Skin.title(context, size: 18)),
                    Text('${pack.sizeMb} MB · $count'.toUpperCase(), style: Skin.meta(context, size: 10)),
                  ],
                ),
              ),
              if (fits || here)
                ..._actions(context, first, here: here, progress: progress, testing: testing, label: pack.name),
            ],
          ),
          const SizedBox(height: 4),
          Text(pack.blurb,
              style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.35)),
          const SizedBox(height: 2),
          _LicenceLine(licence: pack.licence, onTap: () => _showLicence(context, pack.name, pack.licence)),
          if (status.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(status,
                style: Skin.ui(
                    size: 13, weight: FontWeight.w600, color: slow ? const Color(0xFFE5674D) : Skin.accentOf(context))),
          ],
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress >= 0.9 ? null : progress / 0.9),
          ],
          if (here && measured == null && !testing && fits && progress == null) ...[
            const SizedBox(height: Gap.xs),
            TextButton.icon(
              onPressed: () => _test(first),
              icon: const Icon(Icons.speed_rounded, size: 18),
              label: const Text('Test speed'),
            ),
          ],
          if (showSpeakers) ...[
            const SizedBox(height: Gap.xs),
            for (final v in speakers) _speakerRow(context, v),
          ],
        ],
      ),
    );
  }

  /// One speaker of a bigger model: its name, what its makers say of it,
  /// and its sample.
  Widget _speakerRow(BuildContext context, NeuralVoice v) {
    final facts = [
      if (v.region.isNotEmpty) regionLabel(v.region),
      if (v.gender.isNotEmpty) v.gender,
      if (v.grade.isNotEmpty) 'grade ${v.grade}',
    ].join(' · ');
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: v.name, style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
              if (facts.isNotEmpty)
                TextSpan(
                  text: '   ${facts.toUpperCase()}',
                  style: Skin.meta(context, size: 10),
                ),
            ]),
          ),
        ),
        _hearButton(context, v),
      ],
    );
  }
}

/// "1 voice", "3 voices".
String _count(int n, String what) => '$n ${n == 1 ? what : '${what}s'}';

/// Megabytes as the gigabytes a phone is sold with: 5,600 MB is a 6 GB phone.
int _gb(int mb) => (mb + 1023) ~/ 1024;

String _quality(String q) => switch (q) {
      'x_low' || 'low' => 'low',
      'high' => 'high',
      _ => 'medium',
    };

/// A voice row's ground.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Container(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
          decoration: BoxDecoration(
            color: Skin.capsuleOn(context),
            borderRadius: BorderRadius.circular(Radii.card / 1.5),
          ),
          child: child,
        ),
      );
}

/// A voice's licence, in a word or two, coloured by what it allows; tap for
/// the whole of it.
class _LicenceLine extends StatelessWidget {
  const _LicenceLine({required this.licence, required this.onTap});

  final VoiceLicence licence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (licence.use) {
      LicenceUse.free || LicenceUse.credit => Skin.inkSoftOn(context),
      LicenceUse.noncommercial => const Color(0xFFC98A2B),
      LicenceUse.restricted || LicenceUse.unclear => const Color(0xFFE5674D),
    };
    return Semantics(
      button: true,
      label: 'Licence: ${licence.name}, ${licence.summary}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          // Whole, over two lines if need be: "No licence granted" cut short
          // to "No licence grant…" said too little.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.gavel_rounded, size: 13, color: color),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  '${licence.name} · ${licence.summary}',
                  style: Skin.ui(size: 12.5, weight: FontWeight.w600, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Another language's heading: tap to show its voices, or fold them away.
class _LanguageFold extends StatelessWidget {
  const _LanguageFold({required this.name, required this.count, required this.open, required this.onTap});

  final String name;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.row),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(name, style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
              ),
              Text(_count(count, 'voice').toUpperCase(), style: Skin.meta(context)),
              const SizedBox(width: Gap.s),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: Motion.of(context, Motion.standard),
                child: Icon(Icons.expand_more_rounded, color: Skin.inkFaintOn(context)),
              ),
            ],
          ),
        ),
      );
}

/// A licence in full: what it allows, what to know, and what the model card
/// says, with the way to the card itself.
Future<void> _showLicence(BuildContext context, String voice, VoiceLicence licence) => showDialog<void>(
      context: context,
      builder: (ctx) {
        final body = Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(ctx)).copyWith(height: 1.4);
        return AlertDialog(
          title: Text(voice),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${licence.name} · ${licence.summary}',
                    style: Skin.ui(size: 15, weight: FontWeight.w700, color: Skin.inkOn(ctx))),
                if (licence.note.isNotEmpty) ...[
                  const SizedBox(height: Gap.s),
                  Text(licence.note, style: body),
                ],
                if (licence.stated.isNotEmpty) ...[
                  const SizedBox(height: Gap.m),
                  Text('The model card says: ${licence.stated}', style: body),
                ],
                if (licence.dataset.isNotEmpty) ...[
                  const SizedBox(height: Gap.s),
                  SelectableText('Recordings: ${licence.dataset}', style: body),
                ],
              ],
            ),
          ),
          actions: [
            if (licence.card.isNotEmpty)
              TextButton(
                onPressed: () => unawaited(const SpeechService().openUrl(licence.card)),
                child: const Text('Model card'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        );
      },
    );

/// What a natural voice costs: true to go ahead. [pack]: a model with many
/// speakers, whose own costs are said.
Future<bool> _costs(BuildContext context, {required String title, int? size, NeuralPack? pack}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Natural voices sound like people, but your phone does the work:',
                style: Skin.ui(size: 14.5, weight: FontWeight.w500, color: Skin.inkOn(ctx)),
              ),
              const SizedBox(height: Gap.m),
              for (final line in [
                size == null
                    ? 'A download of 25 to 125 MB for each voice, more for Kokoro'
                    : 'A download of $size MB, kept on the phone',
                if (pack != null && pack.mustKeepUp)
                  'About 1 GB of free space while it unpacks, which takes a few minutes',
                'More battery while reading aloud than the phone\'s own voices',
                if (pack != null && pack.mustKeepUp)
                  'About 850 MB of memory while it reads'
                else
                  'Up to a few hundred MB of memory while a voice is reading',
                if (pack != null && pack.mustKeepUp)
                  'Many phones cannot keep up with it. TomeVoice tests it after the download and offers it '
                      'for reading only if this phone keeps up'
                else
                  'On older or slower phones the voice can fall behind, with pauses between sentences',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('·  ', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentOf(ctx))),
                      Expanded(
                        child: Text(line,
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(ctx))
                                .copyWith(height: 1.4)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: Gap.s),
              Text(
                'Nothing changes unless you choose one. You can delete them all later in '
                'Settings → Listening → Natural voices.',
                style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(ctx)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("No thanks, keep the phone's voices"),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(size == null ? 'Show me' : 'Download')),
        ],
      ),
    ) ==
    true;
