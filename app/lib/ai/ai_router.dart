import 'dart:async';
import 'dart:math' as math;

import 'ai_client.dart';
import 'ai_keys.dart';

/// Every key of a job is resting (its quota spent) or refused: the work
/// waits until [until], when the first of them wakes, or for the reader to
/// add a key ([until] null: none can do it).
class AiResting implements Exception {
  const AiResting(this.job, this.until, {this.last});

  final AiJob job;
  final DateTime? until;

  /// The last failure met, to say why.
  final AiError? last;

  /// Not a quota: the provider could not be reached, or was too slow. Said
  /// as such ("Every key has used its quota" was wrong for a lost signal).
  bool get unreachable => last != null && (last!.kind == AiFailure.network || last!.slow);

  @override
  String toString() => until == null
      ? 'No key can do ${job.label.toLowerCase()} now${last == null ? '' : ': ${last!.message}'}'
      : 'Every key for ${job.label.toLowerCase()} is resting until $until';
}

/// A call made with the first key of a job that can take it: a key whose
/// quota is spent rests and the next allowed key takes over; one refused is marked so
/// and skipped; the provider failing is tried once more after a moment,
/// then the next key. What each call used is counted to its key.
/// Why nothing was sent: the reader has not yet agreed (see AiRing.consent).
const notConsented = AiError(AiFailure.request, 'TomeVoice needs your go-ahead first: open AI and agree to what is sent.');

class AiRouter {
  AiRouter({
    AiRing? ring,
    AiClient? client,
    this.pause = const Duration(seconds: 2),
    DateTime Function()? clock,
    this.about,
  })
      : ring = ring ?? AiRing.instance,
        client = client ?? AiClient(),
        _clock = clock ?? DateTime.now;

  final AiRing ring;

  /// The book its calls are about, for the log of what was sent.
  String? about;
  final AiClient client;

  /// The wait before trying a failing provider again.
  final Duration pause;
  final DateTime Function() _clock;

  /// The key the last call was made with, to show.
  AiKey? lastKey;

  /// Server or network failures in a row, per key: how long it rests.
  final _troubles = <String, int>{};

