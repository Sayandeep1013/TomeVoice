import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'pronunciation_list.dart';
import 'reading_rules.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

/// "Say this as that": [word] (from a long-pressed sentence) and how it
/// should sound, for this book or every book. [preview] says a line aloud in
/// the book's voice.
Future<void> showSayDialog(
  BuildContext context, {
  required String word,
  String? bookId,
  String? bookTitle,
  Future<void> Function(String text)? preview,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SayDialog(word: word, bookId: bookId, bookTitle: bookTitle, preview: preview),
    );

class _SayDialog extends StatefulWidget {
  const _SayDialog({required this.word, this.bookId, this.bookTitle, this.preview});

  final String word;
  final String? bookId;
  final String? bookTitle;
  final Future<void> Function(String text)? preview;

  @override
  State<_SayDialog> createState() => _SayDialogState();
}

class _SayDialogState extends State<_SayDialog> {
  late final _from = TextEditingController(text: widget.word);
  late final _to = TextEditingController(text: _existing ?? widget.word);
  late bool _onlyThisBook = widget.bookId != null;

  String? get _existing => ReadingRules.instance.say
      .where((r) => r.from.toLowerCase() == widget.word.toLowerCase())
      .firstOrNull
      ?.to;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final from = _from.text.trim();
    final to = _to.text.trim();
    if (from.isEmpty || to.isEmpty) return;
    await ReadingRules.instance.addSay(SayRule(from: from, to: to, book: _onlyThisBook ? widget.bookId : null));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Fix the pronunciation'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _from,
                decoration: const InputDecoration(labelText: 'Word on the page'),
              ),
              const SizedBox(height: Gap.m),
              TextField(
                controller: _to,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Say it as',
                  helperText: 'Spell it the way it sounds: Zor-ee-an',
                  suffixIcon: widget.preview == null
                      ? null
                      : IconButton(
                          tooltip: 'Hear it',
                          icon: const Icon(Icons.play_circle_outline_rounded),
                          onPressed: () => unawaited(widget.preview!(_to.text.trim())),
                        ),
                ),
                onSubmitted: (_) => _save(),
              ),
              if (widget.bookId != null) ...[
                const SizedBox(height: Gap.s),
                SwitchRow(
                  title: 'Only in this book',
                  subtitle: widget.bookTitle,
                  value: _onlyThisBook,
                  padding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _onlyThisBook = v),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

/// "Don't read lines like this", for a web novel's line [line]: the words
/// that mark such lines, for this site ([plugin], [siteName]) or every site.
/// True when a rule was added.
Future<bool> showSkipDialog(
  BuildContext context, {
  required String line,
  required String plugin,
  required String siteName,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _SkipDialog(line: line, plugin: plugin, siteName: siteName),
    ) ==
    true;

class _SkipDialog extends StatefulWidget {
  const _SkipDialog({required this.line, required this.plugin, required this.siteName});

  final String line;
  final String plugin;
  final String siteName;

  @override
  State<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends State<_SkipDialog> {
  late final _text = TextEditingController(text: widget.line.length > 80 ? widget.line.substring(0, 80) : widget.line);
  bool _thisSite = true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.length < 3) return;
    await ReadingRules.instance.addSkip(SkipRule(text: text, plugin: _thisSite ? widget.plugin : null));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text("Don't read lines like this"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Lines containing these words are left out, in chapters already downloaded too. '
                'Keep only the words that mark them, such as "Patreon".',
                style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)),
              ),
              const SizedBox(height: Gap.m),
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Lines containing'),
              ),
              const SizedBox(height: Gap.s),
              SwitchRow(
                title: 'Only on ${widget.siteName}',
                value: _thisSite,
                padding: EdgeInsets.zero,
                onChanged: (v) => setState(() => _thisSite = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: _save, child: const Text('Skip them')),
        ],
      );
}

