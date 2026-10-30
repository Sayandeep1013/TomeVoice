import 'dart:typed_data';

import 'package:tomevoice_document/tomevoice_document.dart';

// Who says each quotation in a book ("Level 2" in docs/road-to-1.0.html):
// from its speech tags ("…," said Elizabeth; Elizabeth said, "…"; "…," said
// she, for the last named speaker of that sex where nobody else could be
// meant), a character's own beat beside the words, and the turns of an
// exchange between two people where no tag is given. Book by book, and
// cautious: a line it is unsure of is left to the dialogue voice. English
// speech tags only. Pure Dart, so the tests read real books with it.

/// Whose voice a character is, as far as the book tells.
enum Gender {
  male,
  female,
  unknown;

  String get code => switch (this) { male => 'm', female => 'f', unknown => '' };

  static Gender parse(Object? s) => switch (s) { 'm' => male, 'f' => female, _ => unknown };
}

/// Someone the book's speech tags name: the name shown (the one the tags use
/// most), the others they go by, and how many of the book's lines are
/// theirs, with one of them to hear a voice say.
class Character {
  Character(this.name, {Iterable<String> also = const [], this.gender = Gender.unknown, this.lines = 0, this.sample = ''})
      : also = {...also};

  final String name;
  final Set<String> also;
  Gender gender;
  int lines;
  String sample;

  /// Every name it goes by.
  Iterable<String> get names => [name, ...also];

  /// The storyteller of a book told as "I": "…," I said.
  bool get isI => name == firstPerson;

  @override
  String toString() => '$name (${gender.code}, $lines)';
}

/// The name the storyteller goes by, in a book told as "I".
const firstPerson = 'I';

/// A book's characters as its settings keep them (ListeningPrefs.castByBook,
/// so a backup carries them with the book's own voice and speed), and the
/// voice each one's lines are read in: [narrator], or a voice's name. A
/// character with none is read in the dialogue voice, as before.
class BookCast {
  BookCast(List<Character> people, [Map<String, String> voices = const {}])
      : people = List.unmodifiable(people),
        voices = Map.unmodifiable(voices);

  /// Who the tags name, most lines first (see [findCharacters]).
  final List<Character> people;

  /// Character name -> [narrator] or a voice name.
  final Map<String, String> voices;

  /// A character read in the narrator's own voice.
  static const narrator = 'narrator';

  bool get anyVoice => voices.isNotEmpty;

  /// [name] read in [voice] ([narrator], a voice's name, or null for the
  /// dialogue voice).
  BookCast withVoice(String name, String? voice) {
    final next = {...voices};
    if (voice == null) {
      next.remove(name);
    } else {
      next[name] = voice;
    }
    return BookCast(people, next);
  }

  /// [found] (the book read again) with the voices given here: by name, or
  /// by any name the character goes by now or went by then.
  BookCast refound(List<Character> found) {
    final next = <String, String>{};
    for (final c in found) {
      final names = {...c.names};
      for (final old in people) {
        final voice = voices[old.name];
        if (voice != null && (names.contains(old.name) || old.also.any(names.contains))) {
          next[c.name] = voice;
          break;
        }
      }
      if (!next.containsKey(c.name) && voices.containsKey(c.name)) next[c.name] = voices[c.name]!;
    }
    return BookCast(found, next);
  }

  /// Without the voices in [gone] (removed from the phone).
  BookCast without(Set<String> gone) => BookCast(people, {
        for (final e in voices.entries)
          if (!gone.contains(e.value)) e.key: e.value,
      });

  Map<String, Object?> toJson() => {
        'v': 1,
        'people': [
          for (final c in people)
            {
              'name': c.name,
              if (c.also.isNotEmpty) 'also': [...c.also],
              if (c.gender != Gender.unknown) 'g': c.gender.code,
              'n': c.lines,
            },
        ],
        'voices': voices,
      };

  /// Null when [json] is not a cast this build can read.
  static BookCast? fromJson(Object? json) {
    if (json is! Map || json['people'] is! List) return null;
    final people = <Character>[
      for (final p in json['people'] as List)
        if (p is Map && p['name'] is String && (p['name'] as String).isNotEmpty)
          Character(
            p['name'] as String,
            also: [for (final a in p['also'] is List ? p['also'] as List : const []) if (a is String) a],
            gender: Gender.parse(p['g']),
            lines: (p['n'] as num?)?.toInt() ?? 0,
          ),
    ];
    final names = {for (final c in people) c.name};
    final voices = <String, String>{
      for (final e in (json['voices'] is Map ? json['voices'] as Map : const {}).entries)
        if (e.value is String && names.contains('${e.key}')) '${e.key}': e.value as String,
    };
    return BookCast(people, voices);
  }
}

/// A book's paragraphs as attribution reads them: each one's text and
/// chapter, and the sentences (units) in it, where each starts in the text
/// and how long it is.
class BookText {
  BookText({
    required this.paragraphs,
    required this.chapterOf,
    required this.firstUnit,
    required this.unitCount,
    required this.unitStart,
    required this.unitLength,
  });

  final List<String> paragraphs;
  final Int32List chapterOf;
  final Int32List firstUnit;
  final Int32List unitCount;

  /// Unit -> where it starts in its paragraph's text, and its length.
  final Int32List unitStart;
  final Int32List unitLength;

  int get length => paragraphs.length;

  /// [layout]'s paragraphs that have something to say.
  factory BookText.of(ReadingLayout layout) {
    final paragraphs = <String>[];
    final chapter = <int>[];
    final first = <int>[];
    final count = <int>[];
    for (final item in layout.items) {
      final block = item.block;
      if (block == null || item.unitCount == 0) continue;
      paragraphs.add(block.text);
      chapter.add(item.chapter);
      first.add(item.firstUnit);
      count.add(item.unitCount);
    }
    final lengths = Int32List(layout.units.length);
    for (var u = 0; u < lengths.length; u++) {
      lengths[u] = layout.units[u].text.length;
    }
    return BookText(
      paragraphs: paragraphs,
      chapterOf: Int32List.fromList(chapter),
      firstUnit: Int32List.fromList(first),
      unitCount: Int32List.fromList(count),
      unitStart: layout.unitOffset,
      unitLength: lengths,
    );
  }

  /// The paragraphs of each chapter, as (first, end) ranges, a long chapter
  /// in stretches of at most [most]: attribution starts afresh at each.
  List<(int, int)> stretches({int most = 300}) {
    final out = <(int, int)>[];
    var from = 0;
    for (var p = 1; p <= length; p++) {
      if (p == length || chapterOf[p] != chapterOf[from] || p - from >= most) {
        if (p > from) out.add((from, p));
        from = p;
      }
    }
    return out;
  }

