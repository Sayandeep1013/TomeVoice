import 'dart:io';
import 'dart:math';

/// Writes in flight, by path, so writes to one file happen one at a time and
/// in order (the last one asked for is the one that stays).
final _pending = <String, Future<void>>{};
var _serial = 0;

/// Told apart from another copy of the app writing the same file (an engine
/// of its own, its serial counting from 0 too): two writers sharing a temp
/// file would interleave into invalid JSON.
final _salt = Random().nextInt(1 << 32).toRadixString(36);

/// Write [text] to [file] so that a crash, or a second write at the same
/// moment, never leaves it half written: the text goes into a file beside it,
/// which is then renamed over it (a rename is atomic on the same disk). Does
/// nothing when [file] is null.
Future<void> writeSafely(File? file, String text) => _writeVia(file, (tmp) => tmp.writeAsString(text, flush: true));

/// [writeSafely] for bytes already encoded (library.json, see index_file.dart).
Future<void> writeBytesSafely(File? file, List<int> bytes) =>
    _writeVia(file, (tmp) => tmp.writeAsBytes(bytes, flush: true));

Future<void> _writeVia(File? file, Future<Object?> Function(File tmp) put) {
  if (file == null) return Future<void>.value();
  final path = file.path;
  final before = _pending[path] ?? Future<void>.value();
  final write = before.catchError((Object _) {}).then((_) async {
    final tmp = File('$path.$_salt${_serial++}.tmp');
    try {
      await put(tmp);
      await tmp.rename(path);
    } on Object {
      // Renamed, it is gone; only a write that failed leaves one to clear.
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Swept with the folder, or overwritten by the next.
      }
      rethrow;
    }
  });
  _pending[path] = write;
  return write.whenComplete(() {
    if (identical(_pending[path], write)) _pending.remove(path);
  });
}

/// Every write under way (see [writeSafely]) landed, or failed.
Future<void> writesLanded() async {
  while (_pending.isNotEmpty) {
    await Future.wait([for (final w in _pending.values) w.catchError((Object _) {})]);
  }
}

/// Shut while a restore replaces the library's files or adds a backup to
/// them (backup_flow.dart): what the app holds in memory must not be
/// written over them, nor into the library half swapped. The stores that
/// write there ask here first (the places and the index, quotes, the day's
/// stats, the settings, the reading rules, a sync's state), and no sync or
/// automatic backup starts. Never opened again: the app starts afresh once
/// the restore is done or has failed, and every store reads its files anew.
class RestoreGate {
  RestoreGate._();

  static bool _shut = false;

  /// Whether a restore is under way.
  static bool get shut => _shut;

  /// Shut it, and wait for the writes already under way to land.
  static Future<void> close() async {
    _shut = true;
    await writesLanded();
  }

  /// Open it again: between tests.
  static void open() => _shut = false;
}

/// [file] could not be read: keep it beside, as `<name>.broken`, so the next
/// save does not write over what may still be recovered from it.
Future<void> setAside(File? file) async {
  if (file == null) return;
  try {
    if (await file.exists() && await file.length() > 0) await file.rename('${file.path}.broken');
  } on Object {
    // Nothing to keep.
  }
}
