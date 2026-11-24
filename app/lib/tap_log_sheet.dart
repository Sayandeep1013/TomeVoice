import 'package:flutter/material.dart';

import 'note_log_sheet.dart';
import 'prefs.dart';
import 'tap_log.dart';
import 'ui.dart' show sheetMotion;
import 'voice_log_sheet.dart' show voiceLogHeader;

/// About > Tap log: turn it on, see what it says so far, share it as a file
/// (to whoever is helping with buttons that do not answer), or clear it.
/// Nothing is sent from the app.
Future<void> showTapLog(BuildContext context) {
  // Read here, while the context is the app's: the header is made later.
  final view = View.of(context);
  final size = view.physicalSize / view.devicePixelRatio;
  final phoneStill = MediaQuery.of(context).disableAnimations && (ListeningPrefs.loaded?.animations ?? true);
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => TapLogSheet(screen: size, phoneStill: phoneStill),
  );
}

/// The lines at the top of a shared tap log: the app and the phone (as the
/// voice log's), the screen's size and whether animations are on.
Future<List<String>> tapLogHeader({required Size screen, required bool phoneStill}) async {
  final lines = await voiceLogHeader();
  final animations = !(ListeningPrefs.loaded?.animations ?? true)
      ? 'off in TomeVoice'
      : (phoneStill ? 'removed by the phone' : 'on');
  return [
    ...lines,
    'Screen: ${screen.width.round()} x ${screen.height.round()} dp',
    'Animations: $animations',
  ];
}

class TapLogSheet extends StatelessWidget {
  const TapLogSheet({super.key, required this.screen, required this.phoneStill});

  final Size screen;
  final bool phoneStill;

  @override
  Widget build(BuildContext context) => NoteLogSheet(
        log: TapLog.instance,
        title: 'Tap log',
        intro: 'For buttons that need tapping again and again. While it is on, TomeVoice notes where your '
            'finger comes down, how long it stays, which of its buttons was under it and whether that '
            "answered, and the moments the screen stuck. Never a book's words or what you type. Use the "
            'app as you normally do, then share the file with whoever is helping.',
        switchTitle: 'Record a tap log',
        onWords: 'On: noting every tap',
        summary: tapLogSummary,
        text: tapLogText,
        header: () => tapLogHeader(screen: screen, phoneStill: phoneStill),
      );
}