  /// The paragraph unit [unit] is in (-1 for one in none: a heading).
  int paragraphOf(int unit) {
    var lo = 0, hi = length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (firstUnit[mid] > unit) {
        hi = mid - 1;
      } else if (firstUnit[mid] + unitCount[mid] <= unit) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  /// Paragraphs [from] to [to] alone, their units counted from the first of
  /// them: small enough to hand to another isolate.
  BookText part(int from, int to) {
    final u0 = firstUnit[from];
    final u1 = firstUnit[to - 1] + unitCount[to - 1];
    return BookText(
      paragraphs: paragraphs.sublist(from, to),
      chapterOf: Int32List.fromList(chapterOf.sublist(from, to)),
      firstUnit: Int32List.fromList([for (var p = from; p < to; p++) firstUnit[p] - u0]),
      unitCount: Int32List.fromList(unitCount.sublist(from, to)),
      unitStart: Int32List.fromList(unitStart.sublist(u0, u1)),
      unitLength: Int32List.fromList(unitLength.sublist(u0, u1)),
    );
  }
}

/// Who says the words in quotation marks in a stretch of a book: for each
/// paragraph, each quotation's span and speaker (an index into the cast it
/// was read with, or -1 when it cannot be told).
typedef Spoken = List<List<({int start, int end, int who})>>;

// ------------------------------------------------------------------ words

const _verbs = [
  'went on', 'put in', 'broke in', 'cut in', //
  'said', 'says', 'cried', 'cries', 'replied', 'replies', 'returned', 'answered', 'answers', 'asked', 'asks',
  'added', 'adds', 'continued', 'continues', 'exclaimed', 'exclaims', 'observed', 'observes', 'rejoined',
  'interrupted', 'interposed', 'whispered', 'whispers', 'muttered', 'mutters', 'murmured', 'murmurs', 'shouted',
  'shouts', 'called', 'began', 'begins', 'repeated', 'repeats', 'resumed', 'remarked', 'retorted', 'inquired',
  'enquired', 'protested', 'declared', 'insisted', 'explained', 'sighed', 'laughed', 'snapped', 'growled',
  'demanded', 'pleaded', 'urged', 'suggested', 'admitted', 'agreed', 'persisted', 'stammered', 'faltered',
  'ventured', 'sobbed', 'gasped', 'groaned', 'yelled', 'screamed', 'hissed', 'breathed', 'drawled', 'mused',
  'warned', 'promised', 'reasoned', 'ordered', 'announced', 'responded', 'joked', 'teased', 'scoffed', 'sneered',
  'chuckled', 'countered', 'corrected', 'confessed', 'objected', 'concluded', 'thought', 'wondered', 'smiled',
  'grinned', 'spoke', 'say',
];

const _titleWords = [
  'Mr', 'Mrs', 'Ms', 'Miss', 'Mme', 'Mlle', 'Dr', 'Lady', 'Lord', 'Sir', 'Madam', 'Madame', 'Dame', 'Master',
  'Mistress', 'Colonel', 'Col', 'Captain', 'Capt', 'General', 'Gen', 'Major', 'Lieutenant', 'Lt', 'Sergeant',
  'Sgt', 'Professor', 'Prof', 'Doctor', 'Father', 'Mother', 'Sister', 'Brother', 'Aunt', 'Uncle', 'King',
  'Queen', 'Prince', 'Princess', 'Duke', 'Duchess', 'Count', 'Countess', 'Baron', 'Baroness', 'Saint', 'St',
  'Rev', 'Reverend', 'Judge', 'Inspector', 'Detective', 'Officer', 'Governor', 'President', 'Senator',
  'Grandma', 'Grandpa', 'Granny',
];

const _maleTitles = {
  'Mr', 'Sir', 'Lord', 'Master', 'Father', 'Brother', 'Uncle', 'King', 'Prince', 'Duke', 'Count', 'Baron',
  'Grandpa',
};

const _femaleTitles = {
  'Mrs', 'Ms', 'Miss', 'Mme', 'Mlle', 'Lady', 'Madam', 'Madame', 'Dame', 'Mistress', 'Mother', 'Sister', 'Aunt',
  'Queen', 'Princess', 'Duchess', 'Countess', 'Baroness', 'Grandma', 'Granny',
};

/// Ranks that, in the books people listen to, are most often a man's: his,
/// unless the narration says otherwise.
const _ranks = {'Colonel', 'Col', 'Captain', 'Capt', 'General', 'Gen', 'Major', 'Lieutenant', 'Lt', 'Sergeant', 'Sgt'};

/// Given names whose sex is plain: for a name the narration's pronouns
/// cannot settle ("Darcy … she" is Elizabeth, in the same sentence).
const _herNames = {
  'Abigail', 'Ada', 'Adelaide', 'Agatha', 'Agnes', 'Alice', 'Alicia', 'Alison', 'Amanda', 'Amelia', 'Amy',
  'Anastasia', 'Angela', 'Anna', 'Anne', 'Annie', 'Antonia', 'Arabella', 'Audrey', 'Augusta', 'Barbara',
  'Beatrice', 'Becky', 'Bella', 'Belle', 'Beth', 'Betsy', 'Betty', 'Bianca', 'Bridget', 'Caroline', 'Carrie',
  'Cassandra', 'Catherine', 'Cathy', 'Cecilia', 'Cecily', 'Celia', 'Charlotte', 'Chloe', 'Christina',
  'Christine', 'Claire', 'Clara', 'Clarissa', 'Claudia', 'Cora', 'Cordelia', 'Cynthia', 'Daisy', 'Daphne',
  'Deborah', 'Delia', 'Diana', 'Dinah', 'Dolly', 'Dora', 'Dorothea', 'Dorothy', 'Edith', 'Eleanor', 'Elinor',
  'Elena', 'Eliza', 'Elizabeth', 'Ella', 'Ellen', 'Ellie', 'Elsie', 'Emily', 'Emma', 'Esther', 'Ethel', 'Eva',
  'Eve', 'Evelyn', 'Fanny', 'Fiona', 'Flora', 'Florence', 'Frances', 'Georgiana', 'Georgina', 'Gertrude',
  'Grace', 'Gwen', 'Hannah', 'Harriet', 'Hazel', 'Helen', 'Helena', 'Henrietta', 'Hermione', 'Hester', 'Hilda',
  'Ida', 'Irene', 'Iris', 'Isabel', 'Isabella', 'Isabelle', 'Ivy', 'Jane', 'Janet', 'Jemima', 'Jennifer',
  'Jenny', 'Jessica', 'Jessie', 'Joan', 'Joanna', 'Josephine', 'Judith', 'Judy', 'Julia', 'Julie', 'Juliet',
  'Kate', 'Katherine', 'Kathleen', 'Katie', 'Kitty', 'Laura', 'Lavinia', 'Leah', 'Lily', 'Lillian', 'Linda',
  'Lisa', 'Lizzie', 'Lizzy', 'Lorna', 'Lottie', 'Louisa', 'Louise', 'Lucia', 'Lucinda', 'Lucy', 'Lydia', 'Mabel',
  'Madeline', 'Maggie', 'Margaret', 'Maria', 'Marian', 'Marianne', 'Marie', 'Marilla', 'Marion', 'Martha',
  'Mary', 'Matilda', 'Maud', 'Meg', 'Melanie', 'Mildred', 'Millie', 'Minnie', 'Miranda', 'Molly', 'Nancy',
  'Natalie', 'Nell', 'Nellie', 'Nora', 'Olive', 'Olivia', 'Ophelia', 'Pamela', 'Patience', 'Patricia',
  'Pauline', 'Penelope', 'Phoebe', 'Polly', 'Priscilla', 'Prudence', 'Rachel', 'Rebecca', 'Rose', 'Rosa',
  'Rosalind', 'Rosamond', 'Ruth', 'Sally', 'Sarah', 'Sara', 'Sophia', 'Sophie', 'Stella', 'Susan', 'Susanna',
  'Sylvia', 'Tess', 'Theresa', 'Ursula', 'Vera', 'Veronica', 'Victoria', 'Violet', 'Virginia', 'Wendy',
  'Winifred', 'Zoe',
};

const _hisNames = {
  'Aaron', 'Adam', 'Adrian', 'Albert', 'Alexander', 'Alfred', 'Alan', 'Allan', 'Andrew', 'Anthony', 'Antonio',
  'Archibald', 'Archie', 'Arthur', 'Augustus', 'Basil', 'Ben', 'Benjamin', 'Bernard', 'Bill', 'Bob', 'Brian',
  'Bruce', 'Cecil', 'Charles', 'Charlie', 'Christopher', 'Clarence', 'Colin', 'Daniel', 'David', 'Dick',
  'Donald', 'Douglas', 'Duncan', 'Edgar', 'Edmund', 'Edward', 'Edwin', 'Eli', 'Elijah', 'Eric', 'Ernest',
  'Felix', 'Francis', 'Frank', 'Fred', 'Frederick', 'Gabriel', 'George', 'Gerald', 'Gilbert', 'Giles', 'Godfrey',
  'Gordon', 'Graham', 'Gregory', 'Guy', 'Harold', 'Harry', 'Henry', 'Herbert', 'Horace', 'Hugh', 'Humphrey',
  'Ian', 'Isaac', 'Jack', 'Jacob', 'James', 'Jasper', 'Jim', 'Jimmy', 'Joe', 'John', 'Johnny', 'Jonathan',
  'Joseph', 'Joshua', 'Julian', 'Kenneth', 'Lawrence', 'Leo', 'Leonard', 'Lewis', 'Louis', 'Luke', 'Malcolm',
  'Mark', 'Martin', 'Matthew', 'Maurice', 'Michael', 'Nathan', 'Nathaniel', 'Ned', 'Nicholas', 'Noah', 'Norman',
  'Oliver', 'Oscar', 'Owen', 'Patrick', 'Paul', 'Percy', 'Peter', 'Philip', 'Ralph', 'Raymond', 'Reginald',
  'Richard', 'Robert', 'Roger', 'Ronald', 'Rupert', 'Samuel', 'Sebastian', 'Simon', 'Stephen', 'Steven', 'Ted',
  'Theodore', 'Thomas', 'Timothy', 'Toby', 'Tom', 'Tommy', 'Victor', 'Vincent', 'Walter', 'Wilfred', 'William',
  'Zachary',
};

/// Titles that go before a surname, so that "Darcy" alone can be "Mr. Darcy"
/// ("Lady Catherine" and "Sir William" go before a given name).
const _surnameTitles = {
  'Mr', 'Mrs', 'Ms', 'Miss', 'Dr', 'Doctor', 'Professor', 'Prof', 'Colonel', 'Col', 'Captain', 'Capt',
  'General', 'Gen', 'Major', 'Lieutenant', 'Lt', 'Sergeant', 'Sgt', 'Inspector', 'Detective', 'Officer',
};

/// Capitalised words that are not names where a tag's subject stands.
const _notNames = {
  'I', 'He', 'She', 'It', 'They', 'We', 'You', 'The', 'A', 'An', 'This', 'That', 'These', 'Those', 'His', 'Her',
  'Their', 'Its', 'My', 'Our', 'Your', 'There', 'Here', 'Then', 'But', 'And', 'Or', 'So', 'Yet', 'If', 'When',
  'While', 'As', 'At', 'In', 'On', 'Of', 'To', 'For', 'With', 'By', 'From', 'Oh', 'O', 'Ah', 'Well', 'Yes',
  'No', 'Not', 'Nay', 'Aye', 'God', 'Heaven', 'Now', 'Still', 'Again', 'Some', 'One', 'Everyone', 'Everybody',
  'Nobody', 'Somebody', 'Someone', 'Each', 'Both', 'All', 'Neither', 'Either', 'What', 'Who', 'Why', 'How',
  'Where', 'Which', 'Perhaps', 'Indeed', 'Sir', 'Madam', 'Lord', 'Lady', 'Mr', 'Mrs', 'Miss', 'Ms', 'Dr',
};

/// What a tag that names no one says of the speaker's sex: "his wife",
/// "her father".
const _femaleWords = {
  'wife', 'lady', 'mother', 'sister', 'daughter', 'aunt', 'niece', 'girl', 'woman', 'mistress', 'madam',
  'grandmother', 'maid', 'queen', 'princess', 'duchess', 'ladyship', 'mamma', 'mama', 'mum', 'mom',
};

const _maleWords = {
  'husband', 'father', 'brother', 'son', 'uncle', 'nephew', 'boy', 'man', 'gentleman', 'master', 'grandfather',
  'king', 'prince', 'duke', 'lordship', 'papa', 'dad',
};

const _cap = r"\p{Lu}[\p{L}'’\-]*";
final _titles = _titleWords.join('|');
final _name = r'(?:(?:' + _titles + r')\.?\s+)?' + _cap + r'(?:\s+(?:(?:de|du|van|von|der|di|da|le|la)\s+)?' + _cap + r'){0,2}';
final _verb = _verbs.map((v) => v.replaceAll(' ', r'\s+')).join('|');
const _adv = r'(?:\p{Ll}+ly|only|then|again|now|thus|still|at\s+last|at\s+length|presently|aloud)';

/// A tag's subject: a pronoun (group 1), a name (2), or someone named only
/// by what they are, "his wife" (3).
final _subj = r'(?:([Hh]e|[Ss]he|I)(?![\p{L}])|(' + _name + r')|((?:his|her|their|my|your|our|the|a|an)\s+\p{L}[\p{L}\-]*))';

/// The narration right after a quotation, starting with its tag: "said
/// Elizabeth", "she replied".
final _tagAfter = RegExp(
  r'^[\s,;:—–\-]*(?:(?:' + _verb + r')\s+' + _subj + r'|' + _subj + r'\s+(?:' + _adv + r'\s+){0,2}(?:' + _verb + r'))(?![\p{L}])',
  unicode: true,
);

/// Narration that ends with a speech verb, the quotation following: "Mrs.
/// Bennet said only,".
final _verbAtEnd = RegExp(
  r'(?<![\p{L}])(?:' + _verb + r')(?:\s+(?:' + _adv + r'|most|very|quite|rather|so|to\s+\p{Ll}+|with)){0,2}[\s,;:—–\-]*$',
  unicode: true,
);

/// The tag's subject right before its verb.
final _subjectBefore = RegExp(r'(?<![\p{L}.])' + _subj + r'\s+(?:' + _adv + r'\s+){0,2}$', unicode: true);

/// "Jane, who said," for Jane.
final _whoBefore = RegExp(r'(' + _name + r'),?\s+who\s+(?:' + _adv + r'\s+){0,2}$', unicode: true);

/// A clause's subject at its start, after a "but" or "and".
final _subjectFirst = RegExp(
  r'^\s*(?:(?:[Bb]ut|[Aa]nd|[Tt]hen|[Ss]o|[Yy]et|[Nn]ow|[Ss]till)\s*,?\s+)?' + _subj + r"(?:’s|'s)?(?![\p{L}])",
  unicode: true,
);

/// A tag that says the words were thought, not said: "thought she", "said
/// Elizabeth to herself".
final _thinking = RegExp(r'(?<![\p{L}])(?:thought|wondered|mused)(?![\p{L}])|\bto\s+(?:herself|himself|myself)\b', unicode: true);

/// Narration this long, before a paragraph's first quotation or after its
/// last, may have moved the scene on.
const _longNarration = 40;

/// "…," was her answer.
final _wasReply = RegExp(r'^[\s,;:—–\-]*was\s+(his|her)\s+(?:answer|reply|rejoinder|response)(?![\p{L}])', unicode: true);

/// A quotation that is a thing named, not a line said: "…" was a wonder.
final _quotedThing = RegExp(r'^\s*(?:was|is|were|are)\s+(?:a|an|the|not|no|all|what)(?![\p{L}])', unicode: true);

/// Someone spoken to by name, at a quotation's start ("My dear Mr. Bennet,")
/// or end (", Lizzy.").
final _vocatives = [
  RegExp(
    r'^[“"«„]\s*(?:(?:[Oo]h|[Aa]h|[Nn]ay|[Yy]es|[Nn]o|[Ww]ell|[Cc]ome|[Pp]ray)[,!]?\s+)?(?:(?:[Mm]y\s+)?[Dd]ear(?:est)?\s+)?(' +
        _name +
        r')\s*[,!?]',
    unicode: true,
  ),
  RegExp(r',\s+(?:(?:my\s+)?dear(?:est)?\s+)?(' + _name + r')[.!?]*[”"»]\s*$', unicode: true),
  // "Did not you think, Mr. Darcy, that…": not one of a list of names.
  RegExp(r",(?<!\p{Lu}[\p{L}'’]*,)\s+(?:(?:my\s+)?dear(?:est)?\s+)?(" + _name + r'),\s+\p{Ll}', unicode: true),
];

/// A sentence saying someone did not speak: not a beat for the line beside it.
final _silent = RegExp(
  r'\b(?:made no (?:answer|reply)|said nothing|no reply|was silent|were silent|did not (?:answer|reply|speak)|'
  r'could not (?:answer|reply|speak)|without (?:answering|replying)|not a word)\b',
);

/// A full stop that ends something: not the one after "Mr" or "Mrs".
const _fullStop = r'(?<!(?<![\p{L}])(?:Mr|Mrs|Ms|Dr|St|Mme|Mlle|Capt|Col|Gen|Lt|Sgt|Prof|Rev|Messrs))\.';

final _nameAnywhere = RegExp(r'(?<![\p{L}’])' + _name, unicode: true);
final _titledName = RegExp(r'(?<![\p{L}’])(?:' + _titles + r')\.?\s+' + _cap + r'(?:\s+' + _cap + r'){0,2}', unicode: true);
final _heOrShe = RegExp(r'(?<![\p{L}])([Hh]e|[Ss]he)(?![\p{L}])', unicode: true);
final _sentenceEnd = RegExp(r'(?:' + _fullStop + r'|[!?…])+[’”"]?\s+', unicode: true);
final _clauseEnd = RegExp(r'(?:' + _fullStop + r'|[!?;…])+\s+|—|–', unicode: true);
final _pronoun = RegExp(r'(?<![\p{L}])(he|himself|she|herself)(?![\p{L}])', unicode: true);
final _space = RegExp(r'\s+');

int _words(String s) => s.trim().isEmpty ? 0 : s.trim().split(_space).length;

/// The narration [seg] up to the speech verb it ends with ("Mrs. Bennet "
/// of "Mrs. Bennet said only,"), or null when it does not end with one.
/// Only its last words are looked at: a long paragraph is not searched
/// whole for a verb at its end.
String? _beforeVerbAtEnd(String seg) {
  final from = seg.length > 48 ? seg.length - 48 : 0;
  final v = _verbAtEnd.firstMatch(from == 0 ? seg : seg.substring(from));
  return v == null ? null : seg.substring(0, from + v.start);
}

// ----------------------------------------------------------------- names

/// [raw] as names are compared: one space between words, curly
/// apostrophes, no possessive, a full stop after a short title.
String normalName(String raw) {
  var s = raw.replaceAll(_space, ' ').trim().replaceAll("'", '’');
  if (s.endsWith('’s')) s = s.substring(0, s.length - 2);
  final m = RegExp(r'^(Mr|Mrs|Ms|Dr|St|Mme|Mlle|Capt|Col|Gen|Lt|Sgt|Prof|Rev)\.? ').firstMatch(s);
  if (m != null) s = '${m[1]}. ${s.substring(m.end)}';
  return s;
}

/// [name]'s title ("Mr"), or null.
String? _titleOf(String name) {
  final first = name.split(' ').first.replaceAll('.', '');
  return name.contains(' ') && _titleWords.contains(first) ? first : null;
}

/// [name] without its title.
String _bare(String name) => _titleOf(name) == null ? name : name.substring(name.indexOf(' ') + 1);

Gender _titleGender(String name) {
  final t = _titleOf(name);
  if (t == null) return Gender.unknown;
  if (_maleTitles.contains(t)) return Gender.male;
  if (_femaleTitles.contains(t)) return Gender.female;
  return Gender.unknown;
}

/// Whether [name] (a match of [_name]) is a name, not a capitalised word
/// standing where one could ("Then", "Oh").
bool _isName(String name) {
  final words = name.split(' ');
  final first = words.first.replaceAll('.', '');
  if (_titleWords.contains(first) && words.length > 1) return !_notNames.contains(words[1]);
  if (_notNames.contains(first)) return false;
  // A shouted word ("STOP") is not a name.
  return words.first.length < 2 || words.first.substring(1) != words.first.substring(1).toUpperCase();
}

// ------------------------------------------------------------- quotations

const _openers = {'“': '”', '"': '"', '«': '»', '「': '」', '„': '“'};
const _closers = {'”', '"', '»', '」', '“'};

/// The quotations in [text], as dialogue.dart cuts a sentence: double
/// quotation marks (single ones are too often apostrophes). Each one's span,
/// its marks included; one left open runs to the end ([closed] false).
List<({int start, int end, bool closed})> quotationsIn(String text) {
  final out = <({int start, int end, bool closed})>[];
  final firstOpen = text.indexOf(RegExp('[“"«「„]'));
  final firstClose = text.indexOf(RegExp('[”»」]'));
  // A paragraph that closes a quotation it never opened began inside one.
  var start = firstClose >= 0 && (firstOpen < 0 || firstClose < firstOpen) ? 0 : -1;
  String? closing;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (start < 0) {
      final close = _openers[c];
      if (close != null) {
        start = i;
        closing = close;
      }
    } else if (c == closing || (closing == null && _closers.contains(c))) {
      out.add((start: start, end: i + 1, closed: true));
      start = -1;
      closing = null;
    }
  }
  if (start >= 0 && text.substring(start).trim().length > 1) out.add((start: start, end: text.length, closed: false));
  return out;
}

