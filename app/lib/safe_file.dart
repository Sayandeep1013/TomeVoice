import 'dart:io';

/// Writes in flight, by path, so writes to one file happen one at a time and
/// in order (the last one asked for is the one that stays).
final _pending = <String, Future<void>>{};
var _serial = 0;

/// Write [text] to [file] so that a crash, or a second write at the same
/// moment, never leaves it half written: the text goes into a file beside it,
/// which is then renamed over it (a rename is atomic on the same disk). Does
/// nothing when [file] is null.
Future<void> writeSafely(File? file, String text) {
  if (file == null) return Future<void>.value();
  final path = file.path;
  final before = _pending[path] ?? Future<void>.value();
  final write = before.catchError((Object _) {}).then((_) async {
    final tmp = File('$path.${_serial++}.tmp');
    try {
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  });
  _pending[path] = write;
  return write.whenComplete(() {
    if (identical(_pending[path], write)) _pending.remove(path);
  });
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
