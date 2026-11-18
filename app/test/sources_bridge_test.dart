// A source worker never calls the platform itself: its calls go to the main
// isolate (SourcesBridge.relay). One that ended while a web view was still
// loading a page for it made Flutter's engine end the app when the answer
// came (11 November 2026: "Check failed: did_send").

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/sources/bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tomevoice/sources');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    SourcesBridge.relay = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test("with a relay, a worker's calls go through it and never to the channel", () async {
    final onChannel = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      onChannel.add(call.method);
      return null;
    });
    final relayed = <(String, Map<String, Object?>?)>[];
    SourcesBridge.relay = (method, args) async {
      relayed.add((method, args));
      return switch (method) {
        'browserFetch' => <Object?, Object?>{'html': '<p>hi</p>', 'url': 'https://example.org/c1'},
        'decode' => 'text',
        _ => null,
      };
    };
    final page = await SourcesBridge.browserFetch('https://example.org/c1', 'agent');
    expect(page?['html'], '<p>hi</p>');
    expect(await SourcesBridge.decode(Uint8List.fromList([1, 2]), 'GBK'), 'text');
    // An answer of the wrong kind is no answer.
    expect(await SourcesBridge.appIsOpen(), isFalse);
    expect(relayed.map((r) => r.$1), ['browserFetch', 'decode', 'appIsOpen']);
    expect(relayed.first.$2?['url'], 'https://example.org/c1');
    expect(onChannel, isEmpty);
  });

  test('on the main isolate, a relayed call is made on the channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'decode' ? 'made here' : null);
    expect(await SourcesBridge.answer('decode', {'bytes': Uint8List(0), 'charset': 'GBK'}), 'made here');
  });
}
