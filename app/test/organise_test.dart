// The library past its shelves: tags, series, the orders and filters the
// shelf has, and books that look like another copy of one already there.
// None of it may tell of a book on a shut secret shelf.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, SourceKind;
import 'package:tomevoice_spike/duplicates.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/organise.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/series.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/text_print.dart';

void main() {
  group('a series found in a title', () {
    test('where the title names one', () {
      expect(seriesFromTitle('A Song of Ice and Fire 3'), (name: 'A Song of Ice and Fire', index: 3.0));
      expect(seriesFromTitle('Mistborn, Book Two'), (name: 'Mistborn', index: 2.0));
      expect(seriesFromTitle('Berserk Vol. 41'), (name: 'Berserk', index: 41.0));
      expect(seriesFromTitle('Overlord #14'), (name: 'Overlord', index: 14.0));
      expect(seriesFromTitle('Leviathan Wakes (The Expanse #1)'), (name: 'The Expanse', index: 1.0));
      expect(seriesFromTitle('The Way of Kings (The Stormlight Archive, Book 1)'),
          (name: 'The Stormlight Archive', index: 1.0));
      expect(seriesFromTitle('Star Wars Episode IV'), (name: 'Star Wars', index: 4.0));
      expect(seriesFromTitle('Discworld Volume 2.5'), (name: 'Discworld', index: 2.5));
    });

    test('and not where a number is only part of the title', () {
      for (final title in [
        'Fahrenheit 451',
        'Apollo 13',
        'Catch-22',
        'Blade Runner 2049',
        'The 39 Steps',
        'Nineteen Eighty-Four',
        '1984',
        'Pride and Prejudice',
        'The Way of Kings (Book 1)',
        'Book 3',
        'Poems (1850)',
        'Brave New World 77',
      ]) {
        expect(seriesFromTitle(title), isNull, reason: title);
      }
    });

    test('books before series were kept find theirs on reading; one the reader cleared stays clear', () {
      Map<String, Object?> json(String title, {Object? series = _absent, String source = 'epub'}) => {
            'id': '0123456789abcdef',
            'title': title,
            'source': source,
            if (series != _absent) 'series': series,
          };
      final old = LibraryEntry.fromJson(json('A Song of Ice and Fire 3'));
      expect((old.seriesName, old.seriesIndex), ('A Song of Ice and Fire', 3.0));
      expect(LibraryEntry.fromJson(json('A Song of Ice and Fire 3', series: '')).seriesName, isNull);
      expect(LibraryEntry.fromJson(json('Solo Leveling 2', source: 'web')).seriesName, isNull,
          reason: "a web novel's title is not asked");
      // Written and read back as it was.
      final kept = LibraryEntry.fromJson(Map<String, Object?>.from(jsonDecode(jsonEncode(old.toJson())) as Map));
      expect((kept.seriesName, kept.seriesIndex), ('A Song of Ice and Fire', 3.0));
      expect(old.toJson().containsKey('tags'), isFalse, reason: 'nothing written that was not there');
    });
  });

  group('a series found across the library', () {
    test('in the words titles share before their numbers, at the end or within', () {
      expect(seriesAcross([..._ice, ..._law]), [
        (name: 'A Song of Ice and Fire', index: 1.0),
        (name: 'A Song of Ice and Fire', index: 3.0),
        (name: 'A Song of Ice and Fire', index: 4.0),
        (name: 'A Song of Ice and Fire', index: 5.0),
        (name: 'The First Law', index: 1.0),
        (name: 'The First Law', index: 2.0),
        (name: 'The First Law', index: 3.0),
      ]);
      // Each alone names a series of its own, or none.
      expect(seriesFromTitle(_ice[1]), (name: 'A Storm of Swords A Song of Ice and Fire', index: 3.0));
      expect(seriesFromTitle(_law.first), isNull);
      // Case and separators aside; two copies of a book are not a series
      // of their own, and are in the one their title shares.
      final copies = seriesAcross([
        'A Game of Thrones: A Song of Ice and Fire, 1',
        'A GAME OF THRONES - a song of ice and fire 1',
        'A Storm of Swords (A Song of Ice and Fire #3)',
      ]);
      expect(copies, [
        (name: 'A Song of Ice and Fire', index: 1.0),
        (name: 'A Song of Ice and Fire', index: 1.0),
        (name: 'A Song of Ice and Fire', index: 3.0),
      ]);
    });

    test('a title joins a series the library has already, spelled as it is', () {
      expect(seriesAcross(['A Clash of Kings A Song of Ice and Fire 2'], named: ['A Song of Ice and Fire']),
          [(name: 'A Song of Ice and Fire', index: 2.0)]);
      expect(seriesAcross(['The First Law 4 Best Served Cold', 'The First Law, Book Five'], named: ['The first law']),
          [(name: 'The first law', index: 4.0), (name: 'The first law', index: 5.0)]);
    });

    test('a title that shares none names what it names alone', () {
      final alone = [
        'A Song of Ice and Fire 3',
        'Mistborn, Book Two',
        'Berserk Vol. 41',
        'Leviathan Wakes (The Expanse #1)',
        'Fahrenheit 451',
        'Apollo 13',
        'Catch-22',
        'Blade Runner 2049',
        'Pride and Prejudice',
      ];
      expect(seriesAcross(alone), [for (final t in alone) seriesFromTitle(t)]);
      expect(seriesAcross(alone, named: ['Mistborn', 'The Expanse']), [for (final t in alone) seriesFromTitle(t)]);
      // Nor do numbers that are only part of a title, beside another book.
      final beside = ['Fahrenheit 451', 'Fahrenheit 9/11', 'Apollo 13', 'Apollo 11', 'Catch-22', 'Catch-22 Again',
        'Blade Runner 2049', 'Blade Runner 2'];
      expect(seriesAcross(beside), [null, null, null, null, null, null, null, (name: 'Blade Runner', index: 2.0)]);
    });

    test('and not two books that only share a word, little words, or one place', () {
      // One word.
      expect(seriesAcross(['Ocean Dreams 2', 'Desert Dreams 3']),
          [(name: 'Ocean Dreams', index: 2.0), (name: 'Desert Dreams', index: 3.0)]);
      // One word and little ones: "of the King", "the King".
      expect(seriesAcross(['Rise of the King 2', 'Return of the King 3']),
          [(name: 'Rise of the King', index: 2.0), (name: 'Return of the King', index: 3.0)]);
      expect(seriesAcross(['Songs of the 2', 'Tales of the 3']),
          [(name: 'Songs of the', index: 2.0), (name: 'Tales of the', index: 3.0)]);
      // The same words before the same number: one place, not a series.
      expect(seriesAcross(['Learn Python 3 the Hard Way', 'Learn Python 3 in a Day']), [null, null]);
      expect(seriesAcross(['Harry Potter and the Order of the Phoenix 5', 'Song of the Phoenix 3']).map((s) => s?.name),
          ['Harry Potter and the Order of the Phoenix', 'Song of the Phoenix']);
    });

    test('thousands of books are looked through in moments', () {
      // 5,000 titles: 600 series of five, half with the series before the
      // number at the end and half with it before one within; and books in
      // none, some with a number that is only theirs.
      const first = ['Iron', 'Silver', 'Winter', 'Broken', 'Hidden', 'Burning', 'Silent', 'Golden', 'Shadow', 'Storm',
        'Glass', 'Ember', 'Frost', 'Crimson', 'Hollow', 'Wild', 'Black', 'Pale', 'Dust', 'Salt'];
      const second = ['Crown', 'Throne', 'Sea', 'Road', 'Tower', 'Empire', 'Song', 'Blade', 'Kingdom', 'River',
        'Gate', 'Forest', 'Star', 'Harbour', 'Wolf', 'Dawn', 'Archive', 'Saga', 'Covenant', 'Legacy', 'Accord',
        'Mountain', 'Lantern', 'Orchard', 'Circle', 'Tide', 'Compass', 'Garden', 'Engine', 'Library'];
      const books = ['The Long Night', 'A Cold Fire', 'Ashes and Dust', 'The Last Gate', 'Into the Dark'];
      final series = [for (final a in first) for (final b in second) 'The $a $b'];
      final titles = [
        for (var s = 0; s < series.length; s++)
          for (var b = 1; b <= 5; b++)
            s.isEven ? '${books[b - 1]} ${series[s]} $b' : '${series[s]} $b ${books[b - 1]} - Some Author',
        for (var i = 0; i < 1500; i++) '${books[i % 5]} and Other Stories of the ${first[i % 20]} ${second[i % 30]}',
        for (var i = 0; i < 500; i++) '${first[i % 20]} Poems of ${1500 + i}',
      ];
      expect(titles, hasLength(5000));
      final clock = Stopwatch()..start();
      final found = seriesAcross(titles);
      clock.stop();
      for (var s = 0; s < series.length; s++) {
        for (var b = 1; b <= 5; b++) {
          expect(found[s * 5 + b - 1], (name: series[s], index: b.toDouble()), reason: titles[s * 5 + b - 1]);
        }
      }
      expect(found.skip(3000).where((s) => s != null), isEmpty);
      // ignore: avoid_print
      print('Series found across 5,000 titles in ${clock.elapsedMilliseconds} ms');
      // Every title against every other would take many seconds.
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('the store', () {
    late Directory tmp;
    late LibraryStore store;

    setUp(() {
      LibraryStore.secretOpen.value = false;
      tmp = Directory.systemTemp.createTempSync('tv_organise');
      store = LibraryStore(tmp);
    });

    tearDown(() {
      store.hold();
      LibraryStore.secretOpen.value = false;
      tmp.deleteSync(recursive: true);
    });

    Future<LibraryEntry> add(String name, String text) async {
      final f = File('${tmp.path}/incoming/$name/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
      return store.importFile(PickedFile(path: f.path, name: name));
    }

    String story(String words) => 'Chapter 1\n\n${'$words. ' * 60}\n\nChapter 2\n\n${'And $words again. ' * 60}';

    test('tags: several a book, each once, spelled as the shelf spells them', () async {
      final a = await add('a.txt', story('The first one goes on'));
      final b = await add('b.txt', story('The second one wanders'));
      await store.setTags(a.id, ['Fantasy', 'to lend', 'fantasy ']);
      expect((await store.list()).firstWhere((e) => e.id == a.id).tags, ['Fantasy', 'to lend']);
      // A tag typed again in another case is the one already there.
      await store.tagBooks({b.id}, 'FANTASY');
      expect((await store.list()).firstWhere((e) => e.id == b.id).tags, ['Fantasy']);
      expect(tagsIn(await store.list()), [(name: 'Fantasy', count: 2), (name: 'to lend', count: 1)]);

      await store.tagBooks({a.id, b.id}, 'fantasy', on: false);
      expect(tagsIn(await store.list()), [(name: 'to lend', count: 1)]);

      await store.renameTag('to lend', 'To lend');
      expect((await store.list()).firstWhere((e) => e.id == a.id).tags, ['To lend']);
      await store.tagBooks({b.id}, 'Lent');
      await store.renameTag('Lent', 'to LEND');
      expect(tagsIn(await store.list()), [(name: 'To lend', count: 2)], reason: 'joined to the tag of that name');
      await store.renameTag('to lend', '');
      expect(tagsIn(await store.list()), isEmpty, reason: 'removed, from every book');

      // Kept in library.json, and through being read again.
      await store.setTags(a.id, ['Kept']);
      expect((await LibraryStore(tmp).list()).firstWhere((e) => e.id == a.id).tags, ['Kept']);
    });

    test('series: as the book says, the title says, or the reader puts it; and in its order', () async {
      final three = await add('A Song of Ice and Fire 3.txt', story('Winter is coming'));
      final one = await add('A Song of Ice and Fire 1.txt', story('The man who passes the sentence'));
      final other = await add('Other.txt', story('Nothing in a series'));
      expect((three.seriesName, three.seriesIndex), ('A Song of Ice and Fire', 3.0), reason: 'from its title');
      await store.setSeries(other.id, 'a song of ice and fire', 2);
      final shown = await store.list();
      expect(shown.firstWhere((e) => e.id == other.id).seriesName, 'A Song of Ice and Fire',
          reason: 'spelled as the shelf spells it');
      expect([for (final e in booksInSeries(shown, 'A song of ice and fire')) e.id], [one.id, other.id, three.id]);

      // Taken out of it, it stays out: its title is not asked again.
      await store.setSeries(three.id, '', null);
      final again = await LibraryStore(tmp).list();
      expect(again.firstWhere((e) => e.id == three.id).seriesName, isNull);
      expect(seriesIn(again), [(name: 'A Song of Ice and Fire', count: 2)]);
    });

    // library.json as an earlier build left it: each book with the series
    // it kept, the reader's, or none at all (no key).
    var kept = 0;
    Map<String, Object?> entry(String title, {Object? series = _absent, double? index, String source = 'epub'}) => {
          'id': (++kept).toRadixString(16).padLeft(16, '0'),
          'title': title,
          'authors': const <String>[],
          'source': source,
          'wordCount': 1000,
          'sourcePath': '',
          'addedAt': DateTime(2026, 1, 1).add(Duration(days: kept)).toIso8601String(),
          'category': 'reading',
          if (series != _absent) 'series': series,
          if (index != null) 'seriesIndex': index,
        };
    void keep(List<Map<String, Object?>> books) => File('${tmp.path}/library.json').writeAsStringSync(jsonEncode({
          'categories': [for (final c in Category.defaults) c.toJson()],
          'defaultCategory': 'reading',
          'books': books,
        }));

    /// Each book's series and number, by title.
    Map<String, (String?, double?)> seriesOf(Iterable<LibraryEntry> books) =>
        {for (final e in books) e.title: (e.seriesName, e.seriesIndex)};

    /// The same, as library.json has them.
    Map<String, (Object?, Object?)> onDisk() => {
          for (final b in (jsonDecode(File('${tmp.path}/library.json').readAsStringSync()) as Map)['books'] as List)
            (b as Map)['title'] as String: (b['series'], b['seriesIndex']),
        };

    test("books kept before series were get the series their titles share with the library's", () async {
      keep([
        for (final t in [..._ice, ..._law, 'Mistborn, Book Two', 'Fahrenheit 451']) entry(t),
        entry('Solo Leveling 2', source: 'web'),
        entry('Solo Leveling 3', source: 'web'),
      ]);
      final expected = {
        _ice[0]: ('A Song of Ice and Fire', 1.0),
        _ice[1]: ('A Song of Ice and Fire', 3.0),
        _ice[2]: ('A Song of Ice and Fire', 4.0),
        _ice[3]: ('A Song of Ice and Fire', 5.0),
        _law[0]: ('The First Law', 1.0),
        _law[1]: ('The First Law', 2.0),
        _law[2]: ('The First Law', 3.0),
        'Mistborn, Book Two': ('Mistborn', 2.0),
        'Fahrenheit 451': (null, null),
        'Solo Leveling 2': (null, null),
        'Solo Leveling 3': (null, null),
      };
      expect(seriesOf(await store.list()), expected);
      // Written as any change is, and read again as found.
      expect(onDisk()[_ice[1]], ('A Song of Ice and Fire', 3.0));
      expect(onDisk()[_law.first], ('The First Law', 1.0));
      final again = LibraryStore(tmp);
      expect(seriesOf(await again.list()), expected);
      again.hold();
    });

    test('titles that write a series two ways put it on the shelf once', () async {
      keep([entry('Star Wars: Thrawn 1'), entry('Star Wars Thrawn 2'), entry('Star Wars - Thrawn 3')]);
      final shown = await store.list();
      expect(seriesIn(shown), hasLength(1));
      expect([for (final e in booksInSeries(shown, seriesIn(shown).single.name)) e.seriesIndex], [1.0, 2.0, 3.0]);
    });

    test("a series an earlier build found in each title alone is found again; the reader's stays", () async {
      keep([
        // As builds that asked each title alone kept them.
        entry(_ice[0], series: 'A Game of Thrones A Song of Ice and Fire', index: 1),
        entry(_ice[1], series: 'A Storm of Swords A Song of Ice and Fire', index: 3),
        entry(_ice[2], series: 'A Feast for Crows A Song of Ice and Fire', index: 4),
        entry(_ice[3], series: 'A Dance with Dragons A Song of Ice and Fire', index: 5),
        // The reader's: a series, a number of their own, and none.
        entry('A Clash of Kings A Song of Ice and Fire 2', series: 'Westeros', index: 2),
        entry('The Hedge Knight A Song of Ice and Fire 7',
            series: 'The Hedge Knight A Song of Ice and Fire', index: 0.5),
        entry('The Sworn Sword A Song of Ice and Fire 8', series: ''),
      ]);
      final shown = await store.list();
      expect(seriesOf(shown), {
        _ice[0]: ('A Song of Ice and Fire', 1.0),
        _ice[1]: ('A Song of Ice and Fire', 3.0),
        _ice[2]: ('A Song of Ice and Fire', 4.0),
        _ice[3]: ('A Song of Ice and Fire', 5.0),
        'A Clash of Kings A Song of Ice and Fire 2': ('Westeros', 2.0),
        'The Hedge Knight A Song of Ice and Fire 7': ('The Hedge Knight A Song of Ice and Fire', 0.5),
        'The Sworn Sword A Song of Ice and Fire 8': (null, null),
      });
      expect(seriesLine(shown.firstWhere((e) => e.title == _ice[1])), 'Book 3 of A Song of Ice and Fire');
      final disk = onDisk();
      expect(disk[_ice[1]], ('A Song of Ice and Fire', 3.0));
      expect(disk['The Sworn Sword A Song of Ice and Fire 8'], ('', null), reason: 'still taken out of any');
      // Sort: Series has the four together, in their order.
      expect([for (final e in sortBooks(shown, LibrarySort.series)) e.title].where(_ice.contains), _ice);
    });

    test('a book added joins the series its title shares, and Sort: Series has them in order', () async {
      for (final t in _ice) {
        await add('$t.txt', story(t));
      }
      expect([for (final e in sortBooks(await store.list(), LibrarySort.series)) (e.seriesName, e.seriesIndex)], [
        ('A Song of Ice and Fire', 1.0),
        ('A Song of Ice and Fire', 3.0),
        ('A Song of Ice and Fire', 4.0),
        ('A Song of Ice and Fire', 5.0),
      ]);
      final clash = await add('A Clash of Kings A Song of Ice and Fire 2.txt', story('A clash of kings'));
      expect((clash.seriesName, clash.seriesIndex), ('A Song of Ice and Fire', 2.0));
      expect([for (final e in booksInSeries(await store.list(), 'A Song of Ice and Fire')) e.seriesIndex],
          [1.0, 2.0, 3.0, 4.0, 5.0]);
      expect(seriesIn(await store.list()), [(name: 'A Song of Ice and Fire', count: 5)]);
    });

    test('a series the book names, or the reader gives, stays whatever its title shares', () async {
      await add('${_ice[0]}.txt', story('Winter is coming'));
      final storm = await add('${_ice[1]}.txt', story('The day was grey and bitter cold'));
      final f = File('${tmp.path}/incoming/feast/feast.fb2')
        ..createSync(recursive: true)
        ..writeAsStringSync('<?xml version="1.0" encoding="utf-8"?>'
            '<FictionBook><description><title-info><book-title>${_ice[2]}</book-title>'
            '<sequence name="Song of Ice and Fire" number="4"/></title-info></description>'
            '<body><section><title><p>Prologue</p></title><p>${'The feast was long, and the night was cold. ' * 40}</p>'
            '</section></body></FictionBook>');
      final feast = await store.importFile(PickedFile(path: f.path, name: 'feast.fb2'));
      expect((feast.title, feast.seriesName, feast.seriesIndex), (_ice[2], 'Song of Ice and Fire', 4.0));
      await store.setSeries(storm.id, 'Westeros', 3);
      await add('${_ice[3]}.txt', story('A dance with dragons'));
      expect(seriesOf(await store.list()), {
        _ice[0]: ('A Song of Ice and Fire', 1.0),
        _ice[1]: ('Westeros', 3.0),
        _ice[2]: ('Song of Ice and Fire', 4.0),
        _ice[3]: ('A Song of Ice and Fire', 5.0),
      });
    });

    test("a shut secret shelf's books neither join a series shown nor change one", () async {
      final storm = await add('${_ice[1]}.txt', story('The day was grey and bitter cold'));
      final secret = await store.addCategory('Secret', secret: true);
      await store.moveBooks({storm.id}, secret.id);
      // Added with the shelf shut, a title shares nothing with its books.
      final game = await add('${_ice[0]}.txt', story('Winter is coming'));
      expect((game.seriesName, game.seriesIndex), ('A Game of Thrones A Song of Ice and Fire', 1.0));
      expect(seriesIn((await store.index()).entries), [(name: 'A Game of Thrones A Song of Ice and Fire', count: 1)]);
      // Read again with it shut, nothing changes, on the shelf or off it.
      final again = LibraryStore(tmp);
      final all = seriesOf(await again.list(all: true));
      again.hold();
      expect(all[_ice[0]], ('A Game of Thrones A Song of Ice and Fire', 1.0));
      expect(all[_ice[1]], ('A Storm of Swords A Song of Ice and Fire', 3.0));
      // Open, the two are one series.
      LibraryStore.secretOpen.value = true;
      final open = seriesOf(await store.list());
      expect(open[_ice[0]], ('A Song of Ice and Fire', 1.0));
      expect(open[_ice[1]], ('A Song of Ice and Fire', 3.0));
    });

    test('a book imported again keeps its tags and its series', () async {
      final text = story('A book that comes back');
      final a = await add('again.txt', text);
      await store.setTags(a.id, ['Kept']);
      await store.setSeries(a.id, 'Returns', 4);
      final again = await add('again.txt', text);
      expect(again.id, a.id);
      expect(again.tags, ['Kept']);
      expect((again.seriesName, again.seriesIndex), ('Returns', 4.0));
    });

    test('a shut secret shelf names nothing: no tag, series, language or count of its books', () async {
      final open = await add('open.txt', story('An open book about a garden'));
      final hidden = await add('hidden.txt', story('A secret book about a cellar'));
      await store.setTags(open.id, ['Garden']);
      await store.setTags(hidden.id, ['Private', 'garden']);
      await store.setSeries(hidden.id, 'Cellar Tales', 1);
      final secret = await store.addCategory('Secret', secret: true);
      await store.moveBooks({hidden.id}, secret.id);

      final shown = (await store.index()).entries;
      expect(tagsIn(shown), [(name: 'Garden', count: 1)]);
      expect(seriesIn(shown), isEmpty);
      // A tag typed with the shelf shut never takes its spelling from it.
      expect(tagNamed('PRIVATE', shown), 'PRIVATE');
      // Narrowed to a tag only its books had, the shelf shows all, and says
      // nothing of it.
      const onlyPrivate = ShelfFilter(tags: {'private'});
      expect(onlyPrivate.within(shown).isEmpty, isTrue);
      expect(const ShelfFilter(series: {'cellar tales'}).within(shown).isEmpty, isTrue);
      // Renaming a tag with the shelf shut leaves its books as they were.
      await store.renameTag('garden', 'Gardens');
      LibraryStore.secretOpen.value = true;
      final all = (await store.index()).entries;
      expect(all.firstWhere((e) => e.id == hidden.id).tags, ['Private', 'Garden']);
      expect(all.firstWhere((e) => e.id == open.id).tags, ['Gardens']);
      expect([for (final t in tagsIn(all)) t.name], ['Garden', 'Gardens', 'Private']);
      expect(seriesIn(all), [(name: 'Cellar Tales', count: 1)], reason: 'open, it is all there');
    });

    test("a book removed from an open shelf leaves its marks, saying so", () async {
      // What Saved makes of it: saved_test and secret_shelf_test.
      MarkStore.instance.reset();
      await MarkStore.instance.attach(tmp);
      addTearDown(MarkStore.instance.reset);
      final a = await add('gone.txt', story('A book about to go'));
      await MarkStore.instance
          .add(bookId: a.id, bookTitle: 'gone', kind: MarkKind.quote, at: ReadingCursor.zero, text: 'A book about to go.');
      await store.remove(a.id);
      expect(MarkStore.instance.forBook(a.id).single.left, isNotNull);
      final file = jsonDecode(File('${tmp.path}/marks.json').readAsStringSync()) as List;
      expect((file.single as Map)['left'], isA<String>(), reason: 'kept in marks.json, and so in backups');
    });
  });

  group('order', () {
    LibraryEntry book(String id, String title,
            {List<String> authors = const [], String? series, double? index, double progress = 0, int added = 0}) =>
        LibraryEntry(
          id: id,
          title: title,
          authors: authors,
          source: SourceKind.epub,
          wordCount: 1000,
          sourcePath: '',
          addedAt: DateTime(2026, 1, 1).add(Duration(days: added)),
          series: series ?? '',
          seriesIndex: index,
          progress: progress,
        );

    test('by author: family names, as a shelf of books is; their series in order', () {
      final books = [
        book('1', 'Mansfield Park', authors: ['Jane Austen']),
        book('2', 'The Dispossessed', authors: ['Ursula K. Le Guin']),
        book('3', 'Persuasion', authors: ['Austen, Jane']),
        book('4', 'A Clash of Kings', authors: ['George R. R. Martin'], series: 'A Song of Ice and Fire', index: 2),
        book('5', 'A Game of Thrones', authors: ['George R. R. Martin'], series: 'A Song of Ice and Fire', index: 1),
        book('6', 'Anonymous Notes'),
        book('7', 'Strength to Love', authors: ['Martin Luther King, Jr.']),
        book('8', 'Memoirs of a Midget', authors: ['Walter de la Mare']),
      ];
      expect([for (final e in sortBooks(books, LibrarySort.author)) e.id], ['1', '3', '8', '7', '2', '5', '4', '6']);
      expect(authorKey(['Ursula K. Le Guin']).startsWith('le guin'), isTrue);
      expect(familyNames(['J. Austen']).intersection(familyNames(['Austen, Jane'])), {'austen'});
    });

    test('by series: each in its order, books in none after', () {
      final books = [
        book('a', 'Zebra'),
        book('b', 'Book Three', series: 'Trilogy', index: 3),
        book('c', 'Book One', series: 'Trilogy', index: 1),
        book('d', 'Another', series: 'Duology', index: 2),
        book('e', 'Apple'),
        book('f', 'Book Two', series: 'trilogy', index: 2),
      ];
      expect([for (final e in sortBooks(books, LibrarySort.series)) e.id], ['d', 'c', 'f', 'b', 'e', 'a']);
      expect([for (final e in sortBooks(books, LibrarySort.title)) e.id], ['d', 'e', 'c', 'b', 'f', 'a']);
    });

    test('filters: a state, a format, a language, a tag, a series; each kind narrows', () {
      final epub = book('1', 'One', progress: 0.4);
      final done = book('2', 'Two', progress: 1);
      final fresh = book('3', 'Three');
      expect(ReadState.of(epub), ReadState.reading);
      expect(ReadState.of(done), ReadState.finished);
      expect(ReadState.of(fresh), ReadState.unread);
      const f = ShelfFilter(states: {ReadState.unread, ReadState.finished});
      expect([epub, done, fresh].where(f.matches).map((e) => e.id), ['2', '3']);
      expect(f.copyWith(formats: {'PDF'}).matches(done), isFalse);
      expect(f.copyWith(formats: {'EPUB'}).matches(done), isTrue);
    });
  });

  group('copies', () {
    LibraryEntry book(String id, String title, {List<String> authors = const [], String? print, SourceKind? source}) =>
        LibraryEntry(
          id: id,
          title: title,
          authors: authors,
          source: source ?? SourceKind.epub,
          wordCount: 1000,
          sourcePath: '',
          addedAt: DateTime(2026),
          textPrint: print,
        );

    // The same novel twice, and another book. The second copy as another
    // file has it: a title page and contents first, other quotes and
    // dashes, every tenth sentence elsewhere (a footnote taken out).
    final words = List.generate(3000, (i) => ['the', 'garden', 'was', 'quiet', 'when', 'Anna', 'came', 'home', 'w$i'][i % 9]);
    final novel = [for (var i = 0; i < words.length; i += 12) '${words.skip(i).take(12).join(' ')}.'];
    final asPdf = [
      'The Garden. A Novel. Contents: One, Two, Three.',
      for (var i = 0; i < novel.length; i++)
        if (i % 10 != 9) novel[i].replaceAll('the', '“The”').replaceAll('.', ' —'),
    ];
    final another = [for (var i = 0; i < 300; i++) 'A different book entirely, its sentence number $i of many.'];

    test("a book's print is like another copy's, and unlike another book's", () {
      final a = textPrint(novel)!, b = textPrint(asPdf)!, c = textPrint(another)!;
      expect(printLikeness(a, a), 1);
      expect(printLikeness(a, b), greaterThan(0.4));
      expect(printLikeness(a, c), lessThan(0.1));
      expect(textPrint(['Too short to say.']), isNull);
    });

    test('found by print, or by title and author; never two volumes, never a web novel', () {
      final epub = book('a', 'Pride and Prejudice', authors: ['Jane Austen'], print: textPrint(novel));
      final pdf = book('b', 'pride_and_prejudice', print: textPrint(asPdf), source: SourceKind.pdf);
      final txt = book('c', 'Pride & Prejudice (Penguin Classics)', authors: ['Austen, Jane']);
      final other = book('d', 'Emma', authors: ['Jane Austen'], print: textPrint(another));
      final sameTitleOtherText = book('e', 'Pride and Prejudice', authors: ['J. Austen'], print: textPrint(another));
      expect(whySame(epub, pdf), 'The same text');
      expect(whySame(epub, txt), 'The same title and author');
      expect(whySame(epub, other), isNull);
      expect(whySame(epub, sameTitleOtherText), isNull, reason: 'their texts say they differ');
      final v1 = LibraryEntry.fromJson({'id': '1', 'title': 'Saga 1', 'source': 'epub', 'series': 'Saga', 'seriesIndex': 1});
      final v2 = LibraryEntry.fromJson({'id': '2', 'title': 'Saga 1', 'source': 'epub', 'series': 'Saga', 'seriesIndex': 2});
      expect(whySame(v1, v2), isNull);
      final web = book('w', 'Pride and Prejudice', authors: ['Jane Austen'], source: SourceKind.web);
      expect(whySame(epub, web), isNull);

      final groups = duplicateGroups([epub, other, pdf, txt]);
      expect(groups, hasLength(1));
      expect(groups.single.map((e) => e.id), unorderedEquals(['a', 'b', 'c']));
    });

    test('a book imported is printed; one shown as a copy is only among the books shown', () async {
      LibraryStore.secretOpen.value = false;
      final tmp = Directory.systemTemp.createTempSync('tv_copies');
      final store = LibraryStore(tmp);
      try {
        Future<LibraryEntry> add(String name, List<String> text) async {
          final f = File('${tmp.path}/incoming/$name/$name')
            ..createSync(recursive: true)
            ..writeAsStringSync(text.join('\n\n'));
          return store.importFile(PickedFile(path: f.path, name: name));
        }

        final first = await add('garden.txt', novel);
        expect(first.textPrint, isNotNull);
        final copy = await add('garden copy.md', asPdf);
        expect(copiesOf(copy, [first]).single.$2, 'The same text');
        final secret = await store.addCategory('Secret', secret: true);
        await store.moveBooks({first.id}, secret.id);
        final shown = (await store.index()).entries;
        expect(duplicateGroups(shown), isEmpty, reason: 'its copy on the shut shelf is not named');
        expect(copiesOf(copy, shown.where((e) => e.id != copy.id)), isEmpty);
        // A book read before prints were kept gets one when it is opened.
        final raw = Map<String, Object?>.from(jsonDecode(File('${tmp.path}/library.json').readAsStringSync()) as Map);
        File('${tmp.path}/library.json').writeAsStringSync(jsonEncode({
          ...raw,
          'books': [for (final b in raw['books'] as List) {...(b as Map), 'print': null}..remove('print')],
        }));
        final fresh = LibraryStore(tmp);
        expect((await fresh.list(all: true)).every((e) => e.textPrint == null), isTrue);
        await fresh.loadLayout(copy.id);
        expect((await fresh.list(all: true)).firstWhere((e) => e.id == copy.id).textPrint, isNotNull);
        fresh.hold();
      } finally {
        store.hold();
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

const _absent = Object();

// As a real library has them, with nothing in their files to say.
const _ice = [
  'A Game of Thrones A Song of Ice and Fire 1',
  'A Storm of Swords A Song of Ice and Fire 3',
  'A Feast for Crows A Song of Ice and Fire 4',
  'A Dance with Dragons A Song of Ice and Fire 5',
];
const _law = [
  'The First Law 1 The Blade Itself - Joe Abercrombie',
  'The First Law 2 Before They Are Hanged - Joe Abercrombie',
  'The First Law 3 Last Argument of Kings - Joe Abercrombie',
];