// --------------------------------------------------------------- the cast

/// The names a cast's characters go by, for attribution: each name to its
/// character, and each character's sex.
class CastIndex {
  CastIndex(this.characters) {
    for (var i = 0; i < characters.length; i++) {
      for (final n in characters[i].names) {
        _byName[normalName(n)] = i;
      }
    }
    _first = _byName[firstPerson];
  }

  final List<Character> characters;
  final _byName = <String, int>{};
  int? _first;

  int? of(String name) => _byName[normalName(name)];

  /// Every name, longest first (for finding them in a text).
  late final RegExp? names = _byName.isEmpty
      ? null
      : RegExp(
          '(?<![\\p{L}])(?:${(_byName.keys.where((n) => n != firstPerson).toList()..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|')})(?![\\p{L}])',
          unicode: true,
        );
}

// ------------------------------------------------------------ attribution

/// One quotation as attribution works on it.
class _Quote {
  _Quote(this.start, this.end, this.closed);
  final int start;
  final int end;
  final bool closed;

  /// Who a tag beside it says speaks (an id), or -1.
  int tagged = -1;

  /// It has a tag that names no one it can tell ("his wife"), with what
  /// that says of their sex.
  bool described = false;
  Gender hint = Gender.unknown;
}

/// A paragraph's quotations, said by one speaker or several: a turn of a
/// conversation.
class _Turn {
  _Turn(this.para, this.quotes);
  final int para;
  final List<_Quote> quotes;

