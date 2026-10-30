import 'dart:convert';
import 'dart:io';

/// Hosts whose pages only the phone's web view gets (their Cloudflare turns
/// the app's own requests away; see PluginHost). Kept as the app meets them,
/// so a check made with the app closed, where no web view can run, skips
/// their sources and says why instead of failing on each.
Future<Set<String>> browserHosts(Directory sourcesDir) async {
  try {
    final f = File('${sourcesDir.path}/browser-hosts.json');
    if (await f.exists()) return {for (final h in jsonDecode(await f.readAsString()) as List) '$h'};
  } on Object {
    // None known.
  }
  return const {};
}

/// Remember that [host] needed the web view (see [browserHosts]). Written
/// beside and renamed over, as the source workers may each write it.
Future<void> noteBrowserHost(Directory sourcesDir, String host) async {
  if (host.isEmpty) return;
  try {
    final known = await browserHosts(sourcesDir);
    if (known.contains(host)) return;
    final f = File('${sourcesDir.path}/browser-hosts.json');
    final tmp = File('${f.path}.${host.hashCode.toUnsigned(32)}.tmp');
    await tmp.writeAsString(jsonEncode([...known, host]), flush: true);
    await tmp.rename(f.path);
  } on Object {
    // Learnt again next time.
  }
}
