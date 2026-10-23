import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One day of reading: time listened and read, words heard, chapters
/// finished, and time per book.
class DayStats {
  DayStats({this.listenMs = 0, this.readMs = 0, this.words = 0, this.chapters = 0, Map<String, int>? books})
      : books = books ?? {};

  int listenMs;
  int readMs;
  int words;
  int chapters;

  /// Book id -> milliseconds (listening and reading).
  final Map<String, int> books;

  int get totalMs => listenMs + readMs;

  Map<String, Object?> toJson() => {
        if (listenMs > 0) 'listen': listenMs,
        if (readMs > 0) 'read': readMs,
        if (words > 0) 'words': words,
        if (chapters > 0) 'chapters': chapters,
        if (books.isNotEmpty) 'books': books,
      };

  static DayStats fromJson(Map<String, Object?> j) => DayStats(
        listenMs: (j['listen'] as num?)?.toInt() ?? 0,
        readMs: (j['read'] as num?)?.toInt() ?? 0,
        words: (j['words'] as num?)?.toInt() ?? 0,
        chapters: (j['chapters'] as num?)?.toInt() ?? 0,
        books: {
          for (final e in (j['books'] as Map? ?? const {}).entries) e.key as String: (e.value as num).toInt(),
        },
      );
}

/// A day begins at 4 am, so listening at 1 am counts toward the night before.
const dayStartsAtHour = 4;

/// The day [t] counts toward, as "2026-10-23".
String dayKey(DateTime t) {
  final d = t.subtract(const Duration(hours: dayStartsAtHour));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// The calendar date of [key].
DateTime dayOf(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// Reading habits, kept by day in `stats.json` at the library root (so a
/// backup carries them, and the streak widget can read them).
class StatsStore {
  StatsStore._();

  static final instance = StatsStore._();

  /// A day counts toward the streak with at least this much reading.
  static const goal = Duration(minutes: 5);

  /// Bumped when the numbers are saved.
  final changes = ValueNotifier<int>(0);

  final Map<String, DayStats> _days = {};
  File? _file;
  Timer? _saveTimer;

  /// Called after a save, so widgets can redraw.
  VoidCallback? onSaved;

  Map<String, DayStats> get days => _days;

  Future<void> attach(Directory root) async {
    _file = File('${root.path}/stats.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString()) as Map;
        for (final e in (raw['days'] as Map? ?? const {}).entries) {
          _days[e.key as String] = DayStats.fromJson(Map<String, Object?>.from(e.value as Map));
        }
        changes.value++;
      }
    } on Object {
      // Start counting afresh.
    }
  }

  DayStats today([DateTime? now]) => _days.putIfAbsent(dayKey(now ?? DateTime.now()), DayStats.new);

  void addTime(String bookId, Duration d, {required bool listening, DateTime? now}) {
    if (d <= Duration.zero) return;
    final day = today(now);
    if (listening) {
      day.listenMs += d.inMilliseconds;
    } else {
      day.readMs += d.inMilliseconds;
    }
    day.books[bookId] = (day.books[bookId] ?? 0) + d.inMilliseconds;
    _scheduleSave();
  }

  void addWords(int n, {DateTime? now}) {
    if (n <= 0) return;
    today(now).words += n;
    _scheduleSave();
  }

  void addChapter({DateTime? now}) {
    today(now).chapters++;
    _scheduleSave();
  }

  /// Write now (leaving the reader, the app going to the background).
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _save();
  }

  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(seconds: 30), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    _saveTimer = null;
    changes.value++;
    try {
      await _file?.writeAsString(jsonEncode({
        'goalMinutes': goal.inMinutes,
        'days': {for (final e in _days.entries) e.key: e.value.toJson()},
      }));
      onSaved?.call();
    } on Object {
      // Saved with the next change.
    }
  }

  bool met(String key) => (_days[key]?.totalMs ?? 0) >= goal.inMilliseconds;

  /// Days in a row the goal was met, up to today; today not yet met does not
  /// break it (the day is not over).
  int streak([DateTime? now]) {
    final todayKey = dayKey(now ?? DateTime.now());
    var day = dayOf(todayKey);
    if (!met(todayKey)) day = day.subtract(const Duration(days: 1));
    var n = 0;
    while (met(_key(day))) {
      n++;
      day = day.subtract(const Duration(days: 1));
    }
    return n;
  }

  /// The longest streak ever.
  int bestStreak() {
    final keys = _days.keys.where(met).map(dayOf).toList()..sort();
    var best = 0;
    var run = 0;
    DateTime? prev;
    for (final d in keys) {
      run = prev != null && d.difference(prev).inDays == 1 ? run + 1 : 1;
      best = math.max(best, run);
      prev = d;
    }
    return best;
  }

  /// Minutes on each of the last [n] days, oldest first, ending today.
  List<int> lastDays(int n, [DateTime? now]) {
    final today = dayOf(dayKey(now ?? DateTime.now()));
    return [
      for (var i = n - 1; i >= 0; i--) ((_days[_key(today.subtract(Duration(days: i)))]?.totalMs ?? 0) / 60000).round(),
    ];
  }

  static String _key(DateTime d) => dayKey(DateTime(d.year, d.month, d.day, dayStartsAtHour + 1));

  ({int listenMs, int readMs, int words, int chapters, Map<String, int> books}) totals() {
    var l = 0, r = 0, w = 0, c = 0;
    final books = <String, int>{};
    for (final d in _days.values) {
      l += d.listenMs;
      r += d.readMs;
      w += d.words;
      c += d.chapters;
      d.books.forEach((k, v) => books[k] = (books[k] ?? 0) + v);
    }
    return (listenMs: l, readMs: r, words: w, chapters: c, books: books);
  }
}

