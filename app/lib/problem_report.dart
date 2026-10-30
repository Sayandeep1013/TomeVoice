import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'error_log.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// Where a report goes: a new issue on the project's GitHub.
const issuesUrl = 'https://github.com/Sayandeep1013/TomeVoice/issues/new';

/// The longest link a report is put in: GitHub turns away a new issue's
/// address much past 8,000 characters, so the oldest errors give way first.
const reportLinkMax = 7000;

/// The most errors a report holds, newest first, and the lines of each
/// one's stack it shows.
const reportErrors = 5;
const reportFrames = 8;

/// A problem report: the issue's title and the text it opens with.
typedef ProblemReport = ({String title, String body});

/// "Nothing A059", "Google Pixel 8": the maker, unless the model already
/// says it.
String deviceName(DeviceInfo d) {
  final maker = d.maker.trim();
  final model = d.model.trim();
  if (maker.isEmpty || model.toLowerCase().startsWith(maker.toLowerCase())) return model;
  return '${maker[0].toUpperCase()}${maker.substring(1)} $model'.trim();
}

/// Every word a report says: what happened (the reader's to write), this
/// app and phone, and the last errors from the log, newest first, as many
/// as keep the link that opens it on GitHub within [maxLink] characters.
/// [errors] are the log's, oldest first.
ProblemReport problemReport({
  required String version,
  DeviceInfo? device,
  required List<ErrorEntry> errors,
  int maxLink = reportLinkMax,
}) {
  final app = version.isEmpty ? 'TomeVoice' : 'TomeVoice $version';
  final title = 'Problem in $app';
  final name = device == null ? '' : deviceName(device);
  final phone = [
    '- $app',
    if (device != null && device.android.isNotEmpty)
      '- Android ${device.android}${device.sdk > 0 ? ' (API ${device.sdk})' : ''}',
    if (name.isNotEmpty) '- $name',
  ];
  String body(List<ErrorEntry> shown) {
    final left = errors.length - shown.length;
    return [
      '### What happened',
      '',
      'Say what you were doing, and what went wrong.',
      '',
      '### This phone',
      '',
      ...phone,
      '',
      '### Last errors',
      '',
      if (errors.isEmpty)
        'None: the error log on this phone is empty.'
      else if (shown.isEmpty)
        'The log on the phone holds ${errors.length == 1 ? 'one error' : '${errors.length} errors'}, '
            'but even the newest is too long to send this way.'
      else ...[
        "From the error log TomeVoice keeps on the phone, newest first. It never holds a book's title or text.",
        '',
        '```',
        for (final (i, e) in shown.indexed) ...[
          if (i > 0) '',
          ..._lines(e),
        ],
        '```',
        if (left > 0) ...[
          '',
          '${left == 1 ? 'One older error is' : '$left older errors are'} kept on the phone, '
              'left out here to keep this short.',
        ],
      ],
    ].join('\n');
  }

  final newest = errors.reversed.take(reportErrors).toList();
  for (var n = newest.length; n > 0; n--) {
    final report = (title: title, body: body(newest.sublist(0, n)));
    if (issueLink(report).toString().length <= maxLink) return report;
  }
  return (title: title, body: body(const []));
}

/// One error as a report shows it: when, in which version, from which side
/// and how often; what it said; where.
List<String> _lines(ErrorEntry e) {
  final t = e.time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final when = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)} UTC';
  return [
    [
      when,
      if (e.version.isNotEmpty) e.version,
      e.from == 'android' ? 'Android' : 'app',
      if (e.count > 1) '${e.count} times',
    ].join(' · '),
    e.message,
    ...e.stack.split('\n').where((l) => l.isNotEmpty).take(reportFrames),
  ];
}

/// The address that opens [report] on GitHub as a new issue, filled in.
Uri issueLink(ProblemReport report) =>
    Uri.parse(issuesUrl).replace(queryParameters: {'title': report.title, 'body': report.body});

/// About > Report a problem: the whole report, word for word as it would be
/// sent, and a button that opens it on GitHub, filled in, for the reader to
/// read again, change and send there themselves. Nothing is sent from the
/// app, and nothing at all unless they send it.
Future<void> showProblemReport(BuildContext context) async {
  const svc = SpeechService();
  final version = await svc.appVersion() ?? '';
  ErrorLog.instance.version = version;
  final device = await svc.deviceInfo();
  final report = problemReport(version: version, device: device, errors: ErrorLog.instance.entries);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ProblemReportSheet(report: report),
  );
}

/// The report as it would be sent, with Copy and Open GitHub.
class ProblemReportSheet extends StatelessWidget {
  const ProblemReportSheet({super.key, required this.report});

  final ProblemReport report;

  String get _text => '${report.title}\n\n${report.body}';

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: _text));
    if (!context.mounted) return;
    Navigator.of(context).pop();
    messenger?.showSnackBar(const SnackBar(content: Text('Copied. Paste it wherever you like to send it.')));
  }

  Future<void> _open(BuildContext context) async {
    final opened = await const SpeechService().openUrl(issueLink(report).toString());
    if (!context.mounted) return;
    if (opened) {
      Navigator.of(context).pop();
    } else {
      showSnack(context, 'No browser on this phone would open it. Copy the report instead.');
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('Report a problem', subtitle: 'Nothing is sent from here'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                child: Text(
                  'This is the whole report, word for word. Open GitHub and it is filled in there, '
                  'for you to read, change and send yourself.',
                  style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                      .copyWith(height: 1.4),
                ),
              ),
              const SizedBox(height: Gap.m),
              Flexible(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: Gap.l),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.row),
                    border: Border.all(color: Skin.outlineOn(context)),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(Gap.m),
                    child: SelectableText(
                      _text,
                      style: Skin.ui(size: 12.5, weight: FontWeight.w400, color: Skin.inkOn(context), tabular: true)
                          .copyWith(height: 1.45),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.m),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => unawaited(_copy(context)),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => unawaited(_open(context)),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('Open GitHub'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