/// Settings → Reading rules: every pronunciation, by the books it is for,
/// to check or remove, to share as a small file or to add to from one;
/// what the voice skips (the presets, each with an example of what it
/// leaves out); and the lines left out of web novels. With [bookId], one
/// book's: its own pronunciations, and the presets it reads with, every
/// book's or its own.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key, required this.bookTitles, this.bookId, this.bookTitle});

  /// Book id → title, to say which book a rule is for, and to pick the
  /// books a list taken in is for.
  final Map<String, String> bookTitles;

  /// The book whose rules these are; null for every book's.
  final String? bookId;
  final String? bookTitle;

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

/// A book's pronunciations, or every book's, as one list on the screen.
typedef _Group = ({String? book, String title, List<SayRule> rules, bool shared});

class _RulesScreenState extends State<RulesScreen> {
  final _rules = ReadingRules.instance;
  final _svc = const SpeechService();

  /// A list being shared or taken in.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rules.changes.addListener(_changed);
  }

  @override
  void dispose() {
    _rules.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String? get _book => widget.bookId;

  /// The book's title, as far as it is known.
  String? get _title => widget.bookTitle ?? widget.bookTitles[_book];

  @override
  Widget build(BuildContext context) {
    final book = _book;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Reading rules', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    if (book != null) ...[
                      Eyebrow(_title ?? 'This book'),
                      const SizedBox(height: Gap.l),
                    ],
                    ..._pronunciations(context),
                    const SizedBox(height: Gap.xl),
                    ..._presets(context),
                    if (book == null) ...[
                      const SizedBox(height: Gap.xl),
                      ..._skippedLines(context),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------- pronunciations

  /// The rules shown: the book's own, or every one.
  List<SayRule> get _shown => _book == null ? _rules.say : [for (final r in _rules.say) if (r.book == _book) r];

  List<Widget> _pronunciations(BuildContext context) {
    final say = _shown;
    final groups = _book == null ? _groups() : const <_Group>[];
    final shareable = _book != null ? say.isNotEmpty : groups.any((g) => g.shared);
    final everyBook = _book == null ? 0 : _rules.say.where((r) => r.book == null).length;
    return [
      SectionTitle('Pronunciations', note: say.isEmpty ? null : '${say.length}'),
      const SizedBox(height: Gap.xs),
      Wrap(
        spacing: Gap.s,
        children: [
          TextButton.icon(
            onPressed: !shareable || _busy ? null : _share,
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('Share'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : _takeIn,
            icon: const Icon(Icons.playlist_add_rounded, size: 20),
            label: const Text('Add from a file'),
          ),
        ],
      ),
      const SizedBox(height: Gap.xs),
      if (say.isEmpty)
        _hint(context, "Press and hold a word while reading, then Fix how it's said. Or add a list someone shared.")
      else if (_book != null)
        for (final r in say) _row(context, title: '${r.from}  →  ${r.to}', onDelete: () => _rules.removeSay(r))
      else
        for (final g in groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.xs),
            child: Eyebrow('${g.title} · ${g.rules.length}'),
          ),
          for (final r in g.rules) _row(context, title: '${r.from}  →  ${r.to}', onDelete: () => _rules.removeSay(r)),
        ],
      if (everyBook > 0)
        _hint(context, '${_n(everyBook, 'word is', 'words are')} also said your way in every book (Settings, Reading rules).'),
    ];
  }

  /// Every rule by the books it is for: every book's first, then each
  /// book's by its title, then those of books not on the shelves (on a
  /// secret one, or gone), which are not offered to share.
  List<_Group> _groups() {
    final every = <SayRule>[];
    final books = <String, List<SayRule>>{};
    final other = <SayRule>[];
    for (final r in _rules.say) {
      final b = r.book;
      if (b == null) {
        every.add(r);
      } else if (widget.bookTitles.containsKey(b)) {
        (books[b] ??= []).add(r);
      } else {
        other.add(r);
      }
    }
    final ids = books.keys.toList()
      ..sort((a, b) => widget.bookTitles[a]!.toLowerCase().compareTo(widget.bookTitles[b]!.toLowerCase()));
    return [
      if (every.isNotEmpty) (book: null, title: 'Every book', rules: every, shared: true),
      for (final id in ids) (book: id, title: widget.bookTitles[id]!, rules: books[id]!, shared: true),
      if (other.isNotEmpty) (book: null, title: 'Other books', rules: other, shared: false),
    ];
  }

  /// Share a book's list, or (from every book's rules) the lists picked,
  /// as a file through Android's share sheet.
  Future<void> _share() async {
    final book = _book;
    final lists = book != null
        ? [(book: book as String?, title: _title ?? '', count: _shown.length)]
        : [
            for (final g in _groups())
              if (g.shared) (book: g.book, title: g.title, count: g.rules.length),
          ];
    if (lists.isEmpty) return;
    final picked = await showModalBottomSheet<({List<String?> books, String name})>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      // One book's list is named for it: the book's page and the reader
      // both pass its title. Without one, the name is left to be typed.
      builder: (_) => _ShareSheet(lists: lists, name: book == null ? null : (_title ?? '')),
    );
    if (picked == null || !mounted) return;
    final list = PronunciationList.of(
      _rules.say,
      name: picked.name,
      books: picked.books,
      titles: {...widget.bookTitles, if (book != null && _title != null) book: _title!},
    );
    setState(() => _busy = true);
    try {
      final dir = await _svc.shareDir();
      if (dir == null) throw const FileSystemException('there is nowhere to put the file');
      final file = File('$dir/${PronunciationList.fileNameFor(list.name)}');
      await file.writeAsString(list.encode(), flush: true);
      await _svc.shareFile(
        file.path,
        mime: 'application/json',
        text: '${list.name}: ${_n(list.words.length, 'word', 'words')} said right, for TomeVoice',
      );
    } on Object catch (e) {
      if (mounted) showSnack(context, 'The list could not be shared: ${_why(e)}', long: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Add the pronunciations in files picked on the phone: for every book,
  /// or the books they are for, this phone's own saying of a word kept;
  /// then what was added.
  Future<void> _takeIn() async {
    final List<PickedFile> files;
    try {
      files = await _svc.pickDocuments();
    } on PlatformException catch (e) {
      if (mounted) showSnack(context, _why(e));
      return;
    }
    if (files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final lists = <PronunciationList>[];
    try {
      for (final f in files) {
        final list = await PronunciationList.read(File(f.path), name: f.name);
        await _dropCopy(File(f.path));
        if (list != null) lists.add(list);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (lists.isEmpty) {
      showSnack(
        context,
        '${files.length == 1 ? '“${files.single.name}” has no pronunciations in it' : 'Those files have no pronunciations in them'}. '
        'TomeVoice takes a list shared from TomeVoice, or lines such as Zorian = Zor-ee-an.',
        long: true,
      );
      return;
    }
    final list = PronunciationList.join(lists);
    final books = await showModalBottomSheet<List<String?>>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TakeInSheet(list: list, bookTitles: widget.bookTitles, bookId: _book, bookTitle: _title),
    );
    if (books == null || !mounted) return;
    final plan = planImport(_rules.say, list.words, books);
    await _rules.addAll(plan.add);
    if (!mounted) return;
    final where = books.contains(null)
        ? 'every book'
        : books.length == 1
            ? '“${books.single == _book ? (_title ?? 'this book') : (widget.bookTitles[books.single] ?? 'the book')}”'
            : '${books.length} books';
    await _showTakenIn(context, plan, where);
  }

  // ----------------------------------------------------------------- presets

  List<Widget> _presets(BuildContext context) {
    final book = _book;
    final own = book != null && _rules.hasOwnPresets(book);
    final everyBook = [
      for (final p in SkipPreset.values)
        if (_rules.presetOn(p)) p.title.toLowerCase(),
    ];
    return [
      const SectionTitle('What the voice skips'),
      const SizedBox(height: Gap.xs),
      _hint(context, 'The page still shows every word: only the voice passes over these.'),
      if (book != null)
        SwitchRow(
          title: 'For this book only',
          subtitle: own
              ? 'Every other book: ${everyBook.isEmpty ? 'nothing skipped' : everyBook.join(', ')}'
              : 'Off: what you switch below is for every book',
          value: own,
          padding: EdgeInsets.zero,
          onChanged: (v) => unawaited(_rules.setOwnPresets(book, v)),
        ),
      for (final p in SkipPreset.values)
        _PresetRow(
          preset: p,
          on: _rules.presetOn(p, book: book),
          onChanged: (v) => unawaited(_rules.setPreset(p, v, book: book)),
        ),
    ];
  }

  // ----------------------------------------------------------- skipped lines

  List<Widget> _skippedLines(BuildContext context) {
    final skip = _rules.skip;
    return [
      SectionTitle('Skipped lines', note: skip.isEmpty ? null : '${skip.length}'),
      const SizedBox(height: Gap.s),
      if (skip.isEmpty)
        _hint(context, 'In a web novel, press and hold a line, then Don\'t read lines like this.')
      else
        for (final r in skip)
          _row(
            context,
            title: '“${r.text}”',
            detail: r.plugin == null ? 'Every site' : 'Only on ${r.plugin}',
            onDelete: () => _rules.removeSkip(r),
          ),
    ];
  }

  Widget _hint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Text(text, style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
      );

  Widget _row(BuildContext context, {required String title, String? detail, required VoidCallback onDelete}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Skin.ui(size: 15, weight: FontWeight.w600, color: Skin.inkOn(context))),
                  if (detail != null) Text(detail.toUpperCase(), style: Skin.meta(context, size: 10)),
                ],
              ),
            ),
            IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline_rounded), onPressed: onDelete),
          ],
        ),
      );
}

