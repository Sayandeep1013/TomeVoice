/// NovelUpdates (novelupdates.com), the reading-list site for web novels, as
/// far as an app can go there without an API.
///
/// It has none: no API for apps, no sign-in an app may use, and its pages
/// sit behind Cloudflare. The apps that keep a NovelUpdates reading list in
/// step read its pages in a signed-in web view and break whenever the site
/// changes them. So TomeVoice does not sign in there or track for the
/// reader. What it offers, once turned on (Settings > Check for new
/// chapters; off by default), is a link on a web novel's page that finds the
/// novel there, in the phone's browser, where the reader is signed in with
/// their own account and can mark it themselves.
class NovelUpdates {
  const NovelUpdates._();

  /// What Settings says of it.
  static const about = "A link on each web novel's page to find it on NovelUpdates, in your browser, signed in "
      'as you are there. NovelUpdates has no way in for apps, so TomeVoice does not keep your reading list there '
      'itself.';

  /// The search there for [title].
  static String searchFor(String title) =>
      Uri.https('www.novelupdates.com', '/', {'s': title.trim(), 'post_type': 'seriesplans'}).toString();

  /// Whether a novel's page has the link: once the reader turned it on
  /// ([on]), and never for a novel on a shut secret shelf ([hidden]), whose
  /// title would go to the browser.
  static bool offered({required bool on, required bool hidden}) => on && !hidden;
}
