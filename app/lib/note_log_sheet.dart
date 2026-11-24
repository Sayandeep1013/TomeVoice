import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'note_log.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// A log's sheet (About > Voice log, About > Tap log): turn it on, see what
/// it says so far, share it as a file (to whoever is helping), or clear it.
/// Nothing is sent from the app.
class NoteLogSheet extends StatefulWidget {
  const NoteLogSheet({
    super.key,
    required this.log,
    required this.title,
    required this.intro,
    required this.switchTitle,
    required this.onWords,
    required this.summary,
    required this.text,
    required this.header,
  });

  final NoteLog log;

  /// "Voice log": the sheet's heading, and the shared file's name.
  final String title;

  /// What it is for and what it notes.
  final String intro;

  /// The switch's words, and what it says while on.
  final String switchTitle;
  final String onWords;

  /// The log in plain words, a line each.
  final List<String> Function(List<LogEvent> events) summary;

  /// The whole log as text, under [header]'s lines.
  final String Function(List<LogEvent> events, {required List<String> header}) text;

  /// The lines at the top of a shared log: the app and the phone.
  final Future<List<String>> Function() header;

  @override
  State<NoteLogSheet> createState() => _NoteLogSheetState();
}

class _NoteLogSheetState extends State<NoteLogSheet> {
  NoteLog get _log => widget.log;
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await _log.flush();
      final header = await widget.header();
      const svc = SpeechService();
      final dir = await svc.shareDir();
      if (dir == null) throw const FileSystemException('there is nowhere to put the file');
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final file = File('$dir/TomeVoice ${widget.title.toLowerCase()} '
          '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}.txt');
      await file.writeAsString(widget.text(_log.events, header: header), flush: true);
      await svc.shareFile(file.path, mime: 'text/plain', text: 'TomeVoice ${widget.title.toLowerCase()}');
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
            final summary = events.isEmpty ? const <String>[] : widget.summary(events);
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetHeader(widget.title, subtitle: 'Nothing is sent from here'),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                      children: [
                        Text(
                          widget.intro,
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                              .copyWith(height: 1.4),
                        ),
                        const SizedBox(height: Gap.m),
                        SwitchRow(
                          title: widget.switchTitle,
                          subtitle: _log.on ? widget.onWords : 'Off',
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
