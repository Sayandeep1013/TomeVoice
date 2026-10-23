import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'neural_voices.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

/// Natural voices: what is on offer, what is on the phone, and whether this
/// phone keeps up with each (a measured test, not a guess).
class NeuralVoicesScreen extends StatefulWidget {
  const NeuralVoicesScreen({super.key});

  @override
  State<NeuralVoicesScreen> createState() => _NeuralVoicesScreenState();
}

class _NeuralVoicesScreenState extends State<NeuralVoicesScreen> {
  final _voices = NeuralVoices.instance;

  /// Voice id -> measured speed (seconds of speech per second of work).
  final _speed = <String, double>{};
  String? _testing;

  @override
  void initState() {
    super.initState();
    _voices.addListener(_changed);
  }

  @override
  void dispose() {
    _voices.removeListener(_changed);
    super.dispose();
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
    if (!await _costs(context, title: 'Download ${v.name}?', size: v.sizeMb)) return;
    if (!mounted) return;
    setState(() => _prefs.naturalVoices = true);
    _prefs.save();
    try {
      await _voices.download(v);
      VoiceCatalog.instance.neuralChanged();
      if (mounted) showSnack(context, '${v.name} is ready. Pick it in a book\'s voices.');
      unawaited(_test(v));
    } on Object catch (e) {
      if (mounted) showSnack(context, 'The download stopped: ${e is SocketException ? 'no connection' : e}', long: true);
    }
  }

  Future<void> _test(NeuralVoice v) async {
    if (_testing != null) return;
    setState(() => _testing = v.id);
    try {
      final r = await NeuralEngine.instance.measure(v, Directory.systemTemp.path);
      if (mounted) setState(() => _speed[v.id] = r);
    } on Object catch (e) {
      if (mounted) showSnack(context, 'The test failed: $e', long: true);
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  Future<void> _remove(NeuralVoice v) async {
    await _voices.remove(v);
    _forgetVoices({v.voiceName});
    VoiceCatalog.instance.neuralChanged();
    _speed.remove(v.id);
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
    _speed.clear();
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
                        subtitle: 'Off: only the phone\'s own voices, and nothing to download',
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
                                'On this phone: ${_voices.installedVoices.length} '
                                '${_voices.installedVoices.length == 1 ? 'voice' : 'voices'} · '
                                '${(_voices.bytesUsed / 1048576).round()} MB',
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
                      if (_prefs.naturalVoices ?? false)
                        for (final v in neuralVoices) _row(context, v),
                      const SizedBox(height: Gap.l),
                      Text(
                        'Piper voices, made into speech by sherpa-onnx. Each voice keeps the licence of the '
                        'recordings it was trained on; see About → Licences.',
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

  Widget _row(BuildContext context, NeuralVoice v) {
    final here = _voices.installed(v);
    final progress = _voices.downloading[v.id];
    final speed = _speed[v.id];
    final region = v.locale.endsWith('GB') ? 'UK' : 'US';
    final String status;
    if (progress != null) {
      status = progress >= 0.9 ? 'Unpacking…' : 'Downloading ${(progress * 100).round()}%';
    } else if (_testing == v.id) {
      status = 'Testing on this phone…';
    } else if (speed != null) {
      status = speed >= 1.6
          ? 'Keeps up easily (${speed.toStringAsFixed(1)}× real time)'
          : speed >= 1.05
              ? 'Keeps up, just (${speed.toStringAsFixed(1)}× real time)'
              : 'Too slow for this phone (${speed.toStringAsFixed(1)}× real time)';
    } else {
      status = here ? 'On the phone' : '${v.sizeMb} MB';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Container(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
        decoration: BoxDecoration(
          color: Skin.capsuleOn(context),
          borderRadius: BorderRadius.circular(Radii.card / 1.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${v.name}${v.hd ? '  ·  HD' : ''}', style: Skin.title(context, size: 18)),
                  Text('ENGLISH ($region) · ${v.blurb.toUpperCase()}', style: Skin.meta(context, size: 10)),
                  const SizedBox(height: 4),
                  Text(status,
                      style: Skin.ui(
                          size: 13,
                          weight: FontWeight.w600,
                          color: speed != null && speed < 1.05 ? const Color(0xFFE5674D) : Skin.accentOf(context))),
                  if (progress != null) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: progress >= 0.9 ? null : progress / 0.9),
                  ],
                ],
              ),
            ),
            if (progress == null && _testing != v.id)
              here
                  ? PopupMenuButton<String>(
                      tooltip: 'More',
                      onSelected: (a) => a == 'test' ? _test(v) : _remove(v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'test', child: Text('Test speed')),
                        PopupMenuItem(value: 'remove', child: Text('Remove')),
                      ],
                    )
                  : IconButton(
                      tooltip: 'Download ${v.name}',
                      icon: Icon(Icons.download_rounded, color: Skin.accentOf(context)),
                      onPressed: () => _download(v),
                    ),
          ],
        ),
      ),
    );
  }
}

/// What a natural voice costs: true to go ahead.
Future<bool> _costs(BuildContext context, {required String title, int? size}) async =>
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
                size == null ? 'A download of 34 to 55 MB for each voice' : 'A download of $size MB, kept on the phone',
                'More battery while reading aloud than the phone\'s own voices',
                'Up to a few hundred MB of memory while a voice is reading',
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
