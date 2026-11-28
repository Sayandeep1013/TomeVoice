import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cloud_voices.dart';
import 'eleven_labs.dart';
import 'neural_voices.dart';
import 'speech_service.dart';

/// One system voice, with the names people actually read.
class VoiceInfo {
  const VoiceInfo({
    required this.name,
    required this.locale,
    required this.quality,
    required this.networkRequired,
    required this.installed,
  });

  final String name;

  /// BCP-47-ish: "en-US", "bn-IN", or "en_US" from older platforms.
  final String locale;
  final int quality;
  final bool networkRequired;
  final bool installed;

  String get language => locale.split(RegExp('[-_]')).first.toLowerCase();

  String get region {
    final parts = locale.split(RegExp('[-_]'));
    return parts.length > 1 ? parts[1].toUpperCase() : '';
  }

  /// "English (UK)".
  String get languageLabel {
    final lang = languageName(language);
    final r = regionLabel(region);
    return r.isEmpty ? lang : '$lang ($r)';
  }

  /// Google's "bn-IN-language": not a speaker of its own but whichever of
  /// that language's voices is chosen in Google's settings, so the same
  /// speaker listed twice.
  bool get isAlias => name.toLowerCase().endsWith('-language');

  /// Google voice names carry a short variant code: en-us-x-iob-local.
  String get variant {
    final m = RegExp(r'-x-([a-z0-9]+)', caseSensitive: false).firstMatch(name);
    if (m != null) return m.group(1)!.toUpperCase();
    if (name.toLowerCase().endsWith('-language')) return 'Default';
    return name;
  }

  Map<String, Object?> toMap() => {
        'name': name,
        'locale': locale,
        'quality': quality,
        'networkRequired': networkRequired,
        'installed': installed,
      };

  static VoiceInfo fromMap(Map<String, Object?> m) => VoiceInfo(
        name: m['name'] as String? ?? '',
        locale: m['locale'] as String? ?? '',
        quality: m['quality'] as int? ?? 0,
        networkRequired: m['networkRequired'] == true,
        installed: m['installed'] != false,
      );
}

/// Engines and their voices, loaded once per app run and shared by every
/// reader. Opening a book used to re-list engines and voices from scratch,
/// which is the delay before the voice chip filled in.
class VoiceCatalog extends ChangeNotifier {
  VoiceCatalog._();

  static final instance = VoiceCatalog._();

  static const _svc = SpeechService();

