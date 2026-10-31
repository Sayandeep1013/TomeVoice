import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'safe_file.dart';
import 'sources/bridge.dart';
import 'speech_service.dart';

/// One error the app met: when, in which version, what it said and where in
/// the code. [from] is `app` for the app's own code, `android` for a crash
/// on Android's side (ErrorLog.kt).
@immutable
class ErrorEntry {
  const ErrorEntry({
    required this.time,
    required this.version,
    required this.message,
    this.stack = '',
    this.from = 'app',
    this.count = 1,
  });

  final DateTime time;
  final String version;
  final String message;
  final String stack;
  final String from;

  /// How many times in a row it came (a broken frame comes every frame).
  final int count;

  ErrorEntry _with({DateTime? time, String? version, String? message, String? stack, int? count}) => ErrorEntry(
        time: time ?? this.time,
        version: version ?? this.version,
        message: message ?? this.message,
        stack: stack ?? this.stack,
        from: from,
        count: count ?? this.count,
      );

  Map<String, Object?> toJson() => {
        'time': time.toUtc().toIso8601String(),
        'version': version,
        'from': from,
        'message': message,
        if (stack.isNotEmpty) 'stack': stack,
        if (count > 1) 'count': count,
      };

  static ErrorEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final time = DateTime.tryParse('${json['time']}');
    final message = json['message'];
    if (time == null || message is! String) return null;
    final count = json['count'];
    return ErrorEntry(
      time: time,
      version: json['version'] is String ? json['version'] as String : '',
      message: message,
      stack: json['stack'] is String ? json['stack'] as String : '',
      from: json['from'] == 'android' ? 'android' : 'app',
      count: count is int && count > 0 ? count : 1,
    );
  }
}

/// What went wrong, kept on the phone and nowhere else. TomeVoice sends no
/// telemetry, so with no log at all, no problem reported meant silence, not
/// health. Errors Flutter catches, errors nothing caught, and (from
/// ErrorLog.kt) Android's own crashes go into one small file in the app's
/// private storage, the last [keep] of them; "Report a problem" (About)
/// shows them, and the reader sends them, or not, themselves.
///
/// Nothing from a book is ever written: an error's first line only, with
/// anything quoted, every link and file path, and every book's title and
/// author and every secret shelf's name taken out (see [scrubError]), and
/// where in the code it happened. A secret shelf must not show here either.
class ErrorLog {
  ErrorLog._();

  static final instance = ErrorLog._();

  /// The most kept: one more pushes out the oldest.
  static const keep = 50;

  /// Lines of a stack kept: where it happened, not the whole way there.
  static const frames = 12;

  /// The file, in the app's private storage, one entry a line (ErrorLog.kt
  /// adds its crashes to it). Never in a backup (LibraryBackup.kt), and left
  /// on the phone by a restore (backup.dart).
  static const fileName = 'errors.jsonl';

  File? _file;
  List<ErrorEntry> _entries = const [];
  Timer? _saveTimer;

  /// Set while an error is being taken down: one met in doing so is let go,
  /// not logged in its turn.
  bool _busy = false;

  /// When this run began: its errors are this version's, once it is known.
  final _began = DateTime.now();
  String _version = '';
  RegExp? _private;

  /// Oldest first.
  List<ErrorEntry> get entries => _entries;

  /// The app's version, given to this run's errors met before it was known.
  set version(String version) {
    if (version.isEmpty || version == _version) return;
    _version = version;
    bool unnamed(ErrorEntry e) => e.version.isEmpty && e.from == 'app' && !e.time.isBefore(_began);
    if (!_entries.any(unnamed)) return;
    _entries = List.unmodifiable([for (final e in _entries) unnamed(e) ? e._with(version: version) : e]);
    _scheduleSave();
  }

  /// What must never be written: the books' titles and authors, the secret
  /// shelves' names (set by the library as it changes). What is in the log
  /// already is taken through again: Android's side writes without them.
  set privateWords(Iterable<String> words) {
    final kept = {
      for (final w in words)
        if (w.trim().length >= 3) w.trim(),
    }.toList()
      // The longest first, so a title is taken out whole, not a word in it.
      ..sort((a, b) => b.length.compareTo(a.length));
    final any = kept.map(RegExp.escape).join('|');
    _private = kept.isEmpty
        ? null
        : RegExp('(?<![\\p{L}\\p{N}_])(?:$any)(?![\\p{L}\\p{N}_])', caseSensitive: false, unicode: true);
    _rescrub();
  }

