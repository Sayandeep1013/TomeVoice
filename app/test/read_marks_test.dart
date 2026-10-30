// Read marks: a web novel's chapters marked read or unread by hand, kept by
// their addresses, over what the place says; "Mark all above as read"; and
// a chapter marked unread being read again.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/novel_screen.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/read_marks.dart';
import 'package:tomevoice_spike/sources/models.dart';

const _channel = MethodChannel('tomevoice/tts');

const _plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');

List<ChapterItem> _chapters(int n) => [for (var i = 0; i < n; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'ch/$i')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which chapters show as read', () {
    test('with no marks, those before the place; none before the novel is begun', () {
      const m = ReadMarks.none;
      expect([for (var i = 0; i < 5; i++) m.isRead(i, 'ch/$i', 3)], [true, true, true, false, false]);
      expect([for (var i = 0; i < 5; i++) m.isRead(i, 'ch/$i', -1)], everyElement(isFalse));
    });

    test('a mark says otherwise for its chapter: read ahead, unread behind', () {
      final m = ReadMarks.none.marking(['ch/4'], asRead: true).marking(['ch/1'], asRead: false);
      expect([for (var i = 0; i < 6; i++) m.isRead(i, 'ch/$i', 3)], [true, false, true, false, true, false]);
    });

    test('marking one way undoes the other, and clearing leaves the place to say', () {
      var m = ReadMarks.none.marking(['ch/1', 'ch/2'], asRead: false);
      m = m.marking(['ch/2'], asRead: true);
      expect({'read': m.read, 'unread': m.unread}, {'read': {'ch/2'}, 'unread': {'ch/1'}});
      m = m.clearing(['ch/1', 'ch/2']);
      expect(m.isEmpty, isTrue);
      expect(m.isRead(1, 'ch/1', 3), isTrue);
    });

    test('the chapters before one: those above it oldest first', () {
      final paths = [for (final c in _chapters(5)) c.path];
      expect(chaptersBefore(paths, 3), ['ch/0', 'ch/1', 'ch/2']);
      expect(chaptersBefore(paths, 0), isEmpty);
      expect(chaptersBefore(paths, 9), paths);
    });

    test('marks follow their chapters to new addresses; one with none goes', () {
      final m = ReadMarks.none.marking(['a/1', 'a/2'], asRead: true).marking(['a/3'], asRead: false);
      final moved = m.mapped((p) => p == 'a/2' ? null : p.replaceFirst('a/', 'b/'));
      expect({'read': moved.read, 'unread': moved.unread}, {'read': {'b/1'}, 'unread': {'b/3'}});
    });

    test('kept as JSON and read back, a broken file read as none', () {
      final m = ReadMarks.none.marking(['x'], asRead: true).marking(['y'], asRead: false);
      final back = ReadMarks.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect({'read': back.read, 'unread': back.unread}, {'read': {'x'}, 'unread': {'y'}});
      expect(ReadMarks.fromJson('nonsense').isEmpty, isTrue);
      expect(ReadMarks.fromJson({'read': [1, 'z']}).read, {'z'});
    });
  });

  group('kept with the novel', () {
    late Directory tmp;
    late LibraryStore store;
    late String id;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tv_read_marks');
      ReadMarkStore.instance.reset();
      store = LibraryStore(tmp);
      id = (await store.addWebNovel(_plugin, SourceNovel(path: 'novel/1', name: 'Shadow', chapters: _chapters(6)))).id;
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test('in the novel\'s folder, read back by another copy of the app', () async {
      await ReadMarkStore.instance.mark(store, id, ['ch/4'], read: true);
      await ReadMarkStore.instance.mark(store, id, ['ch/1'], read: false);
      final f = File('${store.bookDir(id)}/read.json');
      expect(f.existsSync(), isTrue);
      ReadMarkStore.instance.reset();
      final again = await ReadMarkStore.instance.of(LibraryStore(tmp), id);
      expect({'read': again.read, 'unread': again.unread}, {'read': {'ch/4'}, 'unread': {'ch/1'}});

      // No marks left: no file.
      await ReadMarkStore.instance.replace(store, id, ReadMarks.none);
      expect(f.existsSync(), isFalse);
      expect((await ReadMarkStore.instance.of(store, id)).isEmpty, isTrue);
    });

    test('a chapter marked unread is read again by reaching it: its mark goes, others stay', () async {
      await ReadMarkStore.instance.mark(store, id, ['ch/1', 'ch/2'], read: false);
      await ReadMarkStore.instance.mark(store, id, ['ch/5'], read: true);
      await ReadMarkStore.instance.reached(store, id, 1);
      final m = await ReadMarkStore.instance.of(store, id);
      expect({'read': m.read, 'unread': m.unread}, {'read': {'ch/5'}, 'unread': {'ch/2'}});
      // A read chapter reached keeps its mark.
      await ReadMarkStore.instance.reached(store, id, 5);
      expect((await ReadMarkStore.instance.of(store, id)).read, {'ch/5'});
    });

    test('a novel removed and added again starts with none', () async {
      await ReadMarkStore.instance.mark(store, id, ['ch/3'], read: true);
      await store.remove(id);
      await store.addWebNovel(_plugin, SourceNovel(path: 'novel/1', name: 'Shadow', chapters: _chapters(6)));
      expect((await ReadMarkStore.instance.of(store, id)).isEmpty, isTrue);
    });
  });

  group('on the novel\'s page', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tv_read_page');
      ReadMarkStore.instance.reset();
      ListeningPrefs.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Future<void> settle(WidgetTester tester, bool Function() until) async {
      for (var i = 0; i < 60 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<ReadMarks> marksOf(WidgetTester tester, LibraryStore store, String id) async =>
        (await tester.runAsync(() => ReadMarkStore.instance.of(store, id)))!;

    testWidgets('picked chapters are marked read or unread, and all above one as read', (tester) async {
      phone(tester);
      final store = LibraryStore(tmp);
      final id = LibraryStore.webId('fake', 'novel/1');
      await tester.runAsync(
          () => store.addWebNovel(_plugin, SourceNovel(path: 'novel/1', name: 'Shadow', chapters: _chapters(5))));
      await tester.pumpWidget(MaterialApp(home: NovelScreen(store: store, plugin: _plugin, path: 'novel/1', name: 'Shadow')));
      await settle(tester, () => find.text('Chapter 5').evaluate().isNotEmpty);

      // One chapter: Mark as read.
      await tester.longPress(find.text('Chapter 5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mark as read or unread'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as unread'), findsNothing, reason: 'nothing picked is read yet');
      await tester.tap(find.text('Mark as read'));
      await settle(tester, () => find.text('Marked as read.').evaluate().isNotEmpty);
      expect((await marksOf(tester, store, id)).read, {'ch/4'});

      // All above one, oldest first: the chapters before it.
      await tester.pump(const Duration(seconds: 4));
      await tester.longPress(find.text('Chapter 3'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mark as read or unread'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark all above as read'));
      await settle(tester, () => find.text('Marked 2 chapters as read.').evaluate().isNotEmpty);
      expect((await marksOf(tester, store, id)).read, {'ch/0', 'ch/1', 'ch/4'});

      // Picked read ones can go back to unread.
      await tester.pump(const Duration(seconds: 4));
      await tester.longPress(find.text('Chapter 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chapter 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mark as read or unread'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as unread'));
      await settle(tester, () => find.text('Marked 2 chapters as unread.').evaluate().isNotEmpty);
      final m = await marksOf(tester, store, id);
      expect({'read': m.read, 'unread': m.unread}, {'read': {'ch/4'}, 'unread': {'ch/0', 'ch/1'}});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('newest first, the chapters before one are below it, and the menu says so', (tester) async {
      phone(tester);
      final store = LibraryStore(tmp);
      final id = LibraryStore.webId('fake', 'novel/1');
      ListeningPrefs.memory.newestFirstByNovel[id] = true;
      await tester.runAsync(
          () => store.addWebNovel(_plugin, SourceNovel(path: 'novel/1', name: 'Shadow', chapters: _chapters(4))));
      await tester.pumpWidget(MaterialApp(home: NovelScreen(store: store, plugin: _plugin, path: 'novel/1', name: 'Shadow')));
      await settle(tester, () => find.text('Chapter 4').evaluate().isNotEmpty);
      await tester.longPress(find.text('Chapter 3'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mark as read or unread'));
      await tester.pumpAndSettle();
      expect(find.text('Mark all above as read'), findsNothing);
      await tester.tap(find.text('Mark all below as read'));
      await settle(tester, () => find.text('Marked 2 chapters as read.').evaluate().isNotEmpty);
      expect((await marksOf(tester, store, id)).read, {'ch/0', 'ch/1'});
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
