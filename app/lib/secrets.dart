import 'dart:convert';
import 'dart:io';

import 'safe_file.dart';

/// Passwords for catalogues and sync servers, kept apart from the settings
/// in a dot-file in the app's own storage ([home]), which no other app can
/// read: the library's folder is readable by other apps on Android 8 to 10.
/// A backup never carries them (it takes the library's folder, and leaves
/// its dot-files out), and a restore leaves this phone's where they are. A
/// backup restored elsewhere asks for them again.
class Secrets {
  Secrets._(this._file);

  static final _open = <String, Future<Secrets>>{};

  /// Where they are kept: the app's own storage, set as the library opens
  /// (home_shell.dart); the library's folder until then, and in tests.
  static Directory? home;

  /// The secrets of the library at [root], read once. Builds before 1.4 kept
  /// them in the library's folder: moved to [home] the first time, and
  /// deleted there.
  static Future<Secrets> of(Directory root) => _open[root.path] ??= _read(root);

  static Future<Secrets> _read(Directory root) async {
    final s = Secrets._(File('${(home ?? root).path}/.secrets.json'));
    await s._take(s._file);
    final old = File('${root.path}/.secrets.json');
    if (old.path != s._file.path && await old.exists()) {
      // What is kept already stands over the old copy's.
      final kept = {...s._all};
      await s._take(old);
      s._all.addAll(kept);
      try {
        await writeSafely(s._file, jsonEncode(s._all));
        await old.delete();
      } on Object {
        // Moved at the next start; both are read until then.
      }
    }
    return s;
  }

  final File _file;
  final _all = <String, String>{};

  /// What [file] holds, over what is read already.
  Future<void> _take(File file) async {
    try {
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          for (final e in raw.entries) {
            if (e.value is String) _all['${e.key}'] = e.value as String;
          }
        }
      }
    } on Object {
      // Unreadable: asked for again, and written afresh.
    }
  }

  String? operator [](String key) => _all[key];

  /// Keep [value] under [key]; null or empty forgets it.
  Future<void> set(String key, String? value) async {
    if (value == null || value.isEmpty) {
      if (_all.remove(key) == null) return;
    } else {
      if (_all[key] == value) return;
      _all[key] = value;
    }
    await writeSafely(_file, jsonEncode(_all));
  }
}