  /// Read what is kept in [dir] (the app's private storage), with what was
  /// met before it was open, and keep writing there.
  Future<void> attach(Directory dir) async {
    final file = File('${dir.path}/$fileName');
    if (_file?.path == file.path) return;
    _file = file;
    final read = <ErrorEntry>[];
    try {
      if (await file.exists()) {
        for (final line in await file.readAsLines()) {
          if (line.trim().isEmpty) continue;
          try {
            final e = ErrorEntry.fromJson(jsonDecode(line));
            if (e != null) read.add(e);
          } on FormatException {
            // A line cut short by the crash it was about.
          }
        }
      }
    } on Object {
      // Unreadable: the next write starts it afresh.
    }
    _entries = _newest([...read, ..._entries]);
    _rescrub();
    if (_entries.isNotEmpty) _scheduleSave();
  }

  /// [error] met with [stack]: taken down, never thrown on.
  void record(Object error, StackTrace? stack) => _take(() => '$error', stack);

  /// An error Flutter caught (building, laying out, painting, a gesture).
  /// Only the error itself is kept: what Flutter adds about where it was
  /// (the widget being built) can hold a book's words.
  void recordFlutter(FlutterErrorDetails details) {
    // What Flutter itself calls quiet (an image that failed to load, say).
    if (details.silent) return;
    _take(details.exceptionAsString, details.stack);
  }

  void _take(String Function() say, StackTrace? stack) {
    if (_busy) return;
    _busy = true;
    try {
      _add(ErrorEntry(
        time: DateTime.now(),
        version: _version,
        message: scrubError(say(), private: _private),
        stack: _trimmed(stack),
      ));
    } on Object {
      // Nothing to be done: the log must not be the next error.
    } finally {
      _busy = false;
    }
  }

  String _trimmed(StackTrace? stack) {
    if (stack == null) return '';
    return [
      for (final line in '$stack'.split('\n').where((l) => l.trim().isNotEmpty).take(frames))
        scrubLine(line, private: _private),
    ].join('\n');
  }

  void _add(ErrorEntry e) {
    final last = _entries.lastOrNull;
    // The same error again at once: counted, not kept again.
    if (last != null && last.message == e.message && last.stack == e.stack && last.from == e.from) {
      _entries = List.unmodifiable(
          [..._entries.sublist(0, _entries.length - 1), last._with(time: e.time, count: last.count + 1)]);
    } else {
      _entries = _last([..._entries, e]);
    }
    _scheduleSave();
  }

  /// [all] by time, oldest first (those met at the same moment as they
  /// came), the last [keep] of them.
  static List<ErrorEntry> _newest(List<ErrorEntry> all) {
    final order = [for (var i = 0; i < all.length; i++) i]..sort((a, b) {
        final c = all[a].time.compareTo(all[b].time);
        return c != 0 ? c : a.compareTo(b);
      });
    return _last([for (final i in order) all[i]]);
  }

  static List<ErrorEntry> _last(List<ErrorEntry> all) =>
      List.unmodifiable(all.length > keep ? all.sublist(all.length - keep) : all);

  /// What is kept, taken through [scrubError] again with the private words.
  void _rescrub() {
    final private = _private;
    if (private == null) return;
    var changed = false;
    final next = <ErrorEntry>[];
    for (final e in _entries) {
      final message = scrubError(e.message, private: private);
      final stack = [
        for (final l in e.stack.split('\n'))
          if (l.isNotEmpty) scrubLine(l, private: private),
      ].join('\n');
      final same = message == e.message && stack == e.stack;
      changed |= !same;
      next.add(same ? e : e._with(message: message, stack: stack));
    }
    if (!changed) return;
    _entries = List.unmodifiable(next);
    _scheduleSave();
  }

