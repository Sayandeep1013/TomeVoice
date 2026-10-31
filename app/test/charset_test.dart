// Pages in charsets other than UTF-8: the charset is found (the server, the
// page's own <meta>, a byte order mark), UTF-8 and Latin-1 are read in Dart,
// and the rest go to the phone, which knows them all.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/sources/net.dart';

const _channel = MethodChannel('tomevoice/sources');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final asked = <String>[];

  setUp(() {
    asked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'decode') return null;
      final args = call.arguments as Map;
      final charset = args['charset'] as String;
      asked.add(charset);
      // The phone's answer for the charsets it is asked about here.
      return charset == 'unknown-x' ? null : 'decoded as $charset (${(args['bytes'] as Uint8List).length} bytes)';
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  NetResponse page(List<int> bytes, [String? contentType]) => NetResponse(
        status: 200,
        url: 'u',
        headers: {if (contentType != null) 'content-type': contentType},
        bytes: Uint8List.fromList(bytes),
      );

  test("the page's own charset is found and read by the phone", () async {
    final gbk = page(latin1.encode('<html><head><meta charset="gbk"><title>x</title>'));
    expect(await gbk.decode(), startsWith('decoded as gbk'));
    final old = page(latin1.encode('<meta http-equiv="Content-Type" content="text/html; charset=Big5">'));
    expect(await old.decode(), startsWith('decoded as big5'));
    final served = page(const [0x82, 0xa0], 'text/html; charset=Shift_JIS');
    expect(await served.decode(), 'decoded as shift_jis (2 bytes)');
    expect(asked, ['gbk', 'big5', 'shift_jis']);
  });

  test("UTF-8 and Latin-1 are read without the phone; a charset it does not know falls back", () async {
    expect(await page([0xef, 0xbb, 0xbf, ...utf8.encode('café')]).decode(), 'café', reason: 'the BOM is dropped');
    expect(await page(latin1.encode('café'), 'text/html; charset=ISO-8859-1').decode(), 'café');
    expect(asked, isEmpty);
    expect(await page(utf8.encode('café'), 'text/html; charset=unknown-x').decode(), 'café');
    expect(await page([0x93, 0x41, 0x94], 'text/html; charset=windows-1252').decode(), startsWith('decoded as'));
  });

  test("a plugin's own charset (fetchText's) wins over the page's", () async {
    expect(await page(latin1.encode('<meta charset="gbk">'), 'text/html; charset=utf-8').decode('EUC-KR'),
        startsWith('decoded as euc-kr'));
  });
}
