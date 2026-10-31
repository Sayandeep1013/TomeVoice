import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:tomevoice_document/tomevoice_document.dart'
    show BookMetadata, LegacyEncodingException, bookIdOf, countWords;

import 'article.dart';
import 'library_store.dart';
import 'speech_service.dart' show PickedFile;

// Reading anything: a link or words shared to TomeVoice (Chrome's Share,
// chosen text) or pasted from the clipboard. A link to a web page becomes
// an article on the Articles shelf; a link to a book file imports that
// book; any other words become a book named from their first line. Each
// comes once: shared again, it opens the book it already is.

/// What a share came to.
sealed class SharedOutcome {
  const SharedOutcome();
}

/// A book in the library: made now, or [existing] (it came before).
class SharedBook extends SharedOutcome {
  const SharedBook(this.entry, {this.existing = false});

  final LibraryEntry entry;
  final bool existing;
}

/// The book file a link led to, downloaded for the usual import (a PDF's
/// text is read by the platform, with its progress).
class SharedFile extends SharedOutcome {
  const SharedFile(this.file);

  final PickedFile file;
}

/// A share the platform kept for the app (see MainActivity.takeSharedText).
typedef PendingShare = ({String id, String text, String? subject});

const _channel = MethodChannel('tomevoice/tts');

/// The share that started the app, if one is waiting: taken once.
Future<PendingShare?> takePendingShare() async {
  try {
    final raw = await _channel.invokeMapMethod<String, Object?>('pendingShare');
    return raw == null ? null : shareOf(raw);
  } on Object {
    return null;
  }
}

/// A sharedText event, or a pending share, as a share; null when it has
/// no words.
PendingShare? shareOf(Map<Object?, Object?> raw) {
  final text = raw['text']?.toString() ?? '';
  if (text.trim().isEmpty) return null;
  final subject = raw['subject']?.toString().trim() ?? '';
  return (id: raw['id']?.toString() ?? '', text: text, subject: subject.isEmpty ? null : subject);
}

/// One share at a time: two at once could each make an Articles shelf.
Future<void> _queue = Future<void>.value();

/// Forget a share still holding the queue (between widget tests).
@visibleForTesting
void resetShareQueue() => _queue = Future<void>.value();

/// Read [text], shared or pasted: a link as an article (or the book file it
/// leads to), anything else as a book. [subject] is what the sharing app
/// called it, used when a page has no title of its own. [legacy] decodes a
/// page in an East Asian legacy encoding (the platform's, by default).
///
/// Throws [ArticleProblem] in words for the reader, and what an import
/// throws (a ParseException, say).
Future<SharedOutcome> readShared(LibraryStore store, String text, {String? subject, CharsetDecoder? legacy}) {
  final run = _queue.then((_) => _read(store, text, subject: subject, legacy: legacy ?? _platformCharset));
  _queue = run.then<void>((_) {}, onError: (Object _) {});
  return run;
}

Future<SharedOutcome> _read(LibraryStore store, String raw, {String? subject, required CharsetDecoder legacy}) async {
  final text = tidyShared(raw);
  if (text.isEmpty) throw const ArticleProblem('There is nothing to read in that.');
  final link = sharedLink(text);
  return link == null ? _readText(store, text) : _readLink(store, link, subject: subject, legacy: legacy);
}

/// Words as a book named from their first line, on the shelf new books go
/// to. The same words again are the same book (its id is their hash, as a
/// file's is).
Future<SharedOutcome> _readText(LibraryStore store, String text) async {
  final bytes = Uint8List.fromList(utf8.encode(text));
  final id = bookIdOf(bytes);
  final known = await _known(store, id);
  if (known != null) return SharedBook(known, existing: true);
  return SharedBook(await store.importMade(id: id, name: '${titleOfText(text)}.txt', bytes: bytes));
}

