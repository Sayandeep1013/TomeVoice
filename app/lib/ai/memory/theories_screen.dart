import 'dart:async';

import 'package:flutter/material.dart';

import '../../notebook.dart' show savedWhen;
import '../../theme.dart';
import '../../ui.dart';
import 'theories.dart';

/// The reader's theories about a book: open, or what the story made of
/// them, as far as the reader has read (a verdict further on stays hidden).
class TheoriesScreen extends StatefulWidget {
  const TheoriesScreen({super.key, required this.bookTitle, required this.memoryPath, required this.here});

  final String bookTitle;
  final String memoryPath;

  /// The chapter the reader is at: verdicts beyond it are not shown.
  final int here;

  @override
  State<TheoriesScreen> createState() => _TheoriesScreenState();
}

class _TheoriesScreenState extends State<TheoriesScreen> {
  List<Theory>? _theories;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final t = await theoriesOff(widget.memoryPath, widget.here);
    if (!mounted) return;
    setState(() => _theories = t);
    final told = [for (final x in t) if (x.decided && !x.told) x.id];
    if (told.isNotEmpty) await markToldOff(widget.memoryPath, told);
  }

  Future<void> _remove(Theory t) async {
    final sure = await confirm(context, title: 'Remove this theory?', body: t.text, action: 'Remove');
    if (!sure) return;
    await removeTheoryOff(widget.memoryPath, t.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _theories;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Theories', onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                child: Text(widget.bookTitle, style: Skin.meta(context)),
              ),
              Expanded(
                child: list == null
                    ? const SizedBox.shrink()
                    : list.isEmpty
                        ? const EmptyState(
                            icon: Icons.lightbulb_outline_rounded,
                            title: 'No theories yet',
                            body: 'In Talk, tap the bulb and say what you think is going on. The AI weighs it, '
                                'and as you read on, it tells you when the story settles it.',
                          )
                        : ListView(
                            padding: EdgeInsets.fromLTRB(
                                Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                            children: [for (final t in list) _row(context, t)],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Theory t) {
    final (label, colour) = switch (t.status) {
      'confirmed' => ('Confirmed', const Color(0xFF3E9B5B)),
      'busted' => ('Busted', const Color(0xFFD0503F)),
      'mixed' => ('Partly right', const Color(0xFFD39A2B)),
      _ => ('Open', Skin.inkSoftOn(context)),
    };
    return InkWell(
      onLongPress: () => unawaited(_remove(t)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(label, style: Skin.meta(context, color: colour)),
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text('Stated at chapter ${t.ch + 1} · ${savedWhen(t.made)}', style: Skin.meta(context)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(t.text, style: Skin.ui(size: 15.5, weight: FontWeight.w500, color: Skin.inkOn(context))),
            if (t.decided && t.verdict != null && t.verdict!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Chapter ${t.decidedCh! + 1}: ${t.verdict}',
                  style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.35)),
            ],
          ],
        ),
      ),
    );
  }
}
