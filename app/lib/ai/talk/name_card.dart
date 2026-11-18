import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../memory/graph.dart';
import '../memory/memory_db.dart';
import 'answer_pack.dart';

/// A held word as a name: "Oren's" is Oren.
String bareName(String word) => word.trim().replaceFirst(RegExp("['’]s\$"), '');

/// A card as the sheet shows it: the entity's name, and its lines.
typedef FoundCard = ({String name, List<PackItem> items});

/// The card of whoever or whatever [word] names in [sentence] (the name it
/// is part of there, the longest first), as it stands at chapter [at] (null:
/// all it remembers). Null when the memory knows no such name.
FoundCard? findCard(String path, String word, String sentence, int? at) {
  if (!MemoryDb.existsAt(path)) return null;
  final m = MemoryDb.open(path);
  try {
    final g = BookGraph(m);
    final bare = bareName(word);
    final w = normName(bare);
    int? id;
    // A name in the sentence that has the word in it: "Changing Star" for a
    // hold on "Star".
    var best = 0;
    for (final e in g.namedIn(sentence)) {
      for (final r in m.db.select('SELECT norm FROM aliases WHERE entity = ?', [e])) {
        final norm = r['norm'] as String;
        if (norm.split(' ').contains(w) && norm.length > best) {
          best = norm.length;
          id = g.live(e);
        }
      }
    }
    id ??= g.byName(bare);
    if (id == null) return null;
    final items = cardItems(m, id, at ?? 1 << 30);
    if (items.isEmpty) return null;
    final name = m.db.select('SELECT name FROM entities WHERE id = ?', [id]).first['name'] as String;
    return (name: name, items: items);
  } finally {
    m.close();
  }
}

/// Entity [id]'s card as it stands at chapter [at] (null: all of it).
FoundCard? cardOf(String path, int id, int? at) {
  final m = MemoryDb.open(path);
  try {
    final items = cardItems(m, id, at ?? 1 << 30);
    if (items.isEmpty) return null;
    final name = m.db.select('SELECT name FROM entities WHERE id = ?', [id]).first['name'] as String;
    return (name: name, items: items);
  } finally {
    m.close();
  }
}

/// [cardOf] off the UI thread's isolate.
Future<FoundCard?> cardOff(String path, int id, int? at) => Isolate.run(() => cardOf(path, id, at));

/// Who or what a held word is: its card from the book's memory, at once and
/// with no AI; each line's chapter a tap looks at; Tell me more asks Talk.
Future<void> showNameCard(
  BuildContext context, {
  required String memoryPath,
  required String word,
  required String sentence,
  required int? line,
  required void Function(MemoryPlace place) onLook,
  required void Function(String question) onAsk,
}) async {
  final path = memoryPath;
  final card = await Isolate.run(() => findCard(path, word, sentence, line));
  if (!context.mounted) return;
  if (card == null) {
    showSnack(context, 'Nothing is remembered about "${bareName(word)}" yet. Build the memory from the book\'s page, or ask in Talk.');
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => NameCardSheet(card: card, line: line, onLook: onLook, onAsk: onAsk),
  );
}

class NameCardSheet extends StatelessWidget {
  const NameCardSheet({super.key, required this.card, required this.line, this.onLook, this.onAsk});

  final FoundCard card;
  final int? line;

  /// Looking at a line's chapter, and asking Talk: only in the reader.
  final void Function(MemoryPlace place)? onLook;
  final void Function(String question)? onAsk;

  @override
  Widget build(BuildContext context) {
    final head = card.items.first;
    final rest = card.items.skip(1).toList();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(card.name, subtitle: line == null ? 'All it remembers' : 'As of chapter ${line! + 1}'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: Gap.l),
              children: [
                Text(head.text,
                    style: Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkOn(context)).copyWith(height: 1.4)),
                const SizedBox(height: Gap.s),
                for (final i in rest)
                  InkWell(
                    onTap: i.place == null || onLook == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            onLook!(i.place!);
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(i.text,
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                              .copyWith(height: 1.35)),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: onAsk == null
                ? const SizedBox(height: Gap.m)
                : Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.m),
              child: FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).pop();
                  onAsk!('Tell me about ${card.name}: who or what they are, and what they have done so far.');
                },
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: const Text('Tell me more'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
