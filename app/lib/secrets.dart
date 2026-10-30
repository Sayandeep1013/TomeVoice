import 'dart:convert';
import 'dart:io';

import 'safe_file.dart';

/// Passwords for catalogues and sync servers, kept apart from the settings
/// in a dot-file at the library root: a backup never carries one (it leaves
/// dot-files out, as Settings > Back up library has always done), and a
/// restore leaves this phone's where they are. A backup restored elsewhere
/// asks for them again.
class Secrets {
  Secrets._(this._file);

  static final _open = <String, Secrets>{};

  /// The secrets of the library at [root], read once.
  static Future<Secrets> of(Directory root) async {
    final known = _open[root.path];
    if (known != null) return known;
    final s = Secrets._(File('${root.path}/.secrets.json'));
    try {
      if (await s._file.exists()) {
        final raw = jsonDecode(await s._file.readAsString());
        if (raw is Map) {
          for (final e in raw.entries) {
            if (e.value is String) s._all['${e.key}'] = e.value as String;
          }
        }
      }
    } on Object {
      // Unreadable: asked for again, and written afresh.
    }
    return _open[root.path] ??= s;
  }

  final File _file;
  final _all = <String, String>{};

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
