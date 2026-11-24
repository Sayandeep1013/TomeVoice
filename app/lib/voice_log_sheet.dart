import 'package:flutter/material.dart';

import 'neural_voices.dart';
import 'note_log_sheet.dart';
import 'prefs.dart';
import 'problem_report.dart' show deviceName;
import 'speech_service.dart';
import 'ui.dart' show sheetMotion;
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
    if (ListeningPrefs.loaded?.paletteId case final theme?) 'Theme: $theme',
    // What each natural voice's speed test measured on this phone (seconds
    // of speech made per second of work; below 1 it cannot keep up).
    if (_speedTests() case final tests when tests.isNotEmpty) 'Natural voices tested: $tests',
    'Speech engine: ${engine ?? "the phone's default"}${d['engineVersion'] is String && (d['engineVersion'] as String).isNotEmpty ? ' ${d['engineVersion']}' : ''}',
  ].where((l) => l.isNotEmpty).toList();
}

String _speedTests() {
  try {
    final voices = NeuralVoices.instance;
    final seen = <String>{};
    return [
      for (final v in voices.installedVoices)
        if (seen.add(v.modelId))
          if (voices.speedOf(v) case final s?) '${v.modelId} ${s.toStringAsFixed(2)}${String.fromCharCode(0xD7)}',
    ].join(', ');
  } on Object {
    return '';
  }
}

class VoiceLogSheet extends StatelessWidget {
  const VoiceLogSheet({super.key});

  @override
  Widget build(BuildContext context) => NoteLogSheet(
        log: VoiceLog.instance,
        title: 'Voice log',
        intro: 'For a voice that lags, stops or goes wrong. While it is on, TomeVoice notes how long '
            'the voice takes to start, whether this phone keeps up at each speed, every gap and '
            "every error, with this phone and voice. Never a book's words or title. Read as you "
            'normally do, then share the file with whoever is helping. It does not slow reading down.',
        switchTitle: 'Record a voice log',
        onWords: 'On: noting what reading aloud does',
        summary: voiceLogSummary,
        text: voiceLogText,
        header: voiceLogHeader,
      );
}
