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

  @override
  String toString() => until == null
      ? 'No key can do ${job.label.toLowerCase()} now${last == null ? '' : ': ${last!.message}'}'
      : 'Every key for ${job.label.toLowerCase()} is resting until $until';
}

/// A call made with the first key of a job that can take it: a key whose
/// quota is spent rests and the next takes over; one refused is marked so
/// and skipped; the provider failing is tried once more after a moment,
/// then the next key. What each call used is counted to its key.
/// Why nothing was sent: the reader has not yet agreed (see AiRing.consent).
const notConsented = AiError(AiFailure.request, 'TomeVoice needs your go-ahead first: open AI and agree to what is sent.');

class AiRouter {
  AiRouter({AiRing? ring, AiClient? client, this.pause = const Duration(seconds: 2), DateTime Function()? clock})
      : ring = ring ?? AiRing.instance,
        client = client ?? AiClient(),
        _clock = clock ?? DateTime.now;

  final AiRing ring;
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

  /// A chat call, as [AiClient.chat], with the job's keys in turn.
  Future<AiReply> chat(
    AiJob job,
    List<Map<String, Object?>> messages, {
    List<AiTool> tools = const [],
    bool json = false,
    int? maxTokens,
    double? temperature,
    void Function(String piece)? onText,
  }) =>
      run(job, (key, to) async {
        final reply = await client.chat(to, messages,
            tools: tools, json: json, maxTokens: maxTokens, temperature: temperature, onText: onText);
        ring.count(key.id, reply.usage);
        return reply;
      });

  /// [call] with each key of [job] in turn until one does it.
  Future<T> run<T>(AiJob job, Future<T> Function(AiKey key, AiEndpoint to) call) async {
    final keys = ring.forJob(job);
    // Nothing is sent before the reader has agreed to what is.
    if (keys.isNotEmpty && !ring.consented) throw AiResting(job, null, last: notConsented);
    AiError? last;
    for (final key in keys) {
      final state = ring.stateOf(key.id);
      if (state.refused != null || state.restingAt(_clock())) continue;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final out = await call(key, key.endpoint(job));
          _troubles.remove(key.id);
          ring.cleared(key.id);
          lastKey = key;
          return out;
        } on AiError catch (e) {
          last = e;
          switch (e.kind) {
            case AiFailure.quota:
              await ring.rest(key.id, _clock().add(e.retryAfter ?? const Duration(minutes: 1)), e.message);
            case AiFailure.refused:
              await ring.refuse(key.id, e.message);
            case AiFailure.server || AiFailure.network:
              if (attempt == 0) {
                await Future<void>.delayed(e.retryAfter != null && e.retryAfter! < const Duration(seconds: 20)
                    ? e.retryAfter!
                    : pause);
                continue;
              }
              // Still failing: the provider is having trouble (or the
              // phone's connection is). The key rests a while, longer each
              // time, and the work waits for it rather than stopping.
              final n = _troubles[key.id] = (_troubles[key.id] ?? 0) + 1;
              await ring.rest(key.id, _clock().add(troubleRest(n)), e.message);
            case AiFailure.request:
              break;
          }
          break;
        }
      }
    }
    throw AiResting(job, ring.wakesAt(job, now: _clock()), last: last);
  }
}
