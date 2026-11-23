import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'safe_file.dart';
import 'secret_shelf.dart';
import 'sources/bridge.dart';
import 'speech_service.dart';
import 'store_build.dart';
import 'theme.dart' show Gap;

/// Whether chapter downloads are kept going by the keep-alive service, as
/// memory building is. The same in both builds for now.
// Play: chapter downloads are not declared to Google Play as a foreground
// service (the owner's choice). To leave them out of the keep-alive in the
// Play build only, make this `!playBuild`; downloads then go on only while
// TomeVoice is open, and pick up where they were when it is opened again.
const keepDownloadsAlive = true;

/// Whether a natural voice's download is kept going by it too.
// Play: as for chapter downloads, `!playBuild` here leaves voice downloads
// out of the keep-alive in the Play build, if that task is not declared.
const keepVoiceDownloadsAlive = true;

/// The kinds of long work the app does itself, in its own Dart.
enum KeepAliveKind {
  downloads('Downloading chapters', 'downloading chapters', 'Chapter downloads', 'Downloads'),
  memory('Building a memory', 'building a memory', 'Memory building', 'Memory building'),
  voice('Downloading a voice', 'downloading a voice', 'The voice download', 'The voice download');

  const KeepAliveKind(this.title, this.also, this.noun, this.paused);

  /// The notification's title for it alone.
  final String title;

  /// After another's: "also building a memory".
  final String also;

  /// What goes on: "Chapter downloads go on from where they stopped."
  final String noun;

  /// What Android paused: "Downloads paused".
  final String paused;

  /// "Chapter downloads" are many; the rest are one thing.
  bool get plural => this == downloads;
}

/// One long job, from when it starts until it ends.
class KeepAliveJob {
  KeepAliveJob({
    required this.key,
    required this.kind,
    String? title,
    this.text = '',
    this.done = 0,
    this.total = 0,
    this.resumable = false,
    this.onStop,
    this.onHold,
    this.onGoOn,
  }) : title = title ?? kind.title;

  /// "downloads", "memory:<book>", "voice:<model>".
  final String key;
  final KeepAliveKind kind;

  String title;
  String text;

  /// How far it is (0 of 0: not known).
  int done;
  int total;

  /// Kept on disk while it runs: a run that ends before it does (the app
  /// swiped away, closed by Android, the phone restarted) leaves where to
  /// go on from, for the next time TomeVoice is opened.
  final bool resumable;

  /// The notification's Stop: stop as the reader's own Pause or Cancel would.
  final VoidCallback? onStop;

  /// Android's daily time for work in the background is used up: stop
  /// cleanly, without the reader's pause; [onGoOn] when the app is next
  /// in front.
  final VoidCallback? onHold;
  final VoidCallback? onGoOn;
}

/// What the notification says: its title and line, how far (0 of 0: not
/// known), and what it says if Android pauses the work.
typedef KeepAliveNotice = ({String title, String text, int done, int total, String paused});

/// What the notification says while [jobs] run (the one begun first leads,
/// the others are named after it), and what it says if Android pauses them.
KeepAliveNotice keepAliveNotice(List<KeepAliveJob> jobs) {
  if (jobs.isEmpty) return (title: '', text: '', done: 0, total: 0, paused: '');
  final first = jobs.first;
  final also = {for (final j in jobs.skip(1)) j.kind.also}.toList();
  final text = [if (first.text.isNotEmpty) first.text, if (also.isNotEmpty) 'also ${_and(also)}'].join(' · ');
  final kinds = {for (final j in jobs) j.kind}.toList();
  final paused = '${_and([kinds.first.paused, for (final k in kinds.skip(1)) _lower(k.paused)])} paused';
  return (title: first.title, text: text, done: first.done, total: first.total, paused: paused);
}

