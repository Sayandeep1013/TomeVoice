import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:tomevoice_document/tomevoice_document.dart'
    show EncryptedDocumentException, ParseException, UnsupportedDocumentException;

import 'library_store.dart';
import 'opds.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'secrets.dart';
import 'sources/net.dart' show friendlyError;
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// An OPDS catalogue the reader can browse: one of the built-in ones, or
/// one they added (their Calibre library, a library's own).
class Catalogue {
  const Catalogue({
    required this.id,
    required this.title,
    required this.url,
    this.subtitle,
    this.user,
    this.preset = false,
    this.emailOnly = false,
  });

  final String id;
  final String title;
  final String url;
  final String? subtitle;

  /// The user name it signs in with, if it asks for one.
  final String? user;

  /// Built in: not edited or removed, only signed in to.
  final bool preset;

  /// Signs in with an email address and no password (Standard Ebooks).
  final bool emailOnly;

  Catalogue withUser(String? user) => Catalogue(
        id: id,
        title: title,
        url: url,
        subtitle: subtitle,
        user: user == null || user.trim().isEmpty ? null : user.trim(),
        preset: preset,
        emailOnly: emailOnly,
      );

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'url': url, if (user != null) 'user': user};

  static Catalogue? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['url'] is! String) return null;
    return Catalogue(
      id: j['id'] as String,
      title: j['title'] as String? ?? 'Catalogue',
      url: j['url'] as String,
      user: j['user'] as String?,
    );
  }

  /// Free to everyone.
  static const gutenberg = Catalogue(
    id: 'gutenberg',
    title: 'Project Gutenberg',
    url: 'https://www.gutenberg.org/ebooks.opds/',
    subtitle: 'Over 70,000 free ebooks, most of them classics',
    preset: true,
  );

  /// Standard Ebooks' newest books, as a feed open to everyone.
  static const standardNew = Catalogue(
    id: 'standard-ebooks-new',
    title: 'Standard Ebooks: new releases',
    url: 'https://standardebooks.org/feeds/atom/new-releases',
    subtitle: 'Free classics, carefully made, the newest first',
    preset: true,
  );

  /// Standard Ebooks' whole catalogue: for members of its Patrons Circle,
  /// who sign in with their email address and no password.
  static const standardAll = Catalogue(
    id: 'standard-ebooks',
    title: 'Standard Ebooks: the whole catalogue',
    url: 'https://standardebooks.org/feeds/opds',
    subtitle: 'For Patrons Circle members: sign in with your email address',
    preset: true,
    emailOnly: true,
  );

  static const presets = [gutenberg, standardNew, standardAll];
}

/// The catalogues the reader added, and the user names they sign in to the
/// built-in ones with: kept with the settings (prefs.json), so a backup
/// carries them and a restore, or Add with the backup's settings, brings
/// them back. Their passwords are kept apart (see [Secrets]).
class CatalogueStore {
  CatalogueStore(this.root);

  final Directory root;

  static ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  /// The built-in catalogues, then the reader's own.
  Future<List<Catalogue>> all() async => [
        for (final p in Catalogue.presets) p.withUser(_prefs.catalogueUsers[p.id]),
        for (final c in _prefs.catalogues)
          if (Catalogue.fromJson(c) case final x?) x,
      ];

  /// Keep [c] (added, changed, or a built-in one signed in to) and its
  /// [password] (null leaves the one kept; empty forgets it).
  Future<void> save(Catalogue c, {String? password}) async {
    final p = _prefs;
    if (c.preset) {
      final user = c.user;
      if (user == null) {
        p.catalogueUsers.remove(c.id);
      } else {
        p.catalogueUsers[c.id] = user;
      }
    } else {
      final at = p.catalogues.indexWhere((o) => o['id'] == c.id);
      if (at < 0) {
        p.catalogues.add(c.toJson());
      } else {
        p.catalogues[at] = c.toJson();
      }
    }
    p.save();
    if (password != null) await (await Secrets.of(root)).set('catalogue:${c.id}', password);
  }

  Future<void> remove(Catalogue c) async {
    _prefs
      ..catalogues.removeWhere((o) => o['id'] == c.id)
      ..save();
    await (await Secrets.of(root)).set('catalogue:${c.id}', null);
  }

  Future<String?> password(Catalogue c) async => (await Secrets.of(root))['catalogue:${c.id}'];

