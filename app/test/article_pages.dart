// Saved-page shapes for the article tests: what news sites, blogs,
// Wikipedia, Medium and a shop's front page serve, cut down to what makes
// each hard (navigation, sidebars, share bars, related links, comments,
// cookie banners, infoboxes, edit links, author boxes, read times).

const newsPage = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Scientists find a quieter way to grow rice | The Daily Planet</title>
<meta property="og:title" content="Scientists find a quieter way to grow rice | The Daily Planet">
<meta property="og:site_name" content="The Daily Planet">
<meta name="author" content="https://dailyplanet.example/people/jane-doe">
<meta property="article:published_time" content="2026-03-03T10:00:00+00:00">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"NewsArticle","headline":"Scientists find a quieter way to grow rice","author":[{"@type":"Person","name":"Jane Doe"}],"publisher":{"@type":"Organization","name":"The Daily Planet"},"datePublished":"2026-03-03T10:00:00Z"}</script>
<script>window.dataLayer = []; if (a < b) { document.write("<p>Script text that is not the article</p>"); }</script>
<style>.share { color: red } p > a { color: blue }</style>
</head>
<body class="article-page">
<div id="cookie-banner" class="cookie-consent">We use cookies to improve your experience on our site. <button>Accept all</button></div>
<header class="site-header">
  <a href="/" class="logo">The Daily Planet</a>
  <nav class="main-nav"><ul><li><a href="/news">News</a></li><li><a href="/sport">Sport</a></li><li><a href="/culture">Culture</a></li><li><a href="/opinion">Opinion</a></li></ul></nav>
  <form class="search" action="/search"><input type="search" name="q"><button>Search</button></form>
</header>
<main>
<article>
  <h1 class="headline">Scientists find a quieter way to grow rice</h1>
  <p class="byline">By <a rel="author" href="/people/jane-doe">Jane Doe</a> &middot; <time datetime="2026-03-03T10:00:00Z">3 March 2026</time></p>
  <div class="share-tools"><a href="https://twitter.com/share">Share on Twitter</a> <a href="https://facebook.com/share">Share on Facebook</a> <a href="mailto:?">Email</a></div>
  <div class="article-body">
    <p>Farmers in three provinces have begun flooding their fields for half as long as before, and the rice has not minded. The method, tested over four seasons, cuts the water used by a third.
    <p>&ldquo;We expected the yield to fall,&rdquo; said Dr Li Wei, who led the trials. &ldquo;Instead it rose a little, and the fields gave off far less methane.&rdquo;
    <div class="ad-slot"><p>Advertisement</p></div>
    <p>Rice paddies are among the largest farm sources of methane, a gas that warms the planet many times faster than carbon dioxide over its first decades in the air.</p>
    <figure class="inline-image">
      <img src="/img/paddy.jpg" alt="A drained paddy">
      <figcaption>A paddy left to dry for a week in May. Photograph: A. Photographer</figcaption>
    </figure>
    <h2>How it works</h2>
    <p>Instead of keeping the paddies under water all season, farmers let them dry out for a week at a time, twice before the plants flower. Microbes that make methane need water without air, and the dry spells starve them.</p>
    <ul>
      <li>Fields are drained for seven days after the plants are established.
      <li>They are flooded again before the soil cracks too deeply.
    </ul>
    <blockquote><p>The surprise was how little the plants cared about the dry weeks, as long as the timing was right.</p></blockquote>
    <aside class="related-links"><h3>Related</h3><ul><li><a href="/a">Drought hits the wheat belt</a></li><li><a href="/b">Methane from cattle, explained</a></li></ul></aside>
    <p>The researchers now want to know whether the same timing works in the colder north, where the growing season is shorter and the soil holds water for longer.</p>
    <div class="newsletter-signup"><h3>Get the Planet in your inbox</h3><p>Sign up for our daily newsletter, sent every morning at seven.</p><form><input type="email"><button>Sign up</button></form></div>
  </div>
  <footer class="article-footer"><p>Topics: <a href="/t/farming">Farming</a>, <a href="/t/climate">Climate</a></p></footer>
