// A shared link to a web novel on an installed source's site opens the
// novel there: the source found by the link's site, the novel's path by
// asking the source for each likely one (a chapter's link climbs to its
// novel); any other link is read as a page.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/novel_link.dart';
import 'package:tomevoice_spike/sources/models.dart';

const _royal = PluginInfo(id: 'royalroad', name: 'Royal Road', site: 'https://www.royalroad.com/', lang: 'English', version: '1', url: 'u');
const _full = PluginInfo(id: 'readnovelfull', name: 'ReadNovelFull', site: 'https://readnovelfull.com/', lang: 'English', version: '1', url: 'u');

void main() {
  test('the source is the one whose site the link is on, with or without www.', () {
    expect(sourcesFor(Uri.parse('https://royalroad.com/fiction/1/x'), [_royal, _full]), [_royal]);
    expect(sourcesFor(Uri.parse('https://www.readnovelfull.com/a.html'), [_royal, _full]), [_full]);
    expect(sourcesFor(Uri.parse('https://en.wikipedia.org/wiki/Novel'), [_royal, _full]), isEmpty);
  });

  test("the novel's likely paths: the link's own, or the novel above a chapter", () {
    expect(novelPathsOf(Uri.parse('https://www.royalroad.com/fiction/21220/mother-of-learning'), _royal.site),
        ['fiction/21220/mother-of-learning']);
    expect(
      novelPathsOf(
          Uri.parse('https://www.royalroad.com/fiction/21220/mother-of-learning/chapter/301778/1-good-morning-brother'),
          _royal.site),
      ['fiction/21220/mother-of-learning', 'fiction/21220/mother-of-learning/chapter/301778/1-good-morning-brother'],
    );
    expect(novelPathsOf(Uri.parse('https://readnovelfull.com/shadow-slave/chapter-1-nightmare-begins.html'), _full.site),
        ['shadow-slave', 'shadow-slave.html', 'shadow-slave/chapter-1-nightmare-begins.html']);
    expect(novelPathsOf(Uri.parse('https://readnovelfull.com/shadow-slave.html'), _full.site), ['shadow-slave.html']);
  });

  test('found by asking the source; a link on no source, or no novel there, is null', () async {
    final asked = <String>[];
    Future<String?> nameOf(PluginInfo p, String path) async {
      asked.add('${p.id}:$path');
      return path == 'shadow-slave.html' ? 'Shadow Slave' : null;
    }

    final found = await novelOfLink(
      Uri.parse('https://readnovelfull.com/shadow-slave/chapter-1-nightmare-begins.html'),
      installed: () async => [_royal, _full],
      nameOf: nameOf,
    );
    expect(found?.plugin.id, 'readnovelfull');
    expect(found?.path, 'shadow-slave.html');
    expect(found?.name, 'Shadow Slave');
    // The most likely first; stopped once found.
    expect(asked, ['readnovelfull:shadow-slave', 'readnovelfull:shadow-slave.html']);

    asked.clear();
    expect(await novelOfLink(Uri.parse('https://en.wikipedia.org/wiki/Novel'), installed: () async => [_royal, _full], nameOf: nameOf),
        isNull);
    expect(asked, isEmpty);
    expect(await novelOfLink(Uri.parse('https://www.royalroad.com/forums'), installed: () async => [_royal], nameOf: nameOf),
        isNull);
  });
}
