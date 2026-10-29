import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library_store.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// Secret shelves: shelves whose books show only once the phone's own lock
/// (a fingerprint or face, or its PIN) has been given, and only until
/// TomeVoice is left. While shut, the store leaves them out of every page
/// ([LibraryStore.index]); widgets leave them out too, the lock-screen card
/// names no book of theirs, and Recents shows a blank card while they are
/// open.
///
/// Two ways in: Settings > Secret shelf, where the feature can be found,
/// and pressing and holding the word Library on the shelves, which cannot.
class SecretShelf {
  const SecretShelf._();

  static const _svc = SpeechService();

  static ValueNotifier<bool> get open => LibraryStore.secretOpen;

  /// The app's navigator: leaving TomeVoice with the shelves open goes back
  /// to its first page, so a secret book is not what greets whoever opens
  /// it next.
  static final navigator = GlobalKey<NavigatorState>();

  /// Set while the phone asks for its lock: its prompt (or PIN screen) can
  /// hide TomeVoice for a moment, which is not leaving.
  static bool _asking = false;

  static AppLifecycleListener? _life;

  static void _watch() => _life ??= AppLifecycleListener(onHide: _onLeave, onShow: _onReturn);

  /// Ask for the phone's lock and open the shelves. True if they are open.
  static Future<bool> unlock({String reason = 'Open the secret shelf'}) async {
    _watch();
    if (open.value) return true;
    if (_asking) return false;
    _asking = true;
    try {
      final ok = await _svc.confirmUser(title: 'TomeVoice', subtitle: reason);
      if (ok) {
        unawaited(_svc.hideRecents(true));
        open.value = true;
      }
      return ok;
    } finally {
      // The prompt's own hide and show arrive just after it answers.
      Timer(const Duration(milliseconds: 600), () => _asking = false);
    }
  }

  static void lock() {
    if (!open.value) return;
    open.value = false;
    unawaited(_svc.hideRecents(false));
  }

  static void _onLeave() {
    if (_asking || !open.value) return;
    // Recents keeps its blank card until TomeVoice is back: turned on again
    // now, the card could be taken after it.
    open.value = false;
    navigator.currentState?.popUntil((r) => r.isFirst);
  }

  static void _onReturn() {
    if (!open.value && !_asking) unawaited(_svc.hideRecents(false));
  }

  /// The hidden way in, from the word Library: opens the shelves, or shuts
  /// them if open. With none made yet, it says where they are made.
  static Future<void> toggleFromShelf(BuildContext context, LibraryStore store) async {
    final idx = await store.index(all: true);
    if (!context.mounted) return;
    if (!idx.categories.any((c) => c.secret)) {
      showSnack(context, 'No secret shelf yet. Make one in Settings > Secret shelf.');
      return;
    }
    if (open.value) {
      lock();
      unawaited(HapticFeedback.lightImpact());
      showSnack(context, 'Secret shelf locked.');
      return;
    }
    await unlock();
  }
}

/// Settings > Secret shelf: what it is, and making, opening and shutting it.
Future<void> showSecretShelfSheet(BuildContext context, LibraryStore store) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SecretSheet(store: store),
    );

class _SecretSheet extends StatefulWidget {
  const _SecretSheet({required this.store});

  final LibraryStore store;

  @override
  State<_SecretSheet> createState() => _SecretSheetState();
}

class _SecretSheetState extends State<_SecretSheet> {
  static const _svc = SpeechService();

  /// Whether the phone has a screen lock; null until asked.
  bool? _secure;
  LibraryIndex? _index;

  @override
  void initState() {
    super.initState();
    SecretShelf.open.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    SecretShelf.open.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final secure = await _svc.deviceSecure();
    final idx = await widget.store.index(all: true);
    if (mounted) {
      setState(() {
        _secure = secure;
        _index = idx;
      });
    }
  }

  List<Category> get _secret => [for (final c in _index?.categories ?? const <Category>[]) if (c.secret) c];
  List<Category> get _ordinary => [for (final c in _index?.categories ?? const <Category>[]) if (!c.secret) c];

  Future<void> _make() async {
    if (!await SecretShelf.unlock(reason: 'Make a secret shelf')) return;
    await widget.store.addCategory('Secret', secret: true);
    await _load();
    if (mounted) showSnack(context, 'Made "Secret". Move books to it from the shelf.');
  }

  Future<void> _setSecret(Category c, bool secret) async {
    final idx = _index;
    if (idx == null) return;
    if (secret && _ordinary.length <= 1) {
      showSnack(context, 'One shelf has to stay ordinary.');
      return;
    }
    await widget.store.saveCategories([for (final x in idx.categories) x.id == c.id ? x.withSecret(secret) : x]);
    await _load();
  }

  Future<void> _pickOrdinary() async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Keep which shelf secret?'),
            for (final c in _ordinary)
              SheetAction(icon: Icons.folder_outlined, label: c.name, onTap: () => Navigator.pop(ctx, c)),
            const SizedBox(height: Gap.s),
          ],
        ),
      ),
    );
    if (picked != null) await _setSecret(picked, true);
  }

  @override
  Widget build(BuildContext context) {
    final secure = _secure;
    final open = SecretShelf.open.value;
    final secret = _secret;
    final body = Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              'Secret shelf',
              subtitle: secret.isEmpty ? null : (open ? 'Open until you leave TomeVoice' : 'Locked'),
              trailing: Icon(open ? Icons.lock_open_rounded : Icons.lock_rounded, color: Skin.accentOf(context)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
              child: Text(
                'Books on a secret shelf show only after your fingerprint, face or phone PIN, and only '
                'until you leave TomeVoice. While it is locked they are left out of the shelves, search, '
                'History, Saved, Stats, Updates and widgets, and the lock-screen player says only "TomeVoice".',
                style: body,
              ),
            ),
            if (secure == null)
              const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))
            else if (!secure) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
                child: Text('Your phone needs a screen lock (a PIN, pattern or password) first.', style: body),
              ),
              SheetAction(
                icon: Icons.phonelink_lock_rounded,
                label: 'Set a screen lock',
                onTap: () => _svc.openSecuritySettings(),
              ),
            ] else if (secret.isEmpty)
              SheetAction(icon: Icons.add_moderator_outlined, label: 'Make a secret shelf', onTap: _make)
            else if (!open)
              SheetAction(
                icon: Icons.lock_open_rounded,
                label: 'Open the secret shelf',
                onTap: () => SecretShelf.unlock(),
              )
            else ...[
              SheetAction(
                icon: Icons.lock_rounded,
                label: 'Lock it now',
                onTap: () {
                  SecretShelf.lock();
                  Navigator.pop(context);
                },
              ),
              for (final c in secret)
                SheetAction(
                  icon: Icons.folder_open_outlined,
                  label: 'Make "${c.name}" an ordinary shelf',
                  onTap: () => _setSecret(c, false),
                ),
              if (_ordinary.length > 1)
                SheetAction(icon: Icons.folder_special_outlined, label: 'Keep another shelf secret…', onTap: _pickOrdinary),
            ],
            if (secure == true && secret.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.l),
                child: Text(
                  'The quiet way in: on your shelves, press and hold the word Library. Do it again to lock.',
                  style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                ),
              ),
            const SizedBox(height: Gap.s),
          ],
        ),
      ),
    );
  }
}
