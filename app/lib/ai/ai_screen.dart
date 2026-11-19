import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../guide.dart';
import '../prefs.dart';
import '../theme.dart';
import '../ui.dart';
import 'ai_client.dart';
import '../library_store.dart' show LibraryEntry;
import 'memory/memory_background.dart';
import 'memory/memory_builder.dart' show BuildPhase;
import 'memory/memory_service.dart';
import 'ai_keys.dart';

/// Main menu > AI: the reader's keys, what each job uses, and how they have
/// been used. The memories and their settings join it as they are built.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key, this.ring, this.client});

  final AiRing? ring;
  final AiClient? client;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  AiRing get _ring => widget.ring ?? AiRing.instance;

  @override
  void initState() {
    super.initState();
    _ring.addListener(_changed);
    // The guide to the AI, by itself the first time this page opens.
    final prefs = ListeningPrefs.loaded;
    if (GuideScreen.onFirstLaunch && prefs != null && !prefs.aiGuideShown) {
      prefs.aiGuideShown = true;
      prefs.save();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(showAiGuide(context));
      });
    }
  }

  @override
  void dispose() {
    _ring.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _edit([AiKey? key]) => showModalBottomSheet<void>(
        context: context,
        sheetAnimationStyle: sheetMotion(context),
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => KeySheet(ring: _ring, key: ValueKey(key?.id), editing: key, client: widget.client),
      );

  @override
  Widget build(BuildContext context) {
    final keys = _ring.keys;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'AI', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xxl + bottom),
                  children: [
                    _para(
                      context,
                      keys.isEmpty
                          ? 'TomeVoice talks to the AI with your own keys, straight from this phone to the '
                              'provider: there is no TomeVoice server. Nothing from your books is sent until '
                              'you add a key.'
                          : 'Your keys, straight from this phone to each provider. When one has used up its '
                              'quota it rests, and the next takes over.',
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.page - Gap.s),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => unawaited(showAiGuide(context)),
                          icon: const Icon(Icons.school_outlined, size: 18),
                          label: const Text('How the AI works'),
                        ),
                      ),
                    ),
                    const SizedBox(height: Gap.s),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: Gap.page),
                      child: SectionTitle('Keys'),
                    ),
                    const SizedBox(height: Gap.s),
                    for (final k in keys) _KeyRow(ring: _ring, aiKey: k, onTap: () => unawaited(_edit(k))),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          onPressed: () => unawaited(_edit()),
                          icon: const Icon(Icons.add_rounded),
                          label: Text(keys.isEmpty ? 'Add a key' : 'Add another key'),
                        ),
                      ),
                    ),
                    if (keys.isNotEmpty)
                      for (final job in AiJob.values) ...[
                        const SizedBox(height: Gap.xl),
                        _JobOrder(ring: _ring, job: job),
                      ],
                    if (keys.isNotEmpty) ...[
                      const SizedBox(height: Gap.xl),
                      const _Memories(),
                      const SizedBox(height: Gap.xl),
                      const _TalkSettings(),
                    ],
                    const SizedBox(height: Gap.xl),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: Gap.page),
                      child: SectionTitle('What is sent'),
                    ),
                    const SizedBox(height: Gap.s),
                    _para(
                      context,
                      "Only what a question needs: the passage you ask about, a book's notes and the parts "
                      "of its text that bear on it, and your journal when you ask about it. Books on a "
                      'secret shelf are never sent. Keys are kept in this app alone, and never go into a '
                      'backup.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _para(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.page),
      child: Text(
        text,
        style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4),
      ),
    );

/// "3,412" or "1.2M".
String tokenCount(int n) {
  if (n < 10000) {
    final s = n.toString();
    return s.length > 3 ? '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}' : s;
  }
  if (n < 1000000) return '${(n / 1000).round()}k';
  return '${(n / 1000000).toStringAsFixed(n < 10000000 ? 1 : 0)}M';
}

/// "05:30", or "Tue 05:30" when not today.
String wakeTime(DateTime t, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == at.year && t.month == at.month && t.day == at.day) return hm;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${days[t.weekday - 1]} $hm';
}

