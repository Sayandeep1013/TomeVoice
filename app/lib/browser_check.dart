import 'package:flutter/material.dart';

import 'sources/net.dart';
import 'sources/source_engine.dart';
import 'sources/plugin_host.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// Show the site's browser check (Cloudflare) in a web view, and keep the
/// cookies it hands out for the app's own requests. True when the site let
/// the reader in, so the caller can try again.
Future<bool> passBrowserCheck(BuildContext context, ChallengeException e) async {
  final jar = await const SpeechService().browserCheck(e.url, Net.userAgent);
  if (jar == null) {
    if (context.mounted) showSnack(context, 'The check did not finish. Try again in a moment.');
    return false;
  }
  final cookies = <String, String>{};
  for (final part in jar.split(';')) {
    final at = part.indexOf('=');
    if (at > 0) cookies[part.substring(0, at).trim()] = part.substring(at + 1).trim();
  }
  await Net.instance.setCookies(Uri.parse(e.url).host, cookies);
  return true;
}

/// A source's failure where its results would be: what went wrong, and the
/// way on. A browser check gets the button that opens it.
class SourceProblem extends StatelessWidget {
  const SourceProblem({
    super.key,
    required this.error,
    required this.onRetry,
    this.title = 'The site did not answer',
    this.more,
  });

  final Object error;
  final VoidCallback onRetry;
  final String title;

  /// Another action beside "Try again", such as opening the site.
  final Widget? more;

  @override
  Widget build(BuildContext context) {
    final e = error;
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
          onPressed: () => _install(context, e),
          icon: const Icon(Icons.download_rounded),
          label: Text('Install ${e.name}'),
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

  /// Install the novel's source from the lists already added, then retry.
  Future<void> _install(BuildContext context, MissingSourceException e) async {
    final store = SourceEngine.instance.store;
    try {
      final listed = (await store.available()).where((p) => p.id == e.pluginId).firstOrNull ??
          (await store.available(refresh: true)).where((p) => p.id == e.pluginId).firstOrNull;
      if (listed == null) {
        if (context.mounted) {
          showSnack(context, 'None of your source lists has ${e.name}. Add one that does in Sources.', long: true);
        }
        return;
      }
      if (context.mounted) showSnack(context, 'Installing ${e.name}…');
      await store.install(listed);
      onRetry();
    } on Object catch (err) {
      if (context.mounted) showSnack(context, friendlyError(err), long: true);
    }
  }
}

/// [SourceProblem] on one line, for a row among others (global search).
class SourceProblemLine extends StatelessWidget {
  const SourceProblemLine({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final style = Skin.label(context, size: 13, color: Skin.inkFaintOn(context));
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