/// A page as an article on the Articles shelf, or the book file a link
/// leads to. An article's id is its address, so the same link again opens
/// it at once, without the network.
Future<SharedOutcome> _readLink(
  LibraryStore store,
  Uri link, {
  String? subject,
  required CharsetDecoder legacy,
}) async {
  final known = await _known(store, articleIdOf(link));
  if (known != null) return SharedBook(known, existing: true);
  final got = await fetchLink(link, incoming: Directory('${store.root.path}/incoming'), legacy: legacy);
  if (got case FetchedFile(:final path, :final name, :final mime)) {
    return SharedFile(PickedFile(path: path, name: name, mime: mime));
  }
  final page = got as FetchedPage;
  // A short link, or one that redirects, may lead to an article already
  // read from its own address.
  final id = articleIdOf(page.url);
  final again = await _known(store, id);
  if (again != null) return SharedBook(again, existing: true);
  final url = cleanUrl(page.url);
  final article = await _extract(page.html, url, subject);
  final title = bookTitle(article.title);
  final entry = await store.importMade(
    id: id,
    name: '$title.html',
    bytes: Uint8List.fromList(utf8.encode(article.html)),
    category: await articleShelf(store),
    details: BookMetadata(
      title: title,
      authors: [if (article.byline != null) article.byline!],
      publisher: article.site,
      identifier: url.toString(),
      description: article.description,
    ),
  );
  return SharedBook(entry);
}

// Top-level, so the closure sent to the isolate holds only these three.
Future<Article> _extract(String html, Uri url, String? subject) =>
    Isolate.run(() => extractArticle(html, url: url, fallbackTitle: subject));

Future<LibraryEntry?> _known(LibraryStore store, String id) async =>
    (await store.index(all: true)).entries.where((e) => e.id == id).firstOrNull;

/// The Articles shelf, made the first time an article comes. One of that
/// name that was made secret is passed over: an article never goes to a
/// secret shelf.
Future<String> articleShelf(LibraryStore store) async {
  final idx = await store.index(all: true);
  for (final c in idx.categories) {
    if (!c.secret && c.name.trim().toLowerCase() == 'articles') return c.id;
  }
  return (await store.addCategory('Articles')).id;
}

Future<String> _platformCharset(Uint8List bytes, String charset) async {
  final text = await _channel.invokeMethod<String>('decodeCharset', {'bytes': bytes, 'charset': charset});
  if (text == null) throw LegacyEncodingException(charset);
  return text;
}

// ------------------------------------------------------------------- words

/// [raw] as shared: line ends made one kind, a byte order mark and the
/// space around it gone.
String tidyShared(String raw) =>
    raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(String.fromCharCode(0xFEFF), '').trim();

final _linkPattern = RegExp(
  r'''https?://[^\s<>"'`{}|\\^\[\]]+|(?<![\w@/.])www\.[^\s<>"'`{}|\\^\[\]]+''',
  caseSensitive: false,
);

/// The http(s) link [text] is, or holds with little else (a title, a
/// quote, "Have a look"). Null for none, for two or more, and for a
/// passage that only mentions one: that is read as words.
Uri? sharedLink(String text) {
  final found = <String, Uri>{};
  var rest = text;
  for (final m in _linkPattern.allMatches(text)) {
    final raw = _trimLink(m[0]!);
    final uri = Uri.tryParse(raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw);
    if (uri == null || uri.host.isEmpty) continue;
    found.putIfAbsent(normalUrl(uri), () => uri);
    rest = rest.replaceFirst(m[0]!, ' ');
  }
  if (found.length != 1 || countWords(rest) > 60) return null;
  return found.values.single;
}

/// Characters that end a sentence around a link, not the link: . , ; : ! ?
/// quotes, and » ” ’ >.
const _afterLink = {0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x27, 0x22, 0xBB, 0x201D, 0x2019, 0x3E};