</article>
<section class="comments" id="comments"><h2>Comments (2)</h2><div class="comment"><p>Great news for the planet, honestly a great read this morning.</p></div><div class="comment"><p>I wonder how this applies to wheat and other crops grown in Europe.</p></div></section>
<div class="recommended-stories"><h2>Most read</h2><ol><li><a href="/x">Ten things to do this weekend</a></li><li><a href="/y">The best new phones of the year</a></li></ol></div>
</main>
<footer class="site-footer"><p>&copy; 2026 The Daily Planet. All rights reserved.</p><ul><li><a href="/privacy">Privacy</a></li><li><a href="/terms">Terms</a></li></ul></footer>
</body>
</html>
''';

const blogPage = r'''<!DOCTYPE html>
<html lang="en-GB">
<head>
<meta charset="UTF-8">
<title>Notes from a slow garden &#8211; Jane&#039;s Allotment</title>
<meta name="generator" content="WordPress 6.5">
<link rel="stylesheet" href="/style.css">
</head>
<body class="post-template-default single single-post has-sidebar">
<div id="page" class="site">
  <a class="skip-link screen-reader-text" href="#content">Skip to content</a>
  <div id="masthead" class="site-header">
    <p class="site-title"><a href="/">Jane's Allotment</a></p>
    <p class="site-description">Vegetables, weather and the odd disaster</p>
    <div id="site-navigation" class="main-navigation"><ul id="menu-main"><li><a href="/">Home</a></li><li><a href="/about">About</a></li><li><a href="/recipes">Recipes</a></li></ul></div>
  </div>
  <div id="content" class="site-content">
    <div id="primary" class="content-area">
      <div class="post-12 post type-post status-publish hentry">
        <h1 class="entry-title">Notes from a slow garden</h1>
        <div class="entry-meta"><span class="posted-on">Posted on <time class="entry-date published" datetime="2026-04-12T08:30:00+01:00">12 April 2026</time></span> <span class="byline">by <span class="author vcard"><a class="url fn n" href="/author/jane/">Jane</a></span></span></div>
        <div class="entry-content">
          <p>This spring I decided to do less. Not nothing, but less: fewer rows, wider paths, and a corner left to whatever wanted to grow there.</p>
          <p>The broad beans went in late, in the second week of March, because the soil was still too wet to work. They came up anyway, slowly, and the blackfly found them a week after that.</p>
          <h3>What I planted</h3>
          <ul>
            <li>Broad beans, two short rows</li>
            <li>Early potatoes, in sacks by the shed</li>
            <li>Sweet peas along the fence, for the bees and for the table</li>
          </ul>
          <p>The corner I left alone has turned into the most interesting part of the plot. Nettles first, then cleavers, and now a scatter of poppies that I never sowed.</p>
          <div class="sharedaddy sd-sharing-enabled"><h3 class="sd-title">Share this:</h3><ul><li><a href="?share=twitter">Twitter</a></li><li><a href="?share=facebook">Facebook</a></li></ul></div>
          <div id="jp-relatedposts" class="jp-relatedposts"><h3>Related</h3><p><a href="/2025/frost">The late frost of last year</a></p></div>
        </div>
        <div class="entry-footer"><span class="cat-links">Posted in <a href="/c/garden">Garden</a></span></div>
      </div>
      <div id="comments" class="comments-area">
        <h2 class="comments-title">3 thoughts on &ldquo;Notes from a slow garden&rdquo;</h2>
        <ol class="comment-list">
          <li class="comment"><div class="comment-body"><p>Lovely post. I did the same with a corner of mine last year and got foxgloves everywhere.</p></div></li>
          <li class="comment"><div class="comment-body"><p>The blackfly were terrible here too. Have you tried planting the beans in autumn instead of spring?</p></div></li>
          <li class="comment"><div class="comment-body"><p>Poppies from nowhere are the best kind of poppies, in my experience, and they come back every single year.</p></div></li>
        </ol>
        <div id="respond" class="comment-respond"><h3>Leave a Reply</h3><form><p><label>Comment</label><textarea></textarea></p><p><input type="submit" value="Post Comment"></p></form></div>
      </div>
    </div>
    <div id="secondary" class="widget-area sidebar">
      <section class="widget widget_text"><h2 class="widget-title">About me</h2><div class="textwidget"><p>I have kept an allotment in the north of England for eleven years, with mixed results and a great deal of rain.</p></div></section>
      <section class="widget widget_archive"><h2 class="widget-title">Archives</h2><ul><li><a href="/2026/04/">April 2026</a></li><li><a href="/2026/03/">March 2026</a></li></ul></section>
    </div>
  </div>
  <div id="colophon" class="site-footer"><div class="site-info"><a href="https://wordpress.org/">Proudly powered by WordPress</a></div></div>
