import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../speech_service.dart';
import '../theme.dart';
import '../ui.dart';
import 'ai_keys.dart';

/// What every AI that writes for the reader is told, whatever the book.
const aiSafetyRule = 'Never write sexual content involving anyone under 18, sexual content about real people, '
    'or anything that helps someone hurt themselves or others. A book may hold dark scenes: you may say what '
    'happens in it plainly, without dwelling on graphic detail.';

/// Where a report of an AI answer goes: a Google Form the developer reads,
/// posted from the phone (there is no TomeVoice server). [action] is the
/// form's `formResponse` address; [fields] names each part's `entry.N`.
class AiReportForm {
  const AiReportForm({required this.action, required this.fields});

  final String action;

  /// reason, note, answer, question, model, where, version → `entry.123`.
  final Map<String, String> fields;

  bool get ready => action.isNotEmpty && fields.isNotEmpty;
}

/// The developer's form, "TomeVoice AI reports" (made 20 Nov 2026 in the
/// publishing account; no sign-in, no emails collected). A report is posted
/// to it the way the form's own page would.
const aiReportForm = AiReportForm(
  action: 'https://docs.google.com/forms/d/e/1FAIpQLSfgtOj-lFdd4daTluiS8kYbI1GhEEmYbzGHEnVaDamWXi-1ZQ/formResponse',
  fields: {
    'reason': 'entry.1173485706',
    'note': 'entry.1817592797',
    'answer': 'entry.1020922861',
    'question': 'entry.245498505',
    'model': 'entry.701342862',
    'where': 'entry.1983285404',
    'version': 'entry.369128993',
  },
);

/// Why an answer is reported.
const aiReportReasons = [
  'Harmful or dangerous',
  'Sexual, and should not be',
  'Hateful or harassing',
  'Wrong about the book, or made up',
  'Something else',
];

/// [report] posted to [form]: true when the form took it.
Future<bool> postAiReport(Map<String, String> report, {AiReportForm form = aiReportForm, HttpClient? http}) async {
  if (!form.ready) return false;
  final client = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15));
  try {
    final body = [
      for (final e in report.entries)
        if (form.fields[e.key] case final entry?)
          '${Uri.encodeQueryComponent(entry)}=${Uri.encodeQueryComponent(e.value)}',
    ].join('&');
    final req = await client.postUrl(Uri.parse(form.action));
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    return res.statusCode >= 200 && res.statusCode < 400;
  } on Object {
    return false;
  } finally {
    if (http == null) client.close(force: true);
  }
}

/// The model writing for [job] now, as a report names it: "Google Gemini ·
/// gemini-2.5-flash".
String aiModelFor(AiJob job) {
  final k = AiRing.instance.forJob(job);
  if (k.isEmpty) return '';
  return '${k.first.provider.label} · ${k.first.models[job] ?? ''}';
}

/// "Report this answer": why, a note, and what is sent, said plainly. True
/// when the reader reported it (sent or not), so the answer is hidden.
Future<bool> reportAiAnswer(
  BuildContext context, {
  required String answer,
  String question = '',
  required String where,
  AiJob job = AiJob.talker,
  Future<bool> Function(Map<String, String> report)? send,
}) async {
  final picked = await showModalBottomSheet<({String reason, String note})>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _ReportSheet(),
  );
  if (picked == null) return false;
  final version = await const SpeechService().appVersion() ?? '';
  final report = {
    'reason': picked.reason,
    'note': picked.note,
    'answer': answer.length > 4000 ? '${answer.substring(0, 4000)}…' : answer,
    'question': question.length > 1000 ? '${question.substring(0, 1000)}…' : question,
    'model': aiModelFor(job),
    'where': where,
    'version': version,
  };
  final sent = await (send ?? postAiReport)(report);
  if (context.mounted) {
    showSnack(context, sent ? 'Reported. Thank you: it is hidden here.' : 'Could not send the report now. It is hidden here.');
  }
  return true;
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet();

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHeader('Report this answer', subtitle: 'Written by the AI, not by TomeVoice or the book'),
                for (final r in aiReportReasons)
                  ListTile(
                    dense: true,
                    selected: _reason == r,
                    leading: Icon(_reason == r ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
                    title: Text(r),
                    onTap: () => setState(() => _reason = r),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
                  child: TextField(
                    controller: _note,
                    maxLines: 3,
                    minLines: 1,
                    maxLength: 500,
                    decoration: const InputDecoration(hintText: 'Anything to add (optional)'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, 0),
                  child: Text(
                    'Sent to the developer: this answer, your question, why, your note, the AI model and the app '
                    "version. Nothing else from your book or your journal. The answer is hidden here.",
                    style: Skin.label(context, size: 13),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.l),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      const SizedBox(width: Gap.s),
                      FilledButton(
                        onPressed: _reason == null
                            ? null
                            : () => Navigator.pop(context, (reason: _reason!, note: _note.text.trim())),
                        child: const Text('Send report'),
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

/// Whether an AI answer is held back unshown: sexual words beside words for
/// a child, in one sentence. Only the AI's own words are checked, never the
/// book's.
bool aiAnswerHeld(String text) {
  for (final s in text.toLowerCase().split(RegExp(r'(?<=[.!?\n])'))) {
    if (_young.hasMatch(s) && _sexual.hasMatch(s)) return true;
  }
  return false;
}

final _young = RegExp(
  r'\b(child|children|minor|minors|underage|under-age|preteen|pre-teen|toddler|(?:[1-9]|1[0-7])[- ]years?[- ]old)\b',
);
final _sexual = RegExp(r'\b(sex|sexual|sexually|erotic|porn|pornographic|genitals?|intercourse)\b');
