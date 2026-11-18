import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../ai_keys.dart';
import '../ai_screen.dart' show tokenCount, wakeTime;
import 'graph_screen.dart';
import 'memory_builder.dart';
import 'memory_service.dart';
import 'whos_who_screen.dart';

/// A book's page > Memory: what the AI companion remembers of the book,
/// how far it is built, Build or Pause, and the spoiler guard.
class BookMemorySection extends StatefulWidget {
  const BookMemorySection({super.key, required this.bookId, required this.bookTitle, required this.secret, this.service});

  final String bookId;
  final String bookTitle;

  /// On a secret shelf: never sent, so never built.
  final bool secret;
  final MemoryService? service;

  @override
  State<BookMemorySection> createState() => _BookMemorySectionState();
}

class _BookMemorySectionState extends State<BookMemorySection> {
  MemoryService get _service => widget.service ?? MemoryService.instance;

  @override
  void initState() {
    super.initState();
    AiRing.instance.addListener(_changed);
  }

  @override
  void dispose() {
    AiRing.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _build() async {
    final est = await _service.estimate(widget.bookId);
    if (!mounted) return;
    if (est.chapters == 0) {
      unawaited(_service.build(widget.bookId));
      return;
    }
    final keys = AiRing.instance.forJob(AiJob.builder);
    final go = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('Build the memory', subtitle: 'Each chapter is read once, ever'),
              Text(
                '${est.chapters} ${est.chapters == 1 ? 'chapter' : 'chapters'} to read, in about '
                '${est.calls} ${est.calls == 1 ? 'call' : 'calls'}: some ${tokenCount(est.tokens)} tokens, '
                'with ${keys.map((k) => k.label).join(', then ')}. '
                'It goes on while TomeVoice is open; when a key has used its quota for now, the next takes '
                'over, and when all of them have, it waits for them.',
                style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
              ),
              const SizedBox(height: Gap.l),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Build')),
            ],
          ),
        ),
      ),
    );
    if (go == true) unawaited(_service.build(widget.bookId));
  }

  Future<void> _openWho() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          WhosWhoScreen(bookTitle: widget.bookTitle, memoryPath: _service.pathOf(widget.bookId), line: line),
    ));
  }

  Future<void> _openGraph() async {
    final line = await _service.lineOf(widget.bookId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          MemoryGraphScreen(bookTitle: widget.bookTitle, memoryPath: _service.pathOf(widget.bookId), line: line),
    ));
  }

  Future<void> _forget() async {
    final sure = await confirm(context,
        title: 'Forget what it remembers?',
        body: 'The notes, the cast and the word index of this book are deleted. Your journal stays.',
        action: 'Forget');
    if (sure) await _service.forget(widget.bookId);
  }

  String _line(BookMemoryState s) {
    final b = s.build;
    final ix = s.indexing;
    if (ix != null) return ix.total == 0 ? 'Indexing its words…' : 'Indexing its words · ${ix.done} of ${ix.total}';
    switch (b.phase) {
      case BuildPhase.running:
        return 'Building · ${s.noted} of ${s.indexed} chapters';
      case BuildPhase.resting:
        return 'Waiting: every key has used its quota for now. Goes on at ${wakeTime(b.until!)}.';
      case BuildPhase.failed:
        return 'Stopped: ${b.error ?? 'no key could build it'}';
      case BuildPhase.paused:
        return 'Paused · ${s.noted} of ${s.indexed} chapters';
      case BuildPhase.idle || BuildPhase.done:
        break;
    }
    if (!s.exists || s.indexed == 0) return 'Not built yet';
    if (s.noted == 0) return 'Its words are indexed: Find where… works. No notes yet.';
    final things = '${s.entities} ${s.entities == 1 ? 'person, place or thing' : 'people, places and things'}';
    if (s.noted + s.skipped >= s.indexed) return 'Built to chapter ${(s.lastNoted ?? 0) + 1} · $things';
    return '${s.noted} of ${s.indexed} chapters built · $things';
  }

  @override
  Widget build(BuildContext context) {
    // Off until the reader turns the AI on (adds a key), and never for a
    // book on a secret shelf.
    if (widget.secret || !AiRing.instance.hasKeys) return const SizedBox.shrink();
    return ValueListenableBuilder<BookMemoryState>(
      valueListenable: _service.stateOf(widget.bookId),
      builder: (context, s, _) {
        final busy = s.building || s.build.phase == BuildPhase.resting;
        final left = s.indexed == 0 || s.noted + s.skipped < s.indexed;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: SectionTitle('Memory', note: 'AI')),
                if (s.exists)
                  PopupMenuButton<String>(
                    tooltip: 'More about the memory',
                    onSelected: (v) {
                      if (v == 'forget') unawaited(_forget());
                    },
                    itemBuilder: (_) => const [PopupMenuItem(value: 'forget', child: Text('Forget this memory'))],
                  ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              _line(s),
              style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
            ),
            if (s.build.phase == BuildPhase.running && s.indexed > 0) ...[
              const SizedBox(height: Gap.s),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: s.noted / s.indexed, minHeight: 4),
              ),
            ],
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                if (busy)
                  OutlinedButton.icon(
                    onPressed: () => _service.pause(widget.bookId),
                    icon: const Icon(Icons.pause_rounded, size: 18),
                    label: const Text('Pause'),
                  )
                else if (left)
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(_build()),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text(s.noted == 0 ? 'Build memory' : 'Go on building'),
                  ),
                if (s.entities > 0) ...[
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_openWho()),
                    icon: const Icon(Icons.groups_outlined, size: 18),
                    label: const Text("Who's who"),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_openGraph()),
                    icon: const Icon(Icons.hub_outlined, size: 18),
                    label: const Text('Graph'),
                  ),
                ],
              ],
            ),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.guard,
                onChanged: (v) => unawaited(_service.setGuard(widget.bookId, v)),
                title: Text('Spoiler guard',
                    style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                subtitle: Text(
                  s.guard
                      ? 'The AI keeps to what you have read.'
                      : 'Off: the AI may use all it remembers of the book.',
                  style: Skin.meta(context),
                ),
              ),
          ],
        );
      },
    );
  }
}