String _trimLink(String s) {
  var t = s;
  while (t.isNotEmpty) {
    final last = t.codeUnitAt(t.length - 1);
    // A closing bracket is the link's own when it opened one too
    // (Wikipedia's "Python_(programming_language)").
    final unbalanced = (last == 0x29 && '('.allMatches(t).length < ')'.allMatches(t).length) ||
        (last == 0x7D && '{'.allMatches(t).length < '}'.allMatches(t).length);
    if (!_afterLink.contains(last) && !unbalanced) break;
    t = t.substring(0, t.length - 1);
  }
  return t;
}

/// Tracking tags a share adds to an address; the page is the same without.
const _tracking = {
  'fbclid', 'gclid', 'dclid', 'gbraid', 'wbraid', 'msclkid', 'igshid', 'mc_cid', 'mc_eid', 'smid', 'ref_src',
  'cmpid', 'ocid', '_ga', 'yclid', 'twclid', 'mkt_tok', '_hsenc', '_hsmi',
};

/// [url] as one page however it was written: http or https, with www. or
/// m. or neither, a trailing slash or not, tracking tags or not.
String normalUrl(Uri url) {
  var host = url.host.toLowerCase();
  for (final p in const ['www.', 'm.']) {
    if (host.startsWith(p)) host = host.substring(p.length);
  }
  var path = url.path.isEmpty ? '/' : url.path;
  if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
  final query = [
    for (final part in url.query.split('&'))
      if (part.isNotEmpty && !_isTracking(part.split('=').first)) part,
  ].join('&');
  final port = url.hasPort && url.port != 80 && url.port != 443 ? ':${url.port}' : '';
  return '$host$port$path${query.isEmpty ? '' : '?$query'}';
}

bool _isTracking(String key) {
  final k = key.toLowerCase();
  return k.startsWith('utm_') || _tracking.contains(k);
}

/// [url] without its tracking tags and its #fragment: the address kept
/// with the article.
Uri cleanUrl(Uri url) {
  final query = [
    for (final part in url.query.split('&'))
      if (part.isNotEmpty && !_isTracking(part.split('=').first)) part,
  ].join('&');
  return Uri(
    scheme: url.scheme,
    userInfo: url.userInfo.isEmpty ? null : url.userInfo,
    host: url.host,
    port: url.hasPort ? url.port : null,
    path: url.path,
    query: query.isEmpty ? null : query,
  );
}

/// An article's book id: the same for the same page however its address
/// was written (see [normalUrl]).
String articleIdOf(Uri url) => bookIdOf(Uint8List.fromList(utf8.encode('article ${normalUrl(url)}')));

/// A book named from [text]'s first line: the line itself, or the start of
/// a long one.
String titleOfText(String text) {
  for (final line in text.split('\n')) {
    var t = line.replaceAll(RegExp(r'\s+'), ' ').trim().replaceFirst(RegExp(r'^#{1,6}\s+'), '');
    if (t.isEmpty) continue;
    if (t.length > 80) {
      final cut = t.substring(0, 60);
      final space = cut.lastIndexOf(' ');
      t = '${(space > 30 ? cut.substring(0, space) : cut).trimRight()}${String.fromCharCode(0x2026)}';
    }
    return bookTitle(t);
  }
  return 'Shared text';
}

/// [title] as it comes back from the book's file name, which is where a
/// book parsed again takes it from (titleFromFilename): no slashes (one
/// that looks the same instead), no underscores (they read as spaces), no
/// control characters.
String bookTitle(String title) {
  final t = title
      .replaceAll(RegExp(r'[\\/]'), String.fromCharCode(0x2215))
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return t.isEmpty ? 'Untitled' : t;
}

/// What the import card calls a share: the site a link is on, or the
/// words' first line.
String shareName(String text) {
  final t = tidyShared(text);
  final link = sharedLink(t);
  if (link == null) return titleOfText(t);
  return link.host.startsWith('www.') ? link.host.substring(4) : link.host;
}