String _n(int count, String one, String many) => '$count ${count == 1 ? one : many}';

String _why(Object e) => switch (e) {
      PlatformException(:final message, :final code) => message ?? code,
      FileSystemException(:final message) => message,
      _ => '$e',
    };

/// The picker's copy of a file under incoming/<slot>/, with its slot (see
/// MainActivity's copy into incoming); nothing else is touched.
Future<void> _dropCopy(File f) async {
  try {
    final slot = f.parent;
    if (slot.parent.path.replaceAll(r'\', '/').endsWith('/incoming')) await slot.delete(recursive: true);
  } on FileSystemException {
    // Swept with incoming/ at a later start.
  }
}

/// A preset with its switch, and its example: the page as it shows it,
/// what the voice leaves out struck through, and what it says instead.
class _PresetRow extends StatelessWidget {
  const _PresetRow({required this.preset, required this.on, required this.onChanged});

  final SkipPreset preset;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchRow(
              title: preset.title,
              subtitle: preset.detail,
              value: on,
              padding: EdgeInsets.zero,
              onChanged: onChanged,
            ),
            const SizedBox(height: Gap.xs),
            _Example(preset),
          ],
        ),
      );
}

typedef _Paragraph = ({String text, List<SaidChange> changes});

/// Each preset's example, worked out once.
final _examples = <SkipPreset, List<_Paragraph>>{};

