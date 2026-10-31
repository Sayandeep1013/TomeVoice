import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'folders.dart';
import 'safe_file.dart';
import 'speakers.dart' show BookCast;
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
    Map<String, BookCast>? castByBook,
    Map<String, double>? pitchByVoice,
    Map<String, double>? speedByBook,
    Map<String, int>? highlightOffsetMs,
    this.skipBy = SkipBy.sentence,
    Map<String, bool>? newestFirstByNovel,
    Map<String, String>? autoDownloadByNovel,
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
    this.notesAloud = false,
    this.keepScreenOn = false,
    this.pageBrightness,
    this.pageWarmth = 0,
    this.autoScrollLines = 24,
    this.autoPageSeconds = 30,
    this.themeMode = ThemeMode.system,
    this.paletteId = 'forest',
    this.updateEvery = 'daily',
    this.novelUpdates = false,
    this.gridView = true,
    this.sort = LibrarySort.recent,
    this.bookColours = true,
    this.naturalVoices,
    this.exportFolder,
    this.backupEvery = 'off',
    this.backupFolder,
    this.backupChapters = false,
    this.lastBackup,
    this.webdavOn = false,
    this.webdavUrl,
    this.webdavUser,
    this.kosyncOn = false,
    this.kosyncUrl,
    this.kosyncUser,
    List<Map<String, Object?>>? catalogues,
    Map<String, String>? catalogueUsers,
  })  : catalogues = catalogues ?? [],
        catalogueUsers = catalogueUsers ?? {},
        voiceByLanguage = voiceByLanguage ?? {},
        voiceByBook = voiceByBook ?? {},
        dialogueByBook = dialogueByBook ?? {},
        castByBook = castByBook ?? {},
        pitchByVoice = pitchByVoice ?? {},
        speedByBook = speedByBook ?? {},
        highlightOffsetMs = highlightOffsetMs ?? {},
        newestFirstByNovel = newestFirstByNovel ?? {},
        autoDownloadByNovel = autoDownloadByNovel ?? {};

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

  /// Book id -> its characters and the voices they are read in, for a book
  /// whose characters were given any (see BookCast). Kept here with the
  /// book's other voices, so a backup carries it as it carries them.
  final Map<String, BookCast> castByBook;

  /// Keep [cast] for [book]; one that gives nobody a voice is not kept.
  void setCast(String book, BookCast? cast) {
    if (cast == null || !cast.anyVoice) {
      castByBook.remove(book);
    } else {
      castByBook[book] = cast;
    }
  }

  /// Voice name -> its pitch in semitones, for the voices given one. Each
  /// voice keeps its own: on Google's voices any pitch but 0 makes Google
  /// switch to an older, rougher model, so a pitch set for one voice must
  /// not follow the reader to the next. Natural voices take no pitch.
  final Map<String, double> pitchByVoice;

  /// [voice]'s own pitch, in semitones; 0 unless it was given one.
  double pitchOf(String? voice) => voice == null ? 0 : pitchByVoice[voice] ?? 0;

  void setPitch(String voice, double semitones) {
    if (semitones == 0) {
      pitchByVoice.remove(voice);
    } else {
      pitchByVoice[voice] = semitones;
    }
  }

  /// The listening settings as [voice] is heard with them in [book]: the
  /// voice's own pitch, and the book's own speed if it has one.
  PipelineSettings settingsFor(String? voice, {String? book}) =>
      settings.copyWith(pitchSemitones: pitchOf(voice), speedScale: speedFor(book));

  /// Book id -> its own speed, for a book given one ("for this book only"):
  /// people read fiction at 1x and skim reports at 2.5x (docs/05 section
  /// 5.1). Every other book reads at the speed in [settings].
  final Map<String, double> speedByBook;

  /// The speed [book] is read at.
  double speedFor(String? book) => (book == null ? null : speedByBook[book]) ?? settings.speedScale;

  /// A new speed for [book]: its own, if it has one, else the one for every book.
  void setSpeed(double speed, {String? book}) {
    if (book != null && speedByBook.containsKey(book)) {
      speedByBook[book] = speed;
    } else {
      settings = settings.copyWith(speedScale: speed);
    }
  }

  /// Give [book] a speed of its own (at the speed it reads at now), or take
  /// it away so it reads at everyone's again.
  void setOwnSpeed(String book, bool own) {
    if (own) {
      speedByBook[book] = speedFor(book);
    } else {
      speedByBook.remove(book);
    }
  }

  /// What next and previous do on headphones, the lock screen and the
  /// notification.
  SkipBy skipBy;

  /// Route (`bluetooth`, `other`) -> how much later the highlight moves than
  /// the platform says the voice is heard, in ms: the listener's own fix for
  /// a headset whose delay the phone does not know (docs/05 section 5.9).
  final Map<String, int> highlightOffsetMs;

  int highlightOffset(String route) => highlightOffsetMs[route] ?? 0;

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

  /// Web novel id -> when its new chapters download by themselves as a
  /// check finds them: "wifi" (on Wi-Fi only) or "any" (on any network).
  /// A novel not here does not (see AutoDownload).
  final Map<String, String> autoDownloadByNovel;

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

  /// Footnotes and endnotes read aloud where they stand, instead of only
  /// shown. Off by default; their markers in the text are never read.
  bool notesAloud;

  /// Keep the display awake while a book is open.
  bool keepScreenOn;

  /// The screen's brightness while a book is open, 0 (darker than the phone
  /// goes) to 1 (full); null leaves it as the phone has it (see PageLight).
  double? pageBrightness;

  /// Amber over the page for reading at night, 0 (none) to 1.
  double pageWarmth;

  /// How fast auto-scroll moves the scroll, in lines a minute, and how long
  /// it leaves each page in pages, in seconds (see AutoScroll).
  int autoScrollLines;
  int autoPageSeconds;

  /// Light, dark, or the phone's choice.
  ThemeMode themeMode;

  /// The colour theme: forest, lavender, ocean, black or paper.
  String paletteId;

  /// How often web novels are checked for new chapters (see UpdateEvery).
  String updateEvery;

  /// A link on each web novel's page to find it on NovelUpdates, in the
  /// browser (see NovelUpdates). Off until turned on.
  bool novelUpdates;

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

  /// Where quotes exported as Markdown were last saved.
  PickedFolder? exportFolder;

  /// Automatic backups: off, daily or weekly (see BackupEvery), into
  /// [backupFolder], with downloaded chapters only if [backupChapters].
  String backupEvery;
  PickedFolder? backupFolder;
  bool backupChapters;

  /// When the last automatic backup was made.
  DateTime? lastBackup;

  /// Sync through a WebDAV folder of the reader's own (places, quotes,
  /// bookmarks, reading time; never the books). Off until set up. The
  /// password is kept apart, off backups (see Secrets).
  bool webdavOn;
  String? webdavUrl;
  String? webdavUser;

  /// Sync places with KOReader's sync server (koreader-sync-server). Off
  /// until set up; the password's key kept apart, as above.
  bool kosyncOn;
  String? kosyncUrl;
  String? kosyncUser;

  /// OPDS catalogues the reader added (see Catalogue), and the user names
  /// they sign in to the built-in ones with: kept with the settings, so a
  /// restore brings them back. Their passwords are kept apart.
  final List<Map<String, Object?>> catalogues;
  final Map<String, String> catalogueUsers;

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
        if (castByBook.isNotEmpty) 'castByBook': {for (final e in castByBook.entries) e.key: e.value.toJson()},
        'pitchByVoice': pitchByVoice,
        'speedByBook': speedByBook,
        'highlightOffsetMs': highlightOffsetMs,
        'skipBy': skipBy.name,
        'newestFirstByNovel': newestFirstByNovel,
        if (autoDownloadByNovel.isNotEmpty) 'autoDownloadByNovel': autoDownloadByNovel,
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
        if (notesAloud) 'notesAloud': true,
        'keepScreenOn': keepScreenOn,
        if (pageBrightness != null) 'pageBrightness': pageBrightness,
        if (pageWarmth > 0) 'pageWarmth': pageWarmth,
        if (autoScrollLines != 24) 'autoScrollLines': autoScrollLines,
        if (autoPageSeconds != 30) 'autoPageSeconds': autoPageSeconds,
        'themeMode': themeMode.name,
        'palette': paletteId,
        'updateEvery': updateEvery,
        if (novelUpdates) 'novelUpdates': true,
        'gridView': gridView,
        'sort': sort.name,
        'bookColours': bookColours,
        if (naturalVoices != null) 'naturalVoices': naturalVoices,
        if (exportFolder != null) 'exportFolder': exportFolder!.toJson(),
        if (backupEvery != 'off') 'backupEvery': backupEvery,
        if (backupFolder != null) 'backupFolder': backupFolder!.toJson(),
        if (backupChapters) 'backupChapters': true,
        if (lastBackup != null) 'lastBackup': lastBackup!.toIso8601String(),
        if (webdavOn) 'webdavOn': true,
        if (webdavUrl != null) 'webdavUrl': webdavUrl,
        if (webdavUser != null) 'webdavUser': webdavUser,
        if (kosyncOn) 'kosyncOn': true,
        if (kosyncUrl != null) 'kosyncUrl': kosyncUrl,
        if (kosyncUser != null) 'kosyncUser': kosyncUser,
        if (catalogues.isNotEmpty) 'catalogues': catalogues,
        if (catalogueUsers.isNotEmpty) 'catalogueUsers': catalogueUsers,
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
        castByBook: {
          for (final e in (json['castByBook'] is Map ? json['castByBook'] as Map : const {}).entries)
            if (BookCast.fromJson(e.value) case final cast? when cast.anyVoice) '${e.key}': cast,
        },
        pitchByVoice: {
          for (final e in (json['pitchByVoice'] as Map? ?? const {}).entries)
            if (e.value is num) e.key.toString(): (e.value as num).toDouble().clamp(-12, 12).toDouble(),
        },
        speedByBook: {
          for (final e in (json['speedByBook'] as Map? ?? const {}).entries)
            if (e.value is num) e.key.toString(): (e.value as num).toDouble().clamp(0.5, 3.0).toDouble(),
        },
        highlightOffsetMs: {
          for (final e in (json['highlightOffsetMs'] as Map? ?? const {}).entries)
            if (e.value is num) e.key.toString(): (e.value as num).toInt().clamp(-300, 500),
        },
        skipBy: SkipBy.values.where((s) => s.name == json['skipBy']).firstOrNull ?? SkipBy.sentence,
        newestFirstByNovel: {
          for (final e in (json['newestFirstByNovel'] as Map? ?? const {}).entries)
            if (e.value is bool) e.key.toString(): e.value as bool,
        },
        autoDownloadByNovel: {
          for (final e in (json['autoDownloadByNovel'] is Map ? json['autoDownloadByNovel'] as Map : const {}).entries)
            if (e.value is String) e.key.toString(): e.value as String,
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
        notesAloud: json['notesAloud'] == true,
        keepScreenOn: json['keepScreenOn'] == true,
        pageBrightness: (json['pageBrightness'] as num?)?.toDouble().clamp(0.0, 1.0).toDouble(),
        pageWarmth: ((json['pageWarmth'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0).toDouble(),
        autoScrollLines: ((json['autoScrollLines'] as num?)?.toInt() ?? 24).clamp(4, 120),
        autoPageSeconds: ((json['autoPageSeconds'] as num?)?.toInt() ?? 30).clamp(3, 600),
        themeMode: ThemeMode.values.where((m) => m.name == json['themeMode']).firstOrNull ??
            ThemeMode.system,
        gridView: json['gridView'] as bool? ?? true,
        paletteId: json['palette'] as String? ?? 'forest',
        updateEvery: json['updateEvery'] as String? ?? 'daily',
        novelUpdates: json['novelUpdates'] == true,
        sort: LibrarySort.values.where((m) => m.name == json['sort']).firstOrNull ??
            LibrarySort.recent,
        bookColours: json['bookColours'] != false,
        naturalVoices: json['naturalVoices'] as bool?,
        exportFolder: PickedFolder.fromJson(json['exportFolder']),
        backupEvery: json['backupEvery'] as String? ?? 'off',
        backupFolder: PickedFolder.fromJson(json['backupFolder']),
        backupChapters: json['backupChapters'] == true,
        lastBackup: DateTime.tryParse(json['lastBackup'] as String? ?? ''),
        webdavOn: json['webdavOn'] == true,
        webdavUrl: json['webdavUrl'] as String?,
        webdavUser: json['webdavUser'] as String?,
        kosyncOn: json['kosyncOn'] == true,
        kosyncUrl: json['kosyncUrl'] as String?,
        kosyncUser: json['kosyncUser'] as String?,
        catalogues: [
          for (final c in json['catalogues'] is List ? json['catalogues'] as List : const [])
            if (c is Map) Map<String, Object?>.from(c),
        ],
        catalogueUsers: {
          for (final e in (json['catalogueUsers'] is Map ? json['catalogueUsers'] as Map : const {}).entries)
            if (e.value is String) '${e.key}': e.value as String,
        },
      );
}

/// What next and previous do on headphones, the lock screen and the
/// notification. A sentence by default: a whole chapter was lost to an
/// accidental double press.
enum SkipBy {
  sentence('Sentence'),
  seconds('30 seconds'),
  chapter('Chapter');

  const SkipBy(this.label);

  final String label;
}

/// How the library orders books.
enum LibrarySort {
  recent('Last read'),
  added('Date added'),
  title('Title'),
  author('Author'),
  series('Series'),
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
    // Pitch is each voice's own (ListeningPrefs.pitchByVoice). The one
    // pitch every voice once shared is not carried over: on a Google voice
    // it had switched every voice to Google's older model.
  );
}