  /// Who speaks it, when one person does; -1 when unknown, -2 when the
  /// paragraph has two speakers.
  int who = -1;

  /// Found by its own tag or beat (not by the turns around it).
  bool anchored = false;

  /// A tag says someone speaks it whom it cannot name: only the turns round
  /// it can, and only someone of [hint]'s sex.
  bool described = false;
  Gender hint = Gender.unknown;

  /// It carries on the quotation the paragraph before left open.
  bool carriesOn = false;

  /// The words said, for the check that a speaker is not the one addressed.
  String said = '';

  /// Who the narration around it names: the people in the scene.
  Set<int> scene = const {};

  /// Its quotation is a thing named, not a line ("…" was a wonder): it takes
  /// no turn in an exchange.
  bool thing = false;

  /// Who its lines speak to by name: the next line is likely theirs.
  Set<int> spokenTo = const {};

  /// A thought ("…," thought she; said Elizabeth to herself): its speaker's,
  /// but no turn in the conversation round it.
  bool aside = false;

  /// So much narration before its first quotation, or after its last, that
  /// the scene may have moved on: an exchange does not run across it.
  bool longBefore = false;
  bool longAfter = false;
}

/// Attribution with a cast: who says what in a stretch of a book.
class Attributor {
  Attributor(this.cast);

  final CastIndex cast;

  /// Names the cast does not know, met in this stretch: ids after the cast's.
  final _strangers = <String, int>{};
  final _strangerGender = <int, Gender>{};

  Gender genderOf(int who) {
    if (who < 0) return Gender.unknown;
    if (who < cast.characters.length) return cast.characters[who].gender;
    return _strangerGender[who] ?? Gender.unknown;
  }

  /// The id for [name]: the cast's character, or a stranger's.
  int idOf(String name) {
    final n = normalName(name);
    final known = cast.of(n);
    if (known != null) return known;
    return _strangers.putIfAbsent(n, () {
      final id = cast.characters.length + _strangers.length;
      _strangerGender[id] = _titleGender(n);
      _strangerName[id] = n;
      return id;
    });
  }

  final _strangerName = <int, String>{};

  /// Every name [who] goes by.
  Iterable<String> _namesOf(int who) => who < 0
      ? const []
      : who < cast.characters.length
          ? cast.characters[who].names
          : [if (_strangerName[who] case final n?) n];

  /// The people in the scene as the paragraph being read began: named in
  /// the narration of the last few paragraphs, spoken to, or speaking.
  final _scene = <int>{};

