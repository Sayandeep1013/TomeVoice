// The starter's two sources: a first launch without the internet installs
// nothing and says so, so the next launch tries again (it used to record the
// step as done, and the two starter novels never came).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/sources/net.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/starter.dart';

void main() {
  setUp(() => Net.allowPrivateAddresses = true);
  tearDown(() => Net.allowPrivateAddresses = false);

  test('offline, the starter sources are not marked installed; online, both are', () async {
    var online = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final res = req.response;
      if (!online) {
        res.statusCode = 503;
      } else if (req.uri.path == '/plugins.min.json') {
        res.write(jsonEncode([
          for (final id in ['readnovelfull', 'royalroad'])
            {'id': id, 'name': id, 'site': 'https://$id.test/', 'lang': 'English', 'version': '1', 'url': '$base/$id.js'},
        ]));
      } else {
        res.write('exports.default = {}; // ${req.uri.path}');
      }
      await res.close();
    });
    final dir = Directory.systemTemp.createTempSync('tv_starter_sources');
    addTearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    final sources = SourceStore(dir, defaults: ['$base/plugins.min.json'], allowInsecure: true);

    await expectLater(Starter.installStarterSources(sources), throwsA(isA<StateError>()));
    expect(await sources.installed(), isEmpty);

    online = true;
    await Starter.installStarterSources(sources);
    expect((await sources.installed()).map((p) => p.id).toSet(), {'readnovelfull', 'royalroad'});
  });
}