  /// Written a moment after the last error: a frame that fails again and
  /// again is one write, not sixty a second.
  void _scheduleSave() {
    if (_file == null) return;
    _saveTimer ??= Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  /// Write now.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final file = _file;
    if (file == null) return;
    try {
      await writeSafely(file, _entries.isEmpty ? '' : '${_entries.map((e) => jsonEncode(e.toJson())).join('\n')}\n');
    } on Object {
      // Written with the next error.
    }
  }

  /// Forget every error kept.
  Future<void> clear() async {
    _entries = const [];
    await flush();
  }

  /// Back to nothing, nowhere (between tests).
  @visibleForTesting
  void reset() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _file = null;
    _entries = const [];
    _version = '';
    _private = null;
  }
}

// Links of any kind (https:, content:, file:).
final _link = RegExp(r'\b[A-Za-z][A-Za-z0-9+.\-]*://\S+');

// Text in quotes of any kind. A single-quoted name of the code (a type,
// 'package:…') may stay: Dart's own messages quote those that way.
final _quoted = RegExp(r'''“[^”\n]*”|"[^"\n]*"|(?<!\w)'[^'\n]*'(?!\w)|‘[^’\n]*’|«[^»\n]*»|„[^“”\n]*[“”]''');
final _codeName = RegExp(r'^(?:(?:package|dart):\S+|[A-Za-z_$][\w$]*(?:<[\w$<>, ?]*>)?\??)$');

// A file's path: from a slash that starts one up to where the message goes
// on (": ", " (", ", ", a quote, the end), as a name may have spaces in it.
final _path = RegExp(r'''(?<![\w:/.~\-])/[^/\s]*/[^\n]*?(?=: |\s\(|, |['"“”‘’)]|$)''');

final _space = RegExp(r'\s+');

/// [text], an error's message, as the error log may keep it: its first
/// line, with every link, anything in quotes (but the code's own names),
/// every file path and the [private] words (titles, authors, secret
/// shelves) taken out, and no longer than [max]. What is in quotes can be
/// anything: a file's name, a line of a book.
String scrubError(String text, {RegExp? private, int max = 240}) {
  final first = text.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  return scrubLine(first, private: private, max: max);
}

/// One line of an error or of its stack, scrubbed as [scrubError] says.
String scrubLine(String line, {RegExp? private, int max = 240}) {
  var out = line.replaceAll(_link, '<link>');
  out = out.replaceAllMapped(_quoted, (m) {
    final q = m[0]!;
    return q.startsWith("'") && _codeName.hasMatch(q.substring(1, q.length - 1)) ? q : '"…"';
  });
  out = out.replaceAll(_path, '<file>');
  if (private != null) out = out.replaceAll(private, '…');
  out = out.replaceAll(_space, ' ').trim();
  return out.length <= max ? out : '${out.substring(0, max - 1)}…';
}

var _catching = false;

/// Every error the app meets goes to the log, as well as where it went
/// before: Flutter's own (printed as ever), and those nothing caught. Once.
void catchErrors() {
  if (_catching) return;
  _catching = true;
  final flutter = FlutterError.onError;
  FlutterError.onError = (details) {
    ErrorLog.instance.recordFlutter(details);
    flutter?.call(details);
  };
  final platform = PlatformDispatcher.instance;
  final before = platform.onError;
  platform.onError = (error, stack) {
    ErrorLog.instance.record(error, stack);
    return before?.call(error, stack) ?? false;
  };
}

/// What the app's guarded zone hears of an error nothing else caught:
/// logged, and printed as Flutter would have printed it.
void zoneError(Object error, StackTrace stack) {
  ErrorLog.instance.record(error, stack);
  debugPrint('Unhandled: $error\n$stack');
}

/// Open the log in the app's private storage (where the sources live, out
/// of every backup) and learn the app's version. What is met before then is
/// kept in memory, and written with the rest.
Future<void> openErrorLog() async {
  try {
    final dir = await SourcesBridge.sourcesRoot();
    if (dir != null) await ErrorLog.instance.attach(Directory(dir));
    ErrorLog.instance.version = await const SpeechService().appVersion() ?? '';
  } on Object {
    // No log this time; nothing else depends on it.
  }
}
