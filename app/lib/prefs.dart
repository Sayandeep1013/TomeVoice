import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'safe_file.dart';
import 'theme.dart';

/// What the reader chose, remembered across books and launches: voice and
/// listening settings, how the page looks, and how the library is shown.
class ListeningPrefs {
  ListeningPrefs({
    this.settings = const PipelineSettings(),
    this.presetId = 'natural',
    Map<String, String>? voiceByLanguage,
    Map<String, String>? voiceByBook,
    Map<String, String>? dialogueByBook,
    Map<String, bool>? newestFirstByNovel,
    this.newestFirst = false,
    this.engineId,
    this.textSize = 19,
    this.pdfPages = false,
    this.bookFont = BookFont.newsreader,
    this.lineHeight = 1.6,
    this.margin = 22,
    this.justify = false,
    this.indent = false,
    this.pages = false,
    this.pageTurn = 'curl',
    this.pageTone = 'app',
    this.tapToTurn = true,
    this.volumeKeys = false,
    this.fullScreen = false,
    this.keepReading = true,
    this.keepScreenOn = false,
    this.themeMode = ThemeMode.system,
    this.paletteId = 'forest',
    this.updateEvery = 'daily',
    this.gridView = true,
    this.sort = LibrarySort.recent,
    this.bookColours = true,
    this.naturalVoices,
  })  : voiceByLanguage = voiceByLanguage ?? {},
        voiceByBook = voiceByBook ?? {},
        dialogueByBook = dialogueByBook ?? {},
        newestFirstByNovel = newestFirstByNovel ?? {};

  /// Bumped on every change, so the app (theme) and open screens can follow.
  static final revision = ValueNotifier<int>(0);

  PipelineSettings settings;
  String? presetId;

  /// Language code -> voice name. A Bengali book and an English book each
  /// keep their own voice.
  final Map<String, String> voiceByLanguage;

  /// Book id -> voice name, for a book given its own voice on its page.
  final Map<String, String> voiceByBook;

  /// Book id -> the voice its dialogue (words in quotation marks) is read
  /// in, when not the narrator's.
  final Map<String, String> dialogueByBook;

  /// Web novel id -> whether its page lists the newest chapter first, as
  /// the reader last turned it.
  final Map<String, bool> newestFirstByNovel;

  /// The order last chosen on any novel's page: a novel not turned yet
  /// opens this way.
  bool newestFirst;

  /// Whether the chapters of novel [id] are listed newest first.
  bool newestFirstFor(String id) => newestFirstByNovel[id] ?? newestFirst;

  void setNewestFirst(String id, bool value) {
    newestFirstByNovel[id] = value;
    newestFirst = value;
    save();
  }

  String? engineId;

  /// Size of the book's text, in logical pixels.
  double textSize;

  /// Show PDFs as their real pages instead of reflowed text.
  bool pdfPages;

  /// The typeface of the page.
  BookFont bookFont;

  /// Line height of the page, as a multiple of the text size.
  double lineHeight;

  /// Side margin of the page, in logical pixels.
  double margin;

  /// Justified text instead of ragged right.
  bool justify;

  /// Paragraphs as in a printed book: the first line indented and no gap
  /// between them, instead of a line's gap.
  bool indent;

  /// The book in pages turned one at a time, instead of one long scroll.
  bool pages;

  /// How a page turns: curl (over like paper), slide, or none (see
  /// PageTurn).
  String pageTurn;

  /// The page under the text: the app's colours, ink, papyrus or dusk (see
  /// PageTone).
  String pageTone;

  /// A tap near the left or right edge turns the page.
  bool tapToTurn;

  /// The volume keys turn pages (while nothing is being read aloud, when
  /// they still change the volume).
  bool volumeKeys;

  /// The phone's status and navigation bars hidden while reading.
  bool fullScreen;

  /// Leaving a book while it is read aloud does not stop it: the voice reads
  /// on, paused from the library's player or the card in the shade.
  bool keepReading;

  /// Keep the display awake while a book is open.
  bool keepScreenOn;

  /// Light, dark, or the phone's choice.
  ThemeMode themeMode;

  /// The colour theme: forest, lavender, ocean, black or paper.
  String paletteId;

  /// How often web novels are checked for new chapters (see UpdateEvery).
  String updateEvery;

  /// The library as a grid of covers instead of a list.
  bool gridView;

  /// Order of books in the library.
  LibrarySort sort;

  /// Each book's screens take the colour of its cover, and the library the
  /// colour of the book being read, instead of the palette's accent.
  bool bookColours;