  /// The wife (for "his wife") or the husband ("her husband") of the one
  /// Mr. or Mrs. of the scene with a spouse in the cast: "Mrs. Bennet" for
  /// "his wife" with Mr. Bennet there. -1 when there is not exactly one.
  int _spouse(String word) {
    final wife = const {'wife', 'lady'}.contains(word);
    final found = <int>{};
    for (final w in _scene) {
      for (final n in _namesOf(w)) {
        final title = _titleOf(n);
        if (title != (wife ? 'Mr' : 'Mrs')) continue;
        final other = cast.of('${wife ? 'Mrs.' : 'Mr.'} ${_bare(n)}');
        if (other != null) found.add(other);
      }
    }
    return found.length == 1 ? found.single : -1;
  }

  // The people in play: who spoke last of each sex, and who of each sex has
  // been named in the narration since.
  final _lastSpeaker = <Gender, int>{};
  final _lastAt = <Gender, int>{};
  final _namedSince = <Gender, Set<int>>{Gender.male: {}, Gender.female: {}};

  void _reset() {
    _lastSpeaker.clear();
    _lastAt.clear();
    _namedSince[Gender.male]!.clear();
    _namedSince[Gender.female]!.clear();
    _subjectSince[Gender.male]!.clear();
    _subjectSince[Gender.female]!.clear();
    _previous = -1;
  }

  /// Who spoke the paragraph before, when it was a line of its own: a new
  /// paragraph of dialogue is someone else's ("she added" in it is not
  /// them), unless it carries on their quotation.
  int _previous = -1;
  bool _carriesOn = false;

  /// A speaker of this sex is let go after this many paragraphs: "he" a
  /// page later may be someone else.
  static const _forget = 12;

  void _spoke(int who, int para) {
    final g = genderOf(who);
    if (g == Gender.unknown) return;
    _lastSpeaker[g] = who;
    _lastAt[g] = para;
    _namedSince[g]!.clear();
    _subjectSince[g]!.clear();
  }

  void _named(int who, int para) {
    final g = genderOf(who);
    if (g == Gender.unknown) return;
    _namedSince[g]!.add(who);
  }

  /// Who "he" or "she" is, where only one person can be meant: the last to
  /// speak of that sex, if nobody else of it has been named since; or,
  /// before anyone of it has spoken, the one person of it named; or the one
  /// person of it the paragraph itself names, as the subject of a sentence
  /// ("Mr. Darcy, who was leaning against the mantel-piece, … he said,").
  /// Never the one who spoke the line before, in a new line of dialogue.
  /// -1 if not clear.
  int _pronoun(String word, int para) {
    if (word == 'I') return cast._first ?? idOf(firstPerson);
    final g = word.toLowerCase() == 'he' ? Gender.male : Gender.female;
    final last = _lastSpeaker[g];
    final named = _namedSince[g]!;
    var who = -1;
    if (last != null && para - (_lastAt[g] ?? para) <= _forget) {
      if (named.every((n) => n == last)) who = last;
    } else if (named.length == 1 && _subjectSince[g]!.contains(named.first)) {
      who = named.first;
    }
    if (who >= 0 && who == _previous && !_carriesOn) return -1;
    return who;
  }

  /// Who of each sex has been named as the subject of a sentence since that
  /// sex last spoke: a person only mentioned ("looking towards Bingley and
  /// Jane") is not who "she" is.
  final _subjectSince = <Gender, Set<int>>{Gender.male: {}, Gender.female: {}};

  /// The people named at the start of a sentence or clause of [text]: its
  /// subjects ("Mr. Darcy, who was leaning…"; "but Mr. Collins, much
  /// offended,…"; "Mrs. Bennet's eyes sparkled.").
  Set<int> _subjectsIn(String text) {
    final out = <int>{};
    var from = 0;
    for (final end in [..._clauseEnd.allMatches(text).map((m) => m.end), text.length]) {
      if (end <= from) continue;
      final m = _subjectFirst.firstMatch(text.substring(from, end));
      from = end;
      final name = m?[2];
      if (name != null && _isName(name)) out.add(idOf(name));
    }
    return out;
  }

  /// [text]'s names into who has been named since each sex last spoke,
  /// [except] (a tag's speaker) aside, and the subjects among them.
  void _narration(String text, int para, {Set<int> except = const {}, Set<int>? into}) {
    var any = false;
    for (final who in _namesIn(text)) {
      any = true;
      into?.add(who);
      if (!except.contains(who)) _named(who, para);
    }
    if (!any) return;
    for (final who in _subjectsIn(text)) {
      if (except.contains(who)) continue;
      final g = genderOf(who);
      if (g != Gender.unknown) _subjectSince[g]!.add(who);
    }
  }

  /// Names in [text] (narration), in order.
  Iterable<int> _namesIn(String text) sync* {
    final known = cast.names;
    final seen = <(int, int)>[];
    if (known != null) {
      for (final m in known.allMatches(text)) {
        seen.add((m.start, m.end));
        yield cast.of(m[0]!)!;
      }
    }
    // Strangers with a title ("Mrs. Long"): enough to know "she" might be
    // her. A capitalised word alone may be a place.
    for (final m in _titledName.allMatches(text)) {
      final n = m[0]!;
      if (!_isName(n)) continue;
      if (seen.any((s) => m.start < s.$2 && m.end > s.$1)) continue;
      yield idOf(n);
    }
  }

  /// A tag's subject, as an id: [m]'s groups [g] (pronoun), [g]+1 (name),
  /// [g]+2 (description). Null when the match is not a tag after all.
  ({int who, bool described, Gender hint})? _subject(RegExpMatch m, int g, int para) {
    final pronoun = m[g];
    if (pronoun != null) {
      final who = _pronoun(pronoun, para);
      final hint = pronoun == 'I'
          ? Gender.unknown
          : pronoun.toLowerCase() == 'he'
              ? Gender.male
              : Gender.female;
      return (who: who, described: who < 0, hint: hint);
    }
    final name = m[g + 1];
    if (name != null) {
      if (!_isName(name)) return null;
      return (who: idOf(name), described: false, hint: Gender.unknown);
    }
    final desc = m[g + 2];
    if (desc != null) {
      final words = desc.split(_space);
      final word = words.last.toLowerCase();
      final hint = _femaleWords.contains(word)
          ? Gender.female
          : _maleWords.contains(word)
              ? Gender.male
              : Gender.unknown;
      final spouse = (words.first == 'his' && (word == 'wife' || word == 'lady')) ||
              (words.first == 'her' && word == 'husband')
          ? _spouse(word)
          : -1;
      if (spouse >= 0) return (who: spouse, described: false, hint: hint);
      return (who: -1, described: true, hint: hint);
    }
    return null;
  }

  /// "…," was her answer: her, if "she" is clear.
  ({int who, bool described, Gender hint})? _reply(String seg, int para) {
    final m = _wasReply.firstMatch(seg);
    if (m == null) return null;
    final word = m[1] == 'his' ? 'he' : 'she';
    final who = _pronoun(word, para);
    return (who: who, described: who < 0, hint: word == 'he' ? Gender.male : Gender.female);
  }

  /// The people [quote] speaks to by name: "My dear Mr. Bennet," "…like it,
  /// Lizzy."
  Iterable<int> _spokenTo(String quote) sync* {
    for (final re in _vocatives) {
      for (final m in re.allMatches(quote)) {
        final n = m[1]!;
        if (!_isName(n)) continue;
        final known = cast.of(n);
        if (known != null) {
          yield known;
        } else if (_titleOf(normalName(n)) != null) {
          yield idOf(n);
        }
      }
    }
  }

  /// The tag in narration [seg] that ends right before a quotation:
  /// "Mrs. Bennet said only,". Null when it has none.
  ({int who, bool described, Gender hint})? _tagBefore(String seg, int para) {
    final before = _beforeVerbAtEnd(seg);
    if (before == null) return null;
    final who = _whoBefore.firstMatch(before);
    if (who != null && _isName(who[1]!)) return (who: idOf(who[1]!), described: false, hint: Gender.unknown);
    final s = _subjectBefore.firstMatch(before);
    if (s != null) return _subject(s, 1, para);
    // "Mr. Collins, much offended, laid aside his book, and said,—": the
    // clause's subject, at its start; or the last "he" or "she" in it ("he
    // withdrew his own, and coldly said,").
    final cut = _clauseEnd.allMatches(before).lastOrNull;
    final clause = cut == null ? before : before.substring(cut.end);
    final f = _subjectFirst.firstMatch(clause);
    if (f != null) return _subject(f, 1, para);
    final last = _heOrShe.allMatches(clause).lastOrNull;
    if (last == null) return null;
    final who2 = _pronoun(last[1]!, para);
    return (who: who2, described: who2 < 0, hint: last[1]!.toLowerCase() == 'he' ? Gender.male : Gender.female);
  }

