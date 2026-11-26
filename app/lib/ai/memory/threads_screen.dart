import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import '../../theme.dart';
import '../../ui.dart';
import 'memory_db.dart';

/// A thread of the story (a mystery, a promise, a foreshadowing): where it
/// was raised, whether it is settled by the line, and its steps.
typedef StoryThread = ({
  String title,
  String? about,
  int raised,
  int? resolved,
  List<({MemoryPlace place, String step, String what})> steps,
});

/// The threads of the memory at [path] as they stand at chapter [upTo]
/// (null: all of it): the open ones first, the latest moved first; a step
/// or a resolution past the line is not shown.
List<StoryThread> storyThreads(String path, int? upTo) {
  if (!MemoryDb.existsAt(path)) return const [];
  final m = MemoryDb.open(path);
  final at = upTo ?? 1 << 30;
  try {
    final out = <StoryThread>[];
    for (final t in m.db.select(
        'SELECT id, title, about, raised_ch, resolved_ch FROM threads WHERE raised_ch <= ? AND raised_ch >= 0', [at])) {
      final resolved = t['resolved_ch'] as int?;
      out.add((
        title: t['title'] as String,
        about: t['about'] as String?,
        raised: t['raised_ch'] as int,
        resolved: resolved != null && resolved <= at ? resolved : null,
        steps: [
          for (final s in m.db.select(
              'SELECT ch, sec, blk, sen, step, what FROM thread_steps WHERE thread = ? AND ch <= ? ORDER BY ch',
              [t['id'], at]))
            (
              place: MemoryPlace(
                chapter: s['ch'] as int,
                section: (s['sec'] as int?) ?? s['ch'] as int,
                block: (s['blk'] as int?) ?? 0,
                sentence: (s['sen'] as int?) ?? 0,
              ),
              step: (s['step'] as String?) ?? 'advanced',
              what: (s['what'] as String?) ?? '',
            ),
        ],
      ));
    }
    int last(StoryThread t) => t.steps.isEmpty ? t.raised : t.steps.last.place.chapter;
    out.sort((a, b) {
      final open = (a.resolved == null ? 0 : 1).compareTo(b.resolved == null ? 0 : 1);
      return open != 0 ? open : last(b).compareTo(last(a));
    });
    return out;
  } finally {
    m.close();
  }
}

Future<List<StoryThread>> _threadsOff(String path, int? upTo) => Isolate.run(() => storyThreads(path, upTo));

/// A book's memory > Threads: the story's open questions and how each moved
/// on, chapter by chapter; a step tapped opens the book there.
class ThreadsScreen extends StatefulWidget {
  const ThreadsScreen({super.key, required this.memoryPath, this.line, this.onRead});

  final String memoryPath;
  final int? line;
  final void Function(ReadingCursor at)? onRead;

  @override
  State<ThreadsScreen> createState() => _ThreadsScreenState();
}

class _ThreadsScreenState extends State<ThreadsScreen> {
  List<StoryThread>? _threads;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_threadsOff(widget.memoryPath, widget.line).then((t) {
      if (mounted) setState(() => _threads = t);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final all = _threads;
    final shown = all?.where((t) => _settled ? t.resolved != null : t.resolved == null).toList();
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Threads', onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: ChoiceRow<bool>(
                  options: [
                    (false, 'Open ${all?.where((t) => t.resolved == null).length ?? ''}'.trim()),
                    (true, 'Settled ${all?.where((t) => t.resolved != null).length ?? ''}'.trim()),
                  ],
                  value: _settled,
                  onChanged: (v) => setState(() => _settled = v),
                ),
              ),
              Expanded(
                child: shown == null
                    ? const Center(child: CircularProgressIndicator())
                    : shown.isEmpty
                        ? EmptyState(
                            icon: Icons.timeline_rounded,
                            title: _settled ? 'Nothing settled yet' : 'No open threads',
                            body: 'The mysteries, promises and hints the memory finds show here, step by step.',
                          )
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xl + bottom),
                            itemCount: shown.length,
                            itemBuilder: (context, i) => _thread(context, shown[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thread(BuildContext context, StoryThread t) {
    final accent = Skin.accentInkOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Material(
        color: Skin.capsuleOn(context),
        shape: Skin.cardShape(context, Radii.row + 4),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(t.title, style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
          subtitle: Text(
            'Raised in chapter ${t.raised + 1}'
            '${t.resolved == null ? '' : ' · settled in chapter ${t.resolved! + 1}'}'
            '${t.steps.length > 1 ? ' · ${t.steps.length} steps' : ''}',
            style: Skin.meta(context),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((t.about ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.s),
                child: Text(t.about!.trim(),
                    style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))),
              ),
            for (final s in t.steps)
              InkWell(
                onTap: widget.onRead == null
                    ? null
                    : () => widget.onRead!(ReadingCursor(
                        sectionIndex: s.place.section, blockIndex: s.place.block, sentenceIndex: s.place.sentence)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The steps as points on a line: filled where it was settled.
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: s.step == 'resolved' ? accent : Colors.transparent,
                            border: Border.all(color: accent, width: 1.6),
                          ),
                        ),
                      ),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: 'Ch ${s.place.chapter + 1} · ${s.step}  ',
                                style: Skin.meta(context, color: accent)),
                            TextSpan(text: s.what),
                          ]),
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkOn(context))
                              .copyWith(height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
