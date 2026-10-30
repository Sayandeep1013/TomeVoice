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
