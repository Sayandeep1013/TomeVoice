import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

/// What the listener chose, remembered across books and launches. Every
/// earlier build forgot the voice and speed the moment a book closed.
class ListeningPrefs {
  ListeningPrefs({
    this.settings = const PipelineSettings(),
    this.presetId = 'natural',
    Map<String, String>? voiceByLanguage,
    this.engineId,
    this.textSize = 19,
  }) : voiceByLanguage = voiceByLanguage ?? {};

  PipelineSettings settings;
  String? presetId;

  /// Language code -> voice name. A Bengali book and an English book each
  /// keep their own voice.
  final Map<String, String> voiceByLanguage;
  String? engineId;

  /// Size of the book's text, in logical pixels.
  double textSize;

  static ListeningPrefs? _cached;
  static File? _file;
  static Timer? _saveTimer;

  /// Loaded once; every screen shares the same instance.
  static Future<ListeningPrefs> load(String dir) async {
    final cached = _cached;
    if (cached != null) return cached;
    final file = File('$dir/prefs.json');
    _file = file;
    var prefs = ListeningPrefs();
    try {
      if (await file.exists()) {
        prefs = fromJson(
          Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
        );
      }
    } on Object {
      // A corrupt prefs file is not worth refusing to open a book over.
    }
    return _cached = prefs;
  }

  /// In-memory prefs for tests and for when storage is unavailable.
  static ListeningPrefs get memory => _cached ??= ListeningPrefs();

  @visibleForTesting
  static void reset() {
    _saveTimer?.cancel();
    _cached = null;
    _file = null;
  }

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      final file = _file;
      if (file == null) return;
      try {
        await file.writeAsString(jsonEncode(toJson()));
      } on Object {
        // Next change will try again.
      }
    });
  }

  Map<String, Object?> toJson() => {
        'settings': settingsToJson(settings),
        'presetId': presetId,
        'voiceByLanguage': voiceByLanguage,
        'engineId': engineId,
        'textSize': textSize,
      };

  static ListeningPrefs fromJson(Map<String, Object?> json) => ListeningPrefs(
        settings: settingsFromJson(
          Map<String, Object?>.from(json['settings'] as Map? ?? const {}),
        ),
        presetId: json['presetId'] as String?,
        voiceByLanguage: {
          for (final e in (json['voiceByLanguage'] as Map? ?? const {}).entries)
            e.key.toString(): e.value.toString(),
        },
        engineId: json['engineId'] as String?,
        textSize: ((json['textSize'] as num?)?.toDouble() ?? 19).clamp(14, 30).toDouble(),
      );
}

Map<String, Object?> settingsToJson(PipelineSettings s) => {
      'wordGapMs': s.wordGapMs,
      'speedScale': s.speedScale,
      'sentencePauseMs': s.sentencePauseMs,
      'paragraphPauseMs': s.paragraphPauseMs,
      'commaMs': s.punctuation.commaMs,
      'clauseMs': s.punctuation.clauseMs,
      'colonMs': s.punctuation.colonMs,
      'dashMs': s.punctuation.dashMs,
      'ellipsisMs': s.punctuation.ellipsisMs,
      'volume': s.volume,
      'trimDb': s.trimDb,
      'normaliseLoudness': s.normaliseLoudness,
      'compression': s.compression.name,
      'pitchSemitones': s.pitchSemitones,
    };

PipelineSettings settingsFromJson(Map<String, Object?> j) {
  const d = PipelineSettings();
  int i(String k, int fallback) => (j[k] as num?)?.toInt() ?? fallback;
  double f(String k, double fallback) => (j[k] as num?)?.toDouble() ?? fallback;
  return d.copyWith(
    wordGapMs: i('wordGapMs', d.wordGapMs),
    speedScale: f('speedScale', d.speedScale),
    sentencePauseMs: i('sentencePauseMs', d.sentencePauseMs),
    paragraphPauseMs: i('paragraphPauseMs', d.paragraphPauseMs),
    punctuation: d.punctuation.copyWith(
      commaMs: i('commaMs', d.punctuation.commaMs),
      clauseMs: i('clauseMs', d.punctuation.clauseMs),
      colonMs: i('colonMs', d.punctuation.colonMs),
      dashMs: i('dashMs', d.punctuation.dashMs),
      ellipsisMs: i('ellipsisMs', d.punctuation.ellipsisMs),
    ),
    volume: f('volume', d.volume),
    trimDb: f('trimDb', d.trimDb),
    normaliseLoudness: j['normaliseLoudness'] as bool? ?? d.normaliseLoudness,
    compression: Compression.values.firstWhere(
      (c) => c.name == j['compression'],
      orElse: () => d.compression,
    ),
    pitchSemitones: f('pitchSemitones', d.pitchSemitones),
  );
}
