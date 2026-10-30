import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'marks.dart';
import 'theme.dart';
import 'ui.dart';

// The reader's sheets: what can be done with a sentence held, and the
// book's bookmarks. What each choice does is the reader's.

/// Press and hold on a sentence: what can be done with it. The choice made
/// ('read', 'quote', 'share', 'bookmark', 'copy', 'lookup', 'translate',
/// 'say' or 'skip'), or null; Save as audio is [onSaveAsAudio]'s, once the
/// sheet has gone. [word] is the word under the finger ('' for none);
/// [web], a web novel's sentence (a line like it can be left out, and its
/// chapter is saved as audio, not the whole book).
Future<String?> showSentenceActions(
  BuildContext context, {
  required String sentence,
  required String word,
  required bool web,
  required VoidCallback onSaveAsAudio,
}) =>
    showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => carryTint(
        context,
        SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
                  child: Text(
                    sentence,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Newsreader',
                      fontStyle: FontStyle.italic,
                      fontSize: 16,
                      height: 1.4,
                      color: Skin.inkSoftOn(ctx),
                    ),
                  ),
                ),
                SheetAction(icon: Icons.play_arrow_rounded, label: 'Read from here', onTap: () => Navigator.pop(ctx, 'read')),
                SheetAction(icon: Icons.format_quote_rounded, label: 'Save as a quote', onTap: () => Navigator.pop(ctx, 'quote')),
                SheetAction(
                  icon: Icons.ios_share_rounded,
                  label: 'Share as a picture',
                  onTap: () => Navigator.pop(ctx, 'share'),
                ),
                SheetAction(icon: Icons.bookmark_add_outlined, label: 'Bookmark here', onTap: () => Navigator.pop(ctx, 'bookmark')),
                SheetAction(icon: Icons.copy_rounded, label: 'Copy', onTap: () => Navigator.pop(ctx, 'copy')),
                SheetAction(
                  icon: Icons.save_alt_rounded,
                  label: 'Save as audio…',
                  detail: web ? 'This chapter, as you hear it' : 'This chapter or the whole book, as you hear it',
                  onTap: () {
                    Navigator.pop(ctx);
                    onSaveAsAudio();
                  },
                ),
                if (word.isNotEmpty)
                  SheetAction(
                    icon: Icons.menu_book_outlined,
                    label: 'Look up "$word"',
                    onTap: () => Navigator.pop(ctx, 'lookup'),
                  ),
                SheetAction(
                  icon: Icons.translate_rounded,
                  label: 'Translate',
                  detail: 'This sentence, in your translate app',
                  onTap: () => Navigator.pop(ctx, 'translate'),
                ),
                if (word.isNotEmpty)
                  SheetAction(
                    icon: Icons.record_voice_over_outlined,
                    label: 'Fix how "$word" is said',
                    onTap: () => Navigator.pop(ctx, 'say'),
                  ),
                if (web)
                  SheetAction(
                    icon: Icons.visibility_off_outlined,
                    label: "Don't read lines like this",
                    detail: 'Site notices, credits, links: left out from now on',
                    onTap: () => Navigator.pop(ctx, 'skip'),
                  ),
                const SizedBox(height: Gap.s),
              ],
            ),
          ),
        ),
      ),
    );

/// Every bookmark in a book, in the order of the book: a tap goes there
/// ([onOpen], once the sheet has gone), the bin takes one off ([onRemove]).
/// [marks] are read again as bookmarks are added or taken off.
Future<void> showBookmarks(
  BuildContext context, {
  required ReadingLayout layout,
  required List<Mark> Function() marks,
  required ValueChanged<int> onOpen,
  required ValueChanged<Mark> onRemove,
}) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(context),
      builder: (ctx) => carryTint(
        context,
        ValueListenableBuilder<int>(
          valueListenable: MarkStore.instance.changes,
          builder: (ctx, _, __) {
            final kept = [
              for (final m in marks()) (m: m, u: unitOfMark(layout, m)),
            ]..sort((a, b) => a.u.compareTo(b.u));
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetHeader('Bookmarks', subtitle: kept.isEmpty ? null : '${kept.length} in this book'),
                  if (kept.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xxl),
                      child: Text(
                        'None yet. Tap the bookmark at the top of the page to keep a place you want to come back to. '
                        'Where you stopped reading is kept on its own.',
                        style: Skin.label(ctx, size: 14),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: Gap.xl),
                        children: [
                          for (final x in kept)
                            ListTile(
                              key: ValueKey(x.m.id),
                              leading: Icon(Icons.bookmark_rounded, color: Skin.accentOf(ctx)),
                              title: Text(
                                (x.m.chapter ?? layout.chapterTitle(layout.chapterOfUnit(x.u))).toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.meta(ctx, size: 10.5),
                              ),
                              subtitle: Text(
                                x.m.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.page(ctx, size: 15, height: 1.35).copyWith(color: Skin.inkOn(ctx)),
                              ),
                              trailing: IconButton(
                                tooltip: 'Remove bookmark',
                                icon: Icon(Icons.delete_outline_rounded, color: Skin.inkSoftOn(ctx)),
                                onPressed: () => onRemove(x.m),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                onOpen(x.u);
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