</div>
</body>
</html>
''';

const wikiPage = r'''<!DOCTYPE html>
<html class="client-nojs" lang="en" dir="ltr">
<head>
<meta charset="UTF-8">
<title>Alpine swift - Wikipedia</title>
<meta property="og:title" content="Alpine swift - Wikipedia">
<link rel="canonical" href="https://en.wikipedia.org/wiki/Alpine_swift">
</head>
<body class="skin-vector mediawiki ltr sitedir-ltr">
<div id="mw-page-base" class="noprint"></div>
<div id="content" class="mw-body" role="main">
  <a id="top"></a>
  <h1 id="firstHeading" class="firstHeading mw-first-heading"><span class="mw-page-title-main">Alpine swift</span></h1>
  <div id="bodyContent" class="vector-body">
    <div id="siteSub" class="noprint">From Wikipedia, the free encyclopedia</div>
    <div id="mw-content-text" class="mw-body-content mw-content-ltr" lang="en" dir="ltr">
      <div class="mw-parser-output">
        <table class="infobox biota"><tbody><tr><th colspan="2">Alpine swift</th></tr><tr><td>Kingdom:</td><td><a href="/wiki/Animal">Animalia</a></td></tr><tr><td>Order:</td><td><a href="/wiki/Apodiformes">Apodiformes</a></td></tr></tbody></table>
        <p>The <b>Alpine swift</b> (<i lang="la">Tachymarptis melba</i>) is a species of bird in the swift family. It breeds in the mountains from southern Europe to the Himalayas and winters in Africa.<sup id="cite_ref-iucn_1-0" class="reference"><a href="#cite_note-iucn-1">[1]</a></sup></p>
        <p>Like other swifts it spends most of its life in the air, feeding on insects caught in flight and even sleeping on the wing during long migrations.<sup id="cite_ref-2" class="reference"><a href="https://en.wikipedia.org/wiki/Alpine_swift#cite_note-2">[2]</a></sup></p>
        <div id="toc" class="toc" role="navigation"><div class="toctitle"><h2>Contents</h2></div><ul><li><a href="#Description">1 Description</a></li><li><a href="#Behaviour">2 Behaviour</a></li></ul></div>
        <h2><span class="mw-headline" id="Description">Description</span><span class="mw-editsection"><span class="mw-editsection-bracket">[</span><a href="/w/index.php?title=Alpine_swift&amp;action=edit&amp;section=1">edit</a><span class="mw-editsection-bracket">]</span></span></h2>
        <p>The Alpine swift is much larger than the common swift, with a wingspan of up to sixty centimetres. Its upperparts are brown, and its throat and belly are white, separated by a dark band across the breast.</p>
        <h2><span class="mw-headline" id="Behaviour">Behaviour</span><span class="mw-editsection">[<a href="/w/index.php?action=edit&amp;section=2">edit</a>]</span></h2>
        <p>It nests in colonies on cliffs and tall buildings, laying two or three eggs in a cup of feathers and plant matter glued together with saliva. Both parents incubate the eggs for about twenty days.</p>
        <h2><span class="mw-headline" id="References">References</span></h2>
        <div class="reflist"><ol class="references">
          <li id="cite_note-iucn-1"><span class="mw-cite-backlink"><b><a href="#cite_ref-iucn_1-0">^</a></b></span> <span class="reference-text">BirdLife International (2016). <i>Tachymarptis melba</i>. IUCN Red List of Threatened Species.</span></li>
          <li id="cite_note-2"><span class="mw-cite-backlink"><b><a href="#cite_ref-2">^</a></b></span> <span class="reference-text">Liechti, F. and others (2013). Non-stop flight of the Alpine swift. Nature Communications.</span></li>
        </ol></div>
        <div class="navbox" role="navigation"><div class="navbox-title">Swifts</div><ul><li><a href="/wiki/Common_swift">Common swift</a></li><li><a href="/wiki/Pallid_swift">Pallid swift</a></li></ul></div>
      </div>
    </div>
    <div id="catlinks" class="catlinks"><div><a href="/wiki/Help:Category">Categories</a>: <ul><li><a href="/wiki/Category:Apodidae">Apodidae</a></li></ul></div></div>
  </div>
