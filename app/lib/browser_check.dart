import 'package:flutter/material.dart';

import 'sources/bridge.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/source_engine.dart';
import 'sources/source_updates.dart';
import 'sources/plugin_host.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// Show the site's browser check (Cloudflare) in a web view, and keep the
/// cookies it hands out for the app's own requests. True when the site let
/// the reader in, so the caller can try again.
Future<bool> passBrowserCheck(BuildContext context, ChallengeException e) async {
  if (!Net.isWebAddress(e.url)) return false;
  final jar = await const SpeechService().browserCheck(e.url, Net.userAgent);
  if (jar == null) {
    if (context.mounted) showSnack(context, 'The check did not finish. Try again in a moment.');
    return false;
  }
  // Kept for the source that met the check, not for every source.
  await Net.instance.setCookies(Uri.parse(e.url).host, cookiesOf(jar), partition: e.pluginId);
  return true;
}

/// A web view's cookies for a page ("a=1; b=2") by name.
Map<String, String> cookiesOf(String jar) => {
      for (final part in jar.split(';'))
        if (part.indexOf('=') case final at when at > 0) part.substring(0, at).trim(): part.substring(at + 1).trim(),
    };

/// Sign in to [plugin]'s site in a web view, for a site that wants an
/// account: what it sets for the site is kept in that source's own cookies
/// (and no other source's), so its requests go signed in from then on.
/// True once the reader tapped Done.
Future<bool> signInToSite(BuildContext context, PluginInfo plugin) async {
  final site = plugin.site;
  if (!Net.isWebAddress(site)) {
    showSnack(context, '${plugin.name} names no web page to sign in on.');
    return false;
  }
  final jar = await SourcesBridge.browserLogin(site, Net.userAgent);
  if (jar == null) return false;
  final cookies = cookiesOf(jar);
  await Net.instance.setCookies(Uri.parse(site).host, cookies, partition: plugin.id);
  if (context.mounted) {
    showSnack(
      context,
      cookies.isEmpty
          ? 'Nothing was kept: ${plugin.name} set no cookies there.'
          : 'Signed in to ${plugin.name}. Clear its cookies in Sources to sign out.',
      long: cookies.isEmpty,
    );
  }
  return true;
}

/// The update waiting for source [pluginId], if its list has one: a source
/// that fails is often one its site has changed under, and fixed since.
PluginInfo? pendingUpdate(String? pluginId) {
  if (pluginId == null) return null;
  try {
    return SourceEngine.instance.store.pending.value[pluginId];
  } on StateError {
    return null;
  }
}

/// Update source [update] from its row's or a failure's button, kept at
/// the version that works (see updateSources). True when it was updated.
Future<bool> updateSource(BuildContext context, PluginInfo update) async {
  final engine = SourceEngine.instance;
  showSnack(context, 'Updating ${update.name}…');
  final out = (await updateSources(engine.store, engine, [update])).single;
  if (context.mounted) {
    showSnack(context, out.note ?? (out.updated ? '${update.name} is updated.' : 'It could not be updated.'),
        long: out.note != null);
  }
  return out.updated;
}

/// A source's failure where its results would be: what went wrong, and the
/// way on. A browser check gets the button that opens it; a source with an
/// update waiting, the button that updates it.
class SourceProblem extends StatelessWidget {
  const SourceProblem({
    super.key,
    required this.error,
    required this.onRetry,
    this.title = 'The site did not answer',
    this.more,
    this.pluginId,
  });

  final Object error;
  final VoidCallback onRetry;
  final String title;

  /// Another action beside "Try again", such as opening the site.
  final Widget? more;

