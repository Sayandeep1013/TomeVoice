import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'library_store.dart';
import 'ocr.dart';
import 'ocr_jobs.dart';
import 'theme.dart';
import 'ui.dart';

/// Offer to read [offer]'s pages with OCR: which languages they are in, the
/// download of any language data not on the phone yet, then the reading,
/// which goes on in the background (OcrJobs) and shows on the shelf. Declined,
/// a refused scan's copy goes. True when the reading has started.
Future<bool> offerOcr(BuildContext context, LibraryStore store, OcrOffer offer) async {
  await OcrJobs.instance.attach(store);
  var started = false;
  if (context.mounted) {
    started = await showModalBottomSheet<bool>(
          context: context,
          sheetAnimationStyle: sheetMotion(context),
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _OcrSheet(offer: offer),
        ) ==
        true;
  }
  if (!started) await declineOcr(offer);
  return started;
}

/// "0.8 MB".
String _size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// "Bengali", "Bengali and English", "Bengali, Hindi and English".
String _names(List<OcrLanguage> languages) {
  final names = [for (final l in languages) l.name];
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// What went wrong, as the reader can act on it.
String _why(Object e) => switch (e) {
      SocketException() || HttpException() || TimeoutException() =>
        'The language data could not be downloaded. Check the internet connection and try again.',
      FormatException(:final message) => message,
      PlatformException(:final message, :final code) => message ?? code,
      _ => '$e',
    };

Future<int> _countToRead(Map<String, Object?> pdf) => Isolate.run(() => ocrPagesToRead(pdf).length);

class _OcrSheet extends StatefulWidget {
  const _OcrSheet({required this.offer});

  final OcrOffer offer;

  @override
  State<_OcrSheet> createState() => _OcrSheetState();
}

class _OcrSheetState extends State<_OcrSheet> {
  final _data = OcrData.instance;

  /// The book's language and the app's (the phone's): the languages a scan
  /// is first offered in; the last ones picked when the book does not say.
  late final List<OcrLanguage> _picked = defaultOcrLanguages(
    book: widget.offer.language,
    app: WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    last: _data.lastPicked(),
  );

  /// The chips: those offered, then Bengali, Hindi and English, then any
  /// picked from the whole list.
  late final List<OcrLanguage> _shown = [
    ..._picked,
    for (final code in featuredOcrLanguages)
      if (ocrLanguageByCode(code) case final l? when !_picked.contains(l)) l,
  ];

  /// Pages OCR is to read, once counted.
  int? _toRead;

  /// The language data's download, 0 to 1, while it comes.
  double? _progress;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _data.addListener(_changed);
    unawaited(_countToRead(widget.offer.pdf).then((n) {
      if (mounted) setState(() => _toRead = n);
    }));
  }

  @override
  void dispose() {
    _data.removeListener(_changed);
    // Swiped away: a download for it stops.
    if (_busy) {
      for (final l in _picked) {
        _data.cancel(l);
      }
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    if (_picked.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _problem = null;
      _progress = null;
    });
    try {
      await _data.ensure(_picked, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      // Swiped away while the data came: not read after all.
      if (!mounted) return;
      await OcrJobs.instance.start(widget.offer, _picked);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _problem = e is OcrDownloadCancelled ? null : _why(e);
      });
    }
  }

  void _notNow() {
    for (final l in _picked) {
      _data.cancel(l);
    }
    Navigator.pop(context, false);
  }

  Future<void> _more() async {
    final picked = await showModalBottomSheet<List<OcrLanguage>>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _LanguageList(picked: _picked),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _picked
        ..clear()
        ..addAll(picked);
      _shown.addAll([for (final l in picked) if (!_shown.contains(l)) l]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final body = Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.45);
    final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context));
    final pages = offer.pageCount;
    final title = offer.title;
    final toRead = _toRead;
    final missing = [for (final l in _picked) if (!_data.installed(l)) l];
    final what = offer.imported
        ? 'Most pages of “$title” are pictures: ${toRead ?? 'most'} of its $pages pages have no text in them.'
        : '“$title” is scanned: its ${pages == 1 ? 'page is a picture' : '$pages pages are pictures'}, with no text in them.';
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              offer.imported ? 'Read the pictures too?' : 'Read it with OCR?',
              subtitle: 'Text recognition, on this phone',
              trailing: Icon(Icons.document_scanner_outlined, color: Skin.accentOf(context)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
              child: Text(
                '$what TomeVoice can read the words in them (OCR) here on the phone, a few seconds a page, '
                'with the screen off too. What it reads may have mistakes.',
                style: body,
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
              child: Eyebrow('Language of its pages'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final l in _shown)
                    FilterChip(
                      label: Text(l.label),
                      selected: _picked.contains(l),
                      onSelected: _busy
                          ? null
                          : (on) => setState(() {
                                if (on) {
                                  _picked.add(l);
                                } else {
                                  _picked.remove(l);
                                }
                              }),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('More languages'),
                    onPressed: _busy ? null : _more,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
              child: Text(
                [
                  if (_picked.isEmpty) 'Pick the language its pages are in.',
                  if (_picked.length > 1) 'Each extra language makes it slower: pick two only when the pages mix them.',
                  if (missing.isNotEmpty)
                    'First downloads the ${_names(missing)} language data (${_size(missing.fold(0, (n, l) => n + l.bytes))}), once.',
                ].join(' '),
                style: faint,
              ),
            ),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
                child: Progress(_progress!),
              ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 0),
                child: Text(_problem!,
                    style: Skin.ui(size: 14, weight: FontWeight.w500, color: const Color(0xFFE5674D))),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.m),
              child: Row(
                children: [
                  TextButton(onPressed: _notNow, child: const Text('Not now')),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _picked.isEmpty || _busy ? null : _read,
                    icon: _busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.document_scanner_outlined, size: 20),
                    label: const Text('Read it with OCR'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every language OCR reads, to tick; pops the ones ticked, in the order
/// they were picked.
class _LanguageList extends StatefulWidget {
  const _LanguageList({required this.picked});

  final List<OcrLanguage> picked;

  @override
  State<_LanguageList> createState() => _LanguageListState();
}

class _LanguageListState extends State<_LanguageList> {
  late final _picked = [...widget.picked];
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final l in ocrLanguages)
        if (q.isEmpty || l.label.toLowerCase().contains(q) || l.code.contains(q)) l,
    ];
    final accent = Skin.accentOf(context);
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Languages of its pages', subtitle: 'Each is a small download, once'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
            child: SearchField(hint: 'Find a language', onChanged: (v) => setState(() => _query = v)),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final l in shown)
                  CheckboxListTile(
                    value: _picked.contains(l),
                    activeColor: accent,
                    contentPadding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                    title: Text(l.label, style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context))),
                    subtitle: Text(
                      OcrData.instance.installed(l) ? 'On the phone' : _size(l.bytes),
                      style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                    onChanged: (on) => setState(() {
                      if (on == true) {
                        _picked.add(l);
                      } else {
                        _picked.remove(l);
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
                onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked),
                child: Text(_picked.isEmpty ? 'Pick a language' : 'Read in ${_names(_picked)}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The scans being read, on the shelf: how far the one being read has got,
/// with Stop; one that stopped, with Go on and Discard; nothing when there
/// are none. Says when a book is ready (with a snack [lift] above the
/// shelf's foot).
class OcrProgressCard extends StatefulWidget {
  const OcrProgressCard({super.key, this.lift = 0});

  final double lift;

  @override
  State<OcrProgressCard> createState() => _OcrProgressCardState();
}

class _OcrProgressCardState extends State<OcrProgressCard> {
  final _jobs = OcrJobs.instance;
  StreamSubscription<String>? _news;

  @override
  void initState() {
    super.initState();
    _jobs.addListener(_changed);
    _news = _jobs.news.listen((m) {
      if (mounted) showSnack(context, m, long: true, lift: widget.lift);
    });
  }

  @override
  void dispose() {
    _jobs.removeListener(_changed);
    unawaited(_news?.cancel());
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _goOn(OcrJob job) async {
    try {
      await _jobs.resume(job);
    } on Object catch (e) {
      if (mounted) showSnack(context, _why(e), long: true, lift: widget.lift);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _jobs.shown;
    return AnimatedSize(
      duration: Motion.of(context, Motion.standard),
      curve: Motion.out,
      alignment: Alignment.topCenter,
      child: job == null ? const SizedBox(width: double.infinity) : _card(context, job),
    );
  }

  Widget _card(BuildContext context, OcrJob job) {
    final reading = _jobs.running == job.id;
    final making = _jobs.making == job.id;
    final waiting = _jobs.waiting.contains(job.id);
    final total = job.pages.length;
    final others = _jobs.jobs.length - 1;
    final String status;
    if (making) {
      status = 'Making it into a book…';
    } else if (reading) {
      status = _jobs.stopping
          ? 'Stopping after this page…'
          : 'Reading page ${(job.done + 1).clamp(1, total)} of $total';
    } else if (waiting) {
      status = 'Waiting its turn';
    } else {
      status = 'Stopped at page ${(job.done + 1).clamp(1, total)} of $total';
    }
    final quiet = Skin.inkSoftOn(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
      child: Container(
        padding: const EdgeInsets.fromLTRB(Gap.l, 14, Gap.s, 6),
        decoration: BoxDecoration(
          color: Skin.capsuleOn(context),
          borderRadius: BorderRadius.circular(Radii.row + 4),
          border: Border.all(color: Skin.outlineOn(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: Text(
                'OCR: ${job.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Skin.title(context, size: 17),
              ),
            ),
            const SizedBox(height: Gap.xs),
            Eyebrow([status, if (others > 0) '$others more ${others == 1 ? 'scan' : 'scans'}'].join(' · ')),
            if (job.error != null && !reading && !making) ...[
              const SizedBox(height: Gap.xs),
              Text(job.error!, style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
            ],
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: making
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: const LinearProgressIndicator(minHeight: 4),
                    )
                  : Progress(total == 0 ? 1 : job.done / total, height: 4),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (reading || waiting)
                  TextButton(onPressed: _jobs.stopping ? null : _jobs.stop, child: const Text('Stop'))
                else if (!making) ...[
                  TextButton(
                    onPressed: () => _jobs.discard(job),
                    child: Text('Discard', style: TextStyle(color: quiet)),
                  ),
                  TextButton(onPressed: () => _goOn(job), child: const Text('Go on')),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
