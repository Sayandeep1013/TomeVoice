import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai/memory/memory_db.dart' show MemoryDb;
import 'ai/memory/memory_service.dart' show MemoryService;
import 'book_card.dart';
import 'library_store.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// Things you can do to a book, shared by the library and the book's page.

/// The "New category" choice in the category picker.
const _newCategory = '+new';

/// Choose a category for a book, or make a new one. Null if dismissed.
Future<String?> pickCategory(
  BuildContext context,
  LibraryStore store, {
  required String title,
  String? current,
}) async {
  final idx = await store.index();
  if (!context.mounted) return null;
  final picked = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in idx.categories)
                  SheetAction(
                    icon: c.id == current
                        ? Icons.radio_button_checked_rounded
                        : c.secret
                            ? Icons.lock_open_rounded
                            : Icons.folder_outlined,
                    label: c.name,
                    detail: _books(idx.inCategory(c.id).length),
                    onTap: () => Navigator.pop(ctx, c.id),
                  ),
                SheetAction(
                  icon: Icons.create_new_folder_outlined,
                  label: 'New category…',
                  onTap: () => Navigator.pop(ctx, _newCategory),
                ),
                const SizedBox(height: Gap.s),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (picked != _newCategory) return picked;
  final name = await askText(context, title: 'New category', hint: 'For example: Favourites', action: 'Create');
  if (name == null) return null;
  final cat = await store.addCategory(name);
  return cat.id;
}

String _books(int n) => '$n ${n == 1 ? 'book' : 'books'}';

/// Move [entry] to a category the user picks. True if it moved.
Future<bool> moveBook(BuildContext context, LibraryStore store, LibraryEntry entry) async {
  final idx = await store.index();
  final current = entry.categoryIn(idx.categories, idx.defaultCategory);
  if (!context.mounted) return false;
  final target = await pickCategory(context, store, title: 'Move to', current: current);
  if (target == null || target == current) return false;
  await store.moveBooks({entry.id}, target);
  final name = (await store.index()).categories.where((c) => c.id == target).firstOrNull?.name;
  if (context.mounted && name != null) showSnack(context, 'Moved to $name.');
  return true;
}

/// Ask, then remove [entry]. True if it was removed.
Future<bool> removeBook(BuildContext context, LibraryStore store, LibraryEntry entry) async {
  // A secret book takes what was saved from it, and its journal, along
  // (LibraryStore.remove); its folder goes in every case, with the
  // downloaded chapters in it. Its book memory is kept aside unless the
  // reader ticks the box (or the book is secret).
  final secret = store.isSecret(entry.id);
  final memory = MemoryDb.existsIn(store.bookDir(entry.id));
  // A secret book's memory goes with it, as all of it does; anyone else's
  // is kept unless the reader ticks the box (it can cost a long build).
  final keepable = memory && !secret;
  var chapters = 0;
  if (keepable) {
    final service = MemoryService.instance;
    if (service.library != null) {
      await service.refresh(entry.id);
      chapters = service.stateOf(entry.id).value.noted;
    }
    if (!context.mounted) return false;
  }
  final gone = [
    'its reading place',
    if (entry.isWeb) 'its downloaded chapters',
    if (memory && secret) 'its book memory (the AI\'s notes and cast)',
    if (secret) 'its journal and everything saved from it',
  ];
  final stays = secret ? '' : ' Your journal and the quotes you saved from it stay.';
  final source = entry.isWeb ? ' You can add it again from the site.' : ' The original file on your phone is not touched.';
  final body = '"${entry.title}" is deleted from TomeVoice, with ${_listed(gone)}.$stays$source';
  final choice = await showDialog<bool>(
    context: context,
    animationStyle: sheetMotion(context),
    builder: (ctx) => _RemoveDialog(body: body, keepable: keepable, chapters: chapters),
  );
  if (choice == null) return false;
  final keepMemory = keepable && !choice;
  if (keepMemory) await MemoryService.instance.letGo(entry.id);
  await store.remove(entry.id, keepMemory: keepMemory, memoryChapters: chapters);
  return true;
}