  /// A client for [c], signed in as it is set up.
  Future<OpdsClient> client(Catalogue c) async =>
      OpdsClient(Uri.parse(c.url), user: c.user, password: c.emailOnly ? '' : await password(c));
}

/// The shelves a book from a catalogue may go to: never a secret one,
/// whether the secret shelves are open or shut.
Future<List<Category>> destinationShelves(LibraryStore store) async =>
    [for (final c in (await store.index()).categories) if (!c.secret) c];

/// Download [link] of [entry] and add it to the library through the normal
/// import, onto [shelf] when it is one of [destinationShelves]. [onProgress]
/// hears the bytes so far and the whole (-1 when not known); [onImporting],
/// that the file is in and is being read.
Future<LibraryEntry> addFromCatalogue(
  LibraryStore store,
  OpdsClient client,
  OpdsEntry entry,
  OpdsLink link, {
  String? shelf,
  void Function(int done, int total)? onProgress,
  VoidCallback? onImporting,
  void Function(String note)? onNote,
}) async {
  // In a folder of its own under incoming/, as a picked file is: the import
  // removes it once the book is in, and a crash leaves it to be swept.
  final dir = Directory('${store.root.path}/incoming/opds-${DateTime.now().microsecondsSinceEpoch}');
  try {
    final part = File('${dir.path}/download.part');
    final got = await client.download(link.href, part, onProgress: onProgress);
    onImporting?.call();
    final name = downloadName(entry, link, serverName: got.name);
    final file = await part.rename('${dir.path}/$name');
    final mime = link.type.split(';').first.trim();
    var added = await store.importFile(PickedFile(path: file.path, name: name, mime: mime), onNote: onNote);
    final shelves = await destinationShelves(store);
    if (shelf != null && shelves.any((c) => c.id == shelf)) {
      await store.moveBooks({added.id}, shelf);
      added = (await store.list(all: true)).firstWhere((e) => e.id == added.id, orElse: () => added);
    }
    return added;
  } finally {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Swept at a later start (LibraryStore.sweepIncoming).
    }
  }
}

String _reason(Object e) => switch (e) {
      OpdsAuthException() => 'This catalogue asks you to sign in.',
      OpdsFormatException(:final message) => message,
      EncryptedDocumentException(:final message) => message,
      UnsupportedDocumentException(:final message) => message,
      ParseException(:final message) => message,
      PlatformException(:final message, :final code) => message ?? code,
      _ => friendlyError(e),
    };

/// Covers fetched once per catalogue visit.
final _covers = <String, Future<Uint8List?>>{};

/// The catalogues: the free libraries, the ones that need an account, and
/// the reader's own. Each opens to browse, search and add books.
class CataloguesScreen extends StatefulWidget {
  const CataloguesScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<CataloguesScreen> createState() => _CataloguesScreenState();
}

