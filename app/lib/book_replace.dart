import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, ReadingLayout;

import 'library_store.dart';
import 'marks.dart';
import 'novel_move.dart' show movePrefs;
import 'prefs.dart';
import 'reading_rules.dart';
import 'speech_service.dart';
import 'ui.dart';

/// Where sentence [u] of [from] (a book's sentences in reading order) is in
/// [to], another edition of it: the same words, the copy nearest to where
/// it would be going by how far through the book it was. A sentence that
/// was changed is found by its neighbours (the nearest unchanged one before
/// or after it, a step away); one found by neither is taken as far through
/// [to] as it was through [from].
int followSentence(List<String> from, List<String> to, int u) {
  if (to.isEmpty) return 0;
  if (from.isEmpty) return 0;
  u = u.clamp(0, from.length - 1);
  final scale = to.length / from.length;
  final at = <String, List<int>>{};
  for (var i = 0; i < to.length; i++) {
    at.putIfAbsent(_plain(to[i]), () => []).add(i);
  }
  int? nearest(int i, int around) {
    final places = at[_plain(from[i])];
    if (places == null || _plain(from[i]).isEmpty) return null;
    var best = places.first;
    for (final p in places) {
      if ((p - around).abs() < (best - around).abs()) best = p;
    }
    return best;
  }

  final guess = (u * scale).round().clamp(0, to.length - 1);
  final same = nearest(u, guess);
  if (same != null) return same;
  for (var d = 1; d <= 25; d++) {
    if (u - d >= 0) {
      final before = nearest(u - d, guess - d);
      if (before != null) return (before + d).clamp(0, to.length - 1);
    }
    if (u + d < from.length) {
      final after = nearest(u + d, guess + d);
      if (after != null) return (after - d).clamp(0, to.length - 1);
    }
  }
  return guess;
}

String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// The place [c] in [from] as a place in [to] (see [followSentence]).
ReadingCursor followPlace(ReadingLayout from, ReadingLayout to, ReadingCursor c) {
  if (to.units.isEmpty) return ReadingCursor.zero;
  if (from.units.isEmpty) return c;
  final u = unitAtCursor(from.units, c);
  final n = followSentence([for (final x in from.units) x.text], [for (final x in to.units) x.text], u);
  final t = to.units[n];
  return ReadingCursor(sectionIndex: t.sectionIndex, blockIndex: t.blockIndex, sentenceIndex: t.sentenceIndex);
}

/// Book [old]'s file swapped for another (a corrected EPUB, a better scan):
/// the new file is read in, and becomes the book, with its place, quotes,
/// bookmarks, voices and rules found again in it by their sentences. The
/// new book, or null when nothing changed (the picker closed, or the same
/// file picked).
Future<LibraryEntry?> replaceBookFile(LibraryStore store, LibraryEntry old, PickedFile file,
    {void Function(String note)? onNote}) async {
  // As the library has it now: the page's copy may be older than the place.
  old = (await store.list(all: true)).where((e) => e.id == old.id).firstOrNull ?? old;
  final before = await store.loadLayout(old.id);
  final place = await store.cursorFor(old.id);
  final fresh = await store.importFile(file, onNote: onNote);
  // The very same file: imported again, it kept its place itself.
  if (fresh.id == old.id) return null;
  final after = await store.loadLayout(fresh.id);
  ReadingCursor follow(ReadingCursor c) => followPlace(before, after, c);
  await MarkStore.instance.rebook(old.id, fresh.id, follow);
  final prefs = ListeningPrefs.loaded;
  if (prefs != null && movePrefs(prefs, old.id, fresh.id)) prefs.save();
  await ReadingRules.instance.moveBook(old.id, fresh.id);
  return store.replaceBook(old, fresh, follow(place));
}

/// The book page's "Replace the file…": what it does, said first; then the
/// file, read in; then the new book. Null when nothing was replaced.
Future<LibraryEntry?> askReplaceBookFile(BuildContext context, LibraryStore store, LibraryEntry old) async {
  final ok = await confirm(
    context,
    title: 'Replace the file?',
    body: 'Pick another file of this book, a corrected edition say. It takes this one\'s place: your place, '
        'quotes, bookmarks, voices and shelf go with it, found again by their sentences. The file it replaces '
        'is removed from TomeVoice.',
    action: 'Pick a file',
  );
  if (!ok || !context.mounted) return null;
  final picked = await const SpeechService().pickDocuments();
  if (picked.isEmpty || !context.mounted) return null;
  try {
    final fresh = await replaceBookFile(store, old, picked.first,
        onNote: (n) => context.mounted ? showSnack(context, n) : null);
    if (!context.mounted) return fresh;
    showSnack(context, fresh == null ? 'That is the same file: nothing changed.' : 'Replaced. Your place and notes came with it.');
    return fresh;
  } on Object catch (e) {
    if (context.mounted) showSnack(context, 'That file could not be read: ${'$e'.split('\n').first}');
    return null;
  }
}