  /// How long a key rests after its [n]th server or network failure in a
  /// row: a minute, then two, five, ten at most.
  static Duration troubleRest(int n) => const [
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 10),
      ][math.min(n, 4) - 1];

  /// A chat call, as [AiClient.chat], with the job's keys in turn. [only]:
  /// the keys it may use (null: any of the job's, in their order).
  /// [expect]: the tokens it is likely to use, for a key's daily limit
  /// (guessed from the messages when not given). [stopped]: the reader
  /// stopped it, and a streamed reply is let go. [slowToCaller]: a reply
  /// given up on as too slow is the caller's to deal with (the Builder
  /// halves its batch), not rested on and asked again.
  Future<AiReply> chat(
    AiJob job,
    List<Map<String, Object?>> messages, {
    List<AiTool> tools = const [],
    bool json = false,
    int? maxTokens,
    double? temperature,
    void Function(String piece)? onText,
    bool Function()? stopped,
    Set<String>? only,
    int? expect,
    bool slowToCaller = false,
  }) {
    final guess = expect ?? guessUsage(messages, '').input + (maxTokens ?? 0);
    return run(job, (key, to) async {
      try {
        final reply = await client.chat(to, messages,
            tools: tools, json: json, maxTokens: maxTokens, temperature: temperature, onText: onText, stopped: stopped);
        ring.count(key.id, reply.usage);
        return reply;
      } on AiError catch (e) {
        // Given up on as too slow: the provider most likely read it all, and
        // counts it, so the daily limit does too (a guess: it did not say).
        if (e.slow) ring.count(key.id, AiUsage(input: guessUsage(messages, '').input, guessed: true));
        rethrow;
      }
    }, only: only, expect: guess, slowToCaller: slowToCaller);
  }

  /// The key being tried now, or last: for what the caller does with a
  /// reply given up on as too slow.
  AiKey? tried;

  /// [key] given up on as too slow, by the caller: it rests a while, longer
  /// each time it happens, and the work waits for it. Returns until when.
  Future<DateTime> rested(AiKey key, AiError why) async {
    final n = _troubles[key.id] = (_troubles[key.id] ?? 0) + 1;
    final until = _clock().add(troubleRest(n));
    await ring.rest(key.id, until, why.message);
    return until;
  }

  /// [call] with each key of [job] in turn until one does it.
  ///
  /// Which failures move on to the next key: a spent quota or daily limit,
  /// a refused key, and the provider itself failing (an HTTP 5xx). A lost
  /// signal or a reply too slow never does: the next key would be no
  /// better off on the same phone, and a slow reply resent elsewhere is
  /// paid for twice. That key rests a moment (a minute, then longer) and
  /// the work waits for it.
  Future<T> run<T>(
    AiJob job,
    Future<T> Function(AiKey key, AiEndpoint to) call, {
    Set<String>? only,
    int expect = 0,
    bool slowToCaller = false,
  }) async {
    final keys = [for (final k in ring.forJob(job)) if (only == null || only.contains(k.id)) k];
    // Nothing is sent before the reader has agreed to what is.
    if (keys.isNotEmpty && !ring.consented) throw AiResting(job, null, last: notConsented);
    AiError? last;
    for (final key in keys) {
      final state = ring.stateOf(key.id);
      if (state.refused != null || state.restingAt(_clock())) continue;
      // Its daily limit would be passed by this call: it rests until the
      // day turns, before anything is sent (the limit was only looked at
      // after a call, so a 40k-token batch could go over it by as much).
      final cap = key.dailyCap;
      if (cap != null && expect > 0 && ring.today(key.id, now: _clock()).total + expect > cap) {
        final at = _clock();
        await ring.rest(key.id, DateTime(at.year, at.month, at.day + 1),
            '${AiRing.dailyLimitReached} $cap tokens would be passed by the next call');
        last = AiError(AiFailure.quota, '${key.label} would pass its daily limit of $cap tokens');
        continue;
      }
      tried = key;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final out = await call(key, key.endpoint(job));
          ring.logCall(job, key, about: about, usage: out is AiReply ? out.usage : null);
          _troubles.remove(key.id);
          ring.cleared(key.id);
          lastKey = key;
          return out;
        } on AiError catch (e) {
          last = e;
          if (e.slow && slowToCaller) rethrow;
          switch (e.kind) {
            case AiFailure.quota:
              await ring.rest(key.id, _clock().add(e.retryAfter ?? const Duration(minutes: 1)), e.message);
            case AiFailure.refused:
              await ring.refuse(key.id, e.message);
            case AiFailure.server || AiFailure.network:
              // Too slow: not sent again at once (the same long wait, paid
              // twice); a dropped line or a provider's hiccup is, once.
              if (attempt == 0 && !e.slow) {
                await Future<void>.delayed(e.retryAfter != null && e.retryAfter! < const Duration(seconds: 20)
                    ? e.retryAfter!
                    : pause);
                continue;
              }
              // Still failing: the provider is having trouble (or the
              // phone's connection is). The key rests a while, longer each
              // time, and the work waits for it rather than stopping.
              final n = _troubles[key.id] = (_troubles[key.id] ?? 0) + 1;
              final until = _clock().add(troubleRest(n));
              await ring.rest(key.id, until, e.message);
              // No answer at all, or too slow: the same key again after its
              // rest, never the next (see above).
              if (e.kind == AiFailure.network || e.slow) throw AiResting(job, until, last: e);
            case AiFailure.request:
              break;
          }
          break;
        }
      }
    }
    throw AiResting(job, ring.wakesAt(job, now: _clock(), only: only), last: last);
  }
}
