import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Speaking instead of typing: the phone's own speech recogniser (Google's
/// voice typing on most phones), through Dictation.kt. Free, with no key,
/// offline for the languages the phone has downloaded; nothing is recorded
/// or kept, only the words come back.
///
/// The recogniser stops by itself after a pause; while the reader has not
/// tapped stop, it is started again, so a long thought is not cut short.
class Dictation {
  Dictation({MethodChannel? channel}) : _ch = channel ?? defaultChannel {
    _ch.setMethodCallHandler(_event);
  }

  static const defaultChannel = MethodChannel('tomevoice/dictate');

  final MethodChannel _ch;

  /// Listening now (from the first start to the last words after stop).
  final listening = ValueNotifier<bool>(false);

  /// The words being said, as heard so far (not yet whole).
  final heard = ValueNotifier<String>('');

  /// How loud, from 0 to 1, for the microphone's ring.
  final level = ValueNotifier<double>(0);

  /// Each run of words, whole, as the recogniser settles on it.
  void Function(String words)? onWords;

  /// Something went wrong, said for the reader.
  void Function(String problem)? onProblem;

  bool _wanted = false;
  String? _language;
  bool _disposed = false;

  /// Whether the phone has a speech recogniser at all.
  static Future<bool> available({MethodChannel channel = defaultChannel}) async {
    try {
      return await channel.invokeMethod<bool>('available') ?? false;
    } on Object {
      return false;
    }
  }

  /// Listening begins, in [language] (a BCP 47 tag such as "en" or "bn-IN";
  /// null: the phone's own). False when it could not (no microphone
  /// allowed, no recogniser): [onProblem] has said why.
  Future<bool> start({String? language}) async {
    _wanted = true;
    _language = language;
    final String? r;
    try {
      r = await _ch.invokeMethod<String>('start', {'language': language});
    } on Object {
      _wanted = false;
      onProblem?.call('Speaking does not work on this phone.');
      return false;
    }
    if (r != 'listening') {
      _wanted = false;
      onProblem?.call(r == 'denied'
          ? "TomeVoice may not use the microphone. Allow it in the phone's settings to speak here."
          : 'This phone has no speech recogniser. Google\'s speech services (or another) add one.');
      return false;
    }
    if (!_disposed) listening.value = true;
    return true;
  }

  /// Listening ends; the last words still come.
  Future<void> stop() async {
    _wanted = false;
    try {
      await _ch.invokeMethod<void>('stop');
    } on Object {
      if (!_disposed) listening.value = false;
    }
  }

  Future<void> _event(MethodCall call) async {
    if (_disposed) return;
    final a = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'partial':
        heard.value = '${a['text'] ?? ''}';
      case 'final':
        final words = '${a['text'] ?? ''}'.trim();
        heard.value = '';
        if (words.isNotEmpty) onWords?.call(words);
        _again();
      case 'level':
        // About -2 dB in a quiet room to 10 dB speaking up.
        final db = (a['db'] as num?)?.toDouble() ?? 0;
        level.value = ((db + 2) / 12).clamp(0.0, 1.0);
      case 'error':
        final code = (a['code'] as num?)?.toInt() ?? 0;
        // Nothing heard, or a pause too long: listening goes on, if wanted.
        if (code == 6 || code == 7) {
          _again();
          return;
        }
        _wanted = false;
        listening.value = false;
        heard.value = '';
        level.value = 0;
        final problem = problemOf(code, _language);
        if (problem != null) onProblem?.call(problem);
    }
  }

  void _again() {
    if (_wanted) {
      unawaited(_ch.invokeMethod<String>('start', {'language': _language}).then((r) {
        if (r != 'listening' && !_disposed) {
          _wanted = false;
          listening.value = false;
        }
      }, onError: (Object _) {
        if (!_disposed) listening.value = false;
      }));
    } else {
      listening.value = false;
      level.value = 0;
    }
  }

  /// What a recogniser's error code means for the reader (null: nothing to
  /// say, as when it was stopped).
  @visibleForTesting
  static String? problemOf(int code, String? language) => switch (code) {
        1 || 2 => "The phone's speech recogniser needs the internet for this language. Download it for offline "
            "use in the phone's settings (Languages, then Speech).",
        3 => 'The microphone could not be used. Is another app using it?',
        4 => 'The speech service did not answer. Try again.',
        5 => null,
        8 => 'The speech recogniser is busy. Try again in a moment.',
        9 => "TomeVoice may not use the microphone. Allow it in the phone's settings to speak here.",
        12 || 13 => 'The phone cannot hear ${language == null ? 'this language' : 'this book\'s language ($language)'} '
            "yet. Add it in the phone's settings (Languages, then Speech).",
        _ => 'Speaking stopped (the recogniser said $code). Try again.',
      };

  /// Stopped and let go.
  void dispose() {
    _wanted = false;
    _disposed = true;
    unawaited(_ch.invokeMethod<void>('cancel').catchError((Object _) {}));
    _ch.setMethodCallHandler(null);
    listening.dispose();
    heard.dispose();
    level.dispose();
  }
}

/// [words] put into [text] at [at] (or at the end): a space before them
/// when needed, and a capital when they begin a sentence. The new text, and
/// where the cursor goes (after them).
({String text, int at}) insertWords(String text, String words, {int? at}) {
  final i = at == null || at < 0 || at > text.length ? text.length : at;
  final before = text.substring(0, i), after = text.substring(i);
  var w = words.trim();
  if (w.isEmpty) return (text: text, at: i);
  final lead = before.trimRight();
  if (lead.isEmpty || RegExp(r'[.!?…]$').hasMatch(lead) || before.endsWith('\n')) {
    w = w[0].toUpperCase() + w.substring(1);
  }
  final space = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before) ? ' ' : '';
  final tail = after.isNotEmpty && !RegExp(r'^[\s.,;:!?]').hasMatch(after) ? ' ' : '';
  final put = '$space$w$tail';
  return (text: '$before$put$after', at: i + space.length + w.length);
}
