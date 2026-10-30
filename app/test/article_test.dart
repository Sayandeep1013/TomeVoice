// Reading a web page as an article: five saved-page shapes, each wrapped in
// the furniture real sites put round their text, the pages to refuse, and
// the forgiving parser underneath.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/article.dart';
import 'package:tomevoice_spike/html_tree.dart';

import 'article_pages.dart';

/// The article as the app makes it a book: its HTML through the documents
/// package, under a .html name.
Book bookOf(Article a) => ingestBytes(Uint8List.fromList(utf8.encode(a.html)), filename: 'article.html');

/// What the voice says, a sentence a line (silent note markers left out).
String spoken(Book book) => [
      for (final u in flattenSpeakable(book)) spokenText(u.text, u.silent).text,
    ].join('\n');

List<Block> blocksOf(Book book) => [for (final s in book.sections) ...s.blocks];

void expectAll(String text, List<String> kept, List<String> dropped) {
  for (final k in kept) {
    expect(text, contains(k), reason: 'kept: $k');
  }
  for (final d in dropped) {
    expect(text, isNot(contains(d)), reason: 'dropped: $d');
  }
}

void main() {
  group('extraction', () {
    test('a news article: its text, title, byline, site and date; the furniture goes', () {
      final url = Uri.parse('https://dailyplanet.example/science/2026/mar/03/quieter-rice');
      final a = extractArticle(newsPage, url: url);
      expect(a.title, 'Scientists find a quieter way to grow rice', reason: 'og:title without the site');
      expect(a.byline, 'Jane Doe', reason: 'schema.org author; the meta author is an address');
      expect(a.site, 'The Daily Planet');
      expect(dateLabel(a.published!), '3 March 2026');
      expect(a.description, 'From The Daily Planet · 3 March 2026\n$url');
      expectAll(a.text, [
        'Farmers in three provinces',
        '“We expected the yield to fall,” said Dr Li Wei',
        'Rice paddies are among the largest',
        'How it works',
        'Fields are drained for seven days',
        'They are flooded again',
        'The surprise was how little',
        'The researchers now want to know',
        'A paddy left to dry for a week in May',
      ], [
        'We use cookies', 'Accept all', 'Sport', 'Culture', 'Search', 'Share on Twitter', 'Email',
        'Advertisement', 'Related', 'Drought hits the wheat belt', 'Get the Planet', 'newsletter', 'Topics',
        'Great news for the planet', 'Comments', 'Most read', 'Ten things to do', 'All rights reserved',
        'Script text', 'color: red', 'By Jane Doe', 'Scientists find',
      ]);

      final book = bookOf(a);
      final blocks = blocksOf(book);
      expect(blocks.first.role, BlockRole.heading);
      expect(blocks.first.text, a.title);
      expect(blocks.where((b) => b.text == a.title), hasLength(1), reason: 'the headline once');
      final caption = blocks.firstWhere((b) => b.text.startsWith('A paddy left'));
      expect(caption.role, BlockRole.caption, reason: 'a figure keeps its caption, shown not read');
      expect(blocks.firstWhere((b) => b.text.startsWith('From The Daily Planet')).role, BlockRole.caption);
      expect(blocks.firstWhere((b) => b.text.startsWith('The surprise')).role, BlockRole.quote);
      expect(blocks.firstWhere((b) => b.text.startsWith('Fields are drained')).role, BlockRole.listItem);
      final voice = spoken(book);
      expect(voice, startsWith('Scientists find a quieter way to grow rice\nBy Jane Doe\nFarmers in three'));
      expect(voice, isNot(contains('A paddy left')));
      expect(voice, isNot(contains('From The Daily Planet')));
    });

    test('a blog with a sidebar and comments: the post alone', () {
      final a = extractArticle(blogPage, url: Uri.parse('https://janes-allotment.example/2026/04/12/slow-garden/'));
      expect(a.title, 'Notes from a slow garden', reason: '"– Jane\'s Allotment" is the site');
      expect(a.byline, 'Jane');
      expect(a.site, 'janes-allotment.example', reason: 'no site name given: its address');
      expect(dateLabel(a.published!), '12 April 2026', reason: 'the date as the site wrote it, not moved to UTC');
      expectAll(a.text, [
        'This spring I decided to do less',
        'The broad beans went in late',
        'What I planted',
        'Broad beans, two short rows',
        'Early potatoes, in sacks by the shed',
        'Sweet peas along the fence',
        'The corner I left alone',
      ], [
        'Skip to content', 'Vegetables, weather', 'Home', 'Recipes', 'Posted on', 'Share this', 'Twitter',
        'The late frost', 'Posted in', 'Lovely post', 'blackfly were terrible', 'Leave a Reply', 'About me',
        'allotment in the north', 'Archives', 'Proudly powered', 'Notes from a slow garden',
      ]);
      expect(a.words, inInclusiveRange(100, 130));
    });

    test('a Wikipedia page: the article, its notes shown but not read', () {
      final a = extractArticle(wikiPage, url: Uri.parse('https://en.wikipedia.org/wiki/Alpine_swift'));
      expect(a.title, 'Alpine swift', reason: '" - Wikipedia" is the site');
      expect(a.byline, isNull);
      expect(a.site, 'en.wikipedia.org');
      expect(a.published, isNull);
      expectAll(a.text, [
        'is a species of bird in the swift family',
        'Like other swifts',
        'Description',
        'much larger than the common swift',
        'Behaviour',
        'It nests in colonies',
      ], [
        'edit', 'Contents', '1 Description', 'Kingdom', 'Animalia', 'Common swift', 'Pallid swift', 'Categories',
        'Apodidae', 'Navigation menu', 'Log in', 'last edited', 'Creative Commons', 'From Wikipedia',
      ]);

      final book = bookOf(a);
      final notes = blocksOf(book).where((b) => b.role == BlockRole.footnote).map((b) => b.text).join('\n');
      expect(notes, contains('BirdLife International'), reason: 'the references are notes');
      expect(notes, contains('Non-stop flight'));
      final voice = spoken(book);
      expectAll(voice, [
        'winters in Africa.',
        'during long migrations.',
      ], [
        'BirdLife', 'Non-stop flight', 'References', '[1]', '[2]',
      ]);
    });

    test('a Medium post: no author box, read time, claps or more stories', () {
      final a = extractArticle(
        mediumPage,
        url: Uri.parse('https://medium.com/@samrivera/the-quiet-joy-of-reading-aloud-1a2b3c'),
      );
      expect(a.title, 'The quiet joy of reading aloud');
      expect(a.byline, 'Sam Rivera');
      expect(a.site, 'Medium');
      expect(dateLabel(a.published!), '14 February 2026');
      expectAll(a.text, [
        'Photo by Someone on Unsplash',
        'My grandmother read to me every night',
        'I stumbled over half the words',
        'Why the voice matters',
        'A sentence read aloud has to be understood',
        'Reading aloud is the slowest way to read',
        'for page in book:',
        'These days I listen more than I read',
      ], [
        'The quiet joy', 'Sam Rivera', '6 min read', 'Feb 14, 2026', '1.2K', 'Follow', 'Sign in', 'Write',
        'Responses', 'More from', 'Ten books I reread', 'Recommended from Medium', 'not text', 'About', 'Help',
      ]);
      final blocks = blocksOf(bookOf(a));
      expect(blocks.firstWhere((b) => b.text.startsWith('for page')).role, BlockRole.code);
      expect(blocks.firstWhere((b) => b.text.startsWith('Reading aloud is')).role, BlockRole.quote);
      expect(blocks.firstWhere((b) => b.text.startsWith('Photo by')).role, BlockRole.caption);
    });

    test('a page that is mostly navigation has no article', () {
      expect(
        () => extractArticle(shopPage, url: Uri.parse('https://shop.example/')),
        throwsA(isA<ArticleProblem>().having((p) => p.message, 'message', 'There is no article on that page to read.')),
      );
    });

    test('pages to refuse say why: a browser check, a sign-in wall, a page drawn by script', () {
      Matcher problem(String start, {bool browse = false}) => throwsA(isA<ArticleProblem>()
          .having((p) => p.message, 'message', startsWith(start))
          .having((p) => p.browse, 'browse', browse));
      const cloudflare = '<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>'
          '<div id="challenge-running">Checking if the site connection is secure</div>'
          '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script></body></html>';
      expect(() => extractArticle(cloudflare, url: Uri.parse('https://news.example/a')),
          problem(browserCheckMessage, browse: true));

      const login = '<html><body><h1>Sign in</h1><form><input name="user"><input type="password" name="pw">'
          '<button>Sign in</button></form><p>Welcome back. Sign in to read your saved stories.</p></body></html>';
      expect(() => extractArticle(login, url: Uri.parse('https://news.example/account/login?next=/a')),
          problem('That page asks you to sign in first', browse: true));
      expect(() => extractArticle(login, url: Uri.parse('https://forum.example/thread/12')),
          problem('That page asks you to sign in first', browse: true), reason: 'a password box and little else');

      final paywall = '<html><body><article><h1>Big story</h1><p>${'The first lines of a story that goes on. ' * 4}</p>'
          '<div class="gate"><p>Subscribe to continue reading. Already a subscriber? Log in.</p></div></article></body></html>';
      expect(() => extractArticle(paywall, url: Uri.parse('https://paper.example/big-story')),
          problem('That page asks you to sign in first', browse: true));

      const app = '<!doctype html><html><head><title>Reader</title></head><body><div id="root"></div>'
          '<script>render(document.getElementById("root"))</script></body></html>';
      expect(() => extractArticle(app, url: Uri.parse('https://app.example/post/1')),
          problem('There is no article on that page to read.'));
    });

    test('a long article with a login box in its header is still read', () {
      final page = '<html><body><header><form><input type="password"></form></header><article><h1>Long read</h1>'
          '${'<p>A paragraph of the long read, with enough words in it to count as text.</p>' * 12}</article></body></html>';
      final a = extractArticle(page, url: Uri.parse('https://mag.example/long-read'));
      expect(a.words, greaterThan(100));
    });

    test('what is written out is XML the book parser reads, whatever the page held', () {
      final page = '<html><head><title>Fish &amp; chips</title></head><body><article>'
          '<p>Fish &amp; chips cost < 5 pounds, "always" and \'forever\' & more${String.fromCharCode(0)}${String.fromCharCode(0x0B)} here.</p>'
          '<p lang="fr">Un paragraphe en français, assez long pour compter comme du texte.</p>'
          '<p>A third paragraph with more than enough words to make an article of it.</p>'
          '<figure><img src="x.jpg"><figcaption>A caption &lt;b&gt;</figcaption></figure></article></body></html>';
      final a = extractArticle(page, url: Uri.parse('https://food.example/chips'));
      expect(a.title, 'Fish & chips');
      final blocks = blocksOf(bookOf(a));
      // The caption has its own role only when the XML parser read the file
      // (the lenient fallback has none).
      expect(blocks.where((b) => b.role == BlockRole.caption).map((b) => b.text), contains('A caption <b>'));
      expect(blocks.map((b) => b.text), contains('Fish & chips cost < 5 pounds, "always" and \'forever\' & more here.'));
      expect(blocks.firstWhere((b) => b.text.startsWith('Un paragraphe')).language, 'fr');
    });

    test('a table laid out to hold the text is read; a table of data is not', () {
      final page = '<html><body><table><tr><td class="nav"><a href="/">Home</a></td><td>'
          '${'<p>Text of an old page laid out in a table, long enough to be a paragraph.</p>' * 6}'
          '<table class="data"><tr><td>Year</td><td>1999</td></tr></table></td></tr></table></body></html>';
      final a = extractArticle(page, url: Uri.parse('https://old.example/page.html'));
      expect(a.text, contains('Text of an old page'));
      expect(a.text, isNot(contains('1999')));
    });
  });

  group('parser', () {
    String texts(HtmlNode n) => n.descendants.where((d) => d.isText).map((d) => d.text.trim()).where((t) => t.isNotEmpty).join('|');

    test('it closes what pages leave open', () {
      final doc = parseHtml('<ul><li>one<li>two</ul><p>a<p>b<div>c</div><dl><dt>t<dd>d</dl>'
          '<table><tr><td>x<td>y<tr><td>z</table>');
      final els = doc.elements.toList();
      expect(els.where((e) => e.tag == 'li').map((e) => e.textContent), ['one', 'two']);
      expect(els.where((e) => e.tag == 'p').map((e) => e.textContent), ['a', 'b']);
      expect(els.firstWhere((e) => e.tag == 'div').parent!.tag, isNot('p'), reason: 'a div ends an open p');
      expect(els.where((e) => e.tag == 'td').map((e) => e.textContent), ['x', 'y', 'z']);
      expect(els.where((e) => e.tag == 'tr'), hasLength(2));
      expect(els.where((e) => e.tag == 'dd').single.textContent, 'd');
    });

    test('attributes, entities, comments and raw text', () {
      final doc = parseHtml('<!-- <p>hidden</p> --><a href=/x data-x="1" HIDDEN class=\'c d\'>R&amp;D &eacute;t&eacute;</a>'
          '<script>if (a < b) document.write("</div><p>no</p>")</script><style>p{}</style>'
          '<title>A &amp; B</title><br/></br><img src="a.png"/>after');
      final a = doc.elements.firstWhere((e) => e.tag == 'a');
      expect(a.attrs, {'href': '/x', 'data-x': '1', 'hidden': '', 'class': 'c d'});
      expect(a.textContent, 'R&D été');
      expect(doc.elements.firstWhere((e) => e.tag == 'script').textContent, contains('</div><p>no</p>'));
      expect(doc.elements.where((e) => e.tag == 'p'), isEmpty, reason: 'nothing parsed out of the comment or script');
      expect(doc.elements.firstWhere((e) => e.tag == 'title').textContent, 'A & B');
      expect(doc.elements.where((e) => e.tag == 'br'), hasLength(2));
      expect(texts(doc), endsWith('after'));
    });

    test('stray end tags are passed over and deep nesting stays a tree', () {
      final doc = parseHtml('</div></span><p>kept</p></b>');
      expect(texts(doc), 'kept');
      final deep = parseHtml('${'<div>' * 5000}deep${'</div>' * 10}');
      expect(texts(deep), 'deep');
      expect(deep.descendants.length, greaterThan(400));
    });
  });
}
