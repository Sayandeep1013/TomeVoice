import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  /// The phone's voices and the natural voices downloaded to it.
  List<VoiceInfo> get all => [
        ...voices,
        for (final v in NeuralVoices.instance.installedVoices)
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
    return null;
  }

  /// The voice to use for [language] when the user has not chosen one.
  VoiceInfo? bestFor(String language) {
    final pick = SpeechService.pickVoice(
      [for (final v in voices) v.toMap()],
      language,
      preferRegion: PlatformDispatcher.instance.locale.countryCode,
    );
    return pick == null ? null : byName(pick['name'] as String?);
  }

  /// Voices for [language], installed and offline first, then by quality.
  List<VoiceInfo> forLanguage(String language) {
    final list = [
      for (final v in all)
        if (v.language == language) v,
    ];
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
    if (natural != null) return '${natural.name} · natural';
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

String languageName(String code) => _languages[code] ?? code.toUpperCase();

String regionLabel(String code) => _regions[code] ?? code;

const _languages = {
  'af': 'Afrikaans', 'am': 'Amharic', 'ar': 'Arabic', 'as': 'Assamese',
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
};