  /// Who says what in paragraphs [from] to [to] of [text]: for each, its
  /// quotations and their speakers.
  Spoken attribute(BookText text, int from, int to) {
    _reset();
    final out = <List<({int start, int end, int who})>>[];
    final turns = <_Turn?>[];
    // Who the last few paragraphs named, spoke to or heard: the people in
    // the scene, one of whom an exchange may be between.
    final recent = <Set<int>>[];
    void scene(Set<int> here) {
      recent.add(here);
      if (recent.length > 3) recent.removeAt(0);
      _scene
        ..clear()
        ..addAll([for (final s in recent) ...s]);
    }

    _scene.clear();
    final named = <Set<int>>[];
    ({int who, bool described, Gender hint})? pending;
    var openBefore = false;
    for (var p = from; p < to; p++) {
      final t = text.paragraphs[p];
      final spans = quotationsIn(t);
      final namedHere = <int>{};
      named.add(namedHere);
      if (spans.isEmpty) {
        // Narration: the people named in it, and a tag left at its end for
        // the quotation that opens the next paragraph.
        _previous = -1;
        _carriesOn = false;
        _narration(t, p, into: namedHere);
        _scene.addAll(namedHere);
        pending = _tagBefore(t, p);
        openBefore = false;
        turns.add(null);
        scene(namedHere);
        continue;
      }
      final quotes = [for (final s in spans) _Quote(s.start, s.end, s.closed)];
      final turn = _Turn(p, quotes)
        ..carriesOn = openBefore && spans.first.start <= 2
        ..said = [for (final q in quotes) t.substring(q.start, q.end)].join(' ');
      _carriesOn = turn.carriesOn;
      // Whoever the lines speak to by name is there (for "his wife" and "he"
      // in this paragraph), though perhaps not by that name elsewhere: Lady
      // Catherine's "Miss Bennet" is Elizabeth.
      final spokenTo = <int>{};
      for (final q in quotes) {
        for (final who in _spokenTo(t.substring(q.start, q.end))) {
          _scene.add(who);
          spokenTo.add(who);
        }
      }
      turn.spokenTo = spokenTo;
      // Narration between, before and after the quotations.
      var at = 0;
      for (var k = 0; k <= quotes.length; k++) {
        final end = k < quotes.length ? quotes[k].start : t.length;
        final seg = t.substring(at, end);
        if (k > 0) {
          final m = _tagAfter.firstMatch(seg);
          final s = m == null ? _reply(seg, p) : (_subject(m, 1, p) ?? _subject(m, 4, p));
          if (s != null) _note(quotes[k - 1], s, p);
          if (m != null && _thinking.hasMatch(seg.substring(0, (m.end + 16).clamp(0, seg.length)))) turn.aside = true;
        }
        if (k < quotes.length) {
          final s = k == 0 && seg.trim().isEmpty && pending != null ? pending : _tagBefore(seg, p);
          if (s != null) {
            _note(quotes[k], s, p);
            final tail = seg.length > 48 ? seg.substring(seg.length - 48) : seg;
            if (_thinking.hasMatch(tail)) turn.aside = true;
          }
        }
        if (k == 0) turn.longBefore = _words(seg) >= _longNarration;
        if (k == quotes.length) turn.longAfter = _words(seg) >= _longNarration;
        // The people named in the narration, the tag's own name aside.
        final before = namedHere.length;
        _narration(seg, p, except: {for (final q in quotes) if (q.tagged >= 0) q.tagged}, into: namedHere);
        if (namedHere.length != before) _scene.addAll(namedHere);
        if (k < quotes.length) at = quotes[k].end;
      }
      pending = null;
      _settle(turn, t);
      if (turn.who >= 0) {
        if (turn.anchored) _spoke(turn.who, p);
        namedHere.add(turn.who);
      }
      _previous = turn.who >= 0 ? turn.who : -1;
      turn.scene = {..._scene, ...namedHere};
      scene(namedHere);
      turns.add(turn);
      openBefore = !spans.last.closed;
    }
    _alternate(turns, named);
    for (final turn in turns) {
      if (turn == null) {
        out.add(const []);
        continue;
      }
      out.add([
        for (final q in turn.quotes)
          (start: q.start, end: q.end, who: turn.who == -2 ? q.tagged : turn.who),
      ]);
    }
    return out;
  }

  void _note(_Quote q, ({int who, bool described, Gender hint}) s, int para) {
    if (s.who >= 0) {
      q.tagged = s.who;
      // A "she added" later in the paragraph is this speaker.
      _spoke(s.who, para);
    } else if (s.described) {
      q.described = true;
      q.hint = s.hint;
    }
  }

  /// One speaker for the paragraph: the one its tags agree on, or the one
  /// its narration is about (a beat: "Mrs. Bennet's eyes sparkled."); two
  /// different tags, two speakers, each quotation its own.
  void _settle(_Turn turn, String t) {
    final named = {for (final q in turn.quotes) if (q.tagged >= 0) q.tagged};
    // Two people tagged, or one tagged and another only described ("…,"
    // said her mother. "…," said Elizabeth.): each quotation its own tag.
    if (named.length > 1 || (named.length == 1 && turn.quotes.any((q) => q.described))) {
      turn.who = -2;
      return;
    }
    if (named.length == 1) {
      turn
        ..who = named.single
        ..anchored = true;
      return;
    }
    final described = turn.quotes.where((q) => q.described).toList();
    if (described.isNotEmpty) {
      final hints = {for (final q in described) q.hint}..remove(Gender.unknown);
      turn
        ..described = true
        ..hint = hints.length == 1 ? hints.single : Gender.unknown;
      return;
    }
    if (turn.carriesOn) return;
    // "What could have become of them?" was a wonder: nobody's line.
    if (turn.quotes.any((q) => _quotedThing.hasMatch(t.substring(q.end)))) {
      turn.thing = true;
      return;
    }
    final beat = _beat(turn, t);
    if (beat >= 0) {
      turn
        ..who = beat
        ..anchored = true;
    }
  }

  /// The one person the paragraph's narration opens a sentence with, its
  /// subject: whose beat it is. -1 if none, or more than one.
  int _beat(_Turn turn, String t) {
    final subjects = <int>{};
    final others = <int>{};
    var at = 0;
    for (var k = 0; k <= turn.quotes.length; k++) {
      final end = k < turn.quotes.length ? turn.quotes[k].start : t.length;
      final seg = t.substring(at, end);
      if (seg.trim().isNotEmpty) {
        var from = 0;
        for (final s in [..._sentenceEnd.allMatches(seg).map((m) => m.end), seg.length]) {
          final sentence = seg.substring(from, s);
          from = s;
          if (sentence.trim().isEmpty || _silent.hasMatch(sentence)) continue;
          final f = _subjectFirst.firstMatch(sentence);
          final g = f == null ? null : _subject(f, 1, turn.para);
          if (g != null && g.who >= 0) {
            subjects.add(g.who);
          } else {
            others.addAll(_namesIn(sentence));
          }
        }
      }
      if (k < turn.quotes.length) at = turn.quotes[k].end;
    }
    if (subjects.length != 1) return -1;
    final who = subjects.single;
    return others.every((o) => o == who) ? who : -1;
  }