class _CataloguesScreenState extends State<CataloguesScreen> {
  late final _catalogues = CatalogueStore(widget.store.root);
  List<Catalogue>? _all;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final all = await _catalogues.all();
    if (mounted) setState(() => _all = all);
  }

  Future<void> _open(Catalogue c) async {
    var cat = c;
    if (c.emailOnly && c.user == null) {
      final email = await askText(
        context,
        title: 'Your Patrons Circle email',
        hint: 'name@example.com',
        action: 'Sign in',
      );
      if (email == null || !mounted) return;
      cat = c.withUser(email);
      await _catalogues.save(cat);
      await _load();
      if (!mounted) return;
    }
    final client = await _catalogues.client(cat);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FeedScreen(
        store: widget.store,
        client: client,
        url: Uri.parse(cat.url),
        title: cat.title,
        onSignIn: () => _edit(cat),
      ),
    ));
    client.close();
  }

  /// Add a catalogue ([calibre]: one on this network), or change [existing].
  Future<bool> _edit(Catalogue? existing, {bool calibre = false}) async {
    final saved = await showModalBottomSheet<(Catalogue, String?)>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => _CatalogueForm(
        existing: existing,
        calibre: calibre,
        password: existing == null ? null : _catalogues.password(existing),
      ),
    );
    if (saved == null) return false;
    await _catalogues.save(saved.$1, password: saved.$2);
    await _load();
    return true;
  }

  Future<void> _remove(Catalogue c) async {
    if (!await confirm(context, title: 'Remove ${c.title}?', body: 'Books added from it stay in your library.', action: 'Remove')) {
      return;
    }
    await _catalogues.remove(c);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final own = [for (final c in all ?? const <Catalogue>[]) if (!c.preset) c];
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Catalogues', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: all == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: EdgeInsets.fromLTRB(
                            Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                        children: [
                          Text(
                            'Libraries of ebooks that apps can browse (OPDS). Books you add go into your '
                            'library like any other.',
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
                          ),
                          const SizedBox(height: Gap.l),
                          for (final c in all.where((c) => c.preset))
                            _tile(
                              context,
                              c,
                              icon: c.emailOnly ? Icons.card_membership_rounded : Icons.public_rounded,
                              trailing: c.emailOnly && c.user != null
                                  ? IconButton(
                                      tooltip: 'Sign out',
                                      icon: Icon(Icons.logout_rounded, size: 20, color: Skin.inkFaintOn(context)),
                                      onPressed: () async {
                                        await _catalogues.save(c.withUser(null));
                                        await _load();
                                      },
                                    )
                                  : null,
                            ),
                          _row(
                            context,
                            icon: Icons.lan_outlined,
                            title: 'A Calibre library on this network',
                            subtitle: "Your own books, from Calibre's content server",
                            onTap: () => _edit(null, calibre: true),
                          ),
                          if (own.isNotEmpty) ...[
                            const SizedBox(height: Gap.l),
                            const Eyebrow('Yours'),
                            const SizedBox(height: Gap.s),
                            for (final c in own)
                              _tile(
                                context,
                                c,
                                icon: Icons.local_library_outlined,
                                trailing: PopupMenuButton<String>(
                                  tooltip: 'More',
                                  onSelected: (v) => v == 'edit' ? _edit(c) : _remove(c),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'edit', child: Text('Change')),
                                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                                  ],
                                ),
                              ),
                          ],
                          const SizedBox(height: Gap.l),
                          OutlinedButton.icon(
                            onPressed: () => _edit(null),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add a catalogue'),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Catalogue c, {required IconData icon, Widget? trailing}) => _row(
        context,
        icon: icon,
        title: c.title,
        subtitle: c.emailOnly && c.user != null ? 'Signed in as ${c.user}' : (c.subtitle ?? c.url),
        onTap: () => _open(c),
        trailing: trailing,
      );

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? trailing,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Material(
          color: Skin.capsuleOn(context),
          borderRadius: BorderRadius.circular(Radii.row),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.row),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
              child: Row(
                children: [
                  Icon(icon, color: Skin.accentOf(context)),
                  const SizedBox(width: Gap.l),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                        Text(subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                      ],
                    ),
                  ),
                  trailing ?? Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
                ],
              ),
            ),
          ),
        ),
      );
}

/// A catalogue's name, address, and how it signs in.
class _CatalogueForm extends StatefulWidget {
  const _CatalogueForm({this.existing, this.calibre = false, this.password});

  final Catalogue? existing;
  final bool calibre;
  final Future<String?>? password;

  @override
  State<_CatalogueForm> createState() => _CatalogueFormState();
}

class _CatalogueFormState extends State<_CatalogueForm> {
  late final _title = TextEditingController(
      text: widget.existing?.title ?? (widget.calibre ? 'My Calibre library' : ''));
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _user = TextEditingController(text: widget.existing?.user ?? '');
  final _password = TextEditingController();
  bool _passwordShown = false;
  String? _problem;

  bool get _email => widget.existing?.emailOnly ?? false;

  @override
  void initState() {
    super.initState();
    widget.password?.then((p) {
      if (mounted && p != null) _password.text = p;
    });
  }

