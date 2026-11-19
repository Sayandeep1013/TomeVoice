# 14 — AI Companion

How TomeVoice's AI reading companion works, as of 2.0 (on the `ai-companion` branch,
not yet released). It is written for readers who want to know what is sent where, and
for contributors who want to find their way round `app/lib/ai/`.

The companion brings no AI of its own. There is no model on the phone and no TomeVoice
server: the reader adds API keys from the providers they choose, and the app calls those
providers straight from the phone. Everything the companion knows about a book is kept
on the phone, in a SQLite file in the book's folder (`memory.db`).

## 14.1 The parts

| Part | Where | What it does |
|---|---|---|
| Client | `ai/ai_client.dart` | One way to call a model: the OpenAI chat format (chat, streaming, JSON replies, tools, embeddings, the model list), over `dart:io` alone, so it runs the same in a background isolate and in the background worker's engine |
| Key ring | `ai/ai_keys.dart` | The reader's keys, each job's order of them, why a key is resting or refused, and how much each has been used |
| Router | `ai/ai_router.dart` | Makes a call with the first key of a job that can take it, resting or refusing keys as their providers answer |
| AI page | `ai/ai_screen.dart` | Main menu → AI: keys, job order, the memories, Talk and building settings, what is sent |
| Memory | `ai/memory/` | `memory_db.dart` (the file and its schema), `word_index.dart`, `memory_builder.dart`, `chapter_notes.dart` (the Builder's instructions and the reply's checks), `graph.dart` (the merge), `ledger.dart` (Who's who and the graph's data and layout), `meaning.dart`, `theories.dart`, `series.dart`, `hand_off.dart`, `memory_service.dart` (every book's memory, for the pages and the work), `memory_background.dart` (building with the app closed) and the screens |
| Talk | `ai/talk/` | `answer_pack.dart` (what a question is answered from, and the tools), `talk_engine.dart`, `talk_sheet.dart`, `name_card.dart`, `talk_view.dart` (a kept talk, read again) |
| Worker | `app/android_overlay/.../MemoryBuildWorker.kt` | WorkManager job that builds memories with TomeVoice closed |

The reader (`reader_screen.dart`, `reader_sheets.dart`) adds the Talk button, Explain
this and Who or what is "…" to the sentence menu, Previously…, and the note that a
theory has been settled. A book's page (`book_screen.dart`, `novel_screen.dart`) has a
one-row Memory section that opens the book's Memory page. The journal
(`journal.dart`, `journal_screen.dart`, `journal_page.dart`) keeps talks as entries of
their own kind.

## 14.2 Providers and the key ring

**Providers.** Every provider offered speaks the OpenAI chat format, so one client
serves them all:

| Provider | Address | Meaning search |
|---|---|---|
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | yes |
| Inception (Mercury) | `https://api.inceptionlabs.ai/v1` | no |
| OpenRouter | `https://openrouter.ai/api/v1` | no |
| Groq | `https://api.groq.com/openai/v1` | no |
| OpenAI | `https://api.openai.com/v1` | yes |
| Another service | the address the reader gives | if it has `/embeddings` |

Each request carries the key as a bearer token and an `X-Title: TomeVoice` header
(OpenRouter shows the app's name on its usage page); nothing else about the reader goes
with it.

**Keys.** The reader may add as many keys as they like, from any providers, several
from one provider among them. A key has a name, its provider, an address, the secret,
and a model for each **job** it does:

- **Building memories** (`builder`): each chapter's notes, the story-so-far summaries
  and the theory checks. Many long calls, so a cheap, fast model.
- **Talking** (`talker`): Talk, Explain this, Previously… and theories. The best model
  the reader has.
- **Meaning search** (`embedder`, optional): vectors for meaning search, only on a key
  whose provider has an embeddings endpoint.

A key with no model for a job does not do it. Each job has its own order of keys, which
the reader changes by holding a key and moving it. **Check the key** makes one call for
the provider's list of models and fills in a likely model for each job that has none
(Mercury's own model; for Gemini a Flash-Lite to build, a Flash to talk and its
embedding model to search). Only the last four characters of a key are ever shown.

**Rotation.** `AiRouter.run` tries the job's keys in order, skipping any that is refused
or resting. What a provider's answer means for the key (`errorFromResponse`):

| Answer | Kind | What happens |
|---|---|---|
| 429, `RESOURCE_EXHAUSTED`, `insufficient_quota`, or a quota error with 400 or 403 | quota | The key **rests** and the next takes over. It rests for the provider's `Retry-After`, or Gemini's `retryDelay`, or, for a daily quota, until it resets (midnight Pacific time, when Google resets them); a minute when nothing says |
| 401 or 403 | refused | The key is marked **refused**, with the provider's message, and skipped until the reader changes or saves it again |
| 408, 5xx, a timeout, no network | server or network | Tried once more after a moment (two seconds, or the provider's shorter `Retry-After`). If it fails again the key rests a minute, then two, five, and ten at most for each failure in a row, and the work waits for it instead of stopping |
| Any other 4xx (an unknown model, a bad request) | request | The next key is tried; this one is not held against |

A call that works clears whatever was held against its key. When every key of a job is
resting or refused, the call ends with `AiResting`, which says when the first resting key
wakes (none, if all are refused). A memory being built then waits and goes on by itself
at that time while the app is open; Talk tells the reader when to ask again.

**Usage.** Every call is counted to its key for the day: calls, input tokens and output
tokens, as the provider counted them, or guessed at four characters a token when it did
not say. Thirty days are kept, in `.ai_usage.json` (14.10). The AI page shows each key's
state ("Ready", "Resting until 05:30", "Refused: …") and its use today.

## 14.3 What is sent, and what never is

- **Nothing until a key is added.** With no key, the AI's buttons are not shown and
  nothing is sent. A memory is built only after the reader taps **Build memory** on a
  book's page; from then on it is kept up as they read (14.6).
- **Straight to the provider** the reader chose, with their key. There is no TomeVoice
  server, and no model on the phone.
- **Building** sends each chapter's text, once, to the Building memories key, with the
  cast and open threads the memory already knows (14.5).
- **A question** sends only what it needs: the pack gathered for it (14.8), which holds
  the passage being read, the cards of the names in the question, the places in the text
  its words are found, recent chapter summaries, open threads, and the reader's own
  journal entries for that book. Tools the model calls return more of the same memory.
- **Never sent:** a book on a secret shelf (open or shut), and a book the reader keeps
  away from the AI (its Memory menu → Keep this book away from the AI, stored as
  `meta.private`). For either, the Talk button, Explain this and Who or what is "…" are
  not offered, and nothing is built, kept up or built in the background.
- **Keys** are kept with the catalogue and sync passwords (`Secrets`, `.secrets.json` in
  the app's internal storage, under `ai.ring`), never in the library's folder, so never
  in a backup. A restored backup on another phone has no keys until they are added there.
- **The model's own knowledge** is not used unless the reader turns on **What the AI
  already knows of the book** (AI → Talk). By default the Talker is told to use only
  what it is given, so a well-known book is not spoiled from what the model learned
  elsewhere, and to say plainly when the memory does not cover something yet. The
  Builder is always told to work only from the text.

## 14.4 A book's memory: `memory.db`

One SQLite file per book, `books/<id>/memory.db`, opened through the `sqlite3` package
(FFI, so a background isolate opens its own connection). It sits in the book's folder,
so a backup of the library carries it and removing the book removes it; **Forget this
memory** deletes it (the journal stays). Every connection waits up to eight seconds for
another (`busy_timeout`) rather than failing, and the journal mode is `DELETE`, so the
memory is one file with no `-wal` beside it.

**Places.** Every row made from the text carries the chapter it came from, and most
carry the sentence too (`sec`, `blk`, `sen`: the reader's own cursor). That is how the
spoiler guard filters, how answers cite, and how a citation opens the right line. A
book's chapters are numbered from 0 as the reader's chapters run; a web novel's by their
place in the novel's chapter list, since only some may be on the phone.

**Tables** (schema version 4, in `PRAGMA user_version`):

| Table | What it holds |
|---|---|
| `meta` | The book's settings for the companion: `guard` (the spoiler guard), `readUpTo` ("I've read up to chapter…"), `begun` (the reader asked for it to be built), `paused`, `private` (kept away from the AI), `follows` (the earlier book of a series) |
| `chapters` | Each chapter: its section, title, the SHA-1 of its text, how many sentences, whether it is in the word index (`indexed`) and has notes (`noted`), and why the Builder passed it over (`note_error`) |
| `text` | The word index: an FTS5 table (`unicode61`, diacritics removed) of chunks of a few sentences, each with its chapter and the place of its first sentence |
| `notes` | Each chapter's summary, the model that made it and when. The model's whole reply is not kept: everything in it is in the tables below |
| `kinds` | Kinds of entity: eight core ones (person, place, faction, item, power, title, creature, term) and the kinds the Builder proposes for a book's world (aspects, flaws), kept as proposals (`accepted = 0`) |
| `entities` | People, places, groups, items, powers, titles, creatures and terms: kind, name, first description, first and last chapter, how many chapters they appear in (`mentions`), and `merged_into` for one merged into another |
| `aliases` | Every name an entity goes by, as written and in a lookup form (lower case, accents gone, "the" dropped), with the chapter it was first used |
| `appearances` | Which chapters each entity appears in |
| `events` | What happened: a sentence, why, the result, where, an importance from 1 (passing) to 5 (changes the story), and its place |
| `event_roles` | Who took part in each event: `did`, `to`, `with` (an item or power), `at` (the place) |
| `event_links` | One event that led to another |
| `facts` | How something stood over time: an attribute (rank, title, status, location, holder, alive…), its value, the chapter it held from (`from_ch`) and the chapter it ended (`until_ch`). A later description of an entity is kept here too, as `description`, so a card at an earlier chapter is not told what comes later |
| `relations` | Two entities and the relation between them (ally of, enemy of, sibling of, member of, loves…), from and until which chapter, with a note |
| `reveals` | Something the text states plainly that changes what was believed, and what it overturns |
| `quotes` | Lines worth keeping, word for word, and who said them |
| `threads`, `thread_steps` | Mysteries, promises, prophecies and foreshadowing: when each was raised and resolved, and every step between |
| `arcs` | The story so far: level 1 for each 25 chapters, level 2 for each 250, level 3 for an earlier book of a series |
| `theories` | The reader's theories: the claim, the chapter it was stated at, its status (open, confirmed, busted, mixed), the chapter that decided it, the verdict, and whether the reader has been told |
| `vectors` | Meaning search: one vector per chapter summary or event and model, packed as one byte a value with a float scale |
| `asked` | Reserved for what the reader has asked about; nothing writes it in 2.0 |

**Upgrades.** A memory is brought up to the current version when it is opened, in one
transaction: version 2 added `theories.told`; versions 3 and 4 rewrite names a model gave
as identifiers (`Mountain_King`, `StoneSaint`) as a reader would write them ("Mountain
King", "Stone Saint"), redo every name's lookup form, and remove entities that were
really a reference to an event or a thread (`v31`, `#2`).

## 14.5 Building a memory

**The word index first.** **Build memory** indexes the book's words on the phone, free
and offline (`WordIndexer`, off the UI isolate): each chapter's sentences in chunks of
up to five sentences or about 420 characters, never across a section, with the SHA-1 of
the chapter's text. A chapter whose text is as it was is skipped; one whose text changed
(a replaced file, chapters split again) is indexed again and marked to have its notes
made again. A web novel is indexed a hundred chapters at a time, and only the chapters
on the phone; others join as they are downloaded.

**The estimate.** Before anything is sent, the reader sees what the rest of the build
would take: how many chapters, in about how many calls, some number of tokens, and which
keys it will use in turn. Tokens are guessed at four characters each, plus 3,500 a call
for the instructions and the cast it is told of, plus 1,800 a chapter for the notes that
come back.

**In the story's order.** The Builder (`MemoryBuilder.run`) takes the chapters with no
notes in reading order, because chapter N+1 is linked against the memory that chapter N
left. Chapters go in batches, by the provider of the first Building memories key:

| First key's provider | A batch |
|---|---|
| Gemini, Inception (long context) | up to 8 chapters, about 40,000 tokens |
| any other | up to 2 chapters, about 12,000 tokens |

A chapter longer than the limit goes alone. Each call carries the Builder's
instructions (`builderInstructions`), then what the memory already knows that bears on
these chapters (`BookGraph.contextFor`): the kinds; the known entities named in the
batch's text (found by their aliases) and the cast most seen in the last 30 chapters, up
to 150, each with a ref (`e12`), its other names, its description as of the batch and
how it stands; their recent important events (`v31`); and the threads still open (`t4`).
Then the chapters, each passage numbered `[1]`, `[2]`… so the notes can say where things
happen.

**Chapter notes.** The model is asked for one JSON object (`response_format:
json_object`): for each chapter a `summary` (60 to 120 words), `entities` (a known ref,
or `new:<name>`), `events` (what, who, to whom, where, with what, why, the result, the
passage, an importance, and the earlier events it follows from), `facts`, `relations`
(begins or ends), `threads` (raised, advanced or resolved), `reveals`, `quotes` and
`new_kinds`. `parseChapterNotes` checks it: a reply that is not JSON, or a chapter
missing or without a summary, is an error; any other part that is wrong is left out
rather than failing the chapter.

**When the reply is bad.** A reply that fails the check is sent back once with what was
wrong. If it fails again, or was cut off for length, the batch is halved and tried
again; a chapter that fails alone is marked passed over (`note_error`), and the book's
Memory page offers to try the passed-over chapters again.

**The merge.** A batch's notes are merged in one transaction (`BookGraph.apply`), so
stopping at any point loses at most the batch in flight:

- Names are resolved to an existing entity by ref, by any alias (in its lookup form), or
  made new; every name used is kept as an alias with its chapter. A new description of
  an existing entity is kept from that chapter on.
- Events are stored with their roles; "follows from" becomes an `event_links` row.
- A **fact** that changes ends the value before it at this chapter. A **relation** that
  ends gets its `until_ch`. A chapter noted late (a web novel's chapter downloaded after
  those round it) slots into its place in time: its fact ends where the next known value
  begins, and a relation already known from a later chapter is moved to begin here,
  rather than overwriting what came after.
- Threads are matched by ref or by title; reveals and quotes are stored as given.

`BookGraph.merge` can join two entities (the merged one stays, pointing at the other, so
a merge can be undone), but no pass in 2.0 looks for duplicates by itself.

**The story so far.** Between batches, once every chapter of a span of 25 has notes (and
a later chapter is in the word index), the Builder key writes an account of it (150 to
250 words) from the chapters' summaries; once all ten spans of 250 have theirs, an
account of the 250 (250 to 400 words) from them.

**Theories.** After each batch, the reader's open theories stated before its chapters
are held up to what those chapters' notes say (summaries, reveals and threads resolved).
A theory they clearly settle gets its verdict (confirmed, busted or mixed), the chapter
that settled it, and why. The reader is told only once they reach that chapter (14.8).

**Meaning search.** When some key has a model for Meaning search, each batch is followed
by vectors for what has none yet for that model: chapter summaries first, then events of
importance 2 and up, 64 at a time. They are packed as one signed byte a value with a
scale, and compared by cosine at question time.

**One book at a time.** `MemoryService` builds one book at a time, so keys' quotas go to
one book until it is done; starting another pauses the first. **Pause** stops after the
batch in flight and holds until the reader taps Build or Go on building again: neither
keeping up nor the background worker restarts a paused memory.

## 14.6 Keeping up, and building with the app closed

**Kept up as you read.** A book whose memory the reader began (`meta.begun`, or any
notes) is brought up to date without a tap: when the book is opened, when the reader
reaches another chapter, and, for a web novel, about twenty seconds after its chapters
are saved (while a download goes on, what has come joins every twenty seconds or so).
New chapters are indexed and noted. Not a book never built (no quota is spent on it
unasked), not a paused one, and not while another book's memory is being built; and,
except after a download, at most every minute and a half.

**With TomeVoice closed.** `MemoryBuildWorker` (Kotlin) is a periodic WorkManager job,
every 60 minutes, scheduled only while the AI has a key and **Also with TomeVoice
closed** is on (AI → Building memories, on by default). Its conditions: an unmetered
network when **Only on Wi-Fi** is on (the default), any network otherwise; the battery
not low; and charging when **Only while charging** is on (off by default). As the check
for new chapters does, it starts a Flutter engine of its own on
`memory_background.dart`'s entry point and waits for the Dart side to finish. It never
runs while the app's own engine is up (the app builds memories itself then), nor while
the new-chapter check runs: two engines must never write the library at once.

The Dart side (`runBackgroundBuild`) has eight minutes, inside WorkManager's ten. Book by
book, it skips books on a secret shelf, books without a memory, and memories not begun,
paused or kept away from the AI; brings each word index up to date; then builds until
done, out of time, the app opened (checked every ten seconds), or every key resting.

## 14.7 Web novels: chapters for the memory

A memory is made from the chapters on the phone. For a web novel:

- **Build memory** first counts the chapters up to the reader's place (or "I've read up
  to") that are neither on the phone nor queued, and offers **Download them, and build**
  or **Build with what is here**.
- The Memory page's **Chapters for the memory** shows how many chapters are on the
  phone and the space they take, and offers **Download all**. Downloads go through the
  usual download queue, one chapter at a time and gently on the site; **Try again**
  retries those that failed.
- While chapters are still downloading, the Builder goes no further than the chapter
  before the first one not yet on the phone, so ranks, titles and relations are told in
  order. Once nothing waits, it builds the rest wherever it is.
- **Free the space** deletes the downloaded chapters the memory has already read (in the
  word index, with notes). The memory keeps its own copy of their words; a chapter
  opened to read is fetched again from the site.

## 14.8 Answering

**The spoiler line.** The spoiler guard is per book and off by default. Off, the
companion may use all its memory of the book. On, the **line** is the furthest of the
reader's place and "I've read up to chapter…" (for a book read partly elsewhere), and
nothing after it is gathered, shown or sent: the pack, the tools, cards, Who's who, the
graph and the hand-off pack all filter by it, and the Talker is told never to reveal,
hint at or guess beyond it. A theory's verdict is hidden until the reader reaches the
chapter that settled it, whether the guard is on or off, since knowing a theory was
confirmed is itself a spoiler.

**The pack.** Each question is answered from a pack gathered afresh from the memory, off
the UI isolate (`buildPack`):

1. Cards for up to eight entities: those named in the question first (matched by
   alias), then those named in the last part of the passage being read. A card, as of
   the line: the name, kind and other names, the description then, when first met; how
   it stands (facts holding then); up to twelve relations; up to ten key events, by
   importance, in story order; and a line it said.
2. Places in the text: the question's words (up to eight, small words left out) searched
   in the word index, any of them matching, the eight best.
3. Moments that match: with a Meaning search key, the question's vector compared with
   the chapter summaries and events, the six closest.
4. The story so far up to the reader's place, and the latest six chapters' summaries.
5. Threads still open at the line, those the question's words touch first, eight at
   most.
6. The reader's own journal entries for the book within the line (not their talks),
   eight at most.
7. The chapter being read, up to the reader's sentence (its last 6,000 characters).

Each item is numbered as a source (`[S3]`), and the model is asked to cite after each
sentence that rests on one. Sources are numbered across a whole talk, and the talk so
far (the questions and answers, not their material) is sent with each question.

**Tools.** When the Talking key's provider takes tools, the model may ask for more, up to
five rounds, each answered from the memory within the line: `search_text` (the word
index), `card` (by any name), `events` (someone's events between two chapters),
`chapter_notes` (a chapter's summary), `read_chapter` (thirty passages of a chapter's own
text) and `thread` (a thread step by step). A provider that turns tools down is asked
again without them, and that key is not offered tools again while the app runs.

**Citations.** An answer streams into the sheet as it comes. Its `[S3]` marks are drawn
as small chapter chips ("ch 1204"); a tap looks at that place without moving the voice,
and Back to reading returns. A mark naming a number that was never given is dropped. The
answer's length follows AI → Talk (short, normal or long).

**Said aloud.** With **Answers aloud** on (the default; the speaker button in the sheet
turns it off), an answer is said in the voice reading the book, with its settings, a
sentence or a few at a time, without its marks. The book pauses for it and reads on from
where it was once the answer is done; closing the sheet stops the answer.

**Kept in the journal.** When the sheet closes, a talk with at least one answer is kept
in the book's journal, stamped with where the story was when it began. Its citations
are kept as the chapters they named. The journal's filter shows **All**, **My writing**
or **Talks**.

**The other ways in:**

- **Explain this** (the sentence menu) opens Talk asking what the held sentence means
  there in the story.
- **Who or what is "…"?** (holding a word) opens its card at once, with no AI call and
  no network: the longest known name in the sentence that contains the word ("Changing
  Star" for a hold on "Star"; "Oren's" is Oren), as of the line. Each line's chapter can
  be looked at; **Tell me more** asks Talk.
- **Previously…**: opening a book with notes after a number of days away (AI → Talk:
  never, a day, 3 days or a week; 3 by default) offers a short recap of the chapters
  just before the reader's place.
- **Theories**: in Talk, the bulb (or "I have a theory…") sends the next message as a
  theory. It is kept, weighed (what supports it, what speaks against it, what is
  unknown, how likely it seems, from nothing past the reader's place), and checked as
  the Builder reads on. When the reader reaches the chapter that settled it, the reading
  screen says so ("Your theory from chapter 900 was right: chapter 1450 settled it").
  The book's Memory page lists them as Open, Confirmed, Busted or Partly right.
- **Talk elsewhere** (the hand-off pack): the memory as one Markdown page, to copy or
  share as a `.md` file for ChatGPT, Gemini, NotebookLM or a reader with no key: the
  story so far, the forty who matter most with how they stand and their relations, what
  is still unanswered, the reader's theories and journal. With the guard on it stops at
  the line and asks the other AI not to reveal anything after it.
- **Series**: the Memory menu's **Follows on from another book…** carries the earlier
  book's memory over (`followOn`): its entities with their names and how they stood at
  its end, the relations that held, the threads left open, and its story as one account,
  all placed before this book's first chapter (shown as "an earlier book"). The Builder
  then links this book to them, and Talk knows them from the start.

## 14.9 Who's who and the memory graph

**Who's who** lists every entity as of the line, with a chip for each kind (a kind the
book brought, such as Aspects, gets one too), found by any of its names, and sorted by
Seen most, First met or By name. A tap opens the card.

**The memory graph** (`graph_screen.dart`, data and layout in `ledger.dart`):

- It opens **round the most important person** up to the line: **Round** them, **Two
  links out**, or **The whole web** (up to 120 entities, those that matter most). Those
  met in only one chapter are hidden unless **Minor ones** is on; kinds can be filtered.
- **Layout.** Round someone, they sit in the middle, those linked to them in a ring round
  them (grouped by how they are linked), and the rest in rings further out, each near
  what it links to. The whole web is a force layout. Either way no two nodes overlap, the
  layout is the same each time, and it is made off the UI isolate. A node's size on the
  screen is by how many chapters it appears in and does not grow with zoom: zooming in
  spreads a crowd apart.
- **Links** are relations (while they held) or events two took part in together,
  coloured by what they are (allies, enemies, family, belonging dashed, other, shared
  events), with a key. Groups wear a soft halo round their members. Names sit on small
  pills, the most important first, none over another.
- **The timeline.** A slider shows the web at any chapter up to the line, with nodes
  staying where they are; Play shows it growing from the first chapter in about eight
  seconds.
- **A tap** lights a node's links and dims the rest, and shows what it is at that
  chapter, a strip of the chapters it is in, and its relations as chips, with **Card**,
  **Centre here** and **Linked with…** (tap a second node for the relations and shared
  events between the two). Search centres the web on anyone by any name.
- **As a ball** (`graph3d_view.dart`): the same graph, chapter and pick in three
  dimensions, the rings becoming shells round the person in the middle. One finger
  turns it, two pinch it; it turns slowly by itself until touched, and not at all when
  the phone asks for less motion.

## 14.10 Where it is stored

| What | Where |
|---|---|
| Keys, their job order, resting and refused states | `.secrets.json` in internal storage, under `ai.ring` (with the catalogue and sync passwords); never backed up |
| Each key's use, per day, thirty days | `.ai_usage.json` beside it, in internal storage; never backed up |
| A book's memory | `books/<id>/memory.db` in the library folder; carried by backups |
| Talks | `journal.json`, as entries with a `talk` list of lines |
| Settings | `prefs.json`: `aiSpeak`, `aiLength`, `aiRecapDays`, `aiOwnKnowledge`, `aiBackground`, `aiBackgroundWifi`, `aiBackgroundCharging` |

See [11 — Data Model & Storage](11-data-model-and-storage.md) for the rest of the files.

## 14.11 Tests

The companion is tested with a fake provider, an in-memory `memory.db` and fixed notes:

- `ai_client_test.dart`: the client's requests, streamed replies and tool calls; what
  each error means for a key (a quota and how long it rests, refused, the provider
  failing, a wrong request, no network); the ring's order per job, resting, refused
  keys, waiting for the first to wake, and a failing provider tried once more.
- `ai_screen_test.dart`: several keys from one provider and another, each job's order,
  and the likely model picked for each job.
- `memory_index_test.dart`: the word index and its places, a changed chapter indexed
  again (and losing its notes), a fresh memory's kinds and version.
- `memory_builder_test.dart`: reading the notes and their checks; the merge (one cast
  across chapters and names, facts and relations over time, chapters noted late,
  merges, names given as identifiers and the upgrade that tidies them); meaning search;
  building a book in batches, the story so far, keeping up, building with the app
  closed, bad replies, passing over, and every key spent.
- `talk_test.dart`: the pack with the guard off and on, a held word's card, the spoken
  form of an answer, citations and a tool used on the way, and the sheet (chapter chips
  that look there, the talk kept in the journal).
- `memory_views_test.dart`: the graph as of a chapter, its flat and ball layouts (the
  same each time, no two nodes touching), and the hand-off pack kept to the line.

## 14.12 Known limits in 2.0

- The estimate before a build gives chapters, calls, tokens and keys, not time or cost;
  there is no spending cap per key.
- No pass looks for duplicate entities (two names the Builder made for one person), and
  there is no screen to accept a kind the Builder proposed.
- A chapter whose text changed is noted again, but the rows its old notes made are not
  taken out first.
- The word index serves Talk and its tools; it has no search screen of its own yet.
- A replaced book's file starts a new memory: `memory.db` does not move with the book's
  other belongings.