class _Example extends StatelessWidget {
  const _Example(this.preset);

  final SkipPreset preset;

  @override
  Widget build(BuildContext context) {
    final paragraphs = _examples[preset] ??= presetExample(preset);
    final page = Skin.page(context, size: 14.5, height: 1.4).copyWith(color: Skin.inkSoftOn(context));
    final faint = Skin.inkFaintOn(context);
    // Struck through, on a wash, so a lone "~" or "*" left out shows too.
    final left = page.copyWith(
      color: faint,
      decoration: TextDecoration.lineThrough,
      decorationColor: faint,
      backgroundColor: Skin.accentOf(context).withValues(alpha: Skin.isDark(context) ? 0.16 : 0.10),
    );
    final said = page.copyWith(color: Skin.accentOf(context), fontStyle: FontStyle.italic);
    final heard = [
      for (final p in paragraphs)
        if (_heard(p).trim() case final h when h.isNotEmpty) h,
    ];
    return Semantics(
      label: 'For example, ${[for (final p in paragraphs) p.text].join(' ')}. '
          'Read aloud: ${heard.isEmpty ? 'nothing' : heard.join(' ')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
        decoration: BoxDecoration(color: Skin.capsuleOn(context), borderRadius: BorderRadius.circular(Radii.chip)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in paragraphs) Text.rich(TextSpan(children: _spans(p, page, left, said))),
          ],
        ),
      ),
    );
  }

  /// [p] as spans: as the page shows it, its changes struck through and
  /// what is said in their place after them.
  static List<InlineSpan> _spans(_Paragraph p, TextStyle page, TextStyle left, TextStyle said) {
    final out = <InlineSpan>[];
    var at = 0;
    for (final c in p.changes) {
      if (c.start < at) continue;
      if (c.start > at) out.add(TextSpan(text: p.text.substring(at, c.start), style: page));
      out.add(TextSpan(text: p.text.substring(c.start, c.end), style: left));
      if (c.said.isNotEmpty) out.add(TextSpan(text: ' ${c.said}', style: said));
      at = c.end;
    }
    if (at < p.text.length) out.add(TextSpan(text: p.text.substring(at), style: page));
    return out;
  }

  /// [p] as the voice says it.
  static String _heard(_Paragraph p) {
    final out = StringBuffer();
    var at = 0;
    for (final c in p.changes) {
      if (c.start < at) continue;
      out
        ..write(p.text.substring(at, c.start))
        ..write(c.said);
      at = c.end;
    }
    out.write(p.text.substring(at));
    return out.toString().replaceAll(RegExp(r'\s+'), ' ');
  }
}