  /// The turns of an exchange: within a run of paragraphs that all speak,
  /// two people known to take turns give the turns between their own, and
  /// those after, to each other in order. Nothing is filled where a third
  /// person speaks, where the order breaks, or where a line names the one
  /// it would give it to (they are being spoken to).
  void _alternate(List<_Turn?> turns, List<Set<int>> named) {
    // The two people of the last exchange, while the narration between
    // exchanges is short and names nobody else: the same two talk on.
    (int, int)? pair;
    var gap = 0;
    final gapNames = <int>{};
    bool speaks(int i) => turns[i] != null && !turns[i]!.thing && !turns[i]!.aside;
    var moved = false;
    var start = 0;
    while (start < turns.length) {
      if (!speaks(start)) {
        gap++;
        gapNames.addAll(named[start]);
        start++;
        continue;
      }
      if (pair != null && (moved || gap > 2 || gapNames.any((n) => n != pair!.$1 && n != pair.$2))) pair = null;
      // A run of paragraphs that all speak, up to a long stretch of
      // narration inside one: the scene may have moved on there.
      var end = start;
      moved = false;
      while (end < turns.length && speaks(end)) {
        end++;
        if (turns[end - 1]!.longAfter || (end < turns.length && speaks(end) && turns[end]!.longBefore)) {
          moved = true;
          break;
        }
      }
      // A quotation carried on from one paragraph to the next is one turn.
      final run = <List<_Turn>>[];
      for (var i = start; i < end; i++) {
        final t = turns[i]!;
        if (t.carriesOn && run.isNotEmpty) {
          run.last.add(t);
        } else {
          run.add([t]);
        }
      }
      pair = _fillRun(run, pair);
      gap = 0;
      gapNames.clear();
      start = end;
    }
  }

  /// Fill [run] window by window, each from where the last one stopped:
  /// at a third person, or a turn its two people cannot explain. [carried]
  /// is the pair of the exchange before. The pair it ends with.
  (int, int)? _fillRun(List<List<_Turn>> run, (int, int)? carried) {
    final known = [
      for (final group in run) group.map((t) => t.who).firstWhere((w) => w >= 0 || w == -2, orElse: () => -1),
    ];
    final scene = {for (final group in run) for (final t in group) ...t.scene};
    (int, int)? last;
    var s = 0;
    while (s < run.length) {
      final r = _fillWindow(run, known, scene, s, s == 0 ? carried : null);
      // A window cut short by a line its pair cannot explain has a third
      // person in it: its pair is not carried on.
      last = r.cut ? null : r.pair;
      s = r.next > s ? r.next : s + 1;
    }
    return last;
  }

  /// One window of [run] from [s]: the turns up to a third person (or a
  /// known turn out of order), its two people, and the unknown turns between
  /// given to each in turn. Where it stopped, and the pair it filled with.
  ({int next, (int, int)? pair, bool cut}) _fillWindow(
    List<List<_Turn>> run,
    List<int> known,
    Set<int> scene,
    int s,
    (int, int)? carried,
  ) {
    int? a, b, aParity;
    var e = s;
    for (; e < run.length; e++) {
      final w = known[e];
      if (w == -2) break;
      if (w < 0) continue;
      if (a == null) {
        a = w;
        aParity = e % 2;
      } else if (w == a) {
        if (e % 2 != aParity) break;
      } else if (b == null || w == b) {
        if (e % 2 == aParity) break;
        b = w;
      } else {
        break;
      }
    }
    if (a == null || aParity == null) return (next: e, pair: null, cut: false);
    if (b == null && carried != null && (carried.$1 == a || carried.$2 == a)) {
      b = carried.$1 == a ? carried.$2 : carried.$1;
    }
    if (b == null) {
      // One speaker known: the other is the one other person in the scene
      // who fits the "she said" (or "his wife") of their turns, if nobody
      // else of either one's sex is there to be them. With nothing to say
      // their sex, or two who would fit, nobody.
      final hints = <Gender>{};
      for (var i = s; i < e; i++) {
        final first = run[i].first;
        if (known[i] >= 0 || !first.described || first.hint == Gender.unknown) continue;
        if (i % 2 != aParity) hints.add(first.hint);
      }
      if (hints.length != 1) return (next: e, pair: null, cut: false);
      final others = [for (final w in scene) if (w != a && genderOf(w) == hints.single) w];
      if (others.length != 1) return (next: e, pair: null, cut: false);
      final ga = genderOf(a);
      if (ga == Gender.unknown) return (next: e, pair: null, cut: false);
      if (scene.any((w) => w != a && w != others.single && genderOf(w) == ga)) return (next: e, pair: null, cut: false);
      b = others.single;
    }
    for (var i = s; i < e; i++) {
      if (known[i] >= 0) {
        // Carried-on paragraphs of a known turn are its speaker's too.
        for (final t in run[i]) {
          if (t.who < 0) t.who = known[i];
        }
        continue;
      }
      final who = i % 2 == aParity ? a : b;
      final first = run[i].first;
      // A tag that names no one ("said he", "his wife") must fit; a line is
      // not given to the one it speaks to, nor to anyone but the one the
      // line before spoke to by name: either way a third person may have
      // spoken. The window ends there.
      final misfit = first.described && (first.hint == Gender.unknown || first.hint != genderOf(who));
      final answered = i > 0 ? run[i - 1].last.spokenTo : const <int>{};
      if (misfit ||
          run[i].any((t) => _addresses(t.said, who)) ||
          (answered.isNotEmpty && !answered.contains(who))) {
        return (next: i, pair: (a, b), cut: true);
      }
      for (final t in run[i]) {
        t.who = who;
      }
    }
    return (next: e, pair: (a, b), cut: false);
  }

  /// Whether [said] names [who]: a line spoken to them, not by them.
  bool _addresses(String said, int who) {
    if (who >= cast.characters.length) return false;
    for (final n in cast.characters[who].names) {
      if (n == firstPerson) continue;
      final i = said.indexOf(n);
      if (i < 0) continue;
      final after = i + n.length;
      final before = i == 0 ? '' : said[i - 1];
      if ((after >= said.length || !RegExp(r'\p{L}', unicode: true).hasMatch(said[after])) &&
          !RegExp(r'\p{L}', unicode: true).hasMatch(before)) {
        return true;
      }
    }
    return false;
  }
}

/// Speaker of each unit (sentence) of [text]'s paragraphs [from] to [to],
/// from [spoken]: the one person who says every quotation in it, else -1.
void unitSpeakers(BookText text, int from, int to, Spoken spoken, Int32List into) {
  for (var p = from; p < to; p++) {
    final quotes = spoken[p - from];
    if (quotes.isEmpty) continue;
    final first = text.firstUnit[p];
    for (var u = first; u < first + text.unitCount[p]; u++) {
      final s = text.unitStart[u];
      final e = s + text.unitLength[u];
      var who = -1;
      var mixed = false;
      for (final q in quotes) {
        if (q.start >= e || q.end <= s) continue;
        if (q.who < 0 || (who >= 0 && who != q.who)) {
          mixed = true;
          break;
        }
        who = q.who;
      }
      into[u] = mixed ? -1 : who;
    }
  }
}

// -------------------------------------------------------------- the book

/// The characters of [text] (a whole book): everyone its speech tags name
/// at least [least] times in all, by the name used most, the others it goes
/// by folded in ("Darcy" into "Mr. Darcy"), each with their sex as the
/// book's narration and titles tell it, how many lines are theirs and one
/// to hear. Most lines first.
List<Character> findCharacters(BookText text, {int least = 2}) {
  // Every name a tag gives a speaker, and how often.
  final counts = <String, int>{};
  final empty = Attributor(CastIndex(const []));
  for (var p = 0; p < text.length; p++) {
    for (final n in _tagNames(text.paragraphs[p], empty)) {
      counts[n] = (counts[n] ?? 0) + 1;
    }
  }
  final firstPersonTags = counts.remove(firstPerson) ?? 0;
  if (counts.isEmpty && firstPersonTags == 0) return const [];
  final gender = _learnGenders(text, counts.keys.toList());
  final people = _merge(counts, gender);
  if (firstPersonTags > 0) people.add(Character(firstPerson));

  // Who says what, with them: their lines counted, and one kept to hear.
  final index = CastIndex(people);
  for (final (from, to) in text.stretches()) {
    final spoken = Attributor(index).attribute(text, from, to);
    for (var p = from; p < to; p++) {
      final quotes = spoken[p - from];
      final whos = {for (final q in quotes) if (q.who >= 0 && q.who < people.length) q.who};
      for (final who in whos) {
        final c = people[who];
        c.lines++;
        if (c.sample.isEmpty) {
          for (final q in quotes) {
            if (q.who != who) continue;
            final words = _inside(text.paragraphs[p].substring(q.start, q.end));
            if (words.length >= 24 && words.length <= 180) {
              c.sample = words;
              break;
            }
          }
        }
      }
    }
  }
  return [for (final c in people) if (c.lines >= least) c]..sort((a, b) => b.lines - a.lines);
}

