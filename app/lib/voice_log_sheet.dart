import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'prefs.dart';
import 'problem_report.dart' show deviceName;
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voice_log.dart';

/// About > Voice log: turn it on, see what it says so far, share it as a
/// file (to whoever is helping with a voice that lags or goes wrong), or
/// clear it. Nothing is sent from the app.
Future<void> showVoiceLog(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const VoiceLogSheet(),
    );

/// The lines at the top of a shared log: the app, the phone and the voice.
Future<List<String>> voiceLogHeader() async {
  const svc = SpeechService();
  final version = await svc.appVersion() ?? '';
  final device = await svc.deviceInfo();
  final engine = ListeningPrefs.loaded?.engineId;
  final d = await svc.phoneDetails(engine: engine);
  final bits = d['is64'] == null ? '' : (d['is64'] == true ? '64-bit app' : '32-bit app');
  return [
    'App: TomeVoice $version${bits.isEmpty ? '' : ' ($bits)'}',
    if (device != null)
      'Phone: ${deviceName(device)}, Android ${device.android}${device.sdk > 0 ? ' (API ${device.sdk})' : ''}',
    [
      if (d['memoryMb'] != null) 'memory ${d['memoryMb']} MB (${d['freeMb'] ?? '?'} MB free when shared)',
      if (d['lowRam'] == true) 'a low-memory phone',
      if (d['cores'] != null) '${d['cores']} cores',
      if (d['abis'] != null) 'CPU ${d['abis']}',
      if (d['powerSave'] == true) 'battery saver ON',
    ].join(', '),
    'Speech engine: ${engine ?? "the phone's default"}${d['engineVersion'] is String && (d['engineVersion'] as String).isNotEmpty ? ' ${d['engineVersion']}' : ''}',
  ].where((l) => l.isNotEmpty).toList();
}

class VoiceLogSheet extends StatefulWidget {
  const VoiceLogSheet({super.key});

  @override
  State<VoiceLogSheet> createState() => _VoiceLogSheetState();
}

class _VoiceLogSheetState extends State<VoiceLogSheet> {
  final _log = VoiceLog.instance;
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await _log.flush();
      final header = await voiceLogHeader();
      const svc = SpeechService();
      final dir = await svc.shareDir();
      if (dir == null) throw const FileSystemException('there is nowhere to put the file');
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final file = File('$dir/TomeVoice voice log ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}.txt');
      await file.writeAsString(voiceLogText(_log.events, header: header), flush: true);
      await svc.shareFile(file.path, mime: 'text/plain', text: 'TomeVoice voice log');
    } on Object catch (e) {
      if (mounted) showSnack(context, 'The log could not be shared: $e', long: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    await _log.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: _log.changes,
          builder: (context, _, __) {
            final events = _log.events;
            final summary = events.isEmpty ? const <String>[] : voiceLogSummary(events);
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHeader('Voice log', subtitle: 'Nothing is sent from here'),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                      children: [
                        Text(
                          'For a voice that lags, stops or goes wrong. While it is on, TomeVoice notes how long '
                          'the voice takes to start, whether this phone keeps up at each speed, every gap and '
                          'every error, with this phone and voice. Never a book\'s words or title. Read as you '
                          'normally do, then share the file with whoever is helping. It does not slow reading down.',
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                              .copyWith(height: 1.4),
                        ),
                        const SizedBox(height: Gap.m),
                        SwitchRow(
                          title: 'Record a voice log',
                          subtitle: _log.on ? 'On: noting what reading aloud does' : 'Off',
                          value: _log.on,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => unawaited(_log.setOn(v)),
                        ),
                        if (summary.isNotEmpty) ...[
                          const SizedBox(height: Gap.m),
                          Text('SO FAR · ${events.length} NOTES', style: Skin.meta(context)),
                          const SizedBox(height: Gap.s),
                          for (final line in summary)
                            Padding(
                              padding: const EdgeInsets.only(bottom: Gap.xs),
                              child: Text('· $line',
                                  style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkOn(context))
                                      .copyWith(height: 1.4)),
                            ),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.m),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: events.isEmpty || _busy ? null : () => unawaited(_clear()),
                            icon: const Icon(Icons.delete_outline_rounded, size: 18),
                            label: const Text('Clear'),
                          ),
                        ),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: events.isEmpty || _busy ? null : () => unawaited(_share()),
                            icon: const Icon(Icons.ios_share_rounded, size: 18),
                            label: const Text('Share'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
}
