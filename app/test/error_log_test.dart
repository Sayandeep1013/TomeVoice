// The error log on the phone: a ring of the last errors, with nothing from
// a book in it, and the problem report the reader sees before sending it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/error_log.dart';
import 'package:tomevoice_spike/problem_report.dart';
import 'package:tomevoice_spike/settings_screen.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  late Directory tmp;
  final log = ErrorLog.instance;

  setUp(() {
    log.reset();
    tmp = Directory.systemTemp.createTempSync('tv_errors');
  });

  tearDown(() {
    log.reset();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> written() => [
        for (final line in File('${tmp.path}/${ErrorLog.fileName}').readAsLinesSync())
          if (line.isNotEmpty) Map<String, Object?>.from(jsonDecode(line) as Map),
      ];

  group('scrubbing', () {
    test('only the first line is kept, and not too much of it', () {
      expect(scrubError('FormatException: Unexpected character\nthe line of the book it was in\n   ^'),
          'FormatException: Unexpected character');
      expect(scrubError('x' * 1000).length, 240);
    });

    test('anything quoted goes, but the names of the code stay', () {
      expect(scrubError('ParseException: “My Secret Diary.epub” is no longer on the phone.'),
          'ParseException: "…" is no longer on the phone.');
      expect(scrubError('Exception: could not speak "It was a bright cold day"'), 'Exception: could not speak "…"');
      expect(scrubError("Bad state: 'a line from the book' was not found"), 'Bad state: "…" was not found');
      // Dart quotes types and its own sources: those are the app's, not the reader's.
      expect(scrubError("type 'Null' is not a subtype of type 'Map<String, dynamic>' in type cast"),
          "type 'Null' is not a subtype of type 'Map<String, dynamic>' in type cast");
      expect(scrubError("'package:flutter/src/widgets/text.dart': Failed assertion: line 3 pos 4: 'data != null'"),
          "'package:flutter/src/widgets/text.dart': Failed assertion: line 3 pos 4: \"…\"");
      // An apostrophe is not a quote.
      expect(scrubError("StateError: can't open it"), "StateError: can't open it");
    });

    test('links and file paths go, even with spaces in a name', () {
      expect(scrubError('HttpException: Connection closed, uri = https://www.royalroad.com/fiction/123/secret-novel'),
          'HttpException: Connection closed, uri = <link>');
      expect(
        scrubError('FileNotFoundException: /storage/emulated/0/Android/data/app.tomevoice/files/books/ab/My Book.epub: '
            'open failed: ENOENT (No such file or directory)'),
        'FileNotFoundException: <file>: open failed: ENOENT (No such file or directory)',
      );
      expect(scrubError("PathNotFoundException: Cannot open file, path = '/data/user/0/x/books/a b.json' (OS Error)"),
          'PathNotFoundException: Cannot open file, path = "…" (OS Error)');
      // A place in the code is not a path, nor is a sum.
      expect(scrubLine('#0 main (package:tomevoice_spike/main.dart:12:3)'), '#0 main (package:tomevoice_spike/main.dart:12:3)');
      expect(scrubError('RangeError: 3/4 is not 1/2'), 'RangeError: 3/4 is not 1/2');
    });

    test("a book's title, its author and a secret shelf's name never stay", () {
      final private = RegExp('(?<![\\p{L}\\p{N}_])(?:The Hidden Garden|Jane Roe)(?![\\p{L}\\p{N}_])',
          caseSensitive: false, unicode: true);
      expect(scrubError('StateError: no cover for the hidden garden by Jane Roe', private: private),
          'StateError: no cover for … by …');
    });
  });

  group('the ring', () {
    test('keeps the last fifty, oldest first, in a file of one entry a line', () async {
      await log.attach(tmp);
      for (var i = 0; i < 60; i++) {
        log.record(StateError('error $i'), StackTrace.current);
      }
      expect(log.entries, hasLength(ErrorLog.keep));
      expect(log.entries.first.message, 'Bad state: error 10');
      expect(log.entries.last.message, 'Bad state: error 59');
      await log.flush();
      final lines = written();
      expect(lines, hasLength(ErrorLog.keep));
      expect(lines.last['message'], 'Bad state: error 59');
      expect(lines.last['from'], 'app');
      expect('${lines.last['stack']}'.split('\n').length, lessThanOrEqualTo(ErrorLog.frames));
    });

    test('the same error again at once is counted, not kept twice', () {
      final stack = StackTrace.current;
      for (var i = 0; i < 3; i++) {
        log.record(StateError('the same'), stack);
      }
      log.record(StateError('another'), stack);
      expect([for (final e in log.entries) (e.message, e.count)], [('Bad state: the same', 3), ('Bad state: another', 1)]);
    });

    test("errors met before it was open are kept, with Android's crashes read from the file", () async {
      log.record(Exception('early'), null);
      // As ErrorLog.kt writes a crash: one line of JSON, UTC time.
      File('${tmp.path}/${ErrorLog.fileName}').writeAsStringSync(
        '${jsonEncode({
          'time': '2020-01-02T03:04:05.000Z',
          'version': '1.2.0',
          'from': 'android',
          'message': 'java.lang.IllegalStateException: "…"',
          'stack': 'at app.tomevoice.tomevoice_spike.ReadingCore.handle(ReadingCore.kt:12)',
        })}\n{"time": "cut short by the crash',
      );
      await log.attach(tmp);
      expect([for (final e in log.entries) e.from], ['android', 'app']);
      expect(log.entries.first.version, '1.2.0');
      expect(log.entries.last.message, 'Exception: early');
      // The version, known later, is given to this run's errors only.
      log.version = '1.3.0';
      expect([for (final e in log.entries) e.version], ['1.2.0', '1.3.0']);
    });

    test("the books' titles are taken out of what is kept, Android's lines too", () async {
      File('${tmp.path}/${ErrorLog.fileName}').writeAsStringSync('${jsonEncode({
        'time': '2020-01-02T03:04:05.000Z',
        'from': 'android',
        'message': 'java.lang.RuntimeException: no voice for Secret Diaries',
      })}\n');
      await log.attach(tmp);
      log.record(StateError('Secret Diaries has no chapters'), null);
      log.privateWords = ['Secret Diaries', 'A. N. Author', 'ab'];
      expect([for (final e in log.entries) e.message],
          ['java.lang.RuntimeException: no voice for …', 'Bad state: … has no chapters']);
      // From now on as well.
      log.record(StateError('and the secret diaries again'), null);
      expect(log.entries.last.message, 'Bad state: and the … again');
      await log.flush();
      expect(File('${tmp.path}/${ErrorLog.fileName}').readAsStringSync(), isNot(contains('Diaries')));
    });

    test("Flutter's own errors are kept by their first line, never what it adds about the widget", () {
      log.recordFlutter(FlutterErrorDetails(
        exception: FlutterError('A RenderFlex overflowed by 12 pixels on the right.\nThe overflowing Text("A line of the book")'),
        stack: StackTrace.current,
        context: ErrorDescription('building Text("Another line of the book")'),
      ));
      log.recordFlutter(const FlutterErrorDetails(exception: 'an image that would not load', silent: true));
      expect(log.entries.single.message, 'A RenderFlex overflowed by 12 pixels on the right.');
      expect(log.entries.single.stack, isNot(contains('book')));
    });

    test('cleared, nothing is kept', () async {
      await log.attach(tmp);
      log.record(StateError('gone'), null);
      await log.clear();
      expect(log.entries, isEmpty);
      expect(File('${tmp.path}/${ErrorLog.fileName}').readAsStringSync(), isEmpty);
    });
  });

  group('the report', () {
    const device = (android: '14', sdk: 34, maker: 'Nothing', model: 'A059');

    ErrorEntry error(int i, {String from = 'app'}) => ErrorEntry(
          time: DateTime.utc(2026, 10, 30, 14, i),
          version: '1.3.0',
          from: from,
          message: 'Bad state: error $i',
          stack: List.generate(12, (f) => '#$f frame$f (package:tomevoice_spike/x.dart:$f:1)').join('\n'),
        );

    test('says the app, Android and the phone, and the errors newest first', () {
      final r = problemReport(version: '1.3.0', device: device, errors: [error(1), error(2, from: 'android')]);
      expect(r.title, 'Problem in TomeVoice 1.3.0');
      expect(r.body, contains('- TomeVoice 1.3.0\n- Android 14 (API 34)\n- Nothing A059'));
      expect(r.body, contains('2026-10-30 14:02 UTC · 1.3.0 · Android\nBad state: error 2'));
      expect(r.body.indexOf('error 2'), lessThan(r.body.indexOf('error 1')));
      // Eight lines of each stack, no more.
      expect(r.body, contains('#7 frame7'));
      expect(r.body, isNot(contains('#8 frame8')));
      expect(r.body, contains('Say what you were doing'));
    });

    test('with an empty log it says so', () {
      final r = problemReport(version: '1.3.0', device: null, errors: const []);
      expect(r.body, contains('None: the error log on this phone is empty.'));
      expect(r.body, isNot(contains('Android')));
    });

    test('older errors give way, so the link that carries it still opens', () {
      final errors = [for (var i = 0; i < 50; i++) error(i)];
      final r = problemReport(version: '1.3.0', device: device, errors: errors, maxLink: 3000);
      expect(issueLink(r).toString().length, lessThanOrEqualTo(3000));
      expect(r.body, contains('error 49'));
      expect(r.body, isNot(contains('error 44')), reason: 'five at most');
      expect(r.body, contains('older errors are kept on the phone'));
      final full = problemReport(version: '1.3.0', device: device, errors: errors);
      expect(RegExp('Bad state: error').allMatches(full.body).length, reportErrors);
    });

    test('opens as a new issue on GitHub, filled in', () {
      final r = problemReport(version: '1.3.0', device: device, errors: [error(1)]);
      final link = issueLink(r);
      expect('${link.scheme}://${link.host}${link.path}', issuesUrl);
      expect(link.queryParameters['title'], r.title);
      expect(link.queryParameters['body'], r.body);
    });

    test("a phone's name says its maker once", () {
      expect(deviceName((android: '14', sdk: 34, maker: 'Google', model: 'Pixel 8')), 'Google Pixel 8');
      expect(deviceName((android: '14', sdk: 34, maker: 'samsung', model: 'SM-S911B')), 'Samsung SM-S911B');
      expect(deviceName((android: '14', sdk: 34, maker: 'Xiaomi', model: 'Xiaomi 13')), 'Xiaomi 13');
    });

    testWidgets('About shows the report word for word, and only opens it in the browser', (tester) async {
      final calls = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'appVersion' => '1.3.0',
          'deviceInfo' => {'android': '14', 'sdk': 34, 'maker': 'Nothing', 'model': 'A059'},
          'openUrl' => true,
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      log.record(StateError('the last one'), null);
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Report a problem'));
      await tester.pumpAndSettle();
      final shown = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      final report = problemReport(
        version: '1.3.0',
        device: (android: '14', sdk: 34, maker: 'Nothing', model: 'A059'),
        errors: log.entries,
      );
      expect(shown, '${report.title}\n\n${report.body}');
      expect(shown, contains('Bad state: the last one'));
      // Nothing has gone anywhere yet.
      expect(calls.where((c) => c.method == 'openUrl'), isEmpty);

      await tester.tap(find.text('Open GitHub'));
      await tester.pumpAndSettle();
      final opened = calls.singleWhere((c) => c.method == 'openUrl');
      expect((opened.arguments as Map)['url'], issueLink(report).toString());
      expect(find.byType(SelectableText), findsNothing);
    });
  });
}