  /// The source that failed, so a waiting update can be offered.
  final String? pluginId;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final update = e is MissingSourceException || e is TamperedSourceException || e is ChallengeException
        ? null
        : pendingUpdate(pluginId);
    if (update != null) {
      return EmptyState(
        icon: Icons.system_update_alt_rounded,
        title: 'An update is available',
        body: '$e An update for ${update.name} is waiting, and may fix this.',
        action: Wrap(
          spacing: Gap.s,
          runSpacing: Gap.s,
          alignment: WrapAlignment.center,
          children: [
            FilledButton(
              onPressed: () async {
                if (await updateSource(context, update)) onRetry();
              },
              child: Text('Update ${update.name}'),
            ),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (e is ChallengeException) {
      return EmptyState(
        icon: Icons.verified_user_outlined,
        title: 'A quick check first',
        body: '${e.message} It opens the site for a moment so it can see a browser; '
            'tick the box if it asks.',
        action: FilledButton.icon(
          onPressed: () async {
            if (await passBrowserCheck(context, e)) onRetry();
          },
          icon: const Icon(Icons.open_in_browser_rounded),
          label: const Text('Open the check'),
        ),
      );
    }
    if (e is MissingSourceException) {
      return EmptyState(
        icon: Icons.extension_outlined,
        title: 'Needs its source',
        body: '${e.message} The chapters already on the phone still read.',
        action: FilledButton.icon(
          onPressed: () async {
            if (await installMissingSource(context, e)) onRetry();
          },
          icon: const Icon(Icons.download_rounded),
          label: Text('Install ${e.name}'),
        ),
      );
    }
    if (e is TamperedSourceException) {
      return EmptyState(
        icon: Icons.gpp_maybe_outlined,
        title: 'Its source changed on the phone',
        body: '${e.message} Installing it again from its list puts it right.',
        action: FilledButton.icon(
          onPressed: () async {
            if (await reinstallSource(context, e.pluginId, e.name)) onRetry();
          },
          icon: const Icon(Icons.download_rounded),
          label: Text('Reinstall ${e.name}'),
        ),
      );
    }
    return EmptyState(
      icon: Icons.cloud_off_rounded,
      title: title,
      body: '$e',
      action: Wrap(
        spacing: Gap.s,
        runSpacing: Gap.s,
        alignment: WrapAlignment.center,
        children: [
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
          if (more != null) more!,
        ],
      ),
    );
  }

}

/// Install the novel's source from the lists already added. True when it
/// was installed, so the caller can try again.
Future<bool> installMissingSource(BuildContext context, MissingSourceException e) async {
  final store = SourceEngine.instance.store;
  try {
    final listed = (await store.available()).where((p) => p.id == e.pluginId).firstOrNull ??
        (await store.available(refresh: true)).where((p) => p.id == e.pluginId).firstOrNull;
    if (listed == null) {
      if (context.mounted) {
        showSnack(context, 'None of your source lists has ${e.name}. Add one that does in Sources.', long: true);
      }
      return false;
    }
    if (context.mounted) showSnack(context, 'Installing ${e.name}…');
    await store.install(listed);
    return true;
  } on Object catch (err) {
    if (context.mounted) showSnack(context, friendlyError(err), long: true);
    return false;
  }
}

/// Install source [pluginId] again from the list it came from: its code on
/// the phone did not match what was installed. True when it was.
Future<bool> reinstallSource(BuildContext context, String pluginId, String name) async {
  final store = SourceEngine.instance.store;
  try {
    final have = await store.installedById(pluginId);
    final listed = have == null ? null : await store.fromItsList(have, refresh: true);
    if (listed == null) {
      if (context.mounted) {
        showSnack(context, 'The list $name came from no longer has it. Remove it in Sources.', long: true);
      }
      return false;
    }
    if (context.mounted) showSnack(context, 'Installing $name again…');
    await store.install(listed);
    return true;
  } on Object catch (err) {
    if (context.mounted) showSnack(context, friendlyError(err), long: true);
    return false;
  }
}

/// [SourceProblem] on one line, for a row among others (global search).
class SourceProblemLine extends StatelessWidget {
  const SourceProblemLine({super.key, required this.error, required this.onRetry, this.pluginId});

  final Object error;
  final VoidCallback onRetry;

  /// The source that failed, so a waiting update can be offered.
  final String? pluginId;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final style = Skin.label(context, size: 13, color: Skin.inkFaintOn(context));
    final update = e is ChallengeException ? null : pendingUpdate(pluginId);
    if (update != null) {
      return Row(
        children: [
          Expanded(
            child: Text('$e An update is available.', maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
          ),
          TextButton(
            onPressed: () async {
              if (await updateSource(context, update)) onRetry();
            },
            child: const Text('Update'),
          ),
        ],
      );
    }
    if (e is! ChallengeException) {
      return Text('$e', maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
    }
    return Row(
      children: [
        Expanded(child: Text(e.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: style)),
        TextButton(
          onPressed: () async {
            if (await passBrowserCheck(context, e)) onRetry();
          },
          child: const Text('Open the check'),
        ),
      ],
    );
  }
}