  void _save() {
    final existing = widget.existing;
    if (existing != null && existing.preset) {
      Navigator.pop(context, (existing.withUser(_user.text), null));
      return;
    }
    var url = _url.text.trim();
    if (url.isEmpty) return setState(() => _problem = 'Give the catalogue’s address.');
    if (!url.contains('://')) url = 'http://$url';
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      return setState(() => _problem = 'That is not a web address.');
    }
    // Calibre's content server lists its books at /opds.
    if (widget.calibre && (uri.path.isEmpty || uri.path == '/')) url = uri.replace(path: '/opds').toString();
    final title = _title.text.trim().isEmpty ? uri.host : _title.text.trim();
    final c = Catalogue(
      id: existing?.id ?? 'c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      title: title,
      url: url,
      user: _user.text.trim().isEmpty ? null : _user.text.trim(),
    );
    Navigator.pop(context, (c, _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.existing?.preset ?? false;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                preset
                    ? 'Sign in'
                    : widget.existing != null
                        ? 'Change the catalogue'
                        : widget.calibre
                            ? 'A Calibre library'
                            : 'Add a catalogue',
                style: Skin.title(context, size: 22),
              ),
              const SizedBox(height: Gap.s),
              if (widget.calibre)
                Text(
                  'In Calibre, turn on Connect/share > Start Content server, then give the address it shows '
                  '(such as 192.168.1.20:8080), and a user name and password if you set one.',
                  style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
                ),
              if (!preset) ...[
                TextField(controller: _title, decoration: const InputDecoration(labelText: 'Name')),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Address',
                    hintText: widget.calibre ? '192.168.1.20:8080' : 'https://example.org/opds',
                    errorText: _problem,
                  ),
                ),
              ],
              TextField(
                controller: _user,
                autocorrect: false,
                keyboardType: _email ? TextInputType.emailAddress : TextInputType.text,
                decoration: InputDecoration(labelText: _email ? 'Email address' : 'User name (if it asks)'),
              ),
              if (!_email)
                TextField(
                  controller: _password,
                  obscureText: !_passwordShown,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Password (if it asks)',
                    suffixIcon: IconButton(
                      tooltip: _passwordShown ? 'Hide the password' : 'Show the password',
                      icon: Icon(_passwordShown ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _passwordShown = !_passwordShown),
                    ),
                  ),
                ),
              const SizedBox(height: Gap.l),
              FilledButton(onPressed: _save, child: Text(preset ? 'Sign in' : 'Save')),
            ],
          ),
        ),
      ),
    );
  }
}