/// Which lists go into a shared file, and what it is called. Pops the
/// books picked (null for every book's) with the name, or nothing.
class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.lists, this.name});

  final List<({String? book, String title, int count})> lists;

  /// The name for one book's list: its title ('' when it is not known).
  final String? name;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _picked = <int>{0};
  late final _name = TextEditingController(text: _suggested());

  /// The name the sheet last suggested: one typed over it stays.
  late String _suggestion = _name.text;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<String?> get _books => [for (final i in _picked.toList()..sort()) widget.lists[i].book];

  /// A name for what is picked: a book's title, what several titles begin
  /// with ("Mother of Learning" for its volumes), or the first of them.
  String _suggested() {
    if (widget.name != null) return widget.name!;
    final titles = [
      for (final i in _picked.toList()..sort())
        if (widget.lists[i].book != null) widget.lists[i].title,
    ];
    if (titles.isEmpty) return 'My pronunciations';
    if (titles.length == 1) return titles.single;
    return commonTitle(titles) ?? titles.first;
  }

  void _toggle(int i, bool on) {
    setState(() {
      if (on) {
        _picked.add(i);
      } else if (_picked.length > 1) {
        _picked.remove(i);
      }
      if (_name.text == _suggestion) _name.text = _suggestion = _suggested();
    });
  }

  @override
  Widget build(BuildContext context) {
    final words = PronunciationList.of(ReadingRules.instance.say, name: '', books: _books).words.length;
    final body = Skin.ui(size: 14.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(
                'Share pronunciations',
                subtitle: 'A small file, for TomeVoice on another phone',
                trailing: Icon(Icons.ios_share_rounded, color: Skin.accentOf(context)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
                child: Text(
                  'Whoever opens it in Reading rules adds the words they do not say already. '
                  'Their own way of saying a word stays theirs.',
                  style: body,
                ),
              ),
              if (widget.lists.length > 1) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
                  child: Eyebrow('Which words'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (i, l) in widget.lists.indexed)
                        FilterChip(
                          label: Text('${l.title} · ${l.count}'),
                          selected: _picked.contains(i),
                          onSelected: (on) => _toggle(i, on),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.m),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                child: TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context)),
                  decoration: const InputDecoration(
                    labelText: 'Name of the list',
                    helperText: 'A book’s title, or its series’ name',
                  ),
                  // Share waits for a name.
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.m),
                child: _Actions(
                  cancel: () => Navigator.pop(context),
                  action: FilledButton.icon(
                    onPressed: words == 0 || _name.text.trim().isEmpty
                        ? null
                        : () => Navigator.pop(context, (books: _books, name: _name.text.trim())),
                    icon: const Icon(Icons.ios_share_rounded, size: 20),
                    label: Text('Share ${_n(words, 'word', 'words')}'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A sheet's foot: Cancel, and its action at the far side; the action goes
/// above Cancel when the two do not fit side by side (large text).
class _Actions extends StatelessWidget {
  const _Actions({required this.cancel, required this.action});

  final VoidCallback cancel;
  final Widget action;

  @override
  Widget build(BuildContext context) => OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowAlignment: OverflowBarAlignment.end,
        overflowDirection: VerticalDirection.up,
        overflowSpacing: Gap.s,
        children: [TextButton(onPressed: cancel, child: const Text('Cancel')), action],
      );
}

/// What several titles begin with, word for word, less a volume's word or
/// number at its end ("Mother of Learning" for "Mother of Learning: Arc 1"
/// and "Mother of Learning: Arc 2"). Null when they share too little.
String? commonTitle(List<String> titles) {
  if (titles.isEmpty) return null;
  final split = [for (final t in titles) t.trim().split(RegExp(r'\s+'))];
  final common = <String>[];
  for (var i = 0; i < split.first.length; i++) {
    final w = split.first[i];
    if (split.any((s) => s.length <= i || s[i].toLowerCase() != w.toLowerCase())) break;
    common.add(w);
  }
  const volume = {'book', 'volume', 'vol', 'vol.', 'part', 'arc', 'tome', 'season', '#'};
  while (common.isNotEmpty) {
    final last = common.last.toLowerCase().replaceAll(RegExp(r'[:,.\-–—(#]+$'), '');
    if (last.isEmpty || volume.contains(last) || int.tryParse(last) != null) {
      common.removeLast();
    } else {
      break;
    }
  }
  final name = common.join(' ').replaceAll(RegExp(r'[\s:,\-–—(]+$'), '').trim();
  return name.length < 3 ? null : name;
}

/// Where a list taken in goes: every book, or the books it is for (this
/// one, on a book's rules), with what it would add and what stays as this
/// phone says it. Pops the books (null for every book), or nothing.
class _TakeInSheet extends StatefulWidget {
  const _TakeInSheet({required this.list, required this.bookTitles, this.bookId, this.bookTitle});

  final PronunciationList list;
  final Map<String, String> bookTitles;
  final String? bookId;
  final String? bookTitle;

  @override
  State<_TakeInSheet> createState() => _TakeInSheetState();
}

class _TakeInSheetState extends State<_TakeInSheet> {
  late bool _every;
  late final Set<String> _books;

  @override
  void initState() {
    super.initState();
    final book = widget.bookId;
    if (book != null) {
      _books = {book};
      _every = false;
    } else {
      _books = _matching();
      _every = _books.isEmpty;
    }
  }

  /// The books on the phone the list was made from: the same book (by its
  /// id), or one with the same title.
  Set<String> _matching() {
    final byTitle = {for (final e in widget.bookTitles.entries) e.value.trim().toLowerCase(): e.key};
    return {
      for (final b in widget.list.books)
        if (widget.bookTitles.containsKey(b.id))
          b.id
        else if (byTitle[b.title.trim().toLowerCase()] case final id? when b.title.trim().isNotEmpty)
          id,
    };
  }

  List<String?> get _targets => _every ? const [null] : [..._books];

  Future<void> _choose() async {
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BookPicker(bookTitles: widget.bookTitles, picked: _books),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _books
        ..clear()
        ..addAll(picked);
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final plan = planImport(ReadingRules.instance.say, list.words, _targets);
    final adds = plan.added.length;
    final body = Skin.ui(size: 14.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.4);
    final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context));
    final sample = [for (final w in list.words.take(3)) '${w.word} → ${w.say}'].join(', ');
    final nothingPicked = !_every && _books.isEmpty;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              'Add pronunciations',
              subtitle: '${list.name} · ${_n(list.words.length, 'word', 'words')}',
              trailing: Icon(Icons.playlist_add_rounded, color: Skin.accentOf(context)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
              child: Text('$sample${list.words.length > 3 ? '…' : ''}', style: body),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
              child: Eyebrow('For'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: ChoiceRow<bool>(
                options: [(true, 'Every book'), (false, widget.bookId != null ? 'This book' : 'Some books')],
                value: _every,
                onChanged: (v) => setState(() => _every = v),
              ),
            ),
            if (!_every && widget.bookId == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final id in _books)
                      InputChip(
                        label: Text(widget.bookTitles[id] ?? 'A book'),
                        onDeleted: () => setState(() => _books.remove(id)),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add_rounded, size: 18),
                      label: Text(_books.isEmpty ? 'Choose books' : 'More books'),
                      onPressed: _choose,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
              child: Text(
                nothingPicked
                    ? 'Choose the books it is for: a series’ volumes, say.'
                    : [
                        adds == 0 ? 'Nothing new to add' : '${_n(adds, 'word', 'words')} to add',
                        if (plan.same.isNotEmpty) '${plan.same.length} said so already',
                        if (plan.kept.isNotEmpty) '${plan.kept.length} kept as you say ${plan.kept.length == 1 ? 'it' : 'them'}',
                      ].join(' · '),
                style: faint,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.m),
              child: _Actions(
                cancel: () => Navigator.pop(context),
                action: FilledButton.icon(
                  onPressed: nothingPicked || adds == 0 ? null : () => Navigator.pop(context, _targets),
                  icon: const Icon(Icons.playlist_add_rounded, size: 20),
                  label: Text(adds == 0 ? 'Add' : 'Add ${_n(adds, 'word', 'words')}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The books on the shelves, to tick: those a list is for. Pops the ticked.
class _BookPicker extends StatefulWidget {
  const _BookPicker({required this.bookTitles, required this.picked});

  final Map<String, String> bookTitles;
  final Set<String> picked;

  @override
  State<_BookPicker> createState() => _BookPickerState();
}

class _BookPickerState extends State<_BookPicker> {
  late final _picked = {...widget.picked};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final books = [
      for (final e in widget.bookTitles.entries)
        if (q.isEmpty || e.value.toLowerCase().contains(q)) e,
    ]..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Books it is for', subtitle: 'The volumes of a series, say'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
            child: SearchField(hint: 'Find a book', onChanged: (v) => setState(() => _query = v)),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final e in books)
                  CheckboxListTile(
                    value: _picked.contains(e.key),
                    activeColor: Skin.accentOf(context),
                    contentPadding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                    title: Text(e.value, style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context))),
                    onChanged: (on) => setState(() {
                      if (on == true) {
                        _picked.add(e.key);
                      } else {
                        _picked.remove(e.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, Gap.m),
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _picked),
                child: Text(_picked.isEmpty ? 'None' : 'For ${_n(_picked.length, 'book', 'books')}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How many most of the words added, and those kept, are listed by name.
const _listed = 40;

/// What taking a list in did: the words added, and how many were said so
/// already, or are said this phone's own way and stayed so.
Future<void> _showTakenIn(BuildContext context, ImportPlan plan, String where) => showDialog<void>(
      context: context,
      animationStyle: sheetMotion(context),
      builder: (ctx) {
        final added = plan.added;
        final line = Skin.ui(size: 14.5, weight: FontWeight.w500, color: Skin.inkOn(ctx));
        final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(ctx));
        return AlertDialog(
          title: Text(added.isEmpty ? 'Nothing new to add' : 'Added ${_n(added.length, 'pronunciation', 'pronunciations')}'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                if (added.isNotEmpty) ...[
                  Text('For $where:', style: faint),
                  const SizedBox(height: Gap.xs),
                  for (final w in added.take(_listed)) Text('${w.word}  →  ${w.say}', style: line),
                  if (added.length > _listed) Text('and ${added.length - _listed} more', style: faint),
                ],
                if (plan.same.isNotEmpty) ...[
                  const SizedBox(height: Gap.m),
                  Text('${_n(plan.same.length, 'word was', 'words were')} said that way already.', style: faint),
                ],
                if (plan.kept.isNotEmpty) ...[
                  const SizedBox(height: Gap.m),
                  Text(
                    plan.kept.length == 1
                        ? '1 word you say your own way stays as you have it:'
                        : '${plan.kept.length} words you say your own way stay as you have them:',
                    style: faint,
                  ),
                  const SizedBox(height: Gap.xs),
                  for (final k in plan.kept.take(_listed))
                    Text('${k.theirs.word}  →  ${k.mine}  (the list: ${k.theirs.say})', style: line),
                  if (plan.kept.length > _listed) Text('and ${plan.kept.length - _listed} more', style: faint),
                ],
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        );
      },
    );