/// A quotation's words, without its marks or the comma before its tag.
String _inside(String quote) {
  var s = quote.trim();
  if (s.isNotEmpty && _openers.containsKey(s[0])) s = s.substring(1);
  if (s.isNotEmpty && _closers.contains(s[s.length - 1])) s = s.substring(0, s.length - 1);
  s = s.trim();
  if (s.endsWith(',')) s = '${s.substring(0, s.length - 1)}.';
  return s;
}

/// The names [t]'s speech tags give speakers ("I" for the storyteller).
Iterable<String> _tagNames(String t, Attributor a) sync* {
  final quotes = quotationsIn(t);
  var at = 0;
  for (var k = 0; k <= quotes.length; k++) {
    final end = k < quotes.length ? quotes[k].start : t.length;
    final seg = t.substring(at, end);
    if (k > 0) {
      final m = _tagAfter.firstMatch(seg);
      if (m != null) {
        final n = m[2] ?? m[5];
        if (n != null && _isName(n)) yield normalName(n);
        if (m[1] == 'I' || m[4] == 'I') yield firstPerson;
      }
    }
    if (k < quotes.length && quotes.isNotEmpty) {
      final before = _beforeVerbAtEnd(seg);
      if (before != null) {
        final s = _subjectBefore.firstMatch(before);
        final n = s?[2];
        if (n != null && _isName(n)) yield normalName(n);
        if (s?[1] == 'I') yield firstPerson;
      }
    }
    if (k < quotes.length) at = quotes[k].end;
  }
}

/// Each of [names]' sex: from its title ("Mrs."); else from a given name
/// whose sex is plain; else from the pronouns the narration uses for it,
/// where they all but agree ("Elizabeth … she"); else, for a surname alone,
/// a man's when the book has a "Mr." of that name (men go by their surname,
/// as Darcy and Bingley do), or a soldier's rank, his.
Map<String, Gender> _learnGenders(BookText text, List<String> names) {
  final out = <String, Gender>{};
  final untitled = <String>[];
  for (final n in names) {
    var g = _titleGender(n);
    final first = _bare(n).split(' ').first;
    if (g == Gender.unknown && _herNames.contains(first)) g = Gender.female;
    if (g == Gender.unknown && _hisNames.contains(first)) g = Gender.male;
    if (g != Gender.unknown) {
      out[n] = g;
    } else {
      untitled.add(n);
    }
  }
  if (untitled.isEmpty) return out;
  final misters = <String>{};
  final mister = RegExp(r'(?<![\p{L}])Mr\.?\s+(' + _cap + r')', unicode: true);
  for (final t in text.paragraphs) {
    if (!t.contains('Mr')) continue;
    for (final m in mister.allMatches(t)) {
      misters.add(m[1]!);
    }
  }
  final he = <String, int>{};
  final she = <String, int>{};
  final find = RegExp(
    '(?<![\\p{L}.])(${(untitled.toList()..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|')})(?![\\p{L}])',
    unicode: true,
  );
  for (final t in text.paragraphs) {
    // Narration only: a name in a quotation is often the one spoken to.
    final quotes = quotationsIn(t);
    var at = 0;
    for (var k = 0; k <= quotes.length; k++) {
      final end = k < quotes.length ? quotes[k].start : t.length;
      final seg = t.substring(at, end);
      for (final m in find.allMatches(seg)) {
        // The first "he" or "she" after it in its sentence, before anyone
        // else is named (within a line or two).
        final window = seg.substring(m.end, m.end + 140 < seg.length ? m.end + 140 : seg.length);
        final next = _sentenceEnd.firstMatch(window);
        final rest = next == null ? window : window.substring(0, next.start);
        final other = _nameAnywhere.firstMatch(rest);
        final upTo = other == null ? rest : rest.substring(0, other.start);
        final p = _pronoun.firstMatch(upTo);
        if (p == null) continue;
        final w = p[1]!;
        final n = m[1]!;
        if (w.startsWith('s') || w == 'herself') {
          she[n] = (she[n] ?? 0) + 1;
        } else {
          he[n] = (he[n] ?? 0) + 1;
        }
      }
      if (k < quotes.length) at = quotes[k].end;
    }
  }
  for (final n in untitled) {
    final m = he[n] ?? 0;
    final f = she[n] ?? 0;
    out[n] = m >= 3 && m >= 4 * f
        ? Gender.male
        : f >= 3 && f >= 4 * m
            ? Gender.female
            : _ranks.contains(_titleOf(n)) || (!n.contains(' ') && misters.contains(n))
                ? Gender.male
                : Gender.unknown;
  }
  return out;
}

/// [counts]' names as characters: the ones that are one person folded
/// together. A name with more words folds into its shorter form ("Lady
/// Catherine de Bourgh" into "Lady Catherine", "Elizabeth Bennet" into
/// "Elizabeth"); a surname alone into the one titled form it fits ("Darcy"
/// into "Mr. Darcy", not "Miss Darcy": the narration calls Darcy "he").
List<Character> _merge(Map<String, int> counts, Map<String, Gender> gender) {
  final names = counts.keys.toList()..sort((a, b) => (counts[b]! - counts[a]!) != 0 ? counts[b]! - counts[a]! : a.compareTo(b));
  final parent = {for (final n in names) n: n};
  String root(String n) {
    var r = n;
    while (parent[r] != r) {
      r = parent[r]!;
    }
    return r;
  }

  bool fits(String a, String b) {
    final ga = gender[a] ?? Gender.unknown;
    final gb = gender[b] ?? Gender.unknown;
    return ga == Gender.unknown || gb == Gender.unknown || ga == gb;
  }

  for (final n in names) {
    final title = _titleOf(n);
    final words = _bare(n).split(' ');
    String? into;
    if (words.length > 1) {
      // The same title (or none) and the start of the name: its short form.
      final shorter = [
        for (var k = words.length - 1; k >= 1; k--) [if (title != null) title.endsWith('.') ? title : _titled(title), ...words.take(k)].join(' '),
      ];
      into = shorter.where((s) => s != n && counts.containsKey(s) && fits(n, s)).firstOrNull;
      // "Fitzwilliam Darcy", untitled: the titled surname it fits.
      if (into == null && title == null) {
        final last = words.last;
        final titled = [for (final m in names) if (m != n && _titleOf(m) != null && _bare(m) == last && fits(n, m)) m];
        if (titled.length == 1) into = titled.single;
      }
    } else if (title == null) {
      // A surname alone: the one titled form it fits.
      final titled = [
        for (final m in names)
          if (m != n && _surnameTitles.contains(_titleOf(m)) && _bare(m) == n && fits(n, m)) m,
      ];
      if (titled.length == 1) into = titled.single;
    }
    if (into != null) parent[root(n)] = root(into);
  }
  final groups = <String, List<String>>{};
  for (final n in names) {
    groups.putIfAbsent(root(n), () => []).add(n);
  }
  return [
    for (final g in groups.values)
      () {
        g.sort((a, b) => counts[b]! - counts[a]!);
        final known = {for (final n in g) gender[n] ?? Gender.unknown}..remove(Gender.unknown);
        return Character(g.first, also: g.skip(1), gender: known.length == 1 ? known.single : Gender.unknown);
      }(),
  ];
}

/// [title] as names write it: "Mr." for "Mr".
String _titled(String title) =>
    const {'Mr', 'Mrs', 'Ms', 'Dr', 'St', 'Mme', 'Mlle', 'Capt', 'Col', 'Gen', 'Lt', 'Sgt', 'Prof', 'Rev'}.contains(title)
        ? '$title.'
        : title;

/// The speaker of every unit of [text], with [cast]: an index into it, or
/// -1. Stretch by stretch, from [from] to [to] paragraphs (the whole book
/// by default).
Int32List speakersOf(BookText text, CastIndex cast, {int from = 0, int? to}) {
  final out = Int32List(text.unitStart.length)..fillRange(0, text.unitStart.length, -1);
  for (final (a, b) in text.stretches()) {
    if (b <= from || a >= (to ?? text.length)) continue;
    final spoken = Attributor(cast).attribute(text, a, b);
    unitSpeakers(text, a, b, spoken, out);
  }
  for (var u = 0; u < out.length; u++) {
    if (out[u] >= cast.characters.length) out[u] = -1;
  }
  return out;
}
