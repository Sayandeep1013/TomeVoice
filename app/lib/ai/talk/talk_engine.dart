import 'dart:async';
import 'dart:isolate';

import '../ai_client.dart';
import '../ai_keys.dart';
import '../ai_router.dart';
import '../memory/memory_db.dart';
import 'answer_pack.dart';

/// A source an answer may cite as [S3]: where it is in the book.
class TalkSource {
  const TalkSource(this.n, this.label, this.place);

  final int n;
  final String label;
  final MemoryPlace? place;
}

/// An answer, its text with [S3]-style marks, and the sources they name.
class TalkAnswer {
  const TalkAnswer(this.text, this.sources);

  final String text;
  final Map<int, TalkSource> sources;

  /// The sources the text cites, in the order first cited.
  List<TalkSource> get cited {
    final seen = <int>{};
    return [
      for (final m in citeMarks.allMatches(text))
        for (final n in citeNumbers(m.group(0)!))
          if (sources[n] != null && seen.add(n)) sources[n]!,
    ];
  }
}

/// [S3], [S3, S5], [S3][S5].
final citeMarks = RegExp(r'\[S\d+(?:\s*,\s*S?\d+)*\]');

List<int> citeNumbers(String mark) =>
    [for (final m in RegExp(r'\d+').allMatches(mark)) int.parse(m.group(0)!)];

/// How long the reader likes answers.
enum AnswerLength {
  short('Short', 'Answer in two or three sentences.'),
  normal('Normal', 'Answer in a short paragraph or two.'),
  long('Long', 'Answer fully, in as many paragraphs as it needs.');

  const AnswerLength(this.label, this.ask);

  final String label;
  final String ask;
}

/// The tools the Talker may call to look further into the book's memory.
const talkTools = [
  AiTool(
    name: 'search_text',
    description: "Search the book's text for words or a quoted phrase. Returns the places found, by chapter.",
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Words to find; quote a phrase to keep it together.'},
      },
      'required': ['query'],
    },
  ),
  AiTool(
    name: 'card',
    description: 'Everything remembered of a character, place, group, item, power, title or term, by any of its names.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  ),
  AiTool(
    name: 'events',
    description: 'The events someone or something took part in, in order, optionally between two chapters.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'from_chapter': {'type': 'integer'},
        'to_chapter': {'type': 'integer'},
      },
      'required': ['name'],
    },
  ),
  AiTool(
    name: 'chapter_notes',
    description: "A chapter's summary.",
    parameters: {
      'type': 'object',
      'properties': {
        'chapter': {'type': 'integer', 'description': 'The chapter number as the reader counts it.'},
      },
      'required': ['chapter'],
    },
  ),
  AiTool(
    name: 'read_chapter',
    description: "A chapter's own text, thirty passages from the one given.",
    parameters: {
      'type': 'object',
      'properties': {
        'chapter': {'type': 'integer'},
        'from_passage': {'type': 'integer'},
      },
      'required': ['chapter'],
    },
  ),
  AiTool(
    name: 'thread',
    description: 'A mystery, promise or foreshadowing, step by step from where it was raised.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  ),
];

/// One talk about one book: each question answered from a pack gathered
/// afresh from the book's memory (and the model's tools, when its key can
/// use them), the talk so far carried, the sources numbered across it.
class TalkEngine {
  TalkEngine({
    required this.memoryPath,
    required this.bookTitle,
    AiRouter? router,
    this.ownKnowledge = false,
    this.length = AnswerLength.normal,
  }) : router = router ?? AiRouter();

  final String memoryPath;
  final String bookTitle;
  final AiRouter router;
  final bool ownKnowledge;
  final AnswerLength length;

  final _history = <Map<String, Object?>>[];
  final sources = <int, TalkSource>{};
  var _next = 1;

  /// Keys whose provider turned tools down: asked without them after.
  static final _noTools = <String>{};

  String _system(int? line) => [
        'You are the reading companion in TomeVoice, talking with a reader about the book "$bookTitle". '
            'Be warm, direct and specific, like a friend who has read it closely.',
        ownKnowledge
            ? 'Use the material given first. You may add what you know of this book from elsewhere, '
                'and say when you do.'
            : 'Use only the material given (and what your tools find in the book\'s memory). Do not use anything '
                'you may know of this book from elsewhere. If the material does not say, tell the reader plainly '
                'that you do not remember that part yet.',
        if (line != null)
          'The reader has read up to chapter ${line + 1}. Never reveal, hint at or guess anything that happens '
              'after it.',
        'After each sentence that rests on the material, cite it as [S3] (several: [S3, S7]). Cite only '
            'numbers given to you.',
        length.ask,
      ].join('\n\n');

  String _render(List<PackItem> items) {
    final b = StringBuffer();
    String? section;
    for (final i in items) {
      if (i.section != section) {
        section = i.section;
        b.writeln('\n## $section');
      }
      final n = _next++;
      sources[n] = TalkSource(n, i.place == null ? i.section : chapterLabel(i.place!.chapter), i.place);
      b.writeln('[S$n] ${i.text}');
    }
    return b.toString().trim();
  }

  /// [question] answered; [onText] has each piece as it comes.
  Future<TalkAnswer> ask(
    String question, {
    int? line,
    int? here,
    String passage = '',
    List<String> journal = const [],
    void Function(String piece)? onText,
  }) async {
    final input = PackInput(
      path: memoryPath,
      question: question,
      line: line,
      here: here,
      passage: passage,
      journal: journal,
    );
    final items = MemoryDb.existsAt(memoryPath) ? await Isolate.run(() => buildPack(input)) : <PackItem>[
      if (passage.trim().isNotEmpty) PackItem('What the reader is reading now', passage),
      for (final j in journal) PackItem("The reader's journal", j),
    ];
    final material = _render(items);
    final messages = [
      aiMessage('system', _system(line)),
      ..._history,
      aiMessage('user', '${material.isEmpty ? 'No material yet.' : 'Material:\n$material'}\n\n---\nThe reader asks: $question'),
    ];
    final reply = await _converse(messages, line, onText);
    _history
      ..add(aiMessage('user', question))
      ..add(aiMessage('assistant', reply));
    return TalkAnswer(reply, Map.of(sources));
  }

  Future<String> _converse(List<Map<String, Object?>> messages, int? line, void Function(String)? onText) async {
    final key = router.ring.forJob(AiJob.talker).firstOrNull;
    var tools = key != null && !_noTools.contains(key.id) && MemoryDb.existsAt(memoryPath);
    for (var round = 0; round < 5; round++) {
      final AiReply reply;
      try {
        reply = await router.chat(AiJob.talker, messages, tools: tools ? talkTools : const [], onText: onText);
      } on AiResting catch (e) {
        // A provider that turns tools down: once more without them.
        if (tools && e.last?.kind == AiFailure.request) {
          if (key != null) _noTools.add(key.id);
          tools = false;
          continue;
        }
        rethrow;
      }
      if (reply.toolCalls.isEmpty || round == 4) return reply.text.trim();
      messages.add(reply.asMessage);
      for (final call in reply.toolCalls) {
        final args = call.args;
        final path = memoryPath;
        final found = await Isolate.run(() => runTool(path, call.name, args, line));
        messages.add(aiToolAnswer(call.id, _render(found)));
      }
    }
    return '';
  }
}
