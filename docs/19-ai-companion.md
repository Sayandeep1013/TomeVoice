# 19. TomeVoice 2.0: the reading companion

Agreed with the owner on 18 November 2026. This replaces the plan to release the AI in steps (1.7 to 1.10). Everything below ships together as **2.0**, built in stages on one branch, and each stage is tried in the test app before the next begins.

## 0. Ground rules

- **The reader's own keys.** There is no TomeVoice server: the app calls the provider directly. Keys are kept with the catalogue passwords (`Secrets`, in the app's own storage), never in a backup.
- **Off until turned on.** Nothing from a book is sent until the reader adds a key and turns the AI on.
- **Secret-shelf books are never sent.** Any book can also be set to never be sent.
- **Spoiler guard, per book, off by default** (the owner's choice).
  - When off, the AI may use everything in the book's memory.
  - When on, nothing after the reader's line is shown or sent. The line is the furthest point read, and Talk has a switch to use "only up to where I am now".
  - A book that came with reading done elsewhere can be given a line: "I've read up to chapter N".
- **The model's own knowledge.** By default the AI answers only from what the app gives it, so a popular novel is not spoiled from the model's training. A setting allows its own knowledge, with a "may spoil" warning when the guard is on.
- **Spoken in the reading voice**, and written down. Every talk can be kept in the journal.
- **No AI on the phone itself.** Every model call goes to the reader's provider.

## 1. The key ring

- **Any number of keys, from any providers:** several Gemini keys, three Inception keys, OpenRouter, Groq, or any OpenAI-compatible endpoint (base URL and model). Nothing is limited per provider.
  - All of them speak the OpenAI chat format. Gemini has an OpenAI-compatible endpoint at `generativelanguage.googleapis.com/v1beta/openai/`, and Inception's is `api.inceptionlabs.ai/v1` with model `mercury-3`, which has a 1M context.
- **Three jobs, each with its own ordered list of keys and models:**
  - **Builder:** bulk chapter notes. Cheap, fast, long input. Mercury 3 suits it.
  - **Talker:** Talk, Explain, theories and recaps. The best model available.
  - **Embedder** (optional): only for keys whose provider offers embeddings (Gemini does). It turns on meaning search (§3, layer 2b).
- **Rotation:**
  - When a provider says a key's quota is used up (HTTP 429, or its quota error), the key rests until its reset. The reset comes from `Retry-After`, then the provider's daily reset time, then an hour.
  - The next key in the job's list takes over.
  - Server errors are retried with back-off. A key that is refused (401 or 403) is marked broken and shown in red.
  - When all a job's keys are resting, the builder pauses and continues by itself when the first one wakes.
- **Usage:** the ring keeps a log of each key's calls and tokens, both today and in total. For keys with known prices, it shows an estimated cost and enforces an optional daily cap.
- **Test key:** a single call when the key is added. It shows the models offered and whether tool calling and JSON output work.
- **Know-how shown in the app:**
  - Gemini's free quota is per Google project, not per key, so two keys from one project share it.
  - Google may use free-tier requests for training.
  - Inception may end its API (one report says 28 Dec 2026). A book's memory stays on the phone whatever happens to a provider.

## 2. Where it lives in the app

- **Main menu → AI**, the AI home:
  - **Status:** on or off; keys and their state (working, resting until a time, broken); today's usage.
  - **Memory:** every book with a memory and its state ("Ready to chapter 1,812", "Building 640 of 3,214", "Paused: keys resting until 05:30"). Each has Build, Pause, Rebuild and Forget.
  - **Graph:** the memory visualizer (§6), for a book picked here or opened from that book's page.
  - **Settings** (§7).
- **Book page → Memory section:** its state, Build or Pause, the spoiler guard switch, "I've read up to chapter N", series link, Who's who, Graph, Hand-off pack, and Forget.
- **Reader:**
  - The **Talk** button sits beside the pen, as a floating button over the player, and comes and goes with the bars.
  - **Explain** appears in the menu for selected text.
  - **Tap a name** (hold a word → "Who's this?") opens its card.
  - At a chapter's end there can be a recap or a theory check.
- **Journal:**
  - Talks are entries of their own kind.
  - A filter shows **All · My writing · Talks**.
  - The AI can read the reader's own entries.

## 3. A book's memory

One SQLite database per book at `<book folder>/memory.db`. It goes with the book in a backup, a move or a replace, and Forget deletes it.

Every row that comes from the text carries **the chapter, and the sentence (unit) it came from**. That is how the spoiler guard filters, and how answers cite.

### Layer 1: text
These are the chapters themselves.
- EPUBs and other files already hold all of their chapters.
- Web novels get missing chapters fetched slowly by the existing download queue, politely to the source, on Wi-Fi when the reader says so.

### Layer 2: word index (no AI, free, offline)
- An FTS5 table over chunks of each chapter: a few sentences each, with their first and last unit.
- **Find where…** works on every book from import, with or without AI. Results are grouped by chapter, each with its line.

### Layer 2b: meaning search (only with an Embedder key)
- Vectors for each chapter's summary and each event, stored as compact int8.
- With meaning search, "the time he almost died in the snow" can find the place even when the words differ.

### Layer 3: chapter notes (AI, once per chapter)
For each chapter, the Builder returns JSON, checked before it is kept:
- `summary`: about 120 words.
- `entities`: each one seen, as an existing id from the ledger it was given, or new (kind, name, aliases, a line about it).
- `events`: the incidents. Each has what happened, who did it, to whom, where, with what, why, the result, the unit it happens at, and an importance from 1 to 5.
- `facts`: changes of state (rank, title, place, holder of an item, alive or dead, appearance, power gained or lost), each with its unit.
- `relations` begun, changed or ended: ally, enemy, sibling, parent, master or servant, member of, rival, love, owns, and so on.
- `threads`: mysteries, promises and foreshadowing, raised, advanced or resolved.
- `quotes`: lines worth keeping, by unit.
- `reveals`: things the text says outright that change what was known, such as who someone really is. Each links back to what it overturns.

### Layer 4: the graph (the ledger)
It stores everything: things, events and how they connect, each with when.

- **Entities:**
  - Kinds: person, place, faction, item, power or ability, title or rank, creature, concept or term, and any **kinds the AI proposes for the book's genre**, kept once the reader accepts them (Aspects, Flaws, Echoes, Memories for Shadow Slave).
  - Each has a name, aliases (with the chapter each was first used), a short description, first and last appearance, and an importance (how often and how centrally it appears).
- **Events:** nodes of their own, joined to the entities that played a part (doer, done to, witness, place, item). They are joined to each other where one caused or led to another, as given by the notes ("because of", "led to").
- **Facts over time:** an entity's attribute, its value, the chapter it held from and the chapter it ended. "Rank: Sleeper (ch 10) → Awakened (ch 180)". The card shows the state as of the line.
- **Relations over time:** two entities, the relation, from and until, the chapter and unit each came from, and a note.
- **Merging:**
  - The app merges each chapter's notes in Dart. The Builder is given the known names that appear in the chapter, by alias match, so it reuses their ids.
  - Every 50 chapters, a **tidy pass** asks the Builder about likely duplicates (close names, shared aliases) and merges those it confirms.
  - A merge can be undone from the card.

### Layer 5: story so far
- An arc summary for each 25 chapters, a summary of each 10 arcs (250 chapters), and one for the whole book so far.
- **Threads**, each from where it was raised to where it was resolved, with its open or resolved status and the chapters that touched it.

### Layer 6: the reader
- The journal: thoughts and talks (already in `journal.json`).
- **Theories**: the reader's claim, the chapter where it was made, its status (open, confirmed, busted, mixed), the chapter that decided it, and the evidence.
- What the reader has asked about, so "you asked about the Weaver at chapter 1,204" can be said.

## 4. Building, and keeping it built

| Book | What happens |
|---|---|
| **Started in TomeVoice** | Notes are made quietly as each chapter is finished, or ahead of it ("build ahead", on by default). Nothing is shown past the line when the guard is on. |
| **Deep in, or read long ago** | **Build memory** shows an estimate first: chapters, tokens, which keys, likely time and cost on paid keys. It then runs in the background, paused and resumed by the reader, surviving the app being closed. |
| **Ongoing (a chapter a day)** | The new-chapter check fetches it, and the Builder adds its notes on the next run. Cards, threads and the story so far update in place. |
| **A series in separate files** | The reader links the books in order. Each volume's memory starts from the last one's graph, so the cast carries over. |
| **File replaced, or chapters re-split** | Chapters are matched by a hash of their text. Only the ones that changed are made again. |

**How the Builder works:**
- **Order:** chapters go in reading order, because the graph of chapter N is what chapter N+1 is linked against.
- **Batching:** chapters are batched to fit the model. With a 1M context, 10 to 30 chapters go per call, about 60,000 tokens of input. Smaller models take fewer.
- **Bad output:** if a call's JSON fails the check, it is asked again once with the error, then tried on another key, then the chapter is marked "skipped" for a later pass.
- **Where it runs:**
  - In a background isolate while the app is open.
  - In WorkManager while it is closed, on the reader's conditions (Wi-Fi, not on low battery, charging only if chosen).
  - This reuses the new-chapter check's way of starting Flutter in the background.
- **Progress:** each call is committed in one transaction, so stopping at any point loses at most the batch in flight.
- **Size:** Shadow Slave (about 3,200 chapters, roughly 13–15M tokens) takes about 150–300 calls. Mercury 3's 100M free tokens cover it several times over.

## 5. What the reader can do

1. **Who's this (tap a name).** The card, as of the line: the description, what they are now (rank, place, items), relations, first appearance, key events in order, open threads they're in, and the reader's own notes. It's instant and works offline. **Tell me more** asks the Talker.
2. **Explain this.** For selected text. It uses the passage, the cards of the names in it, and the events it refers back to.
3. **Who's who.** The whole ledger, by kind, searchable and sortable by importance or first appearance, as of the line.
4. **Recaps:**
   - **Previously…**, offered on return after a few days away (the number of days is a setting).
   - **Catch me up**, in 2-minute or 10-minute length, for a book left long ago. It is built from the story so far and the threads.
   - A chapter's recap at its end, if wanted.
   - All are spoken.
5. **Talk.** The sheet over the reader; listening goes on, ducked or paused while the answer is spoken.
   - Answers cite chapters (ch 1,204, ¶). A tapped citation **looks** there without moving the place.
   - A talk is saved to the journal when closed, stamped with its chapter, unless the reader turns that off.
6. **Ask the book.** Talk does this, with tools (§8) to search the text, open cards, and read the notes or the chapter itself.
7. **Theory mode:**
   - It lists the open threads and the foreshadowing.
   - The reader states a theory, and the Talker argues for and against it from evidence up to the line.
   - Theories are kept. As the Builder makes later chapters' notes, it checks open theories against new reveals: **"Your theory from chapter 900 was confirmed in chapter 1,450"**, or busted, shown as a note in the reader and in the journal.
8. **Journal:**
   - The AI can read the reader's entries ("What did I think of Nephis back then?").
   - **Interview me** at a chapter's end asks the journal questions aloud and writes the spoken answers in.
9. **Hand-off pack.** A Markdown file with the story so far, the main cards, open threads and the reader's journal, filtered by the line when the guard is on. It's for ChatGPT, Gemini or NotebookLM, and for readers with no key.

## 6. The graph visualizer

- **Overview:** the most important entities (about 150 at most), laid out by force in an isolate. Colour shows kind, size shows importance, and edges are relations.
- **Focus:** tap a node to open its card and centre its neighbourhood (one or two steps out), with its events in time order on a strip below.
- **Time slider:** the graph as of any chapter up to the line (or to the end of the memory when the guard is off). Scrubbing it shows the story's web grow, with relations appearing and ending.
- **Filters:** by kind, by relation, and by search. Pinch to zoom, drag to pan, and drag a node to move it.
- **Thread view:** a thread's events joined across chapters.
- Drawn with a CustomPainter and a hit-test grid, so it stays smooth with thousands of nodes. Only what's on screen is drawn, and labels show at zoom.

## 7. Settings (AI → Settings)

- **Keys:** add, test, edit, remove, and the order for each job.
- **Builder:**
  - build as I read (on), build ahead of my place (on)
  - background building, with conditions: Wi-Fi only, not on low battery, charging only
  - daily token cap for each paid key
  - how fast to fetch missing web chapters
- **Talk:**
  - speak answers (on)
  - pause or duck the book while speaking
  - answer length (short, normal, long)
  - keep talks in the journal (on)
  - model's own knowledge (off)
- **Spoilers:** the guard for new books (off), and the default line (the furthest read).
- **Recaps:** offer "Previously…" after N days away (3); chapter-end recap (off); Interview me at chapter end (off).
- **Theories:** tell me when a theory is decided (on).
- **Privacy:**
  - what is sent where, shown in plain words
  - books never sent
  - the usage log
- **Memory storage:** size per book, export, forget all.

## 8. Answering a question

1. **Find the names.** The question, and the paragraph being read, are matched against the ledger's aliases.
2. **Gather a pack**, filtered by the line when the guard is on:
   - their cards as they stand
   - recent and important events involving them
   - chapter notes and word-index passages that match, plus meaning-search hits when that is available
   - the latest story so far
   - open threads
   - the current chapter up to the reader's sentence
   - the reader's journal entries and theories that mention them

   That's about 5,000–30,000 words, whatever the book's length.
3. **Tools.** When the model supports tool calls, it can ask for more:
   - `search_text(query)`
   - `card(name)`
   - `events(name, from, to)`
   - `chapter_notes(n)`
   - `read_chapter(n, from_unit, to_unit)`
   - `thread(name)`
   - `my_journal(query)`

   Every tool respects the line. Without tool support, the pack alone is used.
4. **The answer** comes with citations as `[ch N ¶U]`, made into links that look there. A citation outside the line, or one that names a missing chapter, is dropped.

## 9. Stages (on branch `ai-companion`, each tried in the test app)

| Stage | What it adds |
|---|---|
| 1 | Key ring and AI client (streaming, JSON, tools, rotation, usage log), the AI home and Settings, and the spoiler guard on the book page. |
| 2 | `memory.db`, the word index, and **Find where…** for every book. |
| 3 | The Builder: chapter notes and the graph merge, catch-up with an estimate, background work, ongoing novels, and the tidy pass. |
| 4 | Answering: the pack, tools, citations that look, Talk (sheet, spoken, saved to the journal, the journal filter), Explain, and cards on a tapped name. |
| 5 | Who's who, story so far and recaps (Previously…, Catch me up, chapter-end). |
| 6 | Threads, theory mode and theory checks; Interview me. |
| 7 | The graph visualizer. |
| 8 | Series, meaning search, the hand-off pack, export and forget, and the privacy page. |
| 9 | A whole-book run on Shadow Slave on the phone, polish, and the 2.0 release. |

**Tests:**
- A fake provider (recorded answers, 429 and 401 cases, broken JSON) for the client, rotation and builder.
- Merge tests on fixed notes.
- Spoiler-filter tests on every query path.
- Widget tests for each screen.
- On the phone: one short book, all the way through, and a slice of 200 chapters of a long one, before the whole run.

**Risks to check early:**
- SQLite (with FTS5) in Flutter tests on Windows, and in background isolates.
- WorkManager time limits on long builds.
- Models that return weak JSON.
- Fetching thousands of web chapters without being blocked by the source.