String _lower(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

String _and(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.single,
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};

/// "Chapter downloads and memory building go on from where they stopped."
String pickedUpLine(Iterable<KeepAliveKind> kinds) {
  final k = {...kinds}.toList();
  final many = k.length > 1 || k.single.plural;
  return '${_and([k.first.noun, for (final x in k.skip(1)) _lower(x.noun)])} '
      '${many ? 'go' : 'goes'} on from where ${many ? 'they' : 'it'} stopped.';
}

/// "Downloads paused while TomeVoice was away: Android allows six hours a
/// day. They go on now."
String heldLine(Iterable<KeepAliveKind> kinds) {
  final k = {...kinds}.toList();
  final many = k.length > 1 || k.single.plural;
  return '${_and([k.first.paused, for (final x in k.skip(1)) _lower(x.paused)])} paused while TomeVoice was away: '
      'Android allows six hours a day. ${many ? 'They go' : 'It goes'} on now.';
}

/// The platform's half (KeepAlive.kt): the service, its notification and
/// its wake lock.
abstract interface class KeepAlivePlatform {
  /// Start the service, or update its notification. Whether it is up or on
  /// its way (false: Android would not start it from where the app is).
  Future<bool> show(KeepAliveNotice notice);

  /// Nothing is left to keep going.
  Future<void> stop();
}

class _ChannelPlatform implements KeepAlivePlatform {
  const _ChannelPlatform();

  static const channel = MethodChannel('tomevoice/keepalive');

  /// Android 13 and later show the notification (and its Stop) only with
  /// the reader's leave: asked as the first long job of a launch starts,
  /// the reader being in the app then. Refused once, not asked again.
  static bool _askedToNotify = false;

  @override
  Future<bool> show(KeepAliveNotice n) async {
    if (!_askedToNotify) {
      _askedToNotify = true;
      unawaited(SourcesBridge.askNotifications(settings: false));
    }
    try {
      return await channel.invokeMethod<bool>('show', {
            'title': n.title,
            'text': n.text,
            'done': n.done,
            'total': n.total,
            'paused': n.paused,
          }) ??
          false;
    } on Object {
      // No platform (tests, the background workers' engines).
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } on Object {
      // Nothing there to stop.
    }
  }
}

/// Long jobs the app does itself, in its own Dart on the app's engine
/// (chapters downloading, a book's memory being built, a natural voice
/// downloading), kept going with TomeVoice behind other apps, the screen
/// off, or swiped from Recents.
///
/// Each job [begin]s as it starts, while the app is in front (as the reader
/// has just asked for it), and the platform's service (KeepAlive.kt, data
/// sync) starts there and then: Android 12 and later refuse to start one
/// from the background, which is why the downloads' service, once started
/// with their first progress, did not always keep them going. It holds a
/// partial wake lock, so the phone does not sleep under the work with the
/// screen off, and the engine stays while it runs (ReadingCore, as for a
/// book read aloud). One quiet notification says what runs, with Stop; the
/// service goes when the last job [end]s.
///
/// Android 15 gives work of this kind six hours a day in the background:
/// then each job is held, and goes on when TomeVoice is next opened. A job
/// that is [KeepAliveJob.resumable] is written down while it runs, so one
/// that a run ended (Android, or a phone maker's battery saving, closing
/// the app) is picked up the next time it is opened, and the reader is
/// told.
class LongJobs {
  LongJobs._(this._platform)
      : _inFrontNow = null,
        _exempt = null,
        _sayTo = null,
        _gather = const Duration(seconds: 2),
        _gap = const Duration(seconds: 1);

  static final instance = LongJobs._(const _ChannelPlatform());

  /// One of a test's own: what is in front, the battery and what is said
  /// stand in for the app's.
  @visibleForTesting
  LongJobs.forTests(
    this._platform, {
    bool Function()? inFront,
    Future<bool?> Function()? exempt,
    void Function(String text, {String? action, VoidCallback? onAction})? say,
    Duration gather = Duration.zero,
    Duration gap = Duration.zero,
  }) : _inFrontNow = inFront,
       _exempt = exempt,
       _sayTo = say,
       _gather = gather,
       _gap = gap;

  final KeepAlivePlatform _platform;
  final bool Function()? _inFrontNow;
  final Future<bool?> Function()? _exempt;
  final void Function(String text, {String? action, VoidCallback? onAction})? _sayTo;

  /// How long to gather the jobs picked up after a run ended, to name them
  /// in one line.
  final Duration _gather;

  /// The least time between two progress updates of the notification: a
  /// voice download said each 1 % of it, and every post took the wake lock
  /// again, a load an old phone felt.
  final Duration _gap;
  DateTime? _postedAt;
  Timer? _later;

  /// The jobs running, in the order they began.
  final _jobs = <String, KeepAliveJob>{};

  /// Held by Android's daily limit, until the app is next in front.
  final _held = <String, KeepAliveJob>{};

  /// Bumped on every change.
  final changes = ValueNotifier<int>(0);

  /// Whether anything runs.
  bool get busy => _jobs.isNotEmpty;

  /// Whether work waits for the app to be opened (Android's daily limit).
  bool get held => _held.isNotEmpty;

  List<KeepAliveJob> get jobs => [..._jobs.values];

  bool isRunning(String key) => _jobs.containsKey(key);

  /// The platform said the service is up, or on its way.
  bool _up = false;
  KeepAliveNotice? _shown;

  // ------------------------------------------------------- kept on disk

  File? _file;

  /// Resumable jobs running now, as written down.
  final _resume = <String>{};

  /// Written down by a run that ended before they did, and not yet picked up.
  final _leftover = <String>{};

  /// The battery hint was given.
  bool _hinted = false;

  AppLifecycleListener? _life;

  /// The library (keep_alive.json in it): what a run that ended left
  /// running, and whether the battery hint was given. Then listens for the
  /// platform (Stop, Android's daily limit) and for the app coming back.
  Future<void> attach(Directory root) async {
    _file = File('${root.path}/keep_alive.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map) {
          _hinted = raw['hinted'] == true;
          for (final k in raw['resume'] as List? ?? const []) {
            if (k is String && !_jobs.containsKey(k)) {
              _leftover.add(k);
              _resume.add(k);
            }
          }
        }
      }
    } on Object {
      // A broken file: nothing to pick up.
    }
    if (_platform is _ChannelPlatform) {
      _ChannelPlatform.channel.setMethodCallHandler((call) async => platformEvent(call.method));
    }
    if (_inFrontNow == null) {
      _life ??= AppLifecycleListener(onResume: _cameToFront);
    }
  }

  /// Written down by the run before, of [prefix] ("memory:"): for their
  /// owner to go on with ([begin]) or let go of ([end]).
  List<String> leftOver(String prefix) => [
    for (final k in _leftover)
      if (k.startsWith(prefix)) k,
  ];

  // ---------------------------------------------------------- the jobs

  /// [job] has started: the service is asked for at once. Begun already
  /// (the same job, or another of the same key, which keeps it): the
  /// notification says what it says now. [hint]: the reader started it,
  /// and may be told once that battery saving can stop it.
  void begin(KeepAliveJob job, {bool hint = true}) {
    final had = _jobs[job.key];
    if (had != null) {
      _show();
      return;
    }
    _held.remove(job.key);
    _jobs[job.key] = job;
    if (_leftover.remove(job.key)) _pickedUp(job.kind);
    if (job.resumable && _resume.add(job.key)) unawaited(_save());
    _show(force: true);
    if (hint) unawaited(_hint());
    changes.value++;
  }

  /// [key]'s progress, for the notification.
  void update(String key, {String? title, String? text, int? done, int? total}) {
    final j = _jobs[key];
    if (j == null) return;
    if (title != null) j.title = title;
    if (text != null) j.text = text;
    if (done != null) j.done = done;
    if (total != null) j.total = total;
    _show();
  }

  /// [key] has ended (done, stopped, failed), or will not go on. With [job],
  /// only if that is the one running: a second start of the same work,
  /// which found it running, leaves it to the first. One held by Android
  /// stays written down until it goes on.
  void end(String key, {KeepAliveJob? job}) {
    final now = _jobs[key];
    if (job != null && now != null && !identical(now, job)) return;
    _leftover.remove(key);
    if (!_held.containsKey(key) && _resume.remove(key)) unawaited(_save());
    if (now == null) return;
    _jobs.remove(key);
    if (_jobs.isEmpty) {
      _up = false;
      _shown = null;
      unawaited(_platform.stop());
    } else {
      _show(force: true);
    }
    changes.value++;
  }

  void _show({bool force = false}) {
    if (_jobs.isEmpty) return;
    final n = keepAliveNotice([..._jobs.values]);
    if (!force && _up && n == _shown) return;
    // Progress said at most once a [_gap]; the latest, a moment later.
    final at = _postedAt;
    if (!force && _up && at != null) {
      final since = DateTime.now().difference(at);
      if (since < _gap) {
        _later ??= Timer(_gap - since, () {
          _later = null;
          _show();
        });
        return;
      }
    }
    _later?.cancel();
    _later = null;
    _postedAt = DateTime.now();
    _shown = n;
    unawaited(
      _platform.show(n).then((up) {
        // Ended meanwhile: it says nothing.
        if (_jobs.isNotEmpty) _up = up;
      }),
    );
  }

  // ------------------------------------------------------ the platform

  /// What the platform says (KeepAlive.kt): "stop" (the notification's
  /// Stop), "timeout" (Android 15's six hours a day of work in the
  /// background are used up) or "refused" (Android would not let the
  /// service start now; tried again when the app is next in front).
  @visibleForTesting
  Future<void> platformEvent(String event) async {
    switch (event) {
      case 'stop':
        for (final j in [..._jobs.values]) {
          j.onStop?.call();
        }
      case 'timeout':
        _hold();
      case 'refused':
        _up = false;
    }
  }

  void _hold() {
    if (_jobs.isEmpty) return;
    final jobs = [..._jobs.values];
    _jobs.clear();
    _up = false;
    _shown = null;
    for (final j in jobs) {
      _held[j.key] = j;
    }
    // The service stopped itself; the engine may go now if nothing shows it.
    unawaited(_platform.stop());
    for (final j in jobs) {
      j.onHold?.call();
    }
    changes.value++;
  }

  // ------------------------------------------------- the app in front

  bool _inFront() {
    final f = _inFrontNow;
    if (f != null) return f();
    if (_file == null) return false;
    return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  final _whenInFront = <VoidCallback>[];

  /// Run [f] now if the app is in front, else when it next comes to it.
  void whenInFront(VoidCallback f) {
    if (_inFront()) {
      f();
    } else {
      _whenInFront.add(f);
    }
  }

  /// The app came to the front: what Android held goes on (its daily time
  /// starts again then), a service it would not start is asked for again,
  /// and what waited for this runs.
  @visibleForTesting
  void cameToFront() => _cameToFront();

  void _cameToFront() {
    if (_held.isNotEmpty) {
      final held = [..._held.values];
      _held.clear();
      _say(heldLine([for (final j in held) j.kind]));
      // Still written down: each is ended (and let go) by its owner, going
      // on or not.
      for (final j in held) {
        j.onGoOn?.call();
      }
      changes.value++;
    }
    if (_jobs.isNotEmpty && !_up) _show(force: true);
    final waiting = [..._whenInFront];
    _whenInFront.clear();
    for (final f in waiting) {
      f();
    }
  }

  final _picked = <KeepAliveKind>{};
  Timer? _gathering;

  void _pickedUp(KeepAliveKind kind) {
    _picked.add(kind);
    if (_gathering != null) return;
    _gathering = Timer(_gather, () {
      _gathering = null;
      whenInFront(() {
        if (_picked.isEmpty) return;
        final line = pickedUpLine(_picked);
        _picked.clear();
        _say(line);
      });
    });
  }

  // ---------------------------------------------------- the battery hint

  /// Once ever, as a job the reader started begins: when battery saving
  /// may stop TomeVoice in the background, a word, and the setting a tap
  /// away (Android's own question in the GitHub build; the Play build may
  /// not ask it, so its list of apps).
  Future<void> _hint() async {
    if (_hinted || !_inFront()) return;
    final exempt = await (_exempt ?? _batteryExempt)();
    if (exempt != false || _hinted) return;
    _hinted = true;
    unawaited(_save());
    _say(
      'Battery saving can stop this with the screen off.',
      action: playBuild ? 'Settings' : 'Allow',
      onAction: () => unawaited(const SpeechService().openBatterySettings(request: !playBuild)),
    );
  }

  static Future<bool?> _batteryExempt() async => (await const SpeechService().batteryStatus())?.exempt;

  /// Whether the battery hint was given.
  bool get hinted => _hinted;

  void _say(String text, {String? action, VoidCallback? onAction}) {
    final to = _sayTo;
    if (to != null) {
      to(text, action: action, onAction: onAction);
      return;
    }
    final context = SecretShelf.navigator.currentContext;
    final messenger = context == null ? null : ScaffoldMessenger.maybeOf(context);
    // After whatever the screen is saying (a chapter queued), not over it.
    messenger?.showSnackBar(SnackBar(
      content: Text(text),
      action: action == null || onAction == null ? null : SnackBarAction(label: action, onPressed: onAction),
      behavior: SnackBarBehavior.floating,
      persist: false,
      duration: const Duration(seconds: 8),
      margin: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
    ));
  }

  // --------------------------------------------------------------- disk

  Future<void>? _saving;

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    final before = _saving;
    final write = () async {
      if (before != null) await before.catchError((Object _) {});
      await writeSafely(
        f,
        jsonEncode({
          if (_hinted) 'hinted': true,
          'resume': [..._resume],
        }),
      );
    }();
    _saving = write;
    try {
      await write;
    } on Object {
      // Kept in memory; written with the next change.
    }
  }

  /// What is written down has been written (tests).
  @visibleForTesting
  Future<void> settled() async {
    try {
      await _saving;
    } on Object {
      // Written or not, nothing is in flight.
    }
  }
}
