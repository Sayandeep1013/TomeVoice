import 'dart:async';

import 'package:flutter/material.dart';

import 'book_tint.dart';
import 'cast.dart';
import 'listen_sheet.dart';
import 'neural_voices.dart';
import 'prefs.dart';
import 'speakers.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

/// The most characters the sheet lists: past this, those who speak least.
const _listed = 40;

/// A book's characters, from its page: who its speech tags name, how often
/// each speaks, and the voice their lines are read in, with one of their
/// own lines to hear it say. [people] are the book's, as found by
/// [findBookCharacters]; [listen] is the book's voice and dialogue voice.
Future<void> showCastSheet(
  BuildContext context, {
  required String bookId,
  required String title,
  required List<Character> people,
  required ListenController listen,
}) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => carryTint(
        context,
        _CastSheet(bookId: bookId, title: title, people: people, listen: listen),
      ),
    );

/// The book's cast as kept, read again from [people] (the book as it is
/// now), or a new one with nobody given a voice.
BookCast castFor(ListeningPrefs prefs, String bookId, List<Character> people) {
  final kept = prefs.castByBook[bookId];
  return kept == null ? BookCast(people) : kept.refound(people);
}

/// What [c] is called in lists: "the storyteller" for a book told as "I".
String characterName(Character c) => c.isI ? 'I, the storyteller' : c.name;

/// "Elizabeth and Mr. Darcy have voices of their own", for the book's page;
/// null when nobody has.
String? castSummary(BookCast? cast) {
  if (cast == null) return null;
  final named = [
    for (final c in cast.people)
      if (cast.voices.containsKey(c.name)) c.isI ? 'the storyteller' : c.name,
  ];
  if (named.isEmpty) return null;
  final who = switch (named.length) {
    1 => named.single,
    2 => '${named[0]} and ${named[1]}',
    _ => '${named[0]}, ${named[1]} and ${named.length - 2} more',
  };
  final line = named.length == 1 ? '$who has a voice of their own' : '$who have voices of their own';
  return '${line[0].toUpperCase()}${line.substring(1)}';
}

class _CastSheet extends StatefulWidget {
  const _CastSheet({required this.bookId, required this.title, required this.people, required this.listen});

  final String bookId;
  final String title;
  final List<Character> people;
  final ListenController listen;

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  final _catalog = VoiceCatalog.instance;
  late BookCast _cast = castFor(_prefs, widget.bookId, widget.people);

  /// The character whose sample is being said.
  String? _hearing;

  ListeningPrefs get _prefs => widget.listen.prefs;

  Map<int, String> get _heard => castVoices(
        _cast,
        narrator: widget.listen.voiceName,
        dialogue: widget.listen.dialogueVoice,
        slots: NeuralEngine.instance.slots,
        here: (v) => _catalog.byName(v) != null,
      );

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_refresh);
  }

  @override
  void dispose() {
    _catalog.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _give(Character c, String? voice) {
    setState(() => _cast = _cast.withVoice(c.name, voice));
    _prefs
      ..setCast(widget.bookId, _cast)
      ..save();
  }

  /// [c]'s own words in [voice] (the dialogue voice's for null).
  Future<void> _hear(Character c, String? voice) async {
    final name = voice == BookCast.narrator ? widget.listen.voiceName : voice ?? widget.listen.dialogueVoice ?? widget.listen.voiceName;
    if (name == null) return;
    setState(() => _hearing = c.name);
    try {
      await speakSample(
        voiceName: name,
        text: c.sample.isEmpty ? 'This is how ${c.isI ? 'the storyteller' : c.name} will sound.' : c.sample,
        settings: _prefs.settingsFor(name, book: widget.bookId),
        engineId: _prefs.engineId ?? _catalog.engineId,
      );
    } on Object catch (e) {
      debugPrint('Voice sample failed: $e');
      if (mounted) showSnack(context, 'That voice could not play a sample. Try another.');
    } finally {
      if (mounted) setState(() => _hearing = null);
    }
  }

  /// What [voice] is called here.
  String _voiceName(String? voice) {
    if (voice == null) return 'Dialogue voice';
    if (voice == BookCast.narrator) return "Narrator's voice";
    final v = _catalog.byName(voice);
    return v == null ? 'A voice no longer on this phone' : _catalog.friendlyName(v);
  }

  @override
  Widget build(BuildContext context) {
    final faint = Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)).copyWith(height: 1.4);
    final people = _cast.people.take(_listed).toList();
    final heard = _heard;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader('Characters', subtitle: widget.title),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
            child: Text(
              people.isEmpty
                  ? 'No one is named in this book\'s speech tags, so its dialogue stays in one voice.'
                  : 'Who speaks, found from the book\'s speech tags ("said Elizabeth"). Give anyone a voice of '
                      'their own; a line that cannot be placed is read in the dialogue voice.',
              style: faint,
            ),
          ),
          if (people.isNotEmpty)
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: Gap.xl),
                children: [
                  for (var i = 0; i < people.length; i++) _row(context, people[i], i, heard),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Character c, int i, Map<int, String> heard) {
    final chosen = _cast.voices[c.name];
    final waiting = chosen != null && !heard.containsKey(i);
    final busy = _hearing == c.name;
    final lines = '${c.lines} ${c.lines == 1 ? 'line' : 'lines'}';
    final also = c.also.isEmpty ? '' : ' · ${c.also.join(', ')}';
    return InkWell(
      onTap: () => _pick(c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.m, Gap.s),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${characterName(c)}$also',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context)),
                  ),
                  Text(
                    waiting ? '$lines · ${_voiceName(chosen)}, not now: ${_refusal(c, chosen)}' : '$lines · ${_voiceName(chosen)}',
                    style: Skin.ui(
                      size: 13,
                      weight: FontWeight.w400,
                      color: chosen == null ? Skin.inkFaintOn(context) : Skin.accentSoftOf(context),
                    ),
                  ),
                ],
              ),
            ),
            if (chosen != null)
              IconButton(
                tooltip: 'Hear ${c.isI ? 'the storyteller' : c.name}',
                onPressed: busy ? null : () => _hear(c, chosen),
                icon: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.play_circle_outline_rounded, color: Skin.accentSoftOf(context), size: 28),
              ),
            Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
          ],
        ),
      ),
    );
  }

  String _refusal(Character c, String voice) =>
      (castRefusal(
                _cast.withVoice(c.name, null),
                c.name,
                voice,
                narrator: widget.listen.voiceName,
                dialogue: widget.listen.dialogueVoice,
                slots: NeuralEngine.instance.slots,
              ) ??
              'the voice is not on this phone')
          .toLowerCase();

  Future<void> _pick(Character c) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => carryTint(
        context,
        _VoiceFor(
          character: c,
          cast: _cast,
          listen: widget.listen,
          onHear: (voice) => _hear(c, voice),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _give(c, picked.isEmpty ? null : picked);
    if (picked.isNotEmpty) unawaited(_hear(c, picked));
  }
}

