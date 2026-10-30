import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'neural_voices.dart';
import 'prefs.dart';
import 'scheduler.dart' show SpeakerVoices;
import 'speakers.dart';
import 'voices.dart';

// A voice for each of a book's characters ("Level 2" in
// docs/road-to-1.0.html): who says each quotation is found from the book's
// speech tags (speakers.dart), and the lines of a character given a voice
// are read in it, aloud and in Save as audio alike. Everyone else's, and
// every line it cannot place, stay in the dialogue voice.

/// The most voices a book's characters are read in, besides the narrator's
/// and the dialogue voice: more are hard to tell apart by ear, and each
/// natural one is a model held in memory.
const maxCastVoices = 4;

/// The voice each of [cast]'s characters is read in now, by their place in
/// its people: their own ([BookCast.narrator] is [narrator]'s), within the
/// limits. The characters with the most lines come first, and a voice that
/// would be the fifth, or a natural voice whose model would be one more
/// than the phone holds ([slots], or the narrator's and the dialogue
/// voice's where those two are already more), is not given: that character
/// stays in the dialogue voice. So reading never loads more models at once
/// than the phone keeps, and never reloads one between two characters'
/// lines. [here] says whether a voice is still on the phone.
Map<int, String> castVoices(
  BookCast cast, {
  required String? narrator,
  required String? dialogue,
  required int slots,
  bool Function(String voice)? here,
}) {
  final models = <String>{
    for (final v in [narrator, dialogue])
      if (neuralVoiceFor(v) case final natural?) natural.modelId,
  };
  final room = math.max(slots, models.length);
  final distinct = <String>{};
  final out = <int, String>{};
  for (var i = 0; i < cast.people.length; i++) {
    final chosen = cast.voices[cast.people[i].name];
    if (chosen == null) continue;
    if (chosen == BookCast.narrator) {
      if (narrator != null) out[i] = narrator;
      continue;
    }
    if (here != null && !here(chosen)) continue;
    if (chosen != narrator && chosen != dialogue && !distinct.contains(chosen)) {
      if (distinct.length >= maxCastVoices) continue;
      final natural = neuralVoiceFor(chosen);
      if (natural != null && !models.contains(natural.modelId)) {
        if (models.length >= room) continue;
        models.add(natural.modelId);
      }
      distinct.add(chosen);
    }
    out[i] = chosen;
  }
  return out;
}

/// Why [voice] would not be [name]'s in [cast] now, as a line to show; null
/// when it would be.
String? castRefusal(
  BookCast cast,
  String name,
  String voice, {
  required String? narrator,
  required String? dialogue,
  required int slots,
}) {
  if (voice == BookCast.narrator) return null;
  final trial = cast.withVoice(name, voice);
  final i = trial.people.indexWhere((c) => c.name == name);
  if (i < 0 || castVoices(trial, narrator: narrator, dialogue: dialogue, slots: slots)[i] == voice) return null;
  final natural = neuralVoiceFor(voice);
  final models = {
    for (final v in [narrator, dialogue, ...trial.voices.values])
      if (neuralVoiceFor(v) case final n?) n.modelId,
  };
  if (natural != null && models.length > math.max(slots, 1)) {
    return slots == 1
        ? 'This phone keeps one natural voice loaded at a time'
        : 'This phone keeps $slots natural voices loaded at a time';
  }
  return 'The characters already have $maxCastVoices voices';
}

/// [layout]'s characters, found on another isolate (a long book takes a
/// second or more): most lines first, each with a line of theirs to hear.
/// None for a book not in English, whose speech tags are not read.
Future<List<Character>> findBookCharacters(ReadingLayout layout) async {
  final language = (layout.book.metadata.language ?? 'en').toLowerCase();
  if (!language.startsWith('en') || layout.isEmpty) return const [];
  final text = BookText.of(layout);
  return Isolate.run(() => findCharacters(text));
}

/// Book id -> its characters as last found this run, and the layout's size
/// they were found in: a book's page opened again does not read it again.
final _found = <String, ({int units, Future<List<Character>> people})>{};

/// Book [bookId]'s characters (see [findBookCharacters]), found once a run.
Future<List<Character>> bookCharacters(String bookId, ReadingLayout layout) {
  final had = _found[bookId];
  if (had != null && had.units == layout.units.length) return had.people;
  final people = findBookCharacters(layout).catchError((Object e) {
    debugPrint('TomeVoice: the characters could not be found ($e)');
    _found.remove(bookId);
    return const <Character>[];
  });
  _found[bookId] = (units: layout.units.length, people: people);
  return people;
}

/// Attribution of one stretch on another isolate: its units' speakers.
Future<Int32List> _onAnotherIsolate(BookText part, List<Character> people) =>
    Isolate.run(() => speakersOf(part, CastIndex(people)));

