// The sync test servers, run on this computer for a phone to sync with,
// through adb reverse (nothing leaves the computer):
//
//   dart app/test/support/sync_servers.dart [--webdav 8081] [--kosync 8082]
//       [--user reader] [--password secret] [--dir <folder to keep files in>]
//
// then, with the phone on USB:
//
//   adb reverse tcp:8081 tcp:8081
//   adb reverse tcp:8082 tcp:8082
//
// and in TomeVoice, Settings > Sync: WebDAV address http://127.0.0.1:8081/dav/
// with that user and password; KOReader server http://127.0.0.1:8082 (Make
// an account the first time). Ctrl+C stops them. Plain Dart: no Flutter,
// no packages.

import 'dart:io';

import 'kosync_server.dart';
import 'webdav_server.dart';

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final user = arg('user') ?? 'reader';
  final password = arg('password') ?? 'secret';
  final dir = arg('dir');
  final dav = await WebDavTestServer.start(
    user: user,
    password: password,
    port: int.parse(arg('webdav') ?? '8081'),
    keepIn: dir == null ? null : Directory('$dir/webdav'),
  );
  final ko = await KosyncTestServer.start(
    port: int.parse(arg('kosync') ?? '8082'),
    keepIn: dir == null ? null : File('$dir/kosync.json'),
  );
  stdout
    ..writeln('WebDAV:  http://127.0.0.1:${dav.port}/dav/  (user "$user", password "$password")')
    ..writeln('kosync:  http://127.0.0.1:${ko.port}')
    ..writeln(dir == null ? 'Files kept in memory only.' : 'Files kept in $dir.')
    ..writeln('For a phone: adb reverse tcp:${dav.port} tcp:${dav.port} && adb reverse tcp:${ko.port} tcp:${ko.port}')
    ..writeln('Each request is printed below. Ctrl+C stops.');
  var seenDav = 0, seenKo = 0;
  // A line per request, so what the phone does can be watched.
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (; seenDav < dav.requests.length; seenDav++) {
      stdout.writeln('webdav  ${dav.requests[seenDav]}');
    }
    for (; seenKo < ko.requests.length; seenKo++) {
      stdout.writeln('kosync  ${ko.requests[seenKo]}');
    }
  }
}