/// Remove this book? With a memory, the box to delete it too (left
/// unticked, it is kept). Pops null (Cancel), or whether the memory goes.
class _RemoveDialog extends StatefulWidget {
  const _RemoveDialog({required this.body, required this.keepable, required this.chapters});

  final String body;
  final bool keepable;
  final int chapters;

  @override
  State<_RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends State<_RemoveDialog> {
  bool _alsoMemory = false;

  @override
  Widget build(BuildContext context) {
    final built = widget.chapters > 0
        ? "The AI's notes and cast, built from ${widget.chapters} ${widget.chapters == 1 ? 'chapter' : 'chapters'}."
        : "The AI's notes and cast of this book.";
    return AlertDialog(
      title: const Text('Remove this book?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.body),
            if (widget.keepable) ...[
              const SizedBox(height: Gap.m),
              Text(
                _alsoMemory
                    ? 'Its book memory is deleted too.'
                    : 'Its book memory is kept: add the same book again and it is back, without building it again.',
                style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
              ),
              const SizedBox(height: Gap.s),
              CheckboxListTile(
                key: const Key('also-memory'),
                value: _alsoMemory,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: Skin.accentMarkOf(context),
                title: Text('Also delete its book memory',
                    style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context))),
                subtitle: Text(built,
                    style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                onChanged: (v) => setState(() => _alsoMemory = v ?? false),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, _alsoMemory), child: const Text('Remove')),
      ],
    );
  }
}

/// "a, b and c".
String _listed(List<String> items) =>
    items.length == 1 ? items.first : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// Pick how a book's cover looks. Each choice shows itself on this book.
Future<void> changeCover(BuildContext context, LibraryStore store, LibraryEntry e) async {
  final choice = await showModalBottomSheet<(CoverMode, bool)>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      Widget option(CoverMode mode, String label, String detail) {
        final selected = e.coverMode == mode;
        return Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.row),
            // A style tile only picks a style; it asks for a photo just
            // when "Your picture" has none yet.
            onTap: () => Navigator.pop(
              ctx,
              (mode, mode == CoverMode.custom && e.customCover == null),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s, horizontal: Gap.xs),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.chip + 2),
                      border: Border.all(
                        color: selected ? Skin.accentOf(context) : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: mode == CoverMode.custom && e.customCover == null
                        ? Container(
                            width: 70,
                            height: 105,
                            decoration: BoxDecoration(
                              color: Skin.raisedOn(ctx),
                              borderRadius: BorderRadius.circular(Radii.chip),
                            ),
                            child: Icon(Icons.add_photo_alternate_outlined,
                                color: Skin.inkSoftOn(ctx), size: 28),
                          )
                        : BookCover(entry: e.withCover(mode, e.customCover), width: 70),
                  ),
                  const SizedBox(height: Gap.s),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: Skin.ui(
                          size: 14,
                          weight: FontWeight.w700,
                          color: selected ? Skin.accentInkOf(context) : Skin.inkOn(ctx))),
                  const SizedBox(height: 2),
                  Text(detail.toUpperCase(), textAlign: TextAlign.center, style: Skin.meta(ctx, size: 9.5)),
                ],
              ),
            ),
          ),
        );
      }

      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('Cover'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  option(CoverMode.auto, 'Automatic', e.cover == null ? 'Made from the title' : "The book's own"),
                  option(CoverMode.custom, 'Your picture', e.customCover == null ? 'Choose one' : 'From your phone'),
                  option(CoverMode.plain, 'Plain', 'Title on colour'),
                ],
              ),
              if (e.customCover != null) ...[
                const SizedBox(height: Gap.m),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(ctx, (CoverMode.custom, true)),
                  icon: Icon(Icons.add_photo_alternate_outlined, size: 18, color: Skin.accentInkOf(context)),
                  label: const Text('Choose a different picture'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  final (mode, pick) = choice;
  PickedFile? picture;
  if (pick) {
    try {
      picture = await const SpeechService().pickImage();
    } on PlatformException catch (err) {
      if (context.mounted) showSnack(context, err.message ?? err.code);
      return;
    }
    // Cancelled the picker: leave the cover as it was.
    if (picture == null) return;
  }
  await store.setCover(e.id, mode, picture: picture);
}