/// What a key's state is, in a few words: working, resting, refused.
(String, Color?) keyStatus(BuildContext context, AiRing ring, AiKey key) {
  final s = ring.stateOf(key.id);
  if (s.refused != null) return ('Refused: ${s.refused}', Theme.of(context).colorScheme.error);
  if (s.restingAt(DateTime.now())) return ('Resting until ${wakeTime(s.restUntil!)}', Skin.accentInkOf(context));
  final today = ring.today(key.id);
  if (today.calls == 0) return ('Ready', null);
  return (
    '${today.calls} ${today.calls == 1 ? 'call' : 'calls'} · ${tokenCount(today.input + today.output)}'
        '${key.dailyCap == null ? '' : ' of ${tokenCount(key.dailyCap!)}'} tokens today',
    null
  );
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.ring, required this.aiKey, required this.onTap});

  final AiRing ring;
  final AiKey aiKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (status, colour) = keyStatus(context, ring, aiKey);
    final jobs = [for (final j in AiJob.values) if (aiKey.models[j] != null) j.label.toLowerCase()];
    return SettingRow(
      icon: Icons.key_rounded,
      title: aiKey.label.isEmpty ? aiKey.provider.label : aiKey.label,
      subtitle: '${aiKey.provider.label} · ${aiKey.masked}\n'
          '${jobs.isEmpty ? 'No job yet: pick its models' : 'For ${jobs.join(', ')}'}',
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: Text(
          status,
          textAlign: TextAlign.end,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Skin.meta(context, color: colour),
        ),
      ),
      onTap: onTap,
    );
  }
}

/// Every book with a memory: how far it is built, Build or Pause.
class _Memories extends StatefulWidget {
  const _Memories();

  @override
  State<_Memories> createState() => _MemoriesState();
}

class _MemoriesState extends State<_Memories> {
  List<LibraryEntry>? _books;

  @override
  void initState() {
    super.initState();
    unawaited(MemoryService.instance.booksWithMemory().then((b) {
      if (mounted) setState(() => _books = b);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    if (books == null || books.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Gap.page),
          child: SectionTitle('Memories', size: 18),
        ),
        for (final b in books)
          ValueListenableBuilder<BookMemoryState>(
            valueListenable: MemoryService.instance.stateOf(b.id),
            builder: (context, s, _) {
              final busy = s.building || s.build.phase == BuildPhase.resting;
              final left = s.indexed == 0 || s.noted + s.skipped < s.indexed;
              final line = switch (s.build.phase) {
                BuildPhase.running => 'Building · ${s.noted} of ${s.indexed} chapters',
                BuildPhase.resting => 'Waiting for a key · goes on at ${wakeTime(s.build.until!)}',
                BuildPhase.paused => 'Paused · ${s.noted} of ${s.indexed} chapters',
                BuildPhase.failed => 'Stopped: ${s.build.error ?? ''}',
                _ => s.noted == 0
                    ? 'Not built yet'
                    : '${s.noted} of ${s.indexed} chapters · ${s.entities} people, places and things',
              };
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
                title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(line, style: Skin.meta(context)),
                    if (s.indexed > 0) ...[
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: s.noted / s.indexed, minHeight: 3),
                      ),
                    ],
                  ],
                ),
                trailing: busy
                    ? IconButton(
                        tooltip: 'Pause',
                        icon: const Icon(Icons.pause_rounded),
                        onPressed: () => MemoryService.instance.pause(b.id),
                      )
                    : left && s.noted > 0
                        ? IconButton(
                            tooltip: 'Go on building',
                            icon: const Icon(Icons.play_arrow_rounded),
                            onPressed: () => unawaited(MemoryService.instance.build(b.id)),
                          )
                        : null,
              );
            },
          ),
      ],
    );
  }
}

/// How Talk answers: aloud or not, how long, from what, and when it offers
/// a recap.
class _TalkSettings extends StatefulWidget {
  const _TalkSettings();

  @override
  State<_TalkSettings> createState() => _TalkSettingsState();
}

