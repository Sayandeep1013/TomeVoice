# 14 — AI Companion

How TomeVoice's AI reading companion works, as of 2.6.6 (25 November 2026). It was
first released in 2.0.0 (19 November 2026); what each release added is in the
[changelog](../CHANGELOG.md). It is written for readers who want to know what is sent
where, and for contributors who want to find their way round `app/lib/ai/`.

The companion brings no AI of its own. There is no model on the phone and no TomeVoice
server: the reader adds API keys from the providers they choose, and the app calls those
providers straight from the phone. Everything the companion knows about a book is kept
on the phone, in a SQLite file in the book's folder (`memory.db`).

## 14.1 The parts

| Part | Where | What it does |
|---|---|---|
| Client | `ai/ai_client.dart`, `ai/ai_anthropic.dart` | One way to call a model: the OpenAI chat format (chat, streaming, JSON replies, tools, embeddings, the model list), over `dart:io` alone, so it runs the same in a background isolate and in the background worker's engine; Claude through Anthropic's own Messages API (14.2) |
| Key ring | `ai/ai_keys.dart` | The reader's keys, each job's order of them, why a key is resting or refused, and how much each has been used |
| Router | `ai/ai_router.dart` | Makes a call with the first key of a job that can take it, resting or refusing keys as their providers answer |
| AI settings | `ai/ai_screen.dart` | AI chat → the gear (Main menu → AI before 2.4.0): keys, job order, the memories, Talk and building settings, what is sent |
| AI chat | `ai/chat/`, `ai/ai_chat_screen.dart` | Saved chats about one book, several or none, answered with tools (14.14) |
| Memory | `ai/memory/` | `memory_db.dart` (the file and its schema), `word_index.dart`, `memory_builder.dart`, `chapter_notes.dart` (the Builder's instructions and the reply's checks), `graph.dart` (the merge), `ledger.dart` (Who's who and the graph's data and layout), `meaning.dart`, `theories.dart`, `series.dart` (carrying a cast over), `series_store.dart`, `series_db.dart`, `series_flow.dart` and `series_screen.dart` (series, 14.15), `hand_off.dart`, `memory_service.dart` (every book's memory, for the pages and the work), `memory_background.dart` (building with the app closed) and the screens |
| Talk | `ai/talk/` | `answer_pack.dart` (what a question is answered from, and the tools), `talk_engine.dart`, `talk_sheet.dart`, `name_card.dart`, `talk_view.dart` (a kept talk, read again) |
| Worker | `app/android_overlay/.../MemoryBuildWorker.kt` | WorkManager job that builds memories with TomeVoice closed |

The reader (`reader_screen.dart`, `reader_sheets.dart`) adds the Talk button, Explain
this and Who or what is "…" to the sentence menu, Previously…, and the note that a
theory has been settled. A book's page (`book_screen.dart`, `novel_screen.dart`) has a
one-row Memory section that opens the book's Memory page. The journal
(`journal.dart`, `journal_screen.dart`, `journal_page.dart`) keeps talks as entries of
their own kind.

## 14.2 Providers and the key ring

**Providers.** Nineteen providers are offered by name (`AiProvider` in `ai_keys.dart`),
and any other service by its address. All but Claude speak the OpenAI chat format, so
one client serves them; Claude is spoken to in Anthropic's own format. The picker (with
a search since 2.6.3) gives each a note: what it costs, whether its free tier may use
what is sent to improve its models, and whether the text passes through a relay on its
way to the model.