/// One feed of a catalogue: its sections or its books, a page at a time,
/// with a search when the catalogue has one.
class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    required this.store,
    required this.client,
    required this.url,
    required this.title,
    this.query,
    this.searchIn,
    this.onSignIn,
  });

  final LibraryStore store;
  final OpdsClient client;
  final Uri url;
  final String title;

  /// Search results for these words, in the catalogue whose feed is [url]
  /// (or [searchIn], that feed already read).
  final String? query;
  final OpdsFeed? searchIn;

  /// The catalogue asked for a sign-in: change how it signs in. True when
  /// that was done (the catalogue is opened again from its list).
  final Future<bool> Function()? onSignIn;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  OpdsFeed? _feed;
  final _entries = <OpdsEntry>[];
  Uri? _next;
  Object? _error;
  bool _more = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final q = widget.query;
      var feed = q != null && widget.searchIn != null ? widget.searchIn! : await widget.client.feed(widget.url);
      if (q != null) feed = await widget.client.search(feed, q);
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _entries
          ..clear()
          ..addAll(feed.entries);
        _next = feed.next;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadMore() async {
    final next = _next;
    if (next == null || _more) return;
    setState(() => _more = true);
    try {
      final page = await widget.client.feed(next);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _next = page.next == next ? null : page.next;
      });
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not load more: ${_reason(e)}');
    } finally {
      if (mounted) setState(() => _more = false);
    }
  }

  void _search(String words) {
    if (words.trim().isEmpty) return;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FeedScreen(
        store: widget.store,
        client: widget.client,
        url: widget.url,
        title: '“${words.trim()}”',
        query: words.trim(),
        searchIn: _feed,
      ),
    )));
  }

  void _openEntry(OpdsEntry e) {
    final feed = e.feed;
    if (e.isBook) {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => OpdsBookScreen(store: widget.store, client: widget.client, entry: e),
      )));
    } else if (feed != null) {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FeedScreen(store: widget.store, client: widget.client, url: feed.href, title: e.title),
      )));
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    final error = _error;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(
                title: widget.query == null && feed != null && feed.title.isNotEmpty ? feed.title : widget.title,
                onBack: () => Navigator.of(context).maybePop(),
              ),
              if (feed != null && feed.searchable && widget.query == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: TextField(
                    textInputAction: TextInputAction.search,
                    style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context)),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded, size: 20),
                      hintText: 'Search this catalogue',
                    ),
                    onSubmitted: _search,
                  ),
                ),
              Expanded(
                child: error != null
                    ? _problem(context, error)
                    : feed == null
                        ? const Center(child: CircularProgressIndicator())
                        : _entries.isEmpty
                            ? const EmptyState(
                                icon: Icons.search_off_rounded,
                                title: 'Nothing here',
                                body: 'This part of the catalogue is empty.',
                              )
                            : ListView.builder(
                                padding: EdgeInsets.fromLTRB(
                                    Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                                itemCount: _entries.length + (_next != null ? 1 : 0),
                                itemBuilder: (context, i) {
                                  if (i == _entries.length) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: Gap.l),
                                      child: Center(
                                        child: _more
                                            ? const CircularProgressIndicator()
                                            : OutlinedButton(onPressed: _loadMore, child: const Text('More')),
                                      ),
                                    );
                                  }
                                  return _EntryRow(entry: _entries[i], client: widget.client, onTap: _openEntry);
                                },
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _problem(BuildContext context, Object error) {
    final signIn = widget.onSignIn;
    final auth = error is OpdsAuthException;
    return EmptyState(
      icon: auth ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
      title: auth ? 'Sign in to this catalogue' : 'Could not open the catalogue',
      body: _reason(error),
      action: auth && signIn != null
          ? FilledButton(
              // Signed in: back to the list, where it opens afresh with it.
              onPressed: () async {
                final nav = Navigator.of(context);
                if (await signIn() && mounted) nav.pop();
              },
              child: const Text('Sign in'),
            )
          : FilledButton(onPressed: _load, child: const Text('Try again')),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.client, required this.onTap});

  final OpdsEntry entry;
  final OpdsClient client;
  final ValueChanged<OpdsEntry> onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final thumb = e.thumbnail;
    final sub = e.isBook
        ? [if (e.authorLine.isNotEmpty) e.authorLine, formatOf(e.downloads.first.type, e.downloads.first.href)!.label]
            .join(' · ')
        : (e.authorLine.isNotEmpty ? e.authorLine : e.summary);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Material(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.row),
          onTap: e.isBook || e.feed != null ? () => onTap(e) : null,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Row(
              children: [
                if (thumb != null) ...[
                  CatalogueCover(client: client, url: thumb, width: e.isBook ? 44 : 32),
                  const SizedBox(width: Gap.m),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context))),
                      if (sub.isNotEmpty)
                        Text(sub,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                    ],
                  ),
                ),
                if (!e.isBook && e.feed != null) Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A cover from a catalogue, fetched through its client (signed in when it
/// must be; a picture written into the feed itself too).
class CatalogueCover extends StatelessWidget {
  const CatalogueCover({super.key, required this.client, required this.url, this.width = 44});

  final OpdsClient client;
  final Uri url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final bytes = _covers[url.toString()] ??= client
        .fetch(url, accept: 'image/*', limit: 4 << 20)
        .then<Uint8List?>((f) => f.bytes)
        .catchError((Object _) => null);
    final height = width * 1.5;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.chip / 2),
      child: SizedBox(
        width: width,
        height: height,
        child: FutureBuilder<Uint8List?>(
          future: bytes,
          builder: (context, snap) {
            final b = snap.data;
            if (b == null) return ColoredBox(color: Skin.inkOn(context).withValues(alpha: 0.08));
            return Image.memory(
              b,
              fit: BoxFit.cover,
              cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, __, ___) => ColoredBox(color: Skin.inkOn(context).withValues(alpha: 0.08)),
            );
          },
        ),
      ),
    );
  }
}

/// A book in a catalogue: its cover, author and description, its files,
/// and Add to library.
class OpdsBookScreen extends StatefulWidget {
  const OpdsBookScreen({super.key, required this.store, required this.client, required this.entry});

  final LibraryStore store;
  final OpdsClient client;
  final OpdsEntry entry;

  @override
  State<OpdsBookScreen> createState() => _OpdsBookScreenState();
}

class _OpdsBookScreenState extends State<OpdsBookScreen> {
  List<Category> _shelves = const [];
  String? _shelf;