class _TalkSettingsState extends State<_TalkSettings> {
  ListeningPrefs get _p => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  void _set(void Function(ListeningPrefs p) change) {
    setState(() => change(_p));
    _p.save();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Gap.page),
            child: SectionTitle('Talk', size: 18),
          ),
          SwitchRow(
            title: 'Keep talks in the journal',
            subtitle: "Each talk is kept in the book's journal when Talk closes",
            value: _p.aiKeepTalks,
            onChanged: (v) => _set((p) => p.aiKeepTalks = v),
          ),
          SwitchRow(
            title: 'Spoiler guard on for new books',
            subtitle: 'Each book whose memory you begin keeps to what you have read (each book can change it)',
            value: _p.aiGuardNew,
            onChanged: (v) => _set((p) => p.aiGuardNew = v),
          ),
          SwitchRow(
            title: 'Answers aloud',
            subtitle: 'Said in the voice reading the book, which pauses for them',
            value: _p.aiSpeak,
            onChanged: (v) => _set((p) => p.aiSpeak = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, Gap.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('How long its answers are'),
                const SizedBox(height: Gap.s),
                ChoiceRow<String>(
                  options: const [('short', 'Short'), ('normal', 'Normal'), ('long', 'Long')],
                  value: _p.aiLength,
                  onChanged: (v) => _set((p) => p.aiLength = v),
                ),
                const SizedBox(height: Gap.l),
                const Eyebrow('"Previously…" when back to a book after'),
                const SizedBox(height: Gap.s),
                ChoiceRow<int>(
                  options: const [(0, 'Never'), (1, 'A day'), (3, '3 days'), (7, 'A week')],
                  value: _p.aiRecapDays,
                  onChanged: (v) => _set((p) => p.aiRecapDays = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.s),
          SwitchRow(
            title: 'What the AI already knows of the book',
            subtitle: _p.aiOwnKnowledge
                ? 'On: it may add what it knows from elsewhere, and says so. It can spoil a well-known book.'
                : 'Off: it keeps to what TomeVoice gives it, so a well-known book is not spoiled from memory.',
            value: _p.aiOwnKnowledge,
            onChanged: (v) => _set((p) => p.aiOwnKnowledge = v),
          ),
          const SizedBox(height: Gap.l),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Gap.page),
            child: SectionTitle('Building memories', size: 18),
          ),
          SwitchRow(
            title: 'Also with TomeVoice closed',
            subtitle: 'Every hour or so, the memories you began go on, never with the battery low',
            value: _p.aiBackground,
            onChanged: (v) => _background((p) => p.aiBackground = v),
          ),
          if (_p.aiBackground) ...[
            SwitchRow(
              title: 'Only on Wi-Fi',
              value: _p.aiBackgroundWifi,
              onChanged: (v) => _background((p) => p.aiBackgroundWifi = v),
            ),
            SwitchRow(
              title: 'Only while charging',
              value: _p.aiBackgroundCharging,
              onChanged: (v) => _background((p) => p.aiBackgroundCharging = v),
            ),
          ],
        ],
      );

  void _background(void Function(ListeningPrefs p) change) {
    _set(change);
    unawaited(MemoryBackground.apply(_p));
  }
}

/// A job's keys in the order it tries them; hold one to move it.
class _JobOrder extends StatelessWidget {
  const _JobOrder({required this.ring, required this.job});

  final AiRing ring;
  final AiJob job;