/// The voices one character can be given: the dialogue voice, the
/// narrator's, or one of the book's language, each with a sample of their
/// own words. Those the cast has no room for say why. Pops the choice:
/// '' for the dialogue voice.
class _VoiceFor extends StatelessWidget {
  const _VoiceFor({required this.character, required this.cast, required this.listen, required this.onHear});

  final Character character;
  final BookCast cast;
  final ListenController listen;
  final void Function(String? voice) onHear;

  @override
  Widget build(BuildContext context) {
    final catalog = VoiceCatalog.instance;
    final narrator = listen.voiceName;
    final dialogue = listen.dialogueVoice;
    final chosen = cast.voices[character.name];
    final others = cast.withVoice(character.name, null);
    final voices = [
      for (final v in catalog.forLanguage(listen.language, keep: chosen))
        if (v.name != narrator && v.name != dialogue) v,
    ];
    final dialogueName = catalog.byName(dialogue);
    final name = characterName(character);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          children: [
            SheetHeader(name, subtitle: 'Whose voice reads their lines'),
            SheetAction(
              icon: chosen == null ? Icons.radio_button_checked_rounded : Icons.forum_outlined,
              label: 'Dialogue voice',
              detail: dialogueName == null
                  ? 'As the rest of the dialogue: the narrator\'s voice'
                  : 'As the rest of the dialogue: ${catalog.friendlyName(dialogueName)}',
              onTap: () => Navigator.pop(context, ''),
            ),
            SheetAction(
              icon: chosen == BookCast.narrator ? Icons.radio_button_checked_rounded : Icons.person_outline_rounded,
              label: 'Narrator',
              detail: 'Read in the narrator\'s own voice',
              onTap: () => Navigator.pop(context, BookCast.narrator),
            ),
            if (voices.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.xs),
                child: Eyebrow('Voices'),
              ),
            for (final v in voices)
              _voiceRow(
                context,
                v,
                selected: v.name == chosen,
                refusal: castRefusal(
                  others,
                  character.name,
                  v.name,
                  narrator: narrator,
                  dialogue: dialogue,
                  slots: NeuralEngine.instance.slots,
                ),
              ),
            const SizedBox(height: Gap.s),
          ],
        ),
      ),
    );
  }

  Widget _voiceRow(BuildContext context, VoiceInfo v, {required bool selected, required String? refusal}) {
    final catalog = VoiceCatalog.instance;
    final off = refusal != null && !selected;
    final ink = off ? Skin.inkFaintOn(context) : Skin.inkOn(context);
    return InkWell(
      onTap: off ? () => showSnack(context, '$refusal.') : () => Navigator.pop(context, v.name),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.m, Gap.s),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              size: 22,
              color: selected ? Skin.accentOf(context) : Skin.inkFaintOn(context),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(catalog.friendlyName(v), style: Skin.ui(size: 16, weight: FontWeight.w600, color: ink)),
                  Text(
                    off ? refusal : (isNeural(v.name) ? '${v.languageLabel} · natural' : v.languageLabel),
                    style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Hear ${catalog.friendlyName(v)}',
              onPressed: () => onHear(v.name),
              icon: Icon(Icons.play_circle_outline_rounded, color: Skin.accentSoftOf(context), size: 28),
            ),
          ],
        ),
      ),
    );
  }
}