/// The cast of book [bookId] as reading aloud and Save as audio use it:
/// for each sentence, the voice its quotations' speaker is given. Nothing
/// is read or worked out for a book whose characters have no voices.
///
/// The book is read for its speakers a stretch at a time (a chapter, or
/// three hundred paragraphs of one), on another isolate so the screen never
/// waits for it, and the stretch after the one being read is read ahead.
///
/// Tests give [attribute] (how a stretch is read), [slots] (the natural
/// voices the phone holds) and [here] (whether a voice is on the phone).
class CastReading implements SpeakerVoices {
  CastReading({
    required this.bookId,
    required this.layout,
    required this.prefs,
    required this.narrator,
    required this.dialogue,
    Future<Int32List> Function(BookText part, List<Character> people)? attribute,
    int? slots,
    bool Function(String voice)? here,
  })  : _attribute = attribute ?? _onAnotherIsolate,
        _slots = slots,
        _here = here;

  final String bookId;

  /// The chapters being read (a web novel's window grows as it reads on).
  final ReadingLayout Function() layout;
  final ListeningPrefs Function() prefs;

  /// The narrator's voice and the dialogue voice, as they are now.
  final String? Function() narrator;
  final String? Function() dialogue;

  final Future<Int32List> Function(BookText part, List<Character> people) _attribute;
  final int? _slots;
  final bool Function(String voice)? _here;

  BookCast? get _cast {
    final c = prefs().castByBook[bookId];
    return c != null && c.anyVoice ? c : null;
  }

  // The voices, worked out again only when the cast or the two voices around
  // it change.
  BookCast? _forCast;
  String? _forNarrator;
  String? _forDialogue;
  Map<int, String> _voices = const {};

  Map<int, String> _voicesOf(BookCast cast) {
    final n = narrator();
    final d = dialogue();
    if (!identical(cast, _forCast) || n != _forNarrator || d != _forDialogue) {
      _forCast = cast;
      _forNarrator = n;
      _forDialogue = d;
      _voices = castVoices(
        cast,
        narrator: n,
        dialogue: d,
        slots: _slots ?? NeuralEngine.instance.slots,
        here: _here ?? (v) => VoiceCatalog.instance.byName(v) != null,
      );
    }
    return _voices;
  }

  @override
  Iterable<String> get voices {
    final cast = _cast;
    return cast == null ? const [] : _voicesOf(cast).values.toSet();
  }

  // The book as read for its speakers: for the layout and the people it
  // was read with.
  ReadingLayout? _layout;
  List<Character>? _people;
  BookText? _text;
  List<(int, int)> _stretches = const [];

  /// Stretch -> each of its units' speaker (a place in the people, or -1).
  final _found = <int, Int32List>{};
  final _finding = <int, Future<Int32List>>{};

  void _readFor(BookCast cast) {
    final l = layout();
    if (identical(l, _layout) && identical(cast.people, _people)) return;
    _layout = l;
    _people = cast.people;
    _text = BookText.of(l);
    _stretches = _text!.stretches();
    _found.clear();
    _finding.clear();
  }

  int _stretchOf(int paragraph) {
    var lo = 0, hi = _stretches.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_stretches[mid].$1 <= paragraph) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  @override
  FutureOr<String?> voiceAt(int unit) {
    final cast = _cast;
    if (cast == null || _voicesOf(cast).isEmpty) return null;
    _readFor(cast);
    final text = _text!;
    final p = text.paragraphOf(unit);
    if (p < 0) return null;
    final s = _stretchOf(p);
    final found = _found[s];
    if (found != null) {
      _readAhead(s + 1, cast);
      return _pick(found, s, unit, cast);
    }
    // Found in this layout's sentences: if the reading moved on to a longer
    // layout meanwhile, this one line keeps the dialogue voice.
    return _find(s, cast).then((f) => identical(_text, text) ? _pick(f, s, unit, cast) : null);
  }

  String? _pick(Int32List found, int s, int unit, BookCast cast) {
    final text = _text;
    if (text == null || s >= _stretches.length) return null;
    final at = unit - text.firstUnit[_stretches[s].$1];
    if (at < 0 || at >= found.length || found[at] < 0) return null;
    return _voicesOf(cast)[found[at]];
  }

  Future<Int32List> _find(int s, BookCast cast) {
    final text = _text!;
    final (from, to) = _stretches[s];
    final people = cast.people;
    return _finding[s] ??= _attribute(text.part(from, to), people).then((found) {
      // Read for a layout or a cast replaced meanwhile: not kept.
      if (identical(_text, text) && identical(_people, people)) {
        _found[s] = found;
        _finding.remove(s);
      }
      return found;
    }, onError: (Object e) {
      // Read in the dialogue voice, as before, rather than not at all.
      debugPrint('TomeVoice: who speaks could not be found here ($e)');
      final n = text.firstUnit[to - 1] + text.unitCount[to - 1] - text.firstUnit[from];
      final none = Int32List(n)..fillRange(0, n, -1);
      if (identical(_text, text)) {
        _found[s] = none;
        _finding.remove(s);
      }
      return none;
    });
  }

  void _readAhead(int s, BookCast cast) {
    if (s >= _stretches.length || _found.containsKey(s) || _finding.containsKey(s)) return;
    unawaited(_find(s, cast));
  }
}