| Provider | Address | Meaning search | Since |
|---|---|---|---|
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | yes | 2.0.0 |
| Inception (Mercury) | `https://api.inceptionlabs.ai/v1` | no | 2.0.0 |
| OpenRouter | `https://openrouter.ai/api/v1` | no | 2.0.0 |
| Groq | `https://api.groq.com/openai/v1` | no | 2.0.0 |
| OpenAI | `https://api.openai.com/v1` | yes | 2.0.0 |
| AgentRouter (a relay) | `https://agentrouter.org/v1` | no | 2.3.0 |
| 100milionseek (a relay to DeepSeek models) | `https://100milionseek.top/v1` | no | 2.4.0 |
| Anthropic (Claude) | `https://api.anthropic.com/v1` | no | 2.6.3 |
| DeepSeek | `https://api.deepseek.com` | no | 2.6.3 |
| Mistral | `https://api.mistral.ai/v1` | yes | 2.6.3 |
| xAI (Grok) | `https://api.x.ai/v1` | no | 2.6.3 |
| Z.ai (GLM) | `https://api.z.ai/api/paas/v4` | no | 2.6.3 |
| Alibaba Cloud (Qwen) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | yes | 2.6.3 |
| Together AI | `https://api.together.ai/v1` | no | 2.6.3 |
| Fireworks AI | `https://api.fireworks.ai/inference/v1` | yes | 2.6.3 |
| Cerebras | `https://api.cerebras.ai/v1` | no | 2.6.3 |
| Moonshot (Kimi) | `https://api.moonshot.ai/v1` | no | 2.6.3 |
| Hugging Face (a relay) | `https://router.huggingface.co/v1` | no | 2.6.3 |
| NVIDIA | `https://integrate.api.nvidia.com/v1` | no | 2.6.3 |
| Another service | the address the reader gives | if it has `/embeddings` | 2.0.0 |

