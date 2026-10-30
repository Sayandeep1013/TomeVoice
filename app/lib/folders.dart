import 'package:flutter/services.dart';

/// A folder on the phone (or in Drive) the reader picked once: TomeVoice may
/// write into it from then on, until the reader takes that back in Android's
/// settings. Kept as Android's tree address and the folder's name.
class PickedFolder {
  const PickedFolder(this.uri, this.name);

  final String uri;
  final String name;

  Map<String, Object?> toJson() => {'uri': uri, 'name': name};

  static PickedFolder? fromJson(Object? json) {
    if (json is! Map || json['uri'] is! String || (json['uri'] as String).isEmpty) return null;
    return PickedFolder(json['uri'] as String, json['name'] as String? ?? 'Folder');
  }
}

/// A file in a picked folder.
typedef FolderFile = ({String id, String name, int size, DateTime modified});

/// Android's folder picker and the files TomeVoice writes there (automatic
/// backups, quotes as Markdown, novels as EPUB). Each call fails with a PlatformException
/// coded FOLDER when the folder is gone or may no longer be written to.
class Folders {
  const Folders();

  static const _channel = MethodChannel('tomevoice/tts');

  /// Ask for a folder and keep the right to write there. Null if closed.
  Future<PickedFolder?> pick() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    return raw == null ? null : PickedFolder.fromJson(raw);
  }

  /// Whether [folder] may still be written to.
  Future<bool> usable(PickedFolder folder) async {
    try {
      return await _channel.invokeMethod<bool>('folderOk', {'tree': folder.uri}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Write [text] to a new file [name] in [folder]. The name Android gave
  /// it (one already taken gets a number).
  Future<String> writeText(PickedFolder folder, String name, String text, {String mime = 'text/markdown'}) async =>
      await _channel.invokeMethod<String>('writeToFolder', {
        'tree': folder.uri,
        'name': name,
        'mime': mime,
        'text': text,
      }) ??
      name;

  /// A copy of the file at [path] (one TomeVoice made, in its own storage:
  /// an EPUB) as a new file [name] in [folder]. The name Android gave it.
  Future<String> copyFile(PickedFolder folder, String name, String path, {required String mime}) async =>
      await _channel.invokeMethod<String>('copyToFolder', {
        'tree': folder.uri,
        'name': name,
        'mime': mime,
        'path': path,
      }) ??
      name;

  /// The library zipped into a new file [name] in [folder], [manifest]
  /// first: what the backup writer puts in a backup saved by hand.
  Future<({int files, int bytes})> backUp(
    PickedFolder folder, {
    required String name,
    required String manifest,
    required bool includeChapters,
  }) async {
    final r = await _channel.invokeMapMethod<String, Object?>('backupToFolder', {
      'tree': folder.uri,
      'name': name,
      'manifest': manifest,
      'includeChapters': includeChapters,
    });
    return (files: (r?['files'] as num?)?.toInt() ?? 0, bytes: (r?['bytes'] as num?)?.toInt() ?? 0);
  }

  /// The files in [folder].
  Future<List<FolderFile>> list(PickedFolder folder) async {
    final raw = await _channel.invokeListMethod<Object?>('listFolder', {'tree': folder.uri});
    return [
      for (final f in raw ?? const [])
        if (f is Map && f['id'] is String && f['name'] is String)
          (
            id: f['id'] as String,
            name: f['name'] as String,
            size: (f['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch((f['modified'] as num?)?.toInt() ?? 0),
          ),
    ];
  }

  /// Delete file [id] (from [list]) in [folder].
  Future<void> delete(PickedFolder folder, String id) =>
      _channel.invokeMethod<void>('deleteFromFolder', {'tree': folder.uri, 'id': id});
}