</div>
<div id="mw-navigation"><h2>Navigation menu</h2><div id="p-personal" role="navigation"><ul><li><a href="/w/index.php?title=Special:UserLogin">Log in</a></li></ul></div><div id="p-search" role="search"><form><input type="search"></form></div></div>
<div id="footer" role="contentinfo"><ul><li>This page was last edited on 1 March 2026, at 10:00.</li><li>Text is available under the Creative Commons Attribution-ShareAlike License.</li></ul></div>
</body>
</html>
''';

const mediumPage = r'''<!doctype html><html lang="en"><head><title>The quiet joy of reading aloud | by Sam Rivera | Medium</title>
<meta property="og:title" content="The quiet joy of reading aloud">
<meta property="og:site_name" content="Medium">
<meta name="author" content="Sam Rivera">
<meta property="article:author" content="https://medium.com/@samrivera">
<meta property="article:published_time" content="2026-02-14T09:12:45.123Z">
<script>window.__APOLLO_STATE__ = {"a":"<div>not text</div>"};</script>
</head><body><div id="root"><div class="a b c"><div class="d e f">
<nav class="ab ac"><div><a href="/">Medium</a><a href="/m/signin">Sign in</a><a href="/new-story">Write</a></div></nav>
<article><div class="l"><section><div class="ib ic"><div class="ah ai">
<h1 id="5f3a" class="pw-post-title ig ih">The quiet joy of reading aloud</h1>
<div class="speechify-ignore ab cp"><div class="pw-author ab"><a rel="noopener follow" href="/@samrivera"><img alt="Sam Rivera" src="a.png"></a><div><span><a rel="noopener follow" href="/@samrivera">Sam Rivera</a></span><span><button>Follow</button></span></div></div><div class="ab"><span data-testid="storyReadTime">6 min read</span><span>&middot;</span><span data-testid="storyPublishDate">Feb 14, 2026</span></div></div>
<div class="ab cp"><div class="pw-multi-vote-icon"><button aria-label="clap"><svg width="24"><path d="M1 1"></path></svg></button></div><div><p class="be b">1.2K</p></div><button aria-label="responses">48</button></div>
<figure class="mw mx"><div><img alt="An open book on a table" src="b.jpg"></div><figcaption class="og oh">Photo by Someone on Unsplash</figcaption></figure>
<p id="1a2b" class="pw-post-body-paragraph ke kf">My grandmother read to me every night until I was nine, and then, one night, she asked me to read to her instead.</p>
<p id="3c4d" class="pw-post-body-paragraph ke kf">I stumbled over half the words. She did not correct me once. She listened the way you listen to music, with her eyes closed, and when I finished she said: read it again.</p>
<h2 id="5e6f" class="lg lh">Why the voice matters</h2>
<p id="7a8b" class="pw-post-body-paragraph ke kf">A sentence read aloud has to be understood all the way through before it can be said well. You cannot skim a sentence you are speaking.</p>
<blockquote class="nm nn"><p id="9c0d" class="no np">Reading aloud is the slowest way to read, and that is the point of it.</p></blockquote>
<pre class="pq pr"><span>for page in book:
    read(page)</span></pre>
<p id="1e2f" class="pw-post-body-paragraph ke kf">These days I listen more than I read. But every so often I still pick a page and say it out loud, slowly, to an empty room.</p>
</div></div></section></div></article>
<div class="ah ai"><div class="pw-responses"><h2>Responses (48)</h2></div><div><h2>More from Sam Rivera</h2><div><a href="/x"><h2>Ten books I reread every year</h2></a><a href="/y"><h2>On keeping a reading diary</h2></a></div></div><div><h2>Recommended from Medium</h2><a href="/z"><h2>How to read more books</h2></a></div></div>
<footer><a href="/about">About</a><a href="/help">Help</a></footer>
</div></div></div></body></html>
''';

const shopPage = r'''<!DOCTYPE html><html><head><title>Example Store - Home</title><meta property="og:site_name" content="Example Store"></head>
<body>
<header><nav><ul><li><a href="/men">Men</a></li><li><a href="/women">Women</a></li><li><a href="/kids">Kids</a></li><li><a href="/sale">Sale</a></li></ul></nav></header>
<div class="hero"><h1>Spring collection</h1><a class="button" href="/spring">Shop now</a></div>
<div class="grid">
  <div class="card"><a href="/p/1"><h3>Linen shirt</h3></a><span class="price">&pound;35</span></div>
  <div class="card"><a href="/p/2"><h3>Canvas shoes</h3></a><span class="price">&pound;50</span></div>
  <div class="card"><a href="/p/3"><h3>Straw hat</h3></a><span class="price">&pound;20</span></div>
</div>
<div class="links"><ul><li><a href="/about">About us</a></li><li><a href="/delivery">Delivery</a></li><li><a href="/returns">Returns</a></li><li><a href="/contact">Contact</a></li></ul></div>
<footer><p>&copy; Example Store 2026. Free delivery on orders over fifty pounds.</p></footer>
</body></html>
''';