  @override
  Widget build(BuildContext context) {
    final keys = ring.forJob(job);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: SectionTitle(job.label, note: keys.length > 1 ? 'Hold to move' : null, size: 18),
        ),
        const SizedBox(height: Gap.xs),
        _para(
          context,
          keys.isEmpty
              ? '${job.about} No key has a model for it yet: open a key to give it one.'
              : keys.length == 1
                  ? job.about
                  : '${job.about} Tried from the top.',
        ),
        if (keys.isNotEmpty)
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(top: Gap.xs),
            onReorderItem: (from, to) {
              final ids = [for (final k in keys) k.id];
              final id = ids.removeAt(from);
              ids.insert(to, id);
              unawaited(ring.reorder(job, ids));
            },
            children: [
              for (final (i, k) in keys.indexed)
                ReorderableDelayedDragStartListener(
                  key: ValueKey(k.id),
                  index: i,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: Gap.page),
                    leading: CircleAvatar(
                      radius: 13,
                      backgroundColor: Skin.capsuleOn(context),
                      child: Text('${i + 1}', style: Skin.meta(context)),
                    ),
                    title: Text(k.label.isEmpty ? k.provider.label : k.label,
                        style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                    subtitle: Text(k.models[job]!, style: Skin.meta(context)),
                    trailing: keys.length > 1 ? Icon(Icons.drag_handle_rounded, color: Skin.inkSoftOn(context)) : null,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// A key added or changed: its provider, name, address and secret, then,
/// checked, the model it uses for each job.
class KeySheet extends StatefulWidget {
  const KeySheet({super.key, required this.ring, this.editing, this.client});

  final AiRing ring;
  final AiKey? editing;
  final AiClient? client;

  @override
  State<KeySheet> createState() => _KeySheetState();
}

class _KeySheetState extends State<KeySheet> {
  late AiProvider _provider = widget.editing?.provider ?? AiProvider.gemini;
  late final _label = TextEditingController(text: widget.editing?.label ?? '');
  late final _base = TextEditingController(text: widget.editing?.baseUrl ?? _provider.baseUrl);
  late final _secret = TextEditingController(text: widget.editing?.secret ?? '');
  late final _cap = TextEditingController(text: widget.editing?.dailyCap == null ? '' : '${widget.editing!.dailyCap}');
  late final _models = {
    for (final j in AiJob.values) j: TextEditingController(text: widget.editing?.models[j] ?? ''),
  };
  bool _shown = false;
  bool _checking = false;
  List<String>? _offered;
  String? _checkNote;
  bool _checkFailed = false;

  late final AiClient _client = widget.client ?? AiClient(timeout: const Duration(seconds: 30));

  @override
  void dispose() {
    _label.dispose();
    _base.dispose();
    _secret.dispose();
    _cap.dispose();
    for (final c in _models.values) {
      c.dispose();
    }
    if (widget.client == null) _client.close();
    super.dispose();
  }

  void _pick(AiProvider p) {
    setState(() {
      // The address follows the provider, unless the reader wrote their own.
      if (_base.text.isEmpty || AiProvider.values.any((o) => o.baseUrl == _base.text)) _base.text = p.baseUrl;
      _provider = p;
      _offered = null;
      _checkNote = null;
    });
  }

  AiEndpoint get _endpoint => AiEndpoint(baseUrl: _base.text.trim(), key: _secret.text.trim(), model: '');

  /// Asks the provider which models the key may use, and fills the jobs it
  /// has none for yet with a likely one.
  Future<void> _check() async {
    if (_secret.text.trim().isEmpty || _base.text.trim().isEmpty) return;
    setState(() {
      _checking = true;
      _checkNote = null;
    });
    try {
      final models = await _client.models(_endpoint);
      if (!mounted) return;
      setState(() {
        _offered = models;
        _checkFailed = false;
        _checkNote = models.isEmpty
            ? 'The key works, but the provider lists no models: write the model names below.'
            : 'The key works: ${models.length} ${models.length == 1 ? 'model' : 'models'} to choose from.';
        for (final job in AiJob.values) {
          final c = _models[job]!;
          if (c.text.isEmpty) c.text = suggestModel(_provider, job, models) ?? '';
        }
      });
      // What Talk and the Builder need of the model: tools, and JSON.
      final model = _models[AiJob.talker]!.text.trim();
      if (model.isNotEmpty) {
        final can = await probeModel(
            _client, AiEndpoint(baseUrl: _base.text.trim(), key: _secret.text.trim(), model: model));
        if (mounted) setState(() => _checkNote = '${_checkNote ?? ''}\n$can');
      }
    } on AiError catch (e) {
      if (!mounted) return;
      setState(() {
        _checkFailed = true;
        _checkNote = switch (e.kind) {
          AiFailure.refused => 'The provider refused this key: ${e.message}',
          AiFailure.network => 'The provider could not be reached. Is the phone online, and the address right?',
          AiFailure.quota => 'The key works, but its quota is used up for now.',
          _ => e.message,
        };
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _chooseModel(AiJob job) async {
    final offered = _offered;
    if (offered == null || offered.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ModelPicker(models: offered, title: job.label),
    );
    if (picked != null && mounted) setState(() => _models[job]!.text = picked);
  }

  bool get _ready => _secret.text.trim().isNotEmpty && Uri.tryParse(_base.text.trim())?.hasScheme == true;

  Future<void> _save() async {
    final models = <AiJob, String>{
      for (final e in _models.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
    };
    final id = widget.editing?.id ?? 'k${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final mine = widget.ring.keys.where((k) => k.provider == _provider && k.id != id).length;
    final label = _label.text.trim().isNotEmpty
        ? _label.text.trim()
        : mine == 0
            ? _provider.label
            : '${_provider.label} ${mine + 1}';
    await widget.ring.put(AiKey(
      id: id,
      provider: _provider,
      label: label,
      baseUrl: _base.text.trim(),
      secret: _secret.text.trim(),
      models: models,
      dailyCap: capOf(_cap.text),
    ));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final k = widget.editing;
    if (k == null) return;
    final sure = await confirm(context,
        title: 'Remove this key?', body: 'TomeVoice forgets it. The provider still has it.', action: 'Remove');
    if (!sure) return;
    await widget.ring.remove(k.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(widget.editing == null ? 'A new key' : 'The key'),
                Wrap(
                  spacing: Gap.s,
                  runSpacing: Gap.s,
                  children: [
                    for (final p in AiProvider.values)
                      ChoiceChip(label: Text(p.label), selected: p == _provider, onSelected: (_) => _pick(p)),
                  ],
                ),
                const SizedBox(height: Gap.s),
                Text(_provider.note,
                    style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                        .copyWith(height: 1.35)),
                const SizedBox(height: Gap.m),
                TextField(
                  controller: _secret,
                  obscureText: !_shown,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'API key',
                    suffixIcon: IconButton(
                      tooltip: _shown ? 'Hide the key' : 'Show the key',
                      icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                      onPressed: () => setState(() => _shown = !_shown),
                    ),
                  ),
                ),
                const SizedBox(height: Gap.s),
                TextField(
                  controller: _label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: 'Its name (optional)', hintText: _provider.label),
                ),
                if (_provider == AiProvider.custom || _base.text != _provider.baseUrl) ...[
                  const SizedBox(height: Gap.s),
                  TextField(
                    controller: _base,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: 'https://example.com/v1',
                    ),
                  ),
                ],
                const SizedBox(height: Gap.m),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _ready && !_checking ? () => unawaited(_check()) : null,
                      icon: _checking
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check_rounded, size: 18),
                      label: const Text('Check the key'),
                    ),
                  ],
                ),
                if (_checkNote != null) ...[
                  const SizedBox(height: Gap.s),
                  Text(_checkNote!,
                      style: Skin.ui(
                        size: 13,
                        weight: FontWeight.w500,
                        color: _checkFailed ? Theme.of(context).colorScheme.error : Skin.inkSoftOn(context),
                      )),
                ],
                const SizedBox(height: Gap.l),
                const Eyebrow('Models, a job each'),
                const SizedBox(height: Gap.xs),
                for (final job in AiJob.values)
                  if (job != AiJob.embedder || _provider.embeds || _provider == AiProvider.custom)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.s),
                      child: TextField(
                        controller: _models[job],
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: job.label,
                          hintText: job == AiJob.embedder ? 'Leave empty to skip' : 'Leave empty: not used for this',
                          suffixIcon: (_offered?.isNotEmpty ?? false)
                              ? IconButton(
                                  tooltip: 'Choose a model for ${job.label.toLowerCase()}',
                                  icon: const Icon(Icons.list_rounded),
                                  onPressed: () => unawaited(_chooseModel(job)),
                                )
                              : null,
                        ),
                      ),
                    ),
                const SizedBox(height: Gap.m),
                TextField(
                  controller: _cap,
                  keyboardType: TextInputType.text,
                  decoration: const InputDecoration(
                    labelText: 'Daily limit, in tokens (optional)',
                    hintText: '2M, 500k, or empty for none',
                    helperText: 'Reached, the key rests until midnight and the next one takes over.',
                  ),
                ),
                const SizedBox(height: Gap.l),
                Row(
                  children: [
                    if (widget.editing != null)
                      TextButton(
                        onPressed: () => unawaited(_remove()),
                        child: Text('Remove', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _ready ? () => unawaited(_save()) : null,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}

/// A likely model for [job] among [models]: Mercury's own; for Gemini a
/// Flash-Lite to build, a Flash to talk, its embedding model to search.
String? suggestModel(AiProvider provider, AiJob job, List<String> models) {
  if (models.isEmpty) return null;
  bool has(String m, List<String> words) => words.every(m.toLowerCase().contains);
  String? best(bool Function(String m) ok) {
    final fit = models.where(ok).toList();
    if (fit.isEmpty) return null;
    // The newest-looking: the highest version number in the name.
    double version(String m) =>
        RegExp(r'(\d+(?:\.\d+)?)').allMatches(m).map((x) => double.tryParse(x.group(1)!) ?? 0).fold(0.0, math.max);
    fit.sort((a, b) => version(b).compareTo(version(a)));
    return fit.first;
  }

  if (job == AiJob.embedder) return best((m) => has(m, ['embed']));
  bool chat(String m) => !has(m, ['embed']) && !has(m, ['tts']) && !has(m, ['image']) && !has(m, ['audio']);
  switch (provider) {
    case AiProvider.inception:
      return best((m) => has(m, ['mercury']) && !has(m, ['coder']) && chat(m)) ?? best(chat);
    case AiProvider.gemini:
      return job == AiJob.builder
          ? best((m) => has(m, ['flash', 'lite']) && chat(m) && !has(m, ['preview']))
              ?? best((m) => has(m, ['flash']) && chat(m))
          : best((m) => has(m, ['flash']) && !has(m, ['lite']) && chat(m) && !has(m, ['preview']))
              ?? best((m) => has(m, ['flash']) && chat(m));
    default:
      return null;
  }
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.title});

  final List<String> models;
  final String title;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final shown = [for (final m in widget.models) if (m.toLowerCase().contains(_q.toLowerCase())) m];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          SheetHeader(widget.title, subtitle: 'Pick a model'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.l),
            child: SearchField(hint: 'Find a model', onChanged: (v) => setState(() => _q = v)),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(shown[i]),
                onTap: () => Navigator.of(context).pop(shown[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A typed daily limit: "2000000", "2M", "500k", "1.5m" (null: none).
int? capOf(String typed) {
  final t = typed.trim().toLowerCase().replaceAll(',', '').replaceAll(' ', '');
  final m = RegExp(r'^(\d+(?:\.\d+)?)([km]?)$').firstMatch(t);
  if (m == null) return null;
  final n = double.parse(m.group(1)!) * switch (m.group(2)) { 'k' => 1000, 'm' => 1000000, _ => 1 };
  return n < 1 ? null : n.round();
}

/// Whether the model at [to] calls tools and keeps to JSON, as a line for
/// the reader: Talk looks further into a book with tools, and the Builder's
/// notes are JSON.
Future<String> probeModel(AiClient client, AiEndpoint to) async {
  const ping = AiTool(
    name: 'ping',
    description: 'Answer a ping.',
    parameters: {
      'type': 'object',
      'properties': {
        'word': {'type': 'string'},
      },
      'required': ['word'],
    },
  );
  bool? tools, json;
  try {
    final r = await client.chat(to, [aiMessage('user', 'Call the tool ping with the word "hello". Do nothing else.')],
        tools: const [ping], maxTokens: 60);
    tools = r.toolCalls.any((c) => c.name == 'ping');
  } on Object {
    tools = false;
  }
  try {
    final r = await client.chat(to, [aiMessage('user', 'Reply with the JSON object {"ok": true} and nothing else.')],
        json: true, maxTokens: 30);
    final t = r.text.trim().replaceAll(RegExp(r'^```(json)?|```$'), '').trim();
    json = jsonDecode(t) is Map;
  } on Object {
    json = false;
  }
  final m = to.model;
  if (tools && json) return '$m calls tools and writes JSON: Talk and building both work fully.';
  return [
    if (!tools) '$m did not call a tool: Talk answers from what it is given, without looking further.',
    if (!json) "$m did not keep to JSON: building a book's memory may fail with it. Choose another for Building.",
  ].join(' ');
}