  List<Map<String, String>> engines = const [];
  String? engineId;
  List<VoiceInfo> voices = const [];
  String? error;
  bool loaded = false;

  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      // Natural voices are listed from their catalog: read it first, so a
      // book's natural voice is there when the list says it has loaded.
      await NeuralVoices.instance.ready;
      engines = await _svc.engines();
      engineId ??= engines.isNotEmpty ? engines.first['name'] : null;
      await _loadVoices();
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
    } on MissingPluginException {
      error = 'No speech engine';
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  Future<void> _loadVoices() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final list = await _svc.voices(engineId);
        if (list.isEmpty && attempt < 2) {
          // Some engines report no voices for a moment after binding.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        voices = [for (final v in list) VoiceInfo.fromMap(v)];
        error = null;
        return;
      } on PlatformException catch (e) {
        error = e.message ?? e.code;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// The phone's voices and the natural voices downloaded to it that can
  /// read here (a Kokoro voice only once this phone's test shows it keeps up).
  List<VoiceInfo> get all => [
        ...voices,
        for (final v in NeuralVoices.instance.readableVoices)
          VoiceInfo(name: v.voiceName, locale: v.locale, quality: 500, networkRequired: false, installed: true),
      ];

  /// A natural voice was downloaded or removed.
  void neuralChanged() => notifyListeners();

  Future<void> switchEngine(String id) async {
    if (id == engineId) return;
    engineId = id;
    voices = const [];
    notifyListeners();
    await _loadVoices();
    notifyListeners();
  }

  VoiceInfo? byName(String? name) {
    if (name == null) return null;
    for (final v in all) {
      if (v.name == name) return v;
    }
    // An ElevenLabs voice: listed apart (the picker's own row), found here
    // so the voice in use shows as chosen.
    final eleven = ElevenLabs.instance.byVoiceName(name);
    if (eleven != null) {
      return VoiceInfo(
          name: eleven.voiceName,
          locale: eleven.language.isEmpty ? 'en' : eleven.language,
          quality: 500,
          networkRequired: true,
          installed: true);
    }
    final cloud = CloudVoices.instance.byVoiceName(name);
    if (cloud != null) {
      return VoiceInfo(
          name: cloud.voiceName,
          locale: cloud.language.isEmpty ? 'en' : cloud.language,
          quality: 500,
          networkRequired: true,
          installed: true);
    }
    return null;
  }

  /// The voice to use for [language] when the user has not chosen one: a
  /// speaker of its own, so it is one the list can show as chosen. With no
  /// voice for [language] on the phone, one for [voiceLanguageFor].
  ///
  /// None for a language with letters of its own (Bengali, Hindi, Arabic…)
  /// when no voice here reads them: an English voice handed Bengali text
  /// says nothing, or stalls, and the reader is better told there is no
  /// Bengali voice, and where to get one.
  VoiceInfo? bestFor(String language) {
    final pick = SpeechService.pickVoice(
      [for (final v in _withoutAliases(voices)) v.toMap()],
      voiceLanguageFor(language),
      preferRegion: PlatformDispatcher.instance.locale.countryCode,
    );
    final v = pick == null ? null : byName(pick['name'] as String?);
    if (v != null && !readsLettersOf(v.language, language)) return null;
    return v;
  }

  /// The script each language is written in, for those not in Latin letters.
  static const _scripts = {
    'bn': 'beng', 'as': 'beng',
    'hi': 'deva', 'mr': 'deva', 'ne': 'deva', 'sa': 'deva',
    'gu': 'gujr', 'pa': 'guru', 'or': 'orya', 'ta': 'taml', 'te': 'telu', 'kn': 'knda', 'ml': 'mlym',
    'si': 'sinh', 'th': 'thai', 'lo': 'laoo', 'km': 'khmr', 'my': 'mymr', 'ka': 'geor', 'hy': 'armn',
    'am': 'ethi', 'he': 'hebr', 'yi': 'hebr', 'el': 'grek',
    'ar': 'arab', 'fa': 'arab', 'ur': 'arab', 'ps': 'arab',
    'ru': 'cyrl', 'uk': 'cyrl', 'be': 'cyrl', 'bg': 'cyrl', 'sr': 'cyrl', 'mk': 'cyrl', 'kk': 'cyrl',
    'zh': 'hani', 'ja': 'jpan', 'ko': 'kore',
  };

  static String _script(String language) => _scripts[language] ?? 'latn';

  /// Whether [language] has letters of its own, not Latin ones.
  static bool ownLetters(String language) => _script(language) != 'latn';

  /// Why a [language] book cannot be read aloud here, or null: no voice
  /// (of the phone's engine, or natural) reads its letters.
  String? noVoiceFor(String language, String? voiceName) {
    if (!loaded || !ownLetters(language) || isNeural(voiceName) || isEleven(voiceName) || isCloud(voiceName)) return null;
    final v = byName(voiceName);
    if (v != null && readsLettersOf(v.language, language)) return null;
    final name = languageName(language);
    return 'No $name voice in this speech engine. Choose one under Voice: another speech engine may have '
        "one, or download $name in the phone's speech settings.";
  }

  /// Whether a [voice] language voice can read a [language] book: its own
  /// language, its relative ([relatedLanguage]), the same letters, or any
  /// voice for a book in Latin letters.
  static bool readsLettersOf(String voice, String language) =>
      voice == language ||
      relatedLanguage[language] == voice ||
      _script(language) == 'latn' ||
      _script(voice) == _script(language);

  /// Another speech engine on the phone that has a voice installed for
  /// [language], when this one has none: Samsung's has no Bengali, Google's
  /// does. Asked once an engine and language.
  Future<({String id, String label})?> otherEngineFor(String language) async {
    for (final e in engines) {
      final id = e['name'];
      if (id == null || id == engineId) continue;
      final key = '$id/$language';
      final known = _otherHas[key];
      final has = known ??
          (_otherHas[key] = await () async {
            try {
              final list = await _svc.voices(id);
              return list.any((v) =>
                  (v['locale'] as String? ?? '').toLowerCase().startsWith(language) && v['installed'] != false);
            } on Object {
              return false;
            }
          }());
      if (has) return (id: id, label: (e['label'] ?? '').isEmpty ? id : e['label']!);
    }
    return null;
  }

  final _otherHas = <String, bool>{};

  /// Languages read in a related language's voice when the phone has none
  /// of their own: Ukrainian, Belarusian, Bulgarian, Serbian and Macedonian
  /// in a Russian one (Slavic, and Cyrillic), Urdu in a Hindi one (one spoken
  /// language in two scripts), Persian in an Arabic one (the same script).
  static const relatedLanguage = {
    'uk': 'ru',
    'be': 'ru',
    'bg': 'ru',
    'sr': 'ru',
    'mk': 'ru',
    'ur': 'hi',
    'fa': 'ar',
  };

  /// The language whose voices read a [language] book on this phone: its
  /// own; else a related one ([relatedLanguage]); else the phone's own
  /// language, rather than whichever voice ranks best, English as often as
  /// not; else [language] (any voice will have to do).
  String voiceLanguageFor(String language) {
    bool has(String l) => voices.any((v) => v.language == l);
    if (has(language)) return language;
    final near = relatedLanguage[language];
    if (near != null && has(near)) return near;
    // In the same letters (Marathi in a Hindi voice, both Devanagari).
    if (ownLetters(language)) {
      final same = voices.where((v) => _script(v.language) == _script(language)).firstOrNull;
      if (same != null) return same.language;
    }
    final own = (phoneLanguage ?? PlatformDispatcher.instance.locale.languageCode).toLowerCase();
    // Only a voice that can read its letters: not English for Bengali.
    return has(own) && readsLettersOf(own, language) ? own : language;
  }

  /// The phone's own language, in tests.
  @visibleForTesting
  String? phoneLanguage;

  /// [list] without the aliases of a region that has its speakers listed;
  /// [keep] stays even so (the voice in use).
  static List<VoiceInfo> _withoutAliases(List<VoiceInfo> list, {String? keep}) {
    final named = {
      for (final v in list)
        if (!v.isAlias) '${v.language}-${v.region}',
    };
    return [
      for (final v in list)
        if (!v.isAlias || v.name == keep || !named.contains('${v.language}-${v.region}')) v,
    ];
  }

  /// Voices for [language], installed and offline first, then by quality.
  /// [keep] is listed even when it would be left out as an alias, so the
  /// voice in use always has its row.
  List<VoiceInfo> forLanguage(String language, {String? keep}) {
    final list = _withoutAliases([
      for (final v in all)
        if (v.language == language) v,
    ], keep: keep);
    int score(VoiceInfo v) =>
        (v.installed ? 4000 : 0) +
        (v.networkRequired ? 0 : 2000) +
        v.quality;
    // Google lists most voices twice, an offline and an online copy of the
    // same speaker. Show each speaker once, the offline copy when there is one.
    final best = <String, VoiceInfo>{};
    for (final v in list) {
      final key = '${v.region}/${v.variant}';
      final have = best[key];
      if (have == null || score(v) > score(have)) best[key] = v;
    }
    final unique = best.values.toList()
      ..sort((a, b) {
        final r = a.region.compareTo(b.region);
        if (r != 0) return r;
        // Natural voices first: someone downloaded them to use them.
        final n = (isNeural(b.name) ? 1 : 0) - (isNeural(a.name) ? 1 : 0);
        if (n != 0) return n;
        if (a.variant == 'Default') return -1;
        if (b.variant == 'Default') return 1;
        return a.variant.compareTo(b.variant);
      });
    return unique;
  }

  /// A name people can read. Google's voices are only told apart by codes
  /// ("IOL", "SFG"), so those become "Voice 1", "Voice 2" in their region;
  /// the engine's default stays "Default voice", and an engine that already
  /// names its voices keeps those names.
  String friendlyName(VoiceInfo v) {
    final natural = neuralVoiceFor(v.name);
    if (natural != null) return naturalName(natural);
    final eleven = ElevenLabs.instance.byVoiceName(v.name);
    if (eleven != null) return '${eleven.name} · ElevenLabs';
    final cloud = CloudVoices.instance.byVoiceName(v.name);
    if (cloud != null) return '${cloud.name} · ${cloud.service.label}';
    if (v.variant == 'Default') return 'Default voice';
    if (!RegExp(r'^[A-Z0-9]{2,5}$').hasMatch(v.variant)) return v.variant;
    final same = [
      for (final x in forLanguage(v.language))
        if (x.region == v.region && RegExp(r'^[A-Z0-9]{2,5}$').hasMatch(x.variant)) x,
    ];
    final i = same.indexWhere((x) => x.variant == v.variant);
    return i < 0 ? v.variant : 'Voice ${i + 1}';
  }

  /// Languages that have at least one voice, by display name.
  List<String> languages() {
    final set = {for (final v in all) v.language};
    return set.toList()
      ..sort((a, b) => languageName(a).compareTo(languageName(b)));
  }
}

/// A natural voice's name in lists: "Kristin · natural", "Lessac · natural
/// HD", "Alpha · Kokoro". The quality is said: one speaker can be on the
/// phone at two.
String naturalName(NeuralVoice v) {
  final pack = v.pack;
  if (pack != null) return '${v.name} · ${pack.name}';
  return switch (v.quality) {
    'high' => '${v.name} · natural HD',
    'low' || 'x_low' => '${v.name} · natural (low)',
    _ => '${v.name} · natural',
  };
}

String languageName(String code) => _languages[code] ?? code.toUpperCase();

String regionLabel(String code) => _regions[code] ?? code;

const _languages = {
  'af': 'Afrikaans', 'am': 'Amharic', 'ar': 'Arabic', 'as': 'Assamese',
  'be': 'Belarusian',
  'bg': 'Bulgarian', 'bn': 'Bengali', 'bs': 'Bosnian', 'ca': 'Catalan',
  'cs': 'Czech', 'cy': 'Welsh', 'da': 'Danish', 'de': 'German',
  'el': 'Greek', 'en': 'English', 'es': 'Spanish', 'et': 'Estonian',
  'eu': 'Basque', 'fa': 'Persian', 'fi': 'Finnish', 'fil': 'Filipino',
  'fr': 'French', 'ga': 'Irish', 'gl': 'Galician', 'gu': 'Gujarati',
  'he': 'Hebrew', 'hi': 'Hindi', 'hr': 'Croatian', 'hu': 'Hungarian',
  'hy': 'Armenian', 'id': 'Indonesian', 'is': 'Icelandic', 'it': 'Italian',
  'ja': 'Japanese', 'jv': 'Javanese', 'ka': 'Georgian', 'kk': 'Kazakh',
  'km': 'Khmer', 'kn': 'Kannada', 'ko': 'Korean', 'la': 'Latin',
  'lo': 'Lao', 'lt': 'Lithuanian', 'lv': 'Latvian', 'mk': 'Macedonian',
  'ml': 'Malayalam', 'mn': 'Mongolian', 'mr': 'Marathi', 'ms': 'Malay',
  'my': 'Burmese', 'nb': 'Norwegian', 'ne': 'Nepali', 'nl': 'Dutch',
  'no': 'Norwegian', 'or': 'Odia', 'pa': 'Punjabi', 'pl': 'Polish',
  'pt': 'Portuguese', 'ro': 'Romanian', 'ru': 'Russian', 'si': 'Sinhala',
  'sk': 'Slovak', 'sl': 'Slovenian', 'sq': 'Albanian', 'sr': 'Serbian',
  'su': 'Sundanese', 'sv': 'Swedish', 'sw': 'Swahili', 'ta': 'Tamil',
  'te': 'Telugu', 'th': 'Thai', 'tl': 'Filipino', 'tr': 'Turkish',
  'uk': 'Ukrainian', 'ur': 'Urdu', 'uz': 'Uzbek', 'vi': 'Vietnamese',
  'yue': 'Cantonese', 'zh': 'Chinese', 'zu': 'Zulu',
  'brx': 'Bodo', 'doi': 'Dogri', 'kok': 'Konkani', 'mai': 'Maithili',
  'mni': 'Manipuri', 'sat': 'Santali', 'sd': 'Sindhi', 'ks': 'Kashmiri',
  'sa': 'Sanskrit', 'ps': 'Pashto', 'so': 'Somali', 'ha': 'Hausa',
  'yo': 'Yoruba', 'ig': 'Igbo', 'mt': 'Maltese', 'lb': 'Luxembourgish',
  'gd': 'Scottish Gaelic', 'fy': 'Frisian', 'bo': 'Tibetan', 'ug': 'Uyghur',
  'ku': 'Kurdish',
};

const _regions = {
  'US': 'US', 'GB': 'UK', 'AU': 'Australia', 'IN': 'India', 'CA': 'Canada',
  'IE': 'Ireland', 'NZ': 'New Zealand', 'ZA': 'South Africa', 'NG': 'Nigeria',
  'BD': 'Bangladesh', 'ES': 'Spain', 'MX': 'Mexico', 'FR': 'France',
  'DE': 'Germany', 'BR': 'Brazil', 'PT': 'Portugal', 'CN': 'China',
  'TW': 'Taiwan', 'HK': 'Hong Kong', 'JP': 'Japan', 'KR': 'Korea',
  'RU': 'Russia', 'IT': 'Italy', 'NL': 'Netherlands', 'BE': 'Belgium',
  'CH': 'Switzerland', 'AT': 'Austria', 'SG': 'Singapore', 'PH': 'Philippines',
  'PK': 'Pakistan', 'NP': 'Nepal', 'LK': 'Sri Lanka', 'EG': 'Egypt',
  'SA': 'Saudi Arabia', 'AE': 'UAE',
  // Where the natural voices come from.
  'AR': 'Argentina', 'JO': 'Jordan', 'CZ': 'Czechia', 'DK': 'Denmark',
  'GR': 'Greece', 'IR': 'Iran', 'FI': 'Finland', 'HU': 'Hungary',
  'IS': 'Iceland', 'GE': 'Georgia', 'KZ': 'Kazakhstan', 'TR': 'Turkey',
  'LU': 'Luxembourg', 'LV': 'Latvia', 'NO': 'Norway', 'PL': 'Poland',
  'RO': 'Romania', 'SK': 'Slovakia', 'SI': 'Slovenia', 'AL': 'Albania',
  'RS': 'Serbia', 'SE': 'Sweden', 'CD': 'Congo', 'UA': 'Ukraine',
  'VN': 'Vietnam', 'ID': 'Indonesia',
};
