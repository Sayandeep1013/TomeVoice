import 'dart:async';

import 'package:flutter/material.dart';

import 'kosync.dart';
import 'library_store.dart';
import 'prefs.dart';
import 'secrets.dart';
import 'sync.dart';
import 'theme.dart';
import 'ui.dart';

/// Settings > Sync: a WebDAV folder of the reader's own, and KOReader's
/// sync server. Both off until set up here.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  late final _davUrl = TextEditingController(text: _prefs.webdavUrl ?? '');
  late final _davUser = TextEditingController(text: _prefs.webdavUser ?? '');
  final _davPassword = TextEditingController();
  late final _koUrl = TextEditingController(text: _prefs.kosyncUrl ?? '');
  late final _koUser = TextEditingController(text: _prefs.kosyncUser ?? '');
  final _koPassword = TextEditingController();
  bool _koKeyKept = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(Secrets.of(widget.store.root).then((s) {
      if (!mounted) return;
      setState(() {
        _davPassword.text = s['webdav'] ?? '';
        _koKeyKept = (s['kosync'] ?? '').isNotEmpty;
      });
    }));
  }

  @override
  void dispose() {
    for (final c in [_davUrl, _davUser, _davPassword, _koUrl, _koUser, _koPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  /// [raw] as a web address, or null with a message said. https:// when
  /// it names no scheme; one typed as plain http:// out on the internet
  /// only once the reader has been told what that sends, and agreed.
  Future<String?> _address(String raw) async {
    final url = withScheme(raw);
    if (url.isEmpty) {
      showSnack(context, 'Give the server’s address first.');
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      showSnack(context, 'That is not a web address.');
      return null;
    }
    if (await passwordMayGo(url, agreed: _prefs.plainHttpOk)) return url;
    if (!mounted) return null;
    final ok = await confirm(
      context,
      title: 'Send your password unencrypted?',
      body: 'This address starts with http://, not https://. Your password, and the places and quotes synced, '
          'would cross the internet where anyone on the way could read them. Use https:// if your server has it.',
      action: 'Use http',
    );
    if (!ok) return null;
    _prefs.plainHttpOk.add(url);
    return url;
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() => _run(() async {
        final r = await BookSync.instance.syncNow(store: widget.store);
        if (!mounted) return;
        showSnack(
          context,
          r.problem ??
              (r.sent + r.taken == 0
                  ? 'Everything was already the same.'
                  : 'Synced: ${r.taken} brought here, ${r.sent} sent.'),
          long: r.problem != null,
        );
      });

  Future<void> _setWebDav(bool on) => _run(() async {
        if (!on) {
          _prefs.webdavOn = false;
          _prefs.save();
          return;
        }
        final url = await _address(_davUrl.text);
        if (url == null || !mounted) return;
        _prefs
          ..webdavOn = true
          ..webdavUrl = url
          ..webdavUser = _davUser.text.trim().isEmpty ? null : _davUser.text.trim();
        _prefs.save();
        _davUrl.text = url;
        await (await Secrets.of(widget.store.root)).set('webdav', _davPassword.text);
        final r = await BookSync.instance.syncNow(store: widget.store);
        if (!mounted) return;
        showSnack(context, r.problem ?? 'Sync is on: places, quotes and reading time go to your server.', long: true);
      });

  /// Sign in to KOReader's server, making the account first if [create].
  Future<void> _kosyncSignIn({bool create = false}) => _run(() async {
        final url = await _address(_koUrl.text);
        final user = _koUser.text.trim();
        if (url == null || !mounted) return;
        if (user.isEmpty || (_koPassword.text.isEmpty && !_koKeyKept)) {
          showSnack(context, 'Give a user name and a password.');
          return;
        }
        final secrets = await Secrets.of(widget.store.root);
        final key = _koPassword.text.isEmpty ? secrets['kosync']! : koreaderKey(_koPassword.text);
        final client = KosyncClient(Uri.parse(url), user: user, key: key);
        try {
          if (create && !await client.register()) {
            if (mounted) showSnack(context, 'That user name is taken. If it is yours, sign in instead.');
            return;
          }
          await client.authorize();
          await secrets.set('kosync', key);
          _prefs
            ..kosyncOn = true
            ..kosyncUrl = url
            ..kosyncUser = user;
          _prefs.save();
          _koKeyKept = true;
          _koPassword.clear();
          final r = await BookSync.instance.syncNow(store: widget.store);
          if (mounted) showSnack(context, r.problem ?? 'Signed in. Places in your books are synced with KOReader.', long: true);
        } on Object catch (e) {
          if (mounted) showSnack(context, e is KosyncAuthException ? e.message : 'Could not reach the server: $e', long: true);
        } finally {
          client.close();
        }
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: 'Sync', onBack: () => Navigator.of(context).maybePop()),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                        Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      Text(
                        'Off unless you set it up here. Places, quotes, bookmarks and reading time go to '
                        'the server you name, and nowhere else; your books never do. Books on a secret shelf '
                        'are synced only while it is open.',
                        style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                            .copyWith(height: 1.45),
                      ),
                      const SizedBox(height: Gap.l),
                      _card(context, 'Your own server (WebDAV)', [
                        Text(
                          'A folder on Nextcloud, a NAS or any WebDAV server. TomeVoice keeps its files in a '
                          'TomeVoice folder there.',
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                        ),
                        TextField(
                          controller: _davUrl,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV address',
                            hintText: 'https://cloud.example.org/remote.php/dav/files/me/',
                          ),
                        ),
                        TextField(
                          controller: _davUser,
                          autocorrect: false,
                          decoration: const InputDecoration(labelText: 'User name'),
                        ),
                        TextField(
                          controller: _davPassword,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(labelText: 'Password'),
                        ),
                        const SizedBox(height: Gap.s),
                        SwitchRow(
                          title: 'Sync through this server',
                          value: _prefs.webdavOn,
                          padding: EdgeInsets.zero,
                          onChanged: _busy ? (_) {} : (v) => unawaited(_setWebDav(v)),
                        ),
                      ]),
                      _card(context, 'KOReader sync', [
                        Text(
                          'Keeps your place in a book the same as in KOReader, on another device, through a '
                          'KOReader sync server. Works for EPUB and PDF files that are the same file in both.',
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                        ),
                        TextField(
                          controller: _koUrl,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(labelText: 'Server', hintText: 'https://sync.example.org'),
                        ),
                        TextField(
                          controller: _koUser,
                          autocorrect: false,
                          decoration: const InputDecoration(labelText: 'User name'),
                        ),
                        TextField(
                          controller: _koPassword,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            hintText: _koKeyKept ? 'Kept (type to change)' : null,
                          ),
                        ),
                        const SizedBox(height: Gap.s),
                        Wrap(
                          spacing: Gap.s,
                          children: [
                            FilledButton(
                              onPressed: _busy ? null : () => unawaited(_kosyncSignIn()),
                              child: const Text('Sign in'),
                            ),
                            OutlinedButton(
                              onPressed: _busy ? null : () => unawaited(_kosyncSignIn(create: true)),
                              child: const Text('Make an account'),
                            ),
                          ],
                        ),
                        if (_prefs.kosyncOn)
                          SwitchRow(
                            title: 'Sync with KOReader',
                            value: true,
                            padding: EdgeInsets.zero,
                            onChanged: (v) {
                              setState(() => _prefs.kosyncOn = v);
                              _prefs.save();
                            },
                          ),
                      ]),
                      const SizedBox(height: Gap.s),
                      ValueListenableBuilder(
                        valueListenable: BookSync.instance.status,
                        builder: (context, s, _) => Text(
                          s.problem ??
                              (s.at == null
                                  ? (BookSync.on ? 'Not synced yet since TomeVoice opened.' : 'Sync is off.')
                                  : 'Last synced at ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(s.at!))}.'),
                          style: Skin.ui(
                            size: 13.5,
                            weight: s.problem == null ? FontWeight.w400 : FontWeight.w600,
                            color: s.problem == null ? Skin.inkFaintOn(context) : Skin.inkOn(context),
                          ),
                        ),
                      ),
                      if (BookSync.on) ...[
                        const SizedBox(height: Gap.s),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => unawaited(_syncNow()),
                          icon: const Icon(Icons.sync_rounded),
                          label: const Text('Sync now'),
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

  Widget _card(BuildContext context, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.l),
        child: Container(
          padding: const EdgeInsets.all(Gap.l),
          decoration: BoxDecoration(
            color: Skin.capsuleOn(context),
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: Skin.outlineOn(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Skin.title(context, size: 19)),
              const SizedBox(height: Gap.s),
              ...children,
            ],
          ),
        ),
      );
}