/// Digits and a few letters as 5 x 7 dots, like a Nothing phone's display.
/// Each row is 5 bits, the left dot the highest.
const dotGlyphs = <String, List<int>>{
  '0': [14, 17, 19, 21, 25, 17, 14],
  '1': [4, 12, 4, 4, 4, 4, 14],
  '2': [14, 17, 1, 2, 4, 8, 31],
  '3': [31, 2, 4, 2, 1, 17, 14],
  '4': [2, 6, 10, 18, 31, 2, 2],
  '5': [31, 16, 30, 1, 1, 17, 14],
  '6': [6, 8, 16, 30, 17, 17, 14],
  '7': [31, 1, 2, 4, 8, 8, 8],
  '8': [14, 17, 17, 14, 17, 17, 14],
  '9': [14, 17, 17, 15, 1, 2, 12],
  'H': [17, 17, 17, 31, 17, 17, 17],
  'M': [17, 27, 21, 21, 17, 17, 17],
  '%': [24, 25, 2, 4, 8, 19, 3],
  ' ': [0, 0, 0, 0, 0, 0, 0],
};

/// [text] drawn as dots, [dot] wide each (the gap is half a dot).
class DotText extends StatelessWidget {
  const DotText(this.text, {super.key, this.dot = 6, this.color, this.off});

  final String text;
  final double dot;
  final Color? color;

  /// The unlit dots, or none.
  final Color? off;

  @override
  Widget build(BuildContext context) {
    final glyphs = text.toUpperCase().split('').where(dotGlyphs.containsKey).toList();
    final step = dot * 1.5;
    return Semantics(
      label: text,
      child: CustomPaint(
        size: Size(glyphs.length * 6 * step - step, 7 * step - dot * 0.5),
        painter: _DotPainter(glyphs, dot, color ?? DefaultTextStyle.of(context).style.color ?? Colors.white, off),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.glyphs, this.dot, this.on, this.off);

  final List<String> glyphs;
  final double dot;
  final Color on;
  final Color? off;

  @override
  void paint(Canvas canvas, Size size) {
    final step = dot * 1.5;
    final lit = Paint()..color = on;
    final dim = off == null ? null : (Paint()..color = off!);
    for (var g = 0; g < glyphs.length; g++) {
      final rows = dotGlyphs[glyphs[g]]!;
      for (var r = 0; r < 7; r++) {
        for (var c = 0; c < 5; c++) {
          final isOn = rows[r] & (16 >> c) != 0;
          final p = isOn ? lit : dim;
          if (p == null) continue;
          canvas.drawCircle(Offset((g * 6 + c) * step + dot / 2, r * step + dot / 2), dot / 2, p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.glyphs.join() != glyphs.join() || old.on != on || old.dot != dot;
}
