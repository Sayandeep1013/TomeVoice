import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai_router.dart';
import '../ai_screen.dart' show wakeTime;
import 'chat_engine.dart';
import 'chat_links.dart';
import 'chat_store.dart';

/// Answers being written, kept apart from any screen: leaving a chat (or
/// the app) does not stop its answer, which is saved when it comes and
/// shown when the chat is opened again. Nothing is read aloud here: an
/// answer is said only when the reader asks for it.
class ChatRunner {
  ChatRunner._();

  static final instance = ChatRunner._();

  final _running = <String, ChatProgress>{};

  /// Bumped as an answer grows, and when one ends.
  final changes = ValueNotifier<int>(0);

  /// The answer chat [chatId] is waiting for, if one is on its way.
  ChatProgress? of(String chatId) => _running[chatId];

  bool busy(String chatId) => _running.containsKey(chatId);

  /// Asks [question] in [chat], answered by [engine]: the question and an
  /// empty answer are added (and the chat kept) at once, so the chat is in
  /// the list while it is answered.
  Future<void> ask(Chat chat, String question, ChatEngine engine, {ChatStore? store}) async {
    final chats = store ?? ChatStore.instance;
    if (busy(chat.id)) return;
    final reply = ChatMessage(mine: false, text: '');
    final p = ChatProgress(reply);
    _running[chat.id] = p;
    chat.messages
      ..add(ChatMessage(mine: true, text: question))
      ..add(reply);
    if (!chat.titled && chat.title == 'New chat') chat.title = chatTitleFrom(question);
    _bump();
    await chats.put(chat);
    try {
      await engine.answer(p, onChange: _bump);
    } on AiResting catch (e) {
      reply.error = e.until != null
          ? 'Every key has used its quota for now. Ask again at ${wakeTime(e.until!)}.'
          : e.last == null
              ? 'No key can talk yet: give one a model for Talking, in AI settings.'
              : 'The AI could not answer: ${e.last!.message}';
    } on Object catch (e) {
      reply.error = 'The AI could not answer: $e';
    } finally {
      if (p.stopped && reply.text.trim().isEmpty && reply.error == null) reply.error = 'Stopped.';
      _running.remove(chat.id);
      _bump();
      await chats.put(chat);
      unawaited(keepChatInJournal(chat));
      unawaited(engine.compact());
    }
  }

  /// The answer to chat [chatId] stopped where it is.
  void stop(String chatId) {
    final p = _running[chatId];
    if (p == null) return;
    p.stopped = true;
    _bump();
  }

  void _bump() => changes.value++;

  @visibleForTesting
  void reset() {
    for (final p in _running.values) {
      p.stopped = true;
    }
    _running.clear();
  }
}