  /// Bytes so far and the whole while downloading (-1: not known), null
  /// when not; the import after it shows as [_importing].
  (int, int)? _progress;
  bool _importing = false;
  LibraryEntry? _added;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final shelves = await destinationShelves(widget.store);
      final idx = await widget.store.index();
      if (!mounted) return;
      setState(() {
        _shelves = shelves;
        _shelf = shelves.any((c) => c.id == idx.defaultCategory) ? idx.defaultCategory : shelves.firstOrNull?.id;
      });
    }());
  }

  bool get _busy => _progress != null || _importing;

  Future<void> _add(OpdsLink link) async {
    if (_busy) return;
    setState(() => _progress = (0, link.length ?? -1));
    final notes = <String>[];
    try {
      final added = await addFromCatalogue(
        widget.store,
        widget.client,
        widget.entry,
        link,
        shelf: _shelf,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
        onImporting: () {
          if (!mounted) return;
          setState(() {
            _progress = null;
            _importing = true;
          });
        },
        onNote: notes.add,
      );
      if (!mounted) return;
      setState(() => _added = added);
      final shelf = _shelves.where((c) => c.id == _shelf).firstOrNull?.name;
      showSnack(
        context,
        [shelf == null ? 'Added to your library.' : 'Added to $shelf.', ...notes].join(' '),
        long: notes.isNotEmpty,
        actionLabel: 'Read',
        onAction: () => unawaited(openBook(context, widget.store, added)),
      );
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not add the book: ${_reason(e)}', long: true);
    } finally {
      if (mounted) {
        setState(() {
          _progress = null;
          _importing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final files = e.downloads;
    final best = files.firstOrNull;
    final image = e.image ?? e.thumbnail;
    final progress = _progress;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: '', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (image != null) ...[
                          CatalogueCover(client: widget.client, url: image, width: 110),
                          const SizedBox(width: Gap.l),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.title, style: Skin.title(context, size: 24)),
                              if (e.authorLine.isNotEmpty) ...[
                                const SizedBox(height: Gap.xs),
                                Text(e.authorLine,
                                    style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkSoftOn(context))),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Gap.l),
                    if (best != null) ...[
                      if (_shelves.length > 1) ...[
                        const SectionTitle('Add to', size: 17),
                        const SizedBox(height: Gap.s),
                        ChoiceRow<String>(
                          options: [for (final c in _shelves) (c.id, c.name)],
                          value: _shelf,
                          minSegment: 84,
                          onChanged: (id) => setState(() => _shelf = id),
                        ),
                        const SizedBox(height: Gap.m),
                      ],
                      if (progress != null || _importing)
                        _progressView(context, progress)
                      else if (_added != null)
                        FilledButton.icon(
                          onPressed: () => unawaited(openBook(context, widget.store, _added!)),
                          icon: const Icon(Icons.menu_book_rounded),
                          label: const Text('Read it now'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: () => _add(best),
                          icon: const Icon(Icons.download_rounded),
                          label: Text('Add to library (${formatOf(best.type, best.href)!.label})'),
                        ),
                      if (files.length > 1 && !_busy && _added == null) ...[
                        const SizedBox(height: Gap.s),
                        for (final f in files.skip(1))
                          TextButton(
                            onPressed: () => _add(f),
                            child: Text('Add as ${f.title ?? formatOf(f.type, f.href)!.label}'),
                          ),
                      ],
                    ] else
                      Text('This catalogue offers no file of this book that TomeVoice opens.',
                          style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))),
                    if (e.description.isNotEmpty) ...[
                      const SizedBox(height: Gap.xl),
                      SelectableText(
                        e.description,
                        style: Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkOn(context)).copyWith(height: 1.5),
                      ),
                    ],
                    if (e.related.isNotEmpty) ...[
                      const SizedBox(height: Gap.xl),
                      const SectionTitle('More like this', size: 17),
                      const SizedBox(height: Gap.s),
                      for (final r in e.related.take(8))
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => FeedScreen(
                                store: widget.store,
                                client: widget.client,
                                url: r.href,
                                title: r.title ?? 'More',
                              ),
                            )),
                            child: Text(r.title ?? r.href.toString(), textAlign: TextAlign.start),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _progressView(BuildContext context, (int, int)? progress) {
    final total = progress?.$2 ?? -1;
    final done = progress?.$1 ?? 0;
    String mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: progress == null || total <= 0 ? null : done / total, color: Skin.accentOf(context)),
        const SizedBox(height: Gap.s),
        Text(
          progress == null
              ? 'Adding to your library…'
              : total > 0
                  ? 'Downloading: ${mb(done)} of ${mb(total)} MB'
                  : 'Downloading: ${mb(done)} MB',
          style: Skin.ui(size: 13.5, weight: FontWeight.w500, color: Skin.inkSoftOn(context)),
        ),
      ],
    );
  }
}
