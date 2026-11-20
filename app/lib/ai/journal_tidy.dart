import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui.dart';
import 'ai_client.dart';
import 'ai_consent.dart';
import 'ai_keys.dart';
import 'ai_router.dart';

/// How a spoken journal entry is tidied: the reader's own words kept.
const tidyAsk = 'You tidy words a reader spoke aloud into their reading journal, as a speech recogniser heard them. '
    'Add punctuation, capitals and paragraph breaks; take out filler ("um", "uh", "you know" said as filler) and '
    'words said twice by accident; mend a word misheard only when the meaning makes it certain. Keep their own '
    'words, their order and their meaning: do not add, explain, summarise or make it sound grander. Keep the '
    'language they spoke in. Reply with the tidied text alone.';

/// [texts] tidied by the AI, each shown beside what was said before it is
/// used. The tidied texts, or null when the reader kept their own (or the
/// AI could not be reached; a note says so).
Future<List<String>?> tidyJournalText(BuildContext context, List<String> texts, {AiRouter? router, String? about}) async {
  final r = router ?? AiRouter(about: about);
  if (!await ensureAiConsent(context, ring: r.ring) || !context.mounted) return null;
  final out = <String>[];
  showSnack(context, 'Tidying what you said…');
  try {
    for (final t in texts) {
      final reply = await r.chat(AiJob.talker, [aiMessage('system', tidyAsk), aiMessage('user', t)]);
      final tidied = reply.text.trim();
      out.add(tidied.isEmpty ? t : tidied);
    }
  } on Object catch (e) {
    if (context.mounted) {
      showSnack(context, e is AiResting ? 'Every key is resting for now: try Tidy again later.' : 'Tidy could not reach the AI.');
    }
    return null;
  }
  if (!context.mounted) return null;
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  final use = await showModalBottomSheet<bool>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Tidied', subtitle: 'Your words, with punctuation and without the ums'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: Gap.l),
              children: [
                for (final (i, t) in out.indexed) ...[
                  Text('YOU SAID', style: Skin.meta(ctx, size: 10.5)),
                  const SizedBox(height: Gap.xs),
                  Text(texts[i], style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(ctx))),
                  const SizedBox(height: Gap.s),
                  Text('TIDIED', style: Skin.meta(ctx, size: 10.5)),
                  const SizedBox(height: Gap.xs),
                  Text(t, style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(ctx))),
                  const SizedBox(height: Gap.l),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep mine')),
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Use these')),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  return use == true ? out : null;
}
