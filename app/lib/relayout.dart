import 'dart:async';

import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'listening_session.dart';

/// How books are laid out changed (Read notes aloud): the book being read
/// aloud goes on at the sentence it was at, in a layout built the new way.
/// Settings are only reached from the library, so the open book is the one
/// reading on in the background. One paused is left as it is: when it is
/// opened again its layout is built anew, and the reader, finding another
/// layout than the paused one's, starts it at the same sentence.
Future<void> relayReadingBook() async {
  final bg = BackgroundReading.current.value;
  if (bg == null || !bg.playing) return;
  final store = bg.store;
  final entry = (await store.list(all: true)).where((e) => e.id == bg.bookId).firstOrNull;
  if (entry == null || !identical(BackgroundReading.current.value, bg)) return;
  final saved = store.placeChanges.value;
  await bg.stop();
  // stop() saves the place without waiting for the write; the new layout
  // opens at what it saved.
  for (var i = 0; i < 40 && store.placeChanges.value == saved; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  await BackgroundReading.startFrom(store, entry);
}

/// TXT book [id] cut into chapters by [rule] (its page's Chapters; see
/// LibraryStore.setTextChapters). The voice reading it in the background
/// stops first, its place written, so that the place carried across is the
/// one it had reached; one that was reading reads on at the same sentence.
Future<ReadingLayout> splitTextBook(LibraryStore store, String id, TextChapters rule) async {
  final bg = BackgroundReading.current.value;
  final mine = bg != null && bg.bookId == id;
  final playing = mine && bg.playing;
  if (mine) {
    await bg.stop();
    await bg.saved;
  }
  final layout = await store.setTextChapters(id, rule);
  if (playing && BackgroundReading.current.value == null) {
    final entry = (await store.list(all: true)).where((e) => e.id == id).firstOrNull;
    if (entry != null) await BackgroundReading.startFrom(store, entry);
  }
  return layout;
}