Each request carries the key as a bearer token and an `X-Title: TomeVoice` header
(OpenRouter shows the app's name on its usage page); Claude's carries the key as
`x-api-key` and the API's version instead. Nothing else about the reader goes with it.

**How each provider differs** (`AiStyle` in `ai_client.dart`). The twelve providers of
2.6.3 were added after reading each one's own documentation on 24 November 2026 against
what the client sends, and these differences were handled:

- **No temperature** for Claude and Kimi. Current Claude models answer 400 to a
  temperature below 1, and Kimi K3 fixes it at 1.0. The 0.1 to 0.3 the Builder and the
  cast tidy ask for is left out for them.
- **Claude in its own format** (`ai_anthropic.dart`, `POST /v1/messages`, with
  `anthropic-version`). Anthropic's OpenAI-compatible endpoint turns down
  `response_format: json_object` and a temperature below 1, and calls itself not meant
  for production. The system prompt goes on its own, a reply's tool calls become
  `tool_use` blocks and the tools' answers `tool_result` blocks, and a reply's own
  blocks, its thinking among them, are sent back unchanged with the answers. Every call
  leaves room for at least 4,096 tokens, since thinking counts towards the answer's
  budget. The models are listed with `?limit=1000` (20 a page otherwise). The picker
  asks for a key made for one workspace: any other key would need a workspace header
  the app does not send.
- **JSON.** Claude gets no `response_format`; the Builder's instructions ask for JSON in
  any case. DeepSeek and Alibaba require the word "json" in the messages when
  `json_object` is sent, and the instructions have it.
- **Thinking sent back on tool calls** for DeepSeek, Kimi, AgentRouter and
  100milionseek. DeepSeek and Kimi answer 400 to a tool loop whose assistant message has
  lost its `reasoning_content`, and the two relays route to DeepSeek's models. DeepSeek's
  thinking is also turned off for JSON calls (`"thinking": {"type": "disabled"}`), so
  notes come faster and cost less.
- **A fixed model list** where `/models` is missing or shaped differently: Z.ai, Alibaba
  and Fireworks. **Check the key** then makes one small call with the first model
  instead.
- **Smaller embedding batches:** Alibaba's take at most 10 texts a call; every other
  provider is sent up to 64. NVIDIA is not offered for meaning search, since its
  embedding models need an `input_type` the app does not send.
- **Only standard fields** go in the shared request body, since Fireworks refuses
  unknown ones.

**Not offered:** GitHub Models (retired on 30 July 2026); SambaNova (every model a
preview not to be used in production, and a free tier of 20 requests a day per model,
too few to build a memory); Perplexity (an aggregator like OpenRouter, gated by usage
tier, with its model list outside its base address); Cohere (a trial key of 1,000 calls
a month, and no model list in its compatibility API). The last three can still be added
as another service, by their address.

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
  `meta.private`). For either, the Talk button and Explain this are not offered (Who or
  what is "…" offers only the memory's card and a web search), and nothing is built,
  kept up or built in the background.
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

**Tables** (schema version 6, in `PRAGMA user_version`; version 5 added `chapter_rows`,
where each chapter's text sits in the word index, so it is read by a jump rather than a
scan; version 6 forgot aliases that are not names, see 14.5):

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
- **One card per character, by name.** When the AI's ref points at a card that does not
  answer to the name given, and another card of that kind does, the name wins. Only
  names are kept as aliases: pronouns, possessives ("her teacher") and lone lowercase
  words ("creature") are not, since they let one card take another's chapters. A card
  first known by a description ("Silver Haired Girl") is renamed when the book gives
  its proper name.
- Events are stored with their roles; "follows from" becomes an `event_links` row.
- A **fact** that changes ends the value before it at this chapter. A **relation** that
  ends gets its `until_ch`. A chapter noted late (a web novel's chapter downloaded after
  those round it) slots into its place in time: its fact ends where the next known value
  begins, and a relation already known from a later chapter is moved to begin here,
  rather than overwriting what came after.
- Threads are matched by ref or by title; reveals and quotes are stored as given.

`BookGraph.merge` joins two entities (the merged one stays, pointing at the other, so a
merge can be undone).

**The cast tidy** (`cast_tidy.dart`). Every 250 chapters noted, and when a book's notes
are done, the Builder key is shown the 120 best-known entries (each with its chapters,
what it is and its other names, with the chapter each was first used) and asked, in one
call, for what to put right:

- **same**: two entries that are one (merged, the best known keeping its name);
- **taken**: a minor character's card that, from some chapter on, holds another's
  story (`BookGraph.handOver` moves its names, appearances, roles, facts, relations and
  quotes from that chapter to the other card). The chapter is the AI's, or, if earlier,
  where the card's own chapters show a long gap before the other's story began
  (`takeoverStart`);
- **names**: a card named by a description, renamed to a name it already goes by;
- **wrong**: another's names taken off a card.

Only entries it was shown are changed, and nothing is made up. **Who's who** has the
same tidy as a button, and the reader can do it by hand (14.9).

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

**How far, by hand.** The Build sheet asks how far: **Every chapter on the phone**,
**Up to chapter N** (offered at the reader's place, or ten past the last noted), or
**The next N chapters** (worked out as the Nth chapter with no notes yet, in reading
order). The answer is kept with the memory (`meta.build_to`, 0-based; unset for every
chapter), and every build of that book stops there, by hand, kept up as it is read or
with the app closed, until the reader asks for more. The memory page then says
**Built to chapter N, where you asked it to stop**, and its button reads **Build more
chapters**, which opens the sheet again; **Go on building** stays for a build paused or
waiting for a key with chapters left before where it stops (it goes on without the
sheet when there is one key). What it would take is counted for the choice made.

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
except after a download, at most every minute and a half. It goes no further than
where the reader asked it to stop.

**Or only when tapped.** Each memory has **Build new chapters by itself** (on its page
and in the Build sheet; `meta.auto_build`, `on` or `off`, unset meaning on for a memory
from before). Off, keeping up only indexes the new chapters' words (free, on the phone,
so Talk's search finds them) and the memory grows only when the reader taps Build. New
memories take **New chapters build by themselves** from AI → Building memories (on by
default). A build the reader asked for is marked (`meta.build_asked`) until it is done,
so the build with the app closed finishes it even for a memory that is not built by
itself.

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
book, it skips books on a secret shelf, books without a memory, memories not begun,
paused or kept away from the AI, and memories not built by themselves with no build the
reader asked for still to finish; brings each word index up to date; then builds until
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
- **Free up space** deletes the downloaded chapters the memory has already read (in the
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
  be looked at; **Tell me more** asks Talk. It is offered for any held word, with or
  without a key. When the memory has nothing (or the book has none), a sheet starts from
  the name the word is probably part of, guessed from the capitals round it ("Six
  Finger", "the Nine", "Lord of Mysteries", "Mr. Darcy"; a sentence's opening "Then" or
  "When" is left out; a word ending "'s" ends the name); the reader can add or drop a
  word at either end within the sentence, or type. With a memory, the words as they
  stand are looked for again and **Open its card** offered when found. Then **Ask the
  AI (no spoilers)** (only where Talk is offered: the question names the words and
  quotes the sentence) or **Search the web (may spoil)**: a Google search for the words
  in quotes with the book's title (no title for a secret book).
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
- **Series** (14.15): a later book of a series starts with the earlier books' cast,
  how they stood, the threads left open and their story, all placed before its first
  chapter (shown as "an earlier book"). The Builder then links this book to them, and
  Talk knows them from the start and looks back into the earlier books' memories.

## 14.9 Who's who and the memory graph

**Who's who** lists every entity as of the line, with a chip for each kind (a kind the
book brought, such as Aspects, gets one too), found by any of its names, and sorted by
Seen most, First met or By name. A tap opens the card. Its wand asks the AI to tidy the
names (14.5). Holding an entry offers **Rename**, **The same as…** (merge it with
another; the better known keeps its name), and **Someone else from a chapter…** (hand
what the card holds from a chapter on to another card; the chapter is suggested from
the card's own chapters).

**The memory graph** (`graph_screen.dart`, data and layout in `ledger.dart`):

- It opens on **The whole web**; the chips above it also give **Round** the most
  important person (or anyone centred), **Two links out**, and the **Story map**. A
  slider sets how many are shown, from the 10 that matter most to everyone. What matters
  is what matters now: those in many chapters near the reader's place first, then a
  share of those who were in many chapters but none lately, drawn with an orange ring as
  ones **you may have forgotten**. Kinds can be filtered from the key.
- **Layout.** Round someone, they sit in the middle, those linked to them round them
  (grouped by how they are linked), and the rest further out, each near what it links
  to. The whole web is a force layout of the book's groups (found by Louvain), placed
  once and kept, so it does not jump as the chapter changes. Each node is pulled to the
  middle by its own amount, so the web settles as an uneven cloud, not a circle or
  rings. The **Story map** shows those groups as islands, each named by the AI from its
  members (kept, and not asked for with the spoiler guard on). No two nodes overlap, the
  layout is the same each time, and it is made off the UI isolate.
- **Drawn as points.** A node is a small solid point with a soft glow, a little larger
  the more chapters it is in (at most 7.5 dp), and it does not grow with zoom: zooming
  in spreads a crowd apart. **Links** are fine straight lines in the ink colour,
  relations (while they held) or events two took part in together; lit, they take the
  colour of what they are (allies, enemies, family, belonging, other, shared events),
  shown in the key. Groups wear a soft halo. Names are plain text with a halo, no pill,
  the most important first, none over another; **More** shows the important names, all
  that fit, or only those picked.
- **The timeline.** A slider shows the web at any chapter up to the line, with nodes
  staying where they are; Play shows it growing from the first chapter in about eight
  seconds.
- **A tap** lights a node's links and dims the rest, and shows what it is at that
  chapter, a strip of the chapters it is in, and its relations as chips, with **Card**,
  **Centre here** and **Linked with…** (tap a second node for the relations and shared
  events between the two), and **Ask about this** opens Talk. Search centres the web
  on anyone by any name.
- **As a ball** (`graph3d_view.dart`, put away in 2.1: `_offerBall` in `graph_screen.dart`
  hides its button, and turning it back on brings it back): the same graph, chapter and pick in three
  dimensions, drawn the same way (points, fine links, plain names), each node at its own
  distance from the person in the middle, so it is a cloud rather than shells. One finger
  turns it, two pinch it; it turns slowly by itself until touched, and not at all when
  the phone asks for less motion.

## 14.10 Where it is stored

| What | Where |
|---|---|
| Keys, their job order, resting and refused states | `.secrets.json` in internal storage, under `ai.ring` (with the catalogue and sync passwords); never backed up |
| Each key's use, per day, thirty days | `.ai_usage.json` beside it, in internal storage; never backed up |
| A book's memory | `books/<id>/memory.db` in the library folder; carried by backups |
| Talks | `journal.json`, as entries with a `talk` list of lines |
| AI chats | `chats/<id>.json` beside the library, one file a chat, and the notes the AI keeps about the reader in `chats/notes.json`; carried by backups (14.14) |
| Series | `memory_series.json` beside the library (carried by backups); each series' All books memory in `memory_series/<id>.db`, made from the books' own and made again when one of them changes (14.15) |
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

## 14.12 Added in 2.1

- **A series carries on** (`series.dart`, `memory_service.dart`): `followOnFromAll`
  brings over one or more earlier books (earliest first), first taking out what came
  over before (`dropNotesOf(beforeThisBook)`), so it is also how a changed earlier book
  comes over again. The link is kept in `meta`: `follows` (ids), `follows_titles`,
  `follows_upto` (how far each was read, with the guard on) and `follows_seen` (a
  signature of each earlier memory: notes, cast, names' length, aliases, facts,
  relations, so a pause or a setting is not a change). Building a book whose series
  (library series and number) has an earlier book with a memory offers it once. 2.5.0
  turned these links into series of their own (14.15).
- **Talk and earlier books** (`answer_pack.dart`): `earlierPack` adds the earlier books'
  cards for names asked about and passages for the question's words; the tool
  `search_earlier_books` searches their text. Their sources read "Title · ch N"; the
  journal of earlier books is read too.
- **A replaced book's memory** moves with it (`MemoryService.moveBook`); the word index
  then reads again only the chapters whose hash changed.
- **A changed chapter** (`MemoryDb.dropNotesOf`): its summary, events, reveals, quotes,
  thread steps, the facts and relations it began (those it ended opened again), its
  appearances, and those first met there and nowhere else, taken out before it is read
  again. A web-novel chapter saved again is checked against its hash.
- **Screens**: Threads (`threads_screen.dart`), Chapter by chapter with Read this
  chapter again (`chapter_notes_screen.dart`), Find where… (`find_where_screen.dart`,
  the word index in the book's order), and the kinds the AI suggests in Who's who.
- **Talk**: the `asked` table is written (a question, its chapter) and an earlier
  question sharing a key word comes back in the pack; catch-up in two or ten minutes;
  the reader's own questions as buttons.
- **Keys**: a daily token limit (`AiKey.dailyCap`): reached, the key rests until
  midnight. Check the key tries the talking model's tools and JSON (`probeModel`).
- **Journal speech** (`Dictation.kt`, `dictation.dart`): Android's SpeechRecognizer on
  the channel `tomevoice/dictate` (RECORD_AUDIO, and a `<queries>` entry for
  `android.speech.RecognitionService`), started again after each pause until stopped;
  the book's voice paused meanwhile. Tidy (`journal_tidy.dart`) asks the talking model to
  punctuate without rewording, and shows both before using it.
- **The guide** (`guide.dart`, `aiGuideCards`): six cards, by itself on the AI page's
  first opening (`aiGuideShown`), and from How the AI works.

## 14.13 Known limits in 2.1

- The estimate before a build gives chapters, calls, tokens and keys, not time or cost.
- The cast tidy sees only the 120 best-known entries; duplicates among minor ones stay
  until the reader merges them in Who's who. A merge cannot be undone.
- Settled theories are told, not written into the journal.
- Speech needs a recogniser on the phone (Google's speech services on most); a language
  not downloaded for offline use needs the internet.

2.2.0 lifted two of these: a merge can be undone in Who's who, and a settled theory is
written into the journal too.

## 14.14 AI chat (2.4.0)

**AI chat** (Main menu → AI chat; `ai/chat/`) is a conversation kept as a chat, about
one book, several, a whole series, or none. It reuses Talk's memory queries but has its
own engine (`ChatEngine`). A design that only enlarged Talk could not talk across books
or carry on later. One that sent everything each time would cost too much and could
only guess what to send on a long book. So the model looks things up with tools.

**One turn:**

1. The reader types, or speaks through the phone's own recogniser, as in the journal.
2. A small pack goes first. For each book in scope that has a memory (four at most),
   it holds the cards, passages and notes that match the question, within that book's
   spoiler line, and then the journal entries that match.
3. The Talking key's model may then call tools, for at most six rounds
   (`ChatEngine.maxRounds`). After that it is told to answer from what it has found.
   Every tool only reads, and the app keeps each book's line itself, never trusting
   the model to:

| Tool | What it gives |
|---|---|
| `list_books` | The books in scope: where the reader is in each, the spoiler line, whether a memory is built |
| `search_text` | A book's text, for words or a quoted phrase |
| `who_is` | A full card, by any name, alias or title |
| `cast` | The most important people, places, groups or items so far |
| `connections` | The memory graph round a name: every tie, how, and since when |
| `events`, `thread` | What someone did, in order; a mystery or promise, step by step |
| `chapter_notes`, `read_chapter` | Summaries of one chapter or up to ten; thirty passages of a chapter's own text |
| `theories` | The reader's theories about the book, and how the story has treated each |
| `search_journal` | The reader's journal |
| `search_past_chats` | Earlier chats and Talk's talks, by their summaries |
| `remember` | Keeps a short note about the reader, for later chats |

**What the reader sees:**

- Under each answer, what was looked at, in plain words ("Looked in: Who's who: Sunny ·
  The graph around Cassie · Your journal").
- Citations as chips ("ch 12", "Dune · ch 4") that open the book at that sentence. A
  number that was never given is dropped.
- Copy, Read aloud, Again and Report under each answer. Stop while it answers, which
  stops the paid reply too.
- A key whose provider turns tools down gets the pack alone, and is remembered for the
  session, as in Talk.

**Long chats.** The last ten messages are always sent as they were
(`keptVerbatim`). Once sixteen more have gathered before them, the older part is
folded into a running summary, one cheap call to the Building memories key. Leaving a
chat with two or more answers also writes a summary of up to 150 words, which
`search_past_chats` finds it by. The whole chat always stays in its file.

**Where chats live.**

- Each chat is its own file, `chats/<id>.json`, beside the library, so backups carry
  it. AI chat lists them as Pinned, Today, This week and Earlier, with a search once
  there are more than three; each can be renamed, pinned or deleted.
- A chat about one book is kept in that book's journal as one entry (`chat-<id>`),
  brought up to date as the chat goes on, unless talks are not kept in the journal.
  Tapping the entry reopens the chat.
- A question asked about one book is noted in its memory (`asked`), so it can say "you
  asked about this before".
- Notes made by `remember` are kept in `chats/notes.json`. They are sent at the start
  of every chat, listed under What the AI remembers about you, and can be deleted one
  by one or all at once, or turned off. A fact from a book's memory always wins over a
  note, since the notes describe the reader, never the book.
- **Deleting a chat** takes out only what it made: the chat and its summary, its
  journal entry (the reader's own pages stay), the notes kept from it, the questions it
  left in a book's memory, and the places other chats cite from it.

**Cost.** A turn makes at most seven calls, and a summary one cheap call. Every call goes
through the key ring, so daily caps and resting keys apply. The same safety rule,
held-back check and Report as Talk apply. In the tests every AI call goes to a fake
provider, so no credits are spent.

## 14.15 Series (2.5.0)

A **series** ties books whose memories are read together, in order.

- **Each book keeps its own memory.** A series only ties them, so a book can be rebuilt,
  forgotten or taken out without the others changing. A book is in one series at most.
- **Where it is kept:** `memory_series.json` beside the library (an id, a name, and the
  book ids in order), which backups carry (`series_store.dart`).
- **Starting a memory** (from the book's page or the Memory screen's **New memory**)
  asks "Does this carry on from another book?". Likely earlier books come first (same
  library series, lower number), then any book by a search; "No, it starts fresh" is
  one tap. Earlier books with no memory are queued and built first, in series order,
  with one estimate for all (`series_flow.dart`).
- **The book after** gets the earlier books' cast for name recognition and their story
  so far before its first chapter (`followOnFromAll`, 14.12). Talk in book k uses books
  1 to k, up to the reader's place; AI chat offers a series as one choice.
- **The series page** (`series_screen.dart`) has a filter at the top: **All books**,
  Book 1, Book 2, and so on. One book shows its own memory, as on its page. **All
  books** shows Who's who, the graph, Chapter by chapter and Threads across the series.
  It is a read-only memory made from the books' own (`series_db.dart`, in
  `memory_series/<id>.db`), with each book's chapters after the one before ("Book 2 ·
  …") and one entry for a person met in several books, matched by name. It is made
  again when one of them changes; nothing is copied into the books' own memories. Find
  where looks in each book.
- **The spoiler line** follows the reader's place in the series: with a book's guard on,
  nothing from a later book, or from later in the current one.
- **The menu** renames the series, adds a book after the last, takes a book out (its
  memory stays) or undoes the series (every memory stays). A book's Memory menu has
  **Add to a series…**.
- **Upgrading:** books linked the old way ("Follows on from another book…", 2.0 to 2.4)
  were made into series once (`seriesFromOldLinks`).