  /// Natural voices: null until the reader has been asked, then whether
  /// they want them offered. Declined, the app never suggests them.
  bool? naturalVoices;

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
      // A corrupt prefs file is not worth refusing to open a book over; it
      // is kept beside as prefs.json.broken.
      await setAside(file);
    }
    _cached = prefs;
    revision.value++;
    return prefs;
  }

  /// In-memory prefs for tests and for when storage is unavailable.
  static ListeningPrefs get memory => _cached ??= ListeningPrefs();

  /// The prefs if [load] has run, without creating a default copy that would
  /// stop the saved file from ever being read.
  static ListeningPrefs? get loaded => _cached;

  @visibleForTesting
  static void reset() {
    _saveTimer?.cancel();
    _cached = null;
    _file = null;
  }

  void save() {
    revision.value++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      final file = _file;
      if (file == null) return;
      try {
        await writeSafely(file, jsonEncode(toJson()));
      } on Object {
        // Next change will try again.
      }
    });
  }

  Map<String, Object?> toJson() => {
        'settings': settingsToJson(settings),
        'presetId': presetId,
        'voiceByLanguage': voiceByLanguage,
        'voiceByBook': voiceByBook,
        'dialogueByBook': dialogueByBook,
        'newestFirstByNovel': newestFirstByNovel,
        'newestFirst': newestFirst,
        'engineId': engineId,
        'textSize': textSize,
        'pdfPages': pdfPages,
        'bookFont': bookFont.name,
        'lineHeight': lineHeight,
        'margin': margin,
        'justify': justify,
        'indent': indent,
        'pages': pages,
        'pageTurn': pageTurn,
        'pageTone': pageTone,
        'tapToTurn': tapToTurn,
        'volumeKeys': volumeKeys,
        'fullScreen': fullScreen,
        'keepReading': keepReading,
        'keepScreenOn': keepScreenOn,
        'themeMode': themeMode.name,
        'palette': paletteId,
        'updateEvery': updateEvery,
        'gridView': gridView,
        'sort': sort.name,
        'bookColours': bookColours,
        if (naturalVoices != null) 'naturalVoices': naturalVoices,
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
        dialogueByBook: {
          for (final e in (json['dialogueByBook'] as Map? ?? const {}).entries)
            e.key.toString(): e.value.toString(),
        },
        voiceByBook: {
          for (final e in (json['voiceByBook'] as Map? ?? const {}).entries)
            e.key.toString(): e.value.toString(),
        },
        newestFirstByNovel: {
          for (final e in (json['newestFirstByNovel'] as Map? ?? const {}).entries)
            if (e.value is bool) e.key.toString(): e.value as bool,
        },
        newestFirst: json['newestFirst'] == true,
        engineId: json['engineId'] as String?,
        textSize: ((json['textSize'] as num?)?.toDouble() ?? 19).clamp(14, 30).toDouble(),
        pdfPages: json['pdfPages'] == true,
        bookFont: BookFont.byName(json['bookFont'] as String?),
        lineHeight: ((json['lineHeight'] as num?)?.toDouble() ?? 1.6).clamp(1.3, 2.0).toDouble(),
        margin: ((json['margin'] as num?)?.toDouble() ?? 22).clamp(8, 48).toDouble(),
        justify: json['justify'] == true,
        indent: json['indent'] == true,
        pages: json['pages'] == true,
        pageTurn: json['pageTurn'] as String? ?? 'curl',
        pageTone: json['pageTone'] as String? ?? 'app',
        tapToTurn: json['tapToTurn'] != false,
        volumeKeys: json['volumeKeys'] == true,
        fullScreen: json['fullScreen'] == true,
        keepReading: json['keepReading'] != false,
        keepScreenOn: json['keepScreenOn'] == true,
        themeMode: ThemeMode.values.where((m) => m.name == json['themeMode']).firstOrNull ??
            ThemeMode.system,
        gridView: json['gridView'] as bool? ?? true,
        paletteId: json['palette'] as String? ?? 'forest',
        updateEvery: json['updateEvery'] as String? ?? 'daily',
        sort: LibrarySort.values.where((m) => m.name == json['sort']).firstOrNull ??
            LibrarySort.recent,
        bookColours: json['bookColours'] != false,
        naturalVoices: json['naturalVoices'] as bool?,
      );
}

/// How the library orders books.
enum LibrarySort {
  recent('Last read'),
  added('Date added'),
  title('Title'),
  progress('Progress');

  const LibrarySort(this.label);

  final String label;
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
