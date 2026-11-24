# Changelog

What changed in each release of TomeVoice, newest first, as each release told it.
Every release has its APK on [Releases](https://github.com/Sayandeep1013/TomeVoice/releases).

## 2.6.4 (2026-11-25)

Buttons answer the first tap again, opening and closing a book is smooth again, and a tap log to find anything that still is not.

**Updating** keeps your library, your keys, every book's memory and your journal.

#### Fixed
- **Taps that needed repeating:** since 2.6.3, a row, a sheet's action (Read from here), a round button or Play often did nothing unless tapped very quickly, so it took several tries. The give under your finger rebuilt the button while it was pressed and the tap was lost. A tap now always counts, however long your finger stays. Battery level had nothing to do with it.
- **Every other place a tap could be lost or land wrong**, found by going through the whole app:
  - **Web novels:** after the voice reached the latest chapter (or the next would not come), Play, Read from here and the player's buttons did nothing on that page until you left it. They work again, and Play tries the next chapter again.
  - **The player and Now Playing:** a press on Play, the skips or a chip that drifted a little was taken as the swipe that opens or closes Now Playing. A swipe now has to go as far as a tap may.
  - **AI chat:** an answer finishing in the background no longer moves the rows under your finger (the Also rows among them), and New chat no longer opens a chat per tap while it finds the book.
  - **Book memories:** Who's who, the graph, Find and the rest open once however often they are tapped; the "Carries on from" line no longer vanishes at every chapter a build notes; the graph's controls keep a press as a load ends; the download buttons stay put as downloads move on; Who's who keeps what you typed when a suggestion comes in.
  - **A book's colours arriving** (a new book, a cover changed) no longer rebuilds its page or the reader, losing the scroll and any press.
  - **The chapter list's fast scroller:** the first drag no longer stops at once with its bubble stuck on screen.
  - **Now Playing:** a sentence pressed as the text moves on reads from that sentence, not a later one.
  - **The reader:** a tap while the page follows the voice brings the bars back, rather than only stopping the scroll.
  - **Sources and Browse:** a source's menu acts on that source, not one that moved into its row.
  - **Play** gives under your finger only where it answers.

#### Smoother
- **Opening and closing a book no longer stutters.** The cover flying between the shelf and the book's page was decoded again at every frame of its flight, some twenty times each way, which kept the phone busy for moments after the page came. It also pushed the shelf's covers out of memory, so the next switch of shelf stuttered while they were decoded again. The cover is decoded once now.
- **Back on the shelf:** the app's colour follows the book read last, and that change was eased across the whole app, rebuilding every screen at every frame for a third of a second just as the shelf came back. It changes at once now; a theme you pick in Settings still eases across.

#### New
- **Tap log** (About, Tap log): for buttons that need tapping again and again. While it is on, TomeVoice notes where your finger comes down, how long it stays, which of its buttons was under it and whether that answered, and the moments the screen stuck. Share it as a file with whoever is helping. Never a book's words or what you type; rows that show your own words (a tag, a shelf, a key's name) are noted by a plain name. Off unless you turn it on, kept on the phone, never in backups. For each moment the screen stuck it notes whether the app's own work or the drawing took the time, and it tells a tap a scroll took apart from a tap that was lost.

## 2.6.3 (2026-11-24)

Painted scenes and two new ones, smooth motion you can turn off, search in Settings and in the provider list, twelve more AI providers, and the name being looked up lit in its sentence.

**Updating** keeps your library, your keys, every book's memory and your journal.

#### Scenes: paintings, and two new ones
- **Every scene is now a real picture**, darkened for reading over: Dungeon (a real fortress dungeon) and Enchanted forest (Asher Durand's *In the Woods*). Free to use; credited under About, licences.
- **Two new scenes:** **Silver witch** (Grimshaw's *A Moonlit Lane*) and **Space · solar** (the sun's edge with a prominence). Each has its own colours, lettering and panels.
- **Starship is now Space · solar:** the same hull panels, in gold. If you had Starship on, you have Space · solar.
- **Each scene moves in its own way:** in the forest, vines grow in from the top corners as a screen opens, leaves budding as they go, while fireflies drift; in the dungeon, torches flicker and water drips down the stone; in Silver witch, mist drifts, silver falls and a ring of runes draws itself; in Space · solar, the sun swells and flares and a small planet crosses it.
- It all stands still with animations off, or with battery saver on.

#### Motion
- **Smooth, never bouncy:** everything eases out, quick to start and soft to stop, without springing past where it lands.
- **Animations switch:** Settings, Appearance, **Animations**. Off, everything changes at once and the scenes stand still, as with the phone's own "remove animations".
- Buttons, pills and rows **give a little** under your finger and ease back. Book covers stay as they are.
- Lists and cards **ease in**; the menu's rows come in one after another as it opens; switching category slides smoothly.
- The choice highlight **slides** to the new choice; play and pause **turn into each other**; the Now Playing cover **rises as the voice starts** and sinks back on pause; an empty screen's picture **floats**.
- Kept light for slower phones: the moving parts draw about 30 pictures a second and only while they can be seen.

#### Finding things
- **Find a setting:** a search at the top of Settings. Type the start of a word or two ("back up", "sync"), tap a match and the list goes to it.
- **Find a provider:** the provider list (AI chat, AI settings, Add a key) has its own search, by name or by what it offers ("free", "Claude"). Another service is always at the end.

#### AI: twelve more providers
- **Anthropic (Claude), DeepSeek, Mistral, xAI (Grok), Z.ai (GLM, with a free model), Alibaba Cloud (Qwen), Together AI, Fireworks AI, Cerebras, Moonshot (Kimi), Hugging Face and NVIDIA**, each in AI settings, Add a key, with a likely model chosen for building and for talking once the key is checked.
- Each provider's quirks are handled for you (some refuse a temperature, Claude has its own format, DeepSeek's thinking must be sent back on tool calls, some list no models, some take fewer texts at a time for meaning search).

#### Reading
- **Who or what:** the sentence is shown with the words being looked up **lit** ("Six Finger", not "Finger"), in the menu and in the look-up sheet. Add or drop a word and the mark stretches to it; tap a word in the sentence to take it in.

## 2.6.2 (2026-11-24)

Choose how far a book's memory goes, a painted forest, and smoother natural voices on slower phones.

**Updating** keeps your library, your keys, every book's memory and your journal.

#### Memory: you choose how far
- **Build sheet, How far:** **Every chapter on the phone**, **Up to chapter N**, or **The next N chapters**. What it would take (chapters, calls, tokens) is counted for the choice you make.
- The memory **stops there** until you ask for more, by hand or by itself. Its page says **Built to chapter N, where you asked it to stop**, and the button reads **Build more chapters**. A paused build still says **Go on building** and goes on as it was.
- **Build new chapters by itself**, on each book's memory and in the Build sheet: on, chapters you download or add later join the memory as they come (up to where you asked it to stop); off, it grows only when you tap Build. New chapters' words are still indexed for search either way.
- **AI → Building memories → New chapters build by themselves** sets it for each memory you begin (on unless you turn it off).
- **Fixed:** the Build sheet could stay at "Counting…" for a book whose memory was just begun.

#### Natural voices on slower phones
- After a pause of more than three minutes, a natural voice was let go to free memory, and loaded again only when the next sentence was due: on a slow phone that left ten seconds of silence after Play. It is now loaded again the moment you press Play, while what was made before the pause plays.
- **Voice log** now also notes each time a natural voice is loaded and how long it took, the theme in use, and what each natural voice's speed test measured on your phone. A log with only a resume (no Play) says so.
- If the log says a natural voice **cannot keep up** on your phone, choose a **Low** voice in Natural voices, or the phone's own voice: they ask far less of it.

#### Scene themes
- **Enchanted forest is a painting now:** Asher B. Durand's *In the Woods* (1855), from the Metropolitan Museum of Art's open access collection (public domain), darkened for reading over. The fireflies still drift over it.
- Scene motion now draws about 30 pictures a second without waking the phone on every frame of the display (two to four times less work on a 60 to 120 Hz screen), and **stands still while battery saver is on**.

#### Smaller and tidier
- The app's own Android code is shrunk and tidied like the rest (about 100 KB less code to load).

## 2.6.1 (2026-11-23)

A voice log, for a voice that lags, stops or goes wrong on your phone.

**Updating** keeps your library, your keys, every book's memory and your journal.

#### Voice log (new)
- **About → Voice log → Record a voice log.** Off unless you turn it on.
- While it is on, TomeVoice notes how long the voice takes to start after Play, a skip or a change of speed; how long each sentence takes to make against how long it takes to say (a phone that cannot keep up at a speed shows here); every time the voice runs dry and for how long; the speech engine's errors; which voice read which alphabet (handy for other languages); and your phone's model, memory, 32 or 64 bits and battery saver.
- It never notes a book's words or title: a sentence is only its length and alphabet.
- **Share** sends it as a text file through any app (WhatsApp, Telegram, email). Nothing is sent by the app itself. **Clear** empties it.
- It does not slow reading down: off, it does nothing; on, it writes a few lines every few seconds.
- Use the 32-bit APK below on older phones.

## 2.6.0 (2026-11-23)

Scene themes you can live in, a smoother voice at any speed, "Who or what is…" for any name, and a long list of fixes from a full check of the app.

**Updating** keeps your library, your keys, every book's memory and your journal.

#### Scene themes (new)
- **Dungeon, Enchanted forest and Starship**: not just colours but places, drawn behind every screen. Settings → Designer themes → Scenes.
- **They move:** torches flicker and throw up embers, fireflies drift and glow while a leaf falls, neon runs along the starship's hull. Nothing moves if your phone is set to remove animations.
- Each one has its own lettering for screen names, buttons and panels made of stone, wood or hull plate, covers in rusted iron, vines or neon, and its own drawer.
- The page you read stays plain.
- A scene keeps its own colours even with "Colours from book covers" on.
- The TomeVoice logo inside the app now takes the colours of your theme.

#### Read-aloud
- **Quicker first words:** the first sentence is split where its first piece ends, so the voice starts sooner, for every voice.
- **Fast speed taps:** tapping + or − several times restarts the voice only once, and the old voice keeps talking until the new one is ready.
- A speed changed while paused is heard when you resume.
- **Shorter pauses when faster** (Fine-tune, on by default): pauses between sentences shrink above 1×.
- A speed between the presets (like 1.35 or 1.55) now shows, lit, in its place in the speed row.
- Quicker skips and lighter home-screen widgets.

#### Who or what is "…"?
- Hold a name and ask: it now takes the whole name ("the Nine", "Six Finger", "Lord of Mysteries"), and you can widen or narrow it a word at a time.
- The book's memory answers first. Otherwise you choose: **ask the AI** (no spoilers) or **search the web** (may spoil). It works without an AI key too.
- It is not offered for a small word held by chance ("of", "the").

#### PDFs shown as real pages
- Going to a chapter, a bookmark or a search hit now opens its page.
- The page you land on is drawn first; pages that failed are tried again; fast flicks scroll smoothly; zoom only when you zoom.

#### Library, memory and backups
- **Removing a book keeps its AI memory** unless you tick "Also delete its book memory". Kept memories are listed under Book memories → From removed books, come back if you add the book again, and travel in backups.
- **Restore → Replace** keeps what the backup lacks (downloaded chapters of web novels in it, natural voices, OCR languages) and says so before you confirm.
- Sync goes by the latest change.
- History's "today" starts at 4 am, so a late-night session counts as the same day.
- Every screen opened from the drawer has Menu at the top left.
- An AI memory build keeps to one key unless you let the next one take over.

#### Smaller fixes
- Download next N takes the next N chapters not yet downloaded or queued; a paused download queue ends its pause properly.
- Now Playing chips fit on small screens; the snack bar sits above the player; Listen and Read tabs stay pinned.
- Journal previews show one answer per line; clearer wording in Settings about what is removed and what stays.
- Faster around the app: lighter library and reader caches, quieter saves, faster search inside memories.

## 2.5.0 (2026-11-23)

Series memory, a journal for every book, a calmer AI chat, a new graph, designer themes, and sources that offer whole books.

#### AI chat
- **Answers are never read aloud by themselves.** Tap **Read aloud** under an answer to hear it. (Talk over the book keeps its own switch, now off unless you turn it on.)
- **Leaving a chat no longer stops the answer.** It goes on and is kept; the chat list says **Answering…** until it is in.
- **Follow-ups keep their thread:** "what did he do then?" is answered from the conversation, and a chat opened again remembers its last messages, not only a summary.
- The AI's look-ups and its notes about you no longer switch off for the rest of the session after one refused request.
- A daily token limit on a key now holds (the call that reached it used to clear it).

#### Memory
- **Series:** books whose memories are read together. Starting a memory asks whether the book carries on from another (the likely ones first); earlier books with no memory are built first. A series is one card in **Memory**, with **All books** (Who's who, the graph, chapters and threads across the books, a person met in several books one entry) or **Book 1, Book 2…** one at a time. Rename, add a book, take one out, or undo the series. AI chat can talk about a whole series.
- **New memory** at the top of the Memory screen: pick a book and start.

#### Graph
- **Only the ones who matter most stand out**; the rest are fine points, on a dotted grid.
- **Each group in its own colour** (or by kind, in the key), links blending between groups.
- **Smooth to move and zoom**, with no wall at the edges; **All of it** shows the whole web.
- The timeline and how many are shown float over the graph.

#### Journal
- **One card per book**, each the same size; a tap opens that book's journal, **every entry its own box**. The same novel from two sites is one book.
- **Web novels have a journal** too, and any entry can be **about any chapter**: pick it from the book's list (nothing needs downloading).
- From a book's page the journal opens at that book; **All books' journals** is a tap away. Find a book by its name.
- The notebook's tabs shrink to fit many books, then scroll.

#### Look
- **Designer themes:** Library, Matcha, Rosewater, Slate, Dune, Midnight Ink, Plum and Maple, by day and by night, over the whole app; and the page tones **Vellum** and **Lamplight**.
- **Sliders** with a track set into the page and a wide handle that lifts as you hold it.

#### Books and sources
- **Sources that offer whole books:** a source can now offer a book's EPUB or PDF to download into your library, with your sign-in to its site kept for that source. Signed out, it says so with **Sign in** a tap away. (Not in the Google Play version. TomeVoice provides no sources.)
- **Add a catalogue** tries the address first and says plainly when it is a web page, not a catalogue; a catalogue that is down says so.
- After reinstalling from the same Google account, Android now brings back your settings, catalogues, journal, chats, marks, stats and installed sources (not the books: restore your TomeVoice backup for those; keys and passwords are never backed up).

## 2.4.2 (2026-11-21)

Book memories show again.

- **Fixed:** after opening AI chat, a book's memory could show as "Not built yet" (in Book memories and on the book's page) until the app was restarted. Nothing was lost: the memory was all there, just not read. Each memory is now read the first time anything asks about it, and read again if it was busy.
- AI chat now reads each book's memory before choosing which books it may use, so a book kept away from the AI is never included, even straight after opening the app.

## 2.4.1 (2026-11-21)

Deleting a chat takes only what that chat made.

- **Delete this chat completely** now removes only what the chat itself added: its copy in the journal, the notes the AI kept from it, and the questions asked in it. The same question asked in Talk or another chat stays in the book's memory; before, it went too.
- Your own journal pages and the book's memory are never touched, even when the chat read them, and the delete dialog now says so.

## 2.4.0 (2026-11-21)

AI chat: talk with the AI about one book, a few, or all of them, in conversations it keeps. And a shorter menu.

#### AI chat
- **AI** in the menu is now **AI chat**: start a new chat, or carry on an old one. Chats are grouped Pinned, Today, This week and Earlier, and can be searched, renamed and pinned.
- **About:** a chat is about one book, a few, or all your books with a memory. Change it with the button at the top.
- **The AI looks things up itself** before it answers: Who's who, the main characters, how people are tied in the graph, events, chapter notes, a chapter's text, storylines, your theories, a word search, your journal and your earlier chats. Under each answer, **Looked in** says where it looked, and the chapter chips open the book at that sentence. Each book's spoiler line holds for every lookup.
- **Copy, Read aloud, Again and Report** under each answer; **Stop** while it answers; the **microphone** to ask by speaking.
- **Tied to your journal:** a chat about one book is kept in that book's journal, and tapping it there opens the chat again.
- **What the AI remembers about you:** things you tell it to keep (what you like, how you like answers) are listed, each one deletable. Long chats get a short summary, so later chats can look back at them. Both can be turned off.
- **Delete a chat completely:** it goes with every trace of it: its page in the journal, the notes the AI kept from it, its questions in the book's memory, and the places other chats cite it.
- **AI settings** (keys, the spoiler guard, everything the AI page had) is behind the gear in AI chat, and the books' memories behind the button beside it.

#### The menu
- In groups, each with a heading: Your books, Find books, Thoughts and AI, App.
- **Catalogues** is a tab of **Browse**, and Sources the button at its top. **Stats** is a tab of **History**.

#### Reading aloud: Bengali and older phones
- **A book in Bengali (or Hindi, Arabic, or another language with letters of its own) on a phone with no voice for it** now says so ("No Bengali voice in this speech engine"), instead of handing the text to an English voice. On some phones that voice's engine crashed on every sentence ("Synthesis failed (code -4)") and the phone slowed right down.
- When another speech engine on the phone has that language (Google's, beside Samsung's), the voice list offers it in one tap: **Use Speech Services by Google, which has one**.
- If the speech engine fails outright, or a voice doesn't answer, reading **stops at once** with a line saying why and what to do, instead of retrying for minutes.
- **The notification no longer says Playing when reading has stopped**: after an error in a web novel, and on Android 12 and older when reading ends.
- Long jobs update their notification at most once a second, and the memory catching up as you read no longer starts a background service every minute and a half. Both were a load on older phones.
- AI chat reads answers aloud in the voice the book uses, even when you never picked one, and in a Bengali voice when the answer is in Bengali.

#### The AI's keys
- **Add a key** no longer jumps about: the provider is chosen from a list, and the page is laid out like the rest of the app.
- **100milionseek** is one of the providers to choose from: DeepSeek models, free for now, through a relay run by people not named on its site.

## 2.3.0 (2026-11-21)

A book's memory, easier to use every day, a clearer graph, and long jobs that keep going in the background.

#### Memory
- **A book's Memory page** lists what you can look through, each with a line saying what it is for and how many there are: Who's who, Chapter by chapter, Graph, Threads, Theories, Find where…, Talk elsewhere. The **spoiler guard** sits near the top and says what it covers.
- **Chapter by chapter** opens with the newest chapters first; the order menu goes back to the start.
- **Who's who**: a new order, **Seen lately**, puts those from the chapters you just read first ("who was that again?"). Each row says where they are in the book ("in 45 chapters, 3 to 210").
- **See their links** on a card in Who's who opens the graph round them.

#### The graph
- Links show their kind's colour softly at rest (allies, enemies, family), and in full round the one you pick.
- Each point has a thin ring of the background, so it stands clear of the lines; the person in the middle and the one picked have a ring of their own.
- **Key** is a button on the graph itself, and says that bigger means in more chapters.
- **Closer, Further, All of it** buttons, for zooming with one thumb.
- Names keep to the colours of your theme, day or night, and a big book's graph pans more smoothly (only what is on the screen is drawn).

#### Long jobs keep going in the background
- **Chapter downloads, building a memory and downloading a voice** keep going with TomeVoice behind other apps, with the screen off, and after a swipe from Recents. One quiet notification says what is running and how far, with **Stop**.
- They no longer stop when the app goes behind before the first chapter came, and the phone no longer sleeps under them with the screen off.
- If a phone ends TomeVoice anyway, downloads and memory building **pick up where they stopped** the next time you open it, and say so. A memory goes on from the last chapter noted: nothing is sent twice.
- Android 15 and later allow six hours a day of this work in the background: then it pauses, says so, and goes on when you open TomeVoice.
- Once, when you start one of these and battery saving is on for TomeVoice, a short note with the setting a tap away. Settings > Listening has a **Keeps stopping?** line for phones (Nothing, Xiaomi, Samsung, OnePlus and others) that stop apps in ways of their own.
- The first long job asks to show its notification (Android 13 and later), so **Stop** is there when you need it.

#### The AI
- **AgentRouter** is one of the providers to choose from: one key for many models.

#### Fixes
- Who's who always says where someone was seen, however long their summary.
- A person's card no longer runs two sentences together ("…is alive First met in…").
- Save as audio no longer says "about under a minute".
- A dash in a screen's title shows (a catalogue's "Standard Ebooks - Newest Ebooks" read as a gap).

## 2.2.0 (2026-11-20)

You stay in charge of the AI: it asks first, shows what it sent, and takes reports. Interview me at a chapter's end, chapter search in a memory, and undo for merges.

#### The AI asks first, and shows its work
- **Before the AI reads with you**: nothing is sent to any AI until you add a key and agree to what is sent.
- **Report** any answer (harmful, sexual, hateful, wrong, or something else): it goes to the developer and the answer is hidden. **Say it again** asks afresh.
- **What was sent**: every call to the AI (when, for what, which book, which model, how many tokens), kept on the phone.
- **Your data**: export every memory, or forget them all, in one place.
- **Use my journal**: Talk sends only the journal entries that bear on your question, and none when this is off.

#### Your journal, out loud
- **Interview me**: at a chapter's end the journal's questions are asked aloud, your spoken answers written down, and reading goes on.

#### Memory
- **Chapter by chapter** has a search: a chapter's number, or words from its title or notes.
- **Undo a merge** in Who's who, right after it or later ("Take X apart again"), and undo the AI's tidy.
- When the story settles a theory you stated, the verdict is written into your journal too.

#### Web novels
- A shared chapter link opens its novel.
- **Download speed** (gentle, normal, fast), and checks for new chapters **only while charging** if you like.

#### Fixes
- An empty answer from the AI no longer leaves Talk on "Remembering…".
- A privacy page: sayandeep1013.github.io/TomeVoice/privacy.html, linked from About.

## 2.1.0 (2026-11-20)

Speak into your journal, a series that carries on by itself, a guide to the AI, and more ways to look into a book's memory.

#### Speak, and the journal writes
- A **microphone** beside Done on the journal page: tap it and speak. The phone's own speech recogniser hears you (no key, nothing downloaded, nothing recorded: only the words are kept), in the book's language. Your words land in the answer you are writing, through pauses, until you tap it again. The book's voice waits while you speak and reads on after.
- **Tidy what you said**, with an AI key: punctuation and capitals added, the ums taken out, your own words kept. It shows the tidied text beside what you said before using it.

#### A series carries on by itself
- Building the memory of a book whose series has an earlier book with a memory offers to **carry on from it**: its people, places and things as they stood, the threads left open and the story so far.
- The Memory page says what a book **carries on from**; when that book's memory has changed since, one tap brings it over again (nobody twice). A book can carry on from several (an omnibus, a spin-off), picked in its Memory menu.
- With the spoiler guard on, an earlier book comes over only as far as you read it.
- **Talk looks into the earlier books** too, citing them by book and chapter ("Book One · ch 4"), and reads what your journal says of them.
- On the graph, those from an earlier book wear a thin ring; the legend hides them.

#### Looking into a memory
- **Threads**: the story's mysteries, promises and hints, open or settled, each step by chapter.
- **Chapter by chapter**: what the AI noted of each chapter, and **Read this chapter again** for a poor one.
- **Find where…**: every word of the whole book searched, even a web novel's chapters not on the phone.
- **Who's who** shows the new kinds the AI suggests for a book, to accept or turn down.
- The 3D view of the graph is put away for now; the flat one stays.

#### Talk
- **Catch me up in two minutes**, or in ten, in detail.
- Your own questions, kept as buttons (**Your own**; hold one to take it away).
- Talk remembers what you asked, and brings back an earlier question on the same thing.
- AI settings: **Keep talks in the journal**, and **Spoiler guard on for new books**.

#### Keys
- **A guide to the AI and the memory**: six cards, shown the first time the AI page opens, and from **How the AI works** there and in Settings.
- A **daily limit** for each key, in tokens (2M, 500k): reached, the key rests until midnight and the next one takes over.
- **Check the key** also tries the model's tools and JSON, and says what that means for Talk and building.

#### Fixes
- Replacing a book's file keeps its AI memory; chapters whose text changed are read again.
- A chapter whose text changed (an edited web-novel chapter) drops what its old notes put in the graph before it is read again; a web-novel chapter downloaded again is checked.
- Pause pressed while a web novel fetches its next chapter is kept: it waits there, paused, and Play reads on.
- Check for new chapters: **Only novels I've begun**, if you want.

## 2.0.0 (2026-11-19)

An AI reading companion that remembers the book with you, working with your own keys.

#### Your keys (Main menu, AI)
- Bring your own keys: Google Gemini, Inception (Mercury), OpenRouter, Groq, OpenAI, or any service that speaks the OpenAI chat format (give its address). As many as you like, several from one provider too, each with its own name.
- Each key names a model for each job: Building memories (many calls: a cheap, fast model), Talking (the best you have), and Meaning search (optional: Gemini, OpenAI and some other services have it). **Check the key** lists the models it may use and picks likely ones. Hold a key to change the order a job tries them in.
- A key that has used its quota rests until it comes back (as long as the provider says, or until a daily quota resets) and the next one takes over; a key the provider refuses is shown as Refused; a provider that keeps failing rests its key a minute, then longer, instead of stopping the work. Each key shows its state and today's calls and tokens, and only its last four characters.
- Straight from the phone to the provider: there is no TomeVoice server, and no AI on the phone. Nothing is sent until you add a key. Books on a secret shelf are never sent; keys stay in the app's own storage and never go into a backup.

#### A memory of each book
- **Build memory**, from a book's page: its words are indexed on the phone (free), then the AI reads each chapter once, in the story's order, and keeps notes in the book's folder (`memory.db`): a summary of each chapter; the people, places, groups, items, powers, titles and terms, with every name they go by; events, who took part and what led to what; how things stand and change over time (ranks, titles, places, who holds what, relations begun and ended); mysteries from raised to resolved; reveals; lines worth keeping. Every 25 chapters, and every 250, a summary of the story so far.
- Before it starts it says how many chapters, calls and tokens it will take, and with which keys. Pause stops after the batch on its way and holds until you go on. A chapter the AI cannot make notes for is passed over, to try again later. Forget this memory deletes it; your journal stays.
- Kept up as you read: a memory you began takes in new chapters when you open the book, at each new chapter, and as a web novel's chapters download.
- With TomeVoice closed: every hour or so, the memories you began go on (AI, Building memories: on by default; only on Wi-Fi, on; only while charging, off; never with the battery low).
- A web novel's chapters for its memory: download the missing ones (one at a time, gently on the site), built in the story's order as they come; then free the space they took, since the memory keeps its own copy of their words.
- A spoiler guard for each book, off by default: on, the AI keeps to what you have read. **I've read up to chapter…** for a book read partly elsewhere. **Keep this book away from the AI** for any book.
- **Follows on from another book…**: a series' next book starts with the cast, how they stood, open mysteries and the story of the one before.
- Main menu, **Memory**: every book's memory and how far it is built, each book under its own highlighted name and author (a tap opens its Memory page), a line between books. A book's page shows it as one row that opens the book's Memory page.
- One card per character: a name the AI gives wins over the card number it pointed at, words that are not names ("she", "her teacher") are never kept as one, and a character first known by a description ("Silver Haired Girl") takes their name once the book gives it. Every 250 chapters, and when a book is done, the AI tidies the cast: two cards for one character joined, a minor character's card that took over another's story handed back from the chapter it began, wrong names taken off.

#### Talk about the book
- **Talk**, a button over the player: ask anything about the book, with the voice still reading. Answers come from the book's memory and the passage you are at, cite the chapters they rest on (a tap on one looks there; Back to reading returns), and are said aloud in the voice reading the book, which pauses for them and reads on after. The speaker button turns that off; Say it again repeats one.
- Every talk is kept in the book's journal, stamped with its chapter; the Journal shows **All**, **My writing** or **Talks**.
- **Explain this**, in the menu of a held sentence: what it means there in the story.
- **Who or what is "…"?**, holding a word: its card at once, from the memory with no waiting: who or what it is, other names, how it stands, relations, key events by chapter, a line they said. **Tell me more** asks Talk.
- **Who's who**: everyone and everything the memory knows, by kind, by any name, sorted by seen most, first met or name. The wand asks the AI to tidy the names now; hold a name to **Rename** it, say it is **The same as…** another, or that it is **Someone else from a chapter…** on (the chapter suggested).
- **The memory graph**: the story's web as points and fine lines, its names as plain text. It opens on the whole web of those who matter now, with those you may have forgotten ringed in orange, and a slider for how many (10 to everyone); or round anyone, two links out, or a **Story map** of the book's groups as islands the AI names. It settles as an uneven cloud, never rings. Links lit in colour by what they are, groups in a halo, a timeline that shows the web at any chapter and plays it growing, a tap for someone's links and what two people share (and Ask about this), and the whole of it as a cloud to turn (3D).
- **Theories**: tap the bulb in Talk and say what you think is going on. The AI weighs it, for and against, from what you have read. As the memory reads on it checks your theories, and tells you when you reach the chapter that settled one, never before.
- **Previously…**: back to a book after a few days away (a day, 3 days or a week; or never), a short recap of the chapters just before your place.
- **Talk elsewhere**: the memory as one Markdown page (the story so far, who matters, what is unanswered, your theories and journal) to copy or share into ChatGPT, Gemini or NotebookLM, kept to your chapter when the guard is on.
- **Meaning search**, with a Meaning search key: a moment described in other words than the book's is found too.
- AI, Talk: how long answers are, answers aloud, when to offer Previously…, and "What the AI already knows of the book" (off: it keeps to what TomeVoice gives it, so a well-known book is not spoiled from the model's memory).

#### The journal and a book's page
- The pen is a round button of its own over the player, at the right, beside Talk (one above the other upright, side by side on its side): it no longer pushes the player's controls aside, and it comes and goes with the bars.
- The journal's notebook (its list, pages and writing page) takes your colour theme's colours, not only plain dark or white.
- A book's page keeps the Journal to one row (how many entries, the latest and its first words, a pen to write) that opens the book's journal, so the chapters are no longer pushed down.

#### PDFs
- A PDF shown as its real pages puts the top bar and the player away on a tap, and brings them back on another, as the text does. A double tap only zooms.
- Importing a big PDF keeps the library smooth while its pages are read.

## 1.6.0 (2026-11-18)

Your reading journal, a notebook to keep it in, and reading made more your own.

#### Your reading journal
- Write what you think as you read or listen: the pen on the player (also Write in the journal in a book's menu, and its page's Journal) opens a notebook page. It asks how you feel (Loving it, Good, Mixed, Meh, Frustrated, or a word of your own), why, what stood out and what you think happens next; skip any, or turn to a blank page and write freely.
- Done stamps the entry with where the story had reached: the chapter the voice is reading, or your place. If the voice read on while you wrote, it says so ("chapters 4 to 6").
- **Journal**, in the menu (and See all from a book's page): your entries by book, newest first; or, with the button beside its title, a notebook with a page for each book, its cover taped at the top, your entries in handwriting on squared paper, and numbered tabs in colour down the edge to turn to a book. It stays as you left it. **Write** (the button at its foot, or on a book's page there) starts a new entry: it asks which book, the one you were last in first, and stamps it where that book's story is. Tap an entry to change it (the questions you skipped are there to answer), hold it to remove it, with Undo. **Export** makes a Markdown file of the journal (every book's, or one book's), each entry under its book with its chapter and date, saved in a folder you pick or copied to paste elsewhere. Your journal goes in backups, and moves with a book whose file you replace.
- Settings, Journal: change the questions, add your own (answered in words, or by a tap on answers you set), and, if you like, a quiet offer to write at each chapter's end. It is off unless you turn it on; the voice never stops for it.

#### The notebook look
- A Notebook paper among the reader's pages (Aa, Read): cream, squared in blue-grey, a fountain pen's ink and a red pen for the voice; as two pages (a tablet, a phone on its side), a spiral binding down the middle.
- A book's Contents with parts has a coloured tab for each down its side: a tap opens the part, and the part in view stands out. Each part's divider carries its tab's colour.
- The handwriting is Caveat (SIL Open Font License), listed in About with the other fonts.

#### Reading comforts
- The reader's top bar has a Contents button. With room (a tablet, a phone on its side) it has Scroll or Pages too, and a PDF its Contents beside its real pages. Layout is now first in Aa, Read.
- Weight (light to bold) and letter spacing for the page's type, in Aa, Read.
- Your own font: add a .ttf or .otf file under the fonts in Aa, Read. It is kept with your library, so a backup carries it.
- Replace the file (a book's menu): pick a corrected edition and it takes the book's place. Your place, quotes, bookmarks, voices, rules and shelf go with it, found again by their sentences.
- Natural voices has a search field: a name, a language, an accent ("british") or "female".
- **Your own chapters for a TXT book:** a web novel saved as one file often heads its chapters in a way TomeVoice does not know ("#12 The Gate"), and was read as one long chapter or as parts that start mid-chapter. A TXT book's page has **Chapters**: found by TomeVoice, at lines that start with what you type (or match a regular expression, such as `^#\d+`), or every 1,000 to 5,000 words. It shows how many chapters that makes and their first titles before anything changes. The book is split again; your place, bookmarks and quotes stay with their words, and the choice is kept with the book (in backups too).

#### Catalogues
- Project Gutenberg opens its new catalogue (OPDS 2), as its older one is retired in 2027: Recently Added, Most Popular, its bookshelves and subjects, search, and each book's EPUB with its cover. If the new one cannot be had, the older one opens as before. Any catalogue you add that speaks OPDS 2 now opens too, instead of saying TomeVoice cannot read it yet.

#### Formats
- DjVu books (.djvu, .djv) open, read by the hidden text under their pages: the OCR that archive.org's scans, and most others, carry. Its paragraphs are kept, running heads and page numbers left out, words broken at line ends mended, and its bookmarks become its chapters. A DjVu whose pages are only pictures says so instead of opening empty, and one kept as a file a page asks to be bundled into one file first.

#### Fixes
- A chapter picked in the reader's own Contents, a bookmark from its list, or a passage found by its search is only looked at while the book is listened to, as the same picked from the book's page already was in 1.5.0: the voice reads on (or stays paused) at its place, and Back to reading returns to it. Before, the voice went there. Meanwhile the player names the chapter the voice is reading ("READING CHAPTER III") in every book, not only in a web novel.
- Replacing a book's file no longer leaves its page with nothing under it: Back goes to the library again.
- On the scroll, Back to reading (and the other pills) goes with the bars, as on pages. Before, it stayed half faded at the foot of the page with the bars gone.
- The app no longer closes when a web-novel site loaded through the hidden web view answers after the source that asked for it has stopped (a check that timed out, a source closed meanwhile). Seen once on 11 November; Flutter's engine ended the whole app.
- Report a problem sends only the errors of the version you run. An older version's errors are counted, not sent again: issue #28 (1.5.0) carried the same 1.4.1 error as #24 and #25, fixed in 1.4.2.
- Crashes in the app's native code, and Android closing the app for not responding, now reach the error log (Android 11 and later): they never did, so a report could not show them.

## 1.5.0 (2026-11-18)

Smoother, lighter on the battery, and a voice that reads "..." and commas as people do.

#### Looking at another chapter
- A chapter picked from a novel's list (or Contents, a bookmark, a passage found) is only looked at: the voice reads on where it is, or stays paused there, and Continue goes on from the voice's place, not from the chapter opened. Only Read from here moves it. Back to reading returns to the voice. In a book only ever read by eye, the place still follows what you open.
- Meanwhile the player is the voice's: it says which chapter is being read, shows Pause while it reads, and its buttons and scrubber move the voice. A tap on it goes back to the voice.
- A tap on the reading card in the notification shade opens the book where the voice is reading, not the page of the app last shown.

#### Listening
- "I... I don't know" is read as one sentence, not "I..." rushed on its own; ". . ." is one mark. Your books, and web-novel chapters already downloaded, are split again when you open them.
- Natural voices no longer pause twice at a comma (their own pause and the one set): the pause set is how long it is in all. A long sentence is made in pieces only over 200 characters, so there are far fewer short silences mid-sentence.
- Where a quote meets its narration in two voices, each side's silence is trimmed and they are always a tenth of a second apart: no half-second gaps, no words run together.
- "well-known" has no pause in it; a dash set apart by spaces has one.
- The word being read stays lit over long clauses (up to 6 seconds without a pause), and a phone voice's word positions that cannot be read for sure are worked out from the audio instead of lighting only the sentence.

#### Smoother
- Upright, the top bar and the player slide over the text instead of resizing it: they come and go smoothly while the voice reads.
- Following the voice moves the page a little at a time, gently, instead of three quarters of a screen at once.
- Now Playing's cover is blurred once, not on every frame.

#### Battery
- With the screen off, nothing redraws the voice's glow, and the player is checked a few times a second instead of 25.
- On Android 12 and later the voice plays through the phone's power-saving audio output.
- Your place is saved every half minute while the voice reads (and at once when it pauses, stops or changes chapter), not after every sentence.

## 1.4.2 (2026-11-18)

Web novels open where you ask, and keep going.

#### Fixes
- A chapter picked from a novel's list (or a bookmark, a passage found, a chapter in Contents) opens there. Before, a book left playing or paused in the background opened at the voice's place instead. While the voice reads, the page shows the chapter picked and the voice reads on; Back to reading returns to it.
- A chapter already on the phone opens at once. Before, the reader first fetched the next three chapters, showed "Fetching chapter 4…" meanwhile, and said it could not open the chapter if one of them failed.
- Reading aloud goes on into the next chapter when a chapter after it cannot be had. If the next one itself cannot be had, it reads on at the next chapter on the phone; if there is none, it says the site failed rather than that the novel has ended.
- A novel's download line counts "3 of 10", lets go of chapters something else downloaded meanwhile (they were shown as still to come until Cancel), ticks each chapter as it comes, and says when it waits for a site that asked for a rest instead of spinning.
- In a book you have listened to, a scroll or a page turned by hand only looks around: the voice's place stays, and Back to reading returns to it. Only Read from here moves it. A book only ever read by eye keeps its place where you are.
- Settings' cards reach closer to the screen's edges.
- Open with TomeVoice is offered for AZW3 files that file managers label as KF8 (application/vnd.amazon.mobi8-ebook).
- A tap on a PDF's real page that went away under the finger (the voice turned it) no longer crashes the app ([#24](https://github.com/Sayandeep1013/TomeVoice/issues/24), [#25](https://github.com/Sayandeep1013/TomeVoice/issues/25)).

## 1.4.1 (2026-10-31)

Fixes from the first day of 1.4.0 on a phone.

#### Fixes
- Updates has **Clear the list**: the list of new chapters empties (with Undo). The chapters stay in their novels, downloaded or not, and checks and downloads go on as before.
- On a PDF's real pages, press and hold offers what to do there (read from the top of the page, or pick a sentence on it, shown as text) instead of reading from the top at once.
- Back with the menu open closes the menu. On Android 16 it took TomeVoice to the background with the menu still open.
- The forms for a catalogue (a Calibre library, Add a catalogue, signing in) and for sync have room between their fields.
- Standard Ebooks' whole catalogue says what its Patrons Circle is before it asks for an email.
- A source update that fails because the site sent a web page instead of its data says so in words, not as a "SyntaxError".
- OCR tells the text engine what resolution a page was drawn at; told nothing, it took a 300 dpi page for 70 dpi and misjudged the size of everything on it.

## 1.4.0 (2026-10-31)

The biggest TomeVoice yet: save a book as an audiobook, a voice for each character, an EPUB's own narration, reading that goes on when you leave the app, web novels that look after themselves, a library you can organise, and your own colours.

#### Listening
- **Save as audio:** a chapter, or a whole book as an M4B audiobook or an MP3, its chapters marked. Swiped away from Recents, it goes on saving. A book on a secret shelf is never named in its notifications.
- **A voice for each character** (experimental): a book's page, and the reader's voice sheet, list who speaks in it, found from its speech tags, and each one's lines can have a voice of their own, aloud and in Save as audio. English books; a line it can't place stays in the dialogue voice.
- **An EPUB's own narration:** a book that comes with a recorded narration (EPUB 3 Media Overlays) can play it, its words lit as they are said, at any speed without the pitch changing.
- **Reading from outside the app:** swiped away from Recents, the book reads on, into a web novel's next chapters too with the screen off; the media card and a headset's Play pick it up with the app closed; Android Auto lists your books. Battery help in Settings → Listening.
- **Natural voices in 42 languages**, about 180 of them, with Kokoro and Kitten for fast phones.
- **Pronunciation lists** shared as a file and taken in, and **what the voice skips**: authors' and translators' notes, rows of symbols and chapter titles said twice, for every book or one (Settings → Reading rules). Off unless you turn them on.
- **Read notes aloud**, a sleep timer that fades out, quicker jumps with natural voices, and nothing running while paused.

#### Reading
- **Light:** the page dims below the phone's lowest brightness, and warms for the night (Reading settings → Read).
- **Auto-scroll** for reading without the voice, in scroll or in pages.
- **Reads anything you share:** links read as articles (a Wikipedia page whole, without its lists of sources), shared words as books, or Paste a link or text.
- **Highlights** in four colours, exported with your quotes as Markdown.
- **A PDF's real pages** zoom, go dark at night, and can crop their margins so the print fills the phone.
- **A short guide** on a new install's first launch.
- The player's chips and scrubber, and choice rows, answer taps in a band around them; a long web novel reads straight on across its chapters with no pause or flash.

#### Your library
- **Tags and series:** give a book as many tags as you like, and a series with its number (from an EPUB's or FB2's own details, or the words several of your books' titles share, so "A Game of Thrones A Song of Ice and Fire 1" and its fellows are one series, in order). Sort by author or by series, and filter the shelves by progress, format, language, tag or series. Nothing of a locked secret shelf shows in any of them.
- **Find duplicates:** a book you add that looks like one you have, in another file or format, is offered to you, never merged.
- **Your own colours** beside the themes, kept readable, and a theme in your wallpaper's colours on Android 12 and later. Small type, icons and controls meet the WCAG AA contrast standard in every theme, the word being read too.
- **OPDS catalogues**, **automatic backups** to a folder (a secret shelf left out unless you say otherwise), and opt-in **sync** through your own WebDAV server or a KOReader server.
- **OCR** for scanned PDFs, on the phone, Bengali included.
- **Report a problem** from an error log you read before sending, and a settable streak goal.
- **Saved** clears the quotes of books no longer in your library together.
- The place is kept at once in the book's own file and written into the library list every few seconds: on 1,000 books, each saved place costs about a tenth of what it did.

#### Web novels
- **Look after themselves:** new chapters checked with the app closed, or in the background; a download queue that keeps going; new chapters that download by themselves for the novels you choose (on Wi-Fi only, unless you say otherwise).
- **Move a novel to another source** with its place, downloads, quotes, read marks and voices; **mark chapters read or unread**; **export the downloaded chapters as an EPUB**; **sign in to a source's site**, the sign-in kept for that source only.
- Each site runs in its own sandbox, off your home network, its code checked before it runs. NovelUpdates has no API for apps, so it gets a link to find each novel there, not tracking.

#### Documents
- A scanned PDF's bookmarks named after its pictures are no longer its chapters. Two speakers' lines in a PDF are two paragraphs. A note's raised number is shown, not said (a power like m² still is). Kindle AZW3 notes are shown, not read. Russian and Ukrainian dialogue isn't cut after "!" or "?". Transcribers' notes aren't read; an RTF file's notes are shown; a Word or ODT table of data is read a row at a time; a Gutenberg text is named by its header.
- Thirteen fixes found by a new set of real books in the tests.
- Your books are read once more when you open them, to take these fixes, and keep their places.

#### Fixes
- A backup made to look like TomeVoice's can no longer delete your library on Replace.
- Moving your default shelf into a secret one takes all its books with it.
- A sleep timer set to the chapter's end pauses only when the voice gets there, not when you move to another chapter, and Now Playing shows when it has paused.
- With Read notes aloud on, the little arrow at the end of a note that leads back to the text (as in Standard Ebooks) is shown but not read out.
- Before release, a fresh review of all the new code found 47 problems, in sync, backups, the sources' sandbox, OCR and the reader. All are fixed.

## 1.3.0 (2026-10-30)

A steadier TomeVoice: the book keeps reading when you leave, documents read the way they are written, and your backups and secret shelf are safer.

#### The book keeps reading
- **Back at the library no longer stops the book.** On Android 14 and 15 it closed TomeVoice and the voice with it, and on Android 16 it did when another app had opened TomeVoice. Back now puts TomeVoice behind, as Home does.
- **A book opened from Files or your browser goes to the TomeVoice you already have open**, instead of starting a second copy that could lose a book you had just added.
- Calls and other apps' sound pause the voice and give it back properly, the phone stays awake while a sentence is made, and a voice that fails says so instead of going quiet.
- Natural voices recover when their worker dies, stop between clauses when you pause, and download safely.
- **A speed for this book only**, skip buttons, and the highlight's timing are remembered per book. The book page, the shelf and the player agree on the time left at that speed.
- Loudness is levelled by measure without distortion, and the highlight follows the voice's pauses, Chinese and Japanese included.

#### Documents
- **Footnotes stay on the page, in small type, and aren't read**, and their little numbers are silent. A long link is read as its site, and a citation like [12] is skipped.
- **PDFs** take their chapters from their bookmarks, leave out running heads and page numbers, keep footnotes and two-column pages in order, and give most speakers' lines their own paragraph (a few longer ones still run together). A PDF that is mostly scanned pictures says so. Your PDFs are read once more when you open them, and keep your place.
- **EPUB** chapters follow the book's own contents, a collection opens on its title story, and books with hidden fonts are no longer refused as DRM.
- **Kindle AZW3 books** open by their chapters, and a cut-short file says so.
- Text saved in an older encoding (Shift_JIS, Big5, Windows code pages) reads as written. Word and Markdown marks aren't read, sentences end where they should in more languages, and Bengali and Hindi words keep their vowel signs.
- A song or a picture picked by mistake is refused with a reason.

#### Your library is safer
- **Backups leave out the downloaded natural voices** (64 to 110 MB each) and warn when they include a secret shelf. Restoring with Add keeps your quotes, stats and reading rules, and takes the backup's settings only if you ask.
- **A book on a secret shelf asks for the lock** when its file is opened again from another app.
- A damaged entry no longer empties the whole shelf, a restore stopped halfway is finished or undone cleanly, and files picked together never overwrite each other.
- Big books import in less than half the memory.

#### Reading
- **Look up a word, or translate its sentence**: press and hold.
- **TalkBack reads the pages, and turns them.**
- **Right-to-left books** (Arabic, Hebrew, Persian) are set and turned right to left.
- Turning the phone or changing the text size keeps your sentence on the page.
- In scroll mode, Papyrus and Ink pages keep their own ink at night.
- **Start from the beginning can be undone.**

#### Smaller things
- About no longer has a Support row, until there is somewhere to send it.
- The app is 4 MB smaller.

## 1.2.2 (2026-10-29)

A small update: the support QR is gone for now.

#### Changes
- **About → Support TomeVoice** no longer shows a UPI QR. The row stays, but it does nothing for now while a better way to support TomeVoice is worked out. Nothing else in the app changes.

## 1.2.1 (2026-10-29)

Changing how the page looks no longer loses your page, and a quiet way to support TomeVoice.

#### Fixes
- **Changing the page theme keeps your page.** Switching between Theme, Ink, Papyrus and Dusk in the reading settings could throw you back to an earlier page (where you opened the book, or where you turned pages on), especially with the voice paused. The page now stays exactly where it is, in pages and in scroll.
- **Papyrus and Dusk run edge to edge.** A darker strip showed beside the camera cut-out on a phone held sideways (and under the status and gesture bars upright). The paper now reaches the screen's edges in one piece.

#### Support TomeVoice
- **About → Support TomeVoice** opens a UPI QR, if you'd like to help keep TomeVoice free. **Pay with UPI** lets you pick any UPI app on your phone (PhonePe, GPay, Paytm…), and **Save QR** puts it in your gallery to scan from another phone. Entirely optional; nothing in the app changes either way.

## 1.2.0 (2026-10-29)

Pages that keep time with the voice, a fast way through long books, and shelves only you can open.

#### Pages turn with the voice
- **Listening on pages, the page turns as the voice reads onto the next one**, not as soon as it begins the last sentence of the page. A sentence that runs over the foot of a page is read to the end of the page before it turns.
- Pressing Play on a page that starts mid-sentence no longer turns back a page, and reading on into the next chapter curls onto it like any other page.

#### Fast scroll
- **A thumb at the right edge of long lists**: a web novel's 3,000 chapters, a book's chapters, Contents, and the text of a long book itself. Drag it to go straight there; a bubble names the chapter you've reached.

#### Secret shelves
- **Shelves that open only with your fingerprint, face or phone PIN**, and lock again the moment you leave TomeVoice.
- While locked, their books are nowhere: not on the shelves, in search, History, Saved, Stats, Updates or the home-screen widgets. The lock-screen player says only "TomeVoice" for them, and Recents shows a blank card while they are open.
- **Settings → Secret shelf** makes one, or moves whole shelves into secret (tick as many as you like; their books go with them). The quiet way in: press and hold the word **Library**. Back on a secret shelf goes to your usual shelf first.

#### Smaller things
- The voice's glow fades away with the player when you tap to read alone, and on pages it rises softly from behind the player instead of showing as a band at the bottom edge.
- No more faint line under the player in scroll mode.

## 1.1.1 (2026-10-28)

Read with nothing but the page.

#### Tap to put the bars away
- **A tap on the text hides the top bar and the player** while you read by scrolling, and the text takes the whole screen. Tap again to bring them back. The voice keeps reading and highlighting while they're away.
- A tap that only stops a fast scroll just stops it; it doesn't hide anything. Press and hold still opens Read from here, quotes and bookmarks.
- On its side, the floating player slides away too. Pages already worked like this with a tap in the middle of the page.

## 1.1.0 (2026-10-27)

Your phone's voices, at their best, and every web novel in its own language.

#### Phone voices sound as they should
- **Google's voices now sound the way Google plays them.** A pitch other than 0 makes Google read with an older, rougher version of the voice, and TomeVoice used one pitch for every voice. Now each voice keeps its own pitch, starting at 0, so the voice packs you download in Google's settings (Bengali, Hindi, English and the rest) sound as good in TomeVoice as in Google's own sample.
- **Pitch is per voice.** Set it in Fine-tune for the voice you are using; other voices keep theirs. On a Google voice, Fine-tune tells you what a pitch away from 0 costs. A pitch set before this update starts again at 0.
- **No voice listed twice.** Google's "Default voice" was the same speaker as one of the others; each language now shows its speakers once, as Google's settings do.

#### Web novels in their own language
- **A novel's language comes from its chapters**, not from the site's label. A Bengali novel from a source the app did not know showed "Book: English" and opened the voices on English; it now says Bengali, offers Bengali voices first, and the library card agrees.
- **English books read in English again.** A voice chosen for one language no longer becomes another language's default, so a Bengali voice picked for a Bengali novel stays with that novel.

## 1.0.9 (2026-10-27)

Bookmarks for readers, and nothing left lying on your page.

#### Bookmarks
- **Bookmark a page with one tap.** The bookmark at the top of the reader marks the page you are on (both pages when the book lies open on its side, a PDF's page, or the paragraph you are reading when you scroll). It fills in while the page has one; tap it again to take it off, with Undo.
- **See them as you read.** A ribbon in the page's corner, or beside the paragraph when you scroll, in the book's colour.
- **Every bookmark in one place.** Hold the bookmark button for the book's bookmarks in order: tap one to go there (and back again with one tap), or remove it.
- Where you stopped reading is still kept on its own: a book always reopens where you left it.

#### A clearer page
- **In pages, "Back to reading" no longer covers the words.** It shows with the top bar and the player, when you tap the middle of the page, and goes when you turn the page.
- **Contents is the book's title.** Tap the title and chapter at the top (now with a small arrow) for the contents.
- After a jump to a chapter or a bookmark while the voice was paused, **Back to where you were** now takes you back.

## 1.0.8 (2026-10-27)

Read a book in pages that turn like paper, keep listening after you leave it, and a smoother app all round.

#### Made for reading, too
- **Pages that turn like paper.** Turn a book into pages (Aa → Layout → Pages): the corner follows your finger and the page curls over, its back showing through. Or slide, or turn at once. Tap the sides, swipe, or use the volume keys.
- **An open book on its side.** Turn the phone and two pages lie open with a crease between them; the right page turns over the spine. A PDF's real pages turn the same way.
- **Four papers.** The app's colours, Ink, Papyrus, or a dim Dusk for reading in the dark.
- **Your place follows your reading.** Scroll or turn on without the voice and that is where you are: the book reopens there and Play starts there. After a jump from Contents or a search, one tap takes you back.
- Above each page the chapter's name, below it the minutes left in the chapter and the page count. Paragraphs spaced or indented like a printed book, and full screen.

#### Keeps reading when you leave the book
- **Back goes to your library while the voice reads on.** Pause it from the library's player or the notification; open the book again and it is still reading, with no break. On by default (Settings → Listening).
- **The library's player plays right there.** Its button reads the book aloud without opening it; tap anywhere else on it to open the book where it is being read.

#### Voices
- **Natural voices start sooner and keep up.** A voice is loaded while a book opens, and speech you are waiting for is made first.
- **Find a voice or language by typing.**
- **Online voices are given a second chance.** A line with nothing to say is passed over, and a voice that cannot reach the internet is asked again before reading stops, with a message saying why.

#### Also
- A web novel's chapters keep the order you sorted them in.
- NovelDokusha's own books (EPUBs you imported there) now come across too, as books.
- Smoother everywhere: the screens behind the reader no longer reload every second or so while it reads, the shelves, Browse, Updates, History and Saved stop cutting, opening a book and a web novel's next chapter no longer flash, and Now Playing glides without jumps.

## 1.0.7 (2026-10-25)

Now Playing shows the page around the voice, the glow is one soft haze, and everything that used to snap now moves.

#### Now Playing
- **The page around the voice.** The cover above whole paragraphs, the sentence being read lit with its word in the book's colour, and the text before and after fading away as it glides along. Tap a sentence to read from it, hold it for a word. On its side, the cover sits beside the page.
- **The glow is one soft haze.** No bar along its edge any more and no separate spikes. It rises behind the player as the voice speaks and runs to the screen's edges. It also costs a fraction of what it did, so nothing else slows down while it plays.

#### Smoother
- **Back to reading scrolls the way to the voice.** Up if you read on past it, down if it's ahead, from close by or from far away, instead of jumping.
- **Natural voices no longer make the screen stutter.** They make speech at a lower priority, so scrolling and animations keep moving while one reads.
- **A pass over every screen.** What snapped now moves:
  - Play and pause turn into each other, the chapter bar glides from sentence to sentence, and progress bars move.
  - Covers fade in. A book's or a web novel's chapters fade in, and its description opens in instead of pushing the list down.
  - Chapter names rise into place, and download marks turn into ticks.
  - Library, Browse, Updates and History fade in from the menu.
  - Search results open in under each source.
- Each library shelf keeps its own scroll place, also when a book is added or removed.

## 1.0.6 (2026-10-25)

A glow that breathes with the voice, a widget cut like a postage stamp, and two fixes you could hear and feel.

#### Reading aloud
- **A glow rises from the player as the voice reads**, as bright as the voice is loud at that moment. It's in the book's colours, sinks to an ember between sentences and fades away on pause. On Now playing it rises from the foot of the screen. There's no glow when the phone is set to remove animations.
- **Voice samples sound right at any speed.** At 1.5× or 2×, "Hear it" and the sample after a setting change came out squeaky and too fast. They now sound exactly as the book will.

#### Updates
- **Pulling down to check for new chapters always checks.** A pull while the check on opening was still running snapped straight back and said "No new chapters." It now waits for that check and says what it found. A pull that starts a little way down the list counts too.

#### Widgets
- **Now reading (stamp)**: the Now reading widget cut like a postage stamp, perforations and all, with the wallpaper showing through. Add it from Settings → Home screen or your launcher's widget list.
- On the 2×2 Now reading, the title and progress line sit a little further in.

## 1.0.5 (2026-10-24)

New versions now ask you properly, instead of a note that was easy to miss.

#### Updates
- **A new version opens a pop-up**: Install, Later, or Skip this version, with a link to what's new.
  - **Later** asks again in three days (or at once, if an even newer version comes out).
  - **Skip this version** stops asking about that one; the next release asks again.
- TomeVoice looks for a new version every few hours instead of once a day, so a release is noticed the same day.
- **Check for updates** in Settings opens the same pop-up.

## 1.0.4 (2026-10-24)

A fix for picking books on the shelf.

#### Library
- **Selecting a book stays on its category.** Pressing and holding a book on any category other than the first one (to move it, say) jumped the shelf back to Reading whenever a book was waiting in the Continue bar. The shelf now stays where you are.

## 1.0.3 (2026-10-24)

Find any chapter in a moment, and web novels that stay in order when the site changes its list.

#### Find
- **Find a chapter**: the search button on a book's page now finds a chapter by its number or words from its title. Type 2000 and Chapter 2000 is the only one left; tap it to read. The same for EPUBs, other files and web novels.
- **Find a passage**: searching the text for a line or a quote you remember is now in the page's ⋮ menu, and web novels have it too (it searches the chapters on the phone).
- A web novel's **Contents**, inside the reader, lists every chapter the site has, not only the downloaded ones; the one you pick is fetched and opened.

#### Web novels
- **Chapters open the chapter you tapped.** When a site took an entry out of its chapter list (Shadow Slave lost a duplicate of 3115), the chapters already downloaded stayed where they were, so tapping 3222 opened 3221. Downloads, your reading place and saved quotes now move with their chapter, and novels already affected are put right the first time they open.
- A chapter list a site sends back cut short no longer replaces the one on the phone.

#### Your library's files
- Two saves at the same moment (your place while a book is being imported, say) can no longer undo each other and make a book vanish from the shelf.
- A damaged library list, settings, stats or pronunciations file is kept beside it as `.broken` instead of being written over with an empty one, and a book whose stored copy was cut short opens from its own file.

## 1.0.2 (2026-10-24)

Look around a web novel without losing your place.

#### Reading
- **Every chapter opens the same way**: a line and its title in the book's colour, so a new chapter is never scrolled past unnoticed (before, only the chapter being read was coloured).
- **The line under the title follows your scrolling**: it names the chapter on screen and its number (3222/3223), while the player keeps showing where the voice is.
- **Play takes you back**: after scrolling away, Play (or **Back to reading**) returns to the sentence where reading stopped and carries on from there.
- **Next chapter** at the end of the page now only looks ahead; your listening place stays where it was.
- Chapter numbers in a web novel's contents match the site's list, and a title that already has its number isn't given a second one. The chapter count no longer gets cut off in portrait.

#### Smoother and safer
- Cancel on an update download now stops it at once, even when the connection has stalled; a server that never answers gives up after 30 seconds.
- A web novel's chapter list and your reading place are saved in a way a crash can't corrupt.

## 1.0.1 (2026-10-23)

Quotes you can shape and annotate, saved lines on each book's page, and natural voices you can hear before downloading.

#### Quotes
- **Save as a quote** now opens a small sheet: take in the sentence before or after (up to eight in all), add a note, then Save. Undo still follows straight away.
- **Notes** show under the quote in **Saved**, where you can add or change one at any time. Search finds them too.
- **Each book's page** (and each web novel's) shows the latest things saved from it, with **See all** for the rest.

#### Natural voices
- **Settings → Natural voices**: tap ▶ beside a voice to hear its own sample before downloading it (about 100 KB, streamed).

#### Smoother and safer
- Now Playing's sentence change no longer shows the old and new lines on top of each other.
- In long paragraphs, the page now follows the sentence being read instead of leaving it below the screen.
- Saved quotes, settings and stats are written in a way a crash can't corrupt.
- Restoring a backup someone else gave you can no longer touch anything outside your library, and an update is only installed if it really is TomeVoice.
- Many smaller fixes: the sleep countdown in the player bar now counts down, a long paragraph of straight-quoted dialogue keeps its dialogue voice, and a double tap opens a book only once.

## 1.0.0 (2026-10-23)

TomeVoice 1.0: keep the habit, put it on your home screen, and, if you want them, voices that sound like people.

#### Listening stats and streaks
- **Menu → Stats**: this week's minutes day by day, the last twenty weeks as dots, totals, and the books you've listened to most.
- **A streak** counts the days you listen for at least 5 minutes. A day runs until 4 am, so a late chapter still counts for the night before.

#### Home-screen widgets
- **Player**: the book you're reading, its cover in a ring of dots that fills as you go, and play. Play starts reading without opening the app; pause stops it. The wider sizes add the chapter and chapter back and next. Choose *Most recent* or pin one book.
- **Streak**: the days so far, today's minutes and the week; the wider sizes add the last weeks as dots.
- Both come in every size, from a thin strip to a large card, in the book's colours. Add them from **Stats**, **Settings → Home screen**, or the launcher's widget list.

#### Natural voices (optional)
- **Settings → Natural voices**: seven voices made on the phone itself, with no internet once downloaded (Kristin, Norman, Alan, Jenny, Cori, and Lessac and Ryan in HD).
- They're **off unless you choose them**. Each is a 64 MB download (110 MB for HD) and works the phone harder than the built-in voices, so the app says so before anything downloads. *No thanks* hides them completely.
- After a download TomeVoice tests how fast your phone runs the voice. **Remove** or **Remove all** takes them off the phone at any time.

#### Dialogue in a second voice
- In **Listen**, pick a **Dialogue voice**: words inside quotation marks are read by it, the rest by the narrator. Choose it per book.

#### Also new
- **Read from here**: press and hold any line and pick *Read from here* to jump there. A tap on the text no longer moves the reading, so scrolling can't send it somewhere by accident.
- **Undo** right after saving a quote or bookmark, and a **Remove** button on each item in Saved.
- **Now Playing**: press and hold a line for the same menu as the page (save, bookmark, share, copy, fix how a word is said). The line now moves up smoothly when it changes.
- **A book's page** keeps Back, Search and the menu at the top however far you scroll.
- **Landscape**: the player floats under the text as one bar with every control, so the text keeps the screen.
- **Updates install from the app**: when a new version is out, tap **Install** and confirm Android's prompt.
- A smaller download: about 27 MB.
- Fixed: with a natural voice and a dialogue voice, reading could skip two or three lines after a jump.

## 0.8.0 (2026-10-23)

Find anything in a book, keep the lines you love, and make the voice say names right.

#### Search
- **The search button in the reader** looks in this chapter first; one tap on *Whole book* widens it. Results come grouped by chapter with the words around each match. Pick one and step through the rest with ↑ ↓.
- **From a book's page**, search starts on the whole book.
- Case and accents don't matter (*cafe* finds *café*); *Whole words* keeps *cat* from finding *concatenate*. In web novels the chapters on the phone are searched, and it says how many.

#### Saved: quotes and bookmarks
- **Press and hold a sentence** to save it as a quote, bookmark the place, copy it, or share it.
- **While listening**, tap *Save* in Now Playing, or the new **Save** button on the lock-screen player, to keep the line being read.
- **Menu → Saved** lists your quotes and bookmarks by book. Tap one to open the book right there; swipe to remove (with Undo).
- **Share as a picture**: the quote in the book's colours, as a post or a story, to WhatsApp, Instagram or anywhere.

#### Say it right
- **Press and hold a word → Fix how it's said.** Type it the way it sounds (*Zor-ee-an*), hear it, save it, for one book or every book. The page keeps the real spelling and the highlight still follows the word.
- **Web novels: press and hold a line → Don't read lines like this.** Notices, credits and links are left out from then on, in chapters already downloaded too.
- **No more doubled chapter titles**: when a chapter's first line repeats its title, it becomes the heading, heard once and shown once.
- All of these are listed, and can be removed, in **Settings → Library → Reading rules**.

## 0.7.0 (2026-10-23)

Every book in its own colours, a Now Playing screen, and a proper landscape.

#### Colours from book covers
- **Each book takes the colour of its cover:** its page, its reader (the sentence being read, the player, the sliders), its sheets, and its tile on the shelf.
- **The app follows the book you're reading.** Open a blue book and the library turns blue; open another and it eases across. The colour is picked from the cover the way Android picks colours from your wallpaper, with contrast kept readable. A grey cover keeps the theme's colour.
- Turn it off in **Settings → Appearance → Colours from book covers** to go back to the theme's accent.

#### Now Playing
- **Swipe up on the player** (or tap its handle) and the book fills the screen: the cover over a blur of itself, the title and chapter, and the words scrolling like lyrics. The sentence being read is large, with the word under the voice lit; tap the sentence before or after to read from it.
- Chapter bar, time left, play, sentence and chapter skips, and speed, sleep timer and voice, all one tap away. Swipe down to go back.

#### Landscape
- **The reader** puts the player in a rail down the right, so the text keeps the full height (the player used to take half of it).
- **Book and web novel pages** show the details beside the chapter list.
- Now Playing puts the cover beside the words.

## 0.6.0 (2026-10-23)

TomeVoice's permanent home. Ready to share.

#### Moving over from 0.5 or earlier (once)
TomeVoice now has its permanent app id, so Android installs 0.6 as a **new app** beside the old one.
1. In the old TomeVoice, update to [0.5.1](https://github.com/Sayandeep1013/TomeVoice/releases/tag/v0.5.1) and tap **Settings → Back up library**.
2. Install 0.6 and open it. It offers **Restore**: pick your backup and choose *Replace my library*. (Or Settings → Restore a backup.)
3. Check your books, then uninstall the old TomeVoice.

From now on every update installs over this one and keeps your library.

#### New
- **Older phones:** `TomeVoice-0.6.0-32bit.apk` is for 32-bit and Android Go phones, where the main APK says *App not installed*.
- **A new install starts ready:** *Pride and Prejudice* plus two web novels on the shelf, and an offer to restore a backup if you're moving from another phone.

## 0.5.1 (2026-10-23)

Back up your library, and hear about new versions. **Install this before 0.6**: 0.6 becomes a new app on your phone, and a backup made here is how your library moves over.

#### Back up and restore
- **Settings → Library → Back up library** saves one file with your books, places, categories, sources, settings and downloaded chapters. Choose where it goes: Downloads, Drive, anywhere Android offers. Leave out downloaded chapters for a smaller file; they download again after a restore.
- **Settings → Library → Restore a backup** brings one back. *Add to my library* adds the books you don't have and, for books in both, keeps whichever place is further. *Replace my library* swaps everything for the backup. The app restarts when it's done.

#### New versions
- TomeVoice checks GitHub once a day for a newer release and tells you once per version. Turn it off in Settings → About. **About TomeVoice → Check for updates** checks right away.

#### Coming in 0.6
TomeVoice gets its permanent app id. Android will treat 0.6 as a new app, so: back up here first, install 0.6, restore your backup in it, then uninstall the old one.

## 0.5.0 (2026-10-23)

A player in the notification shade worth looking at, and fixes found testing on a real phone.

#### The media player in the shade and on the lock screen
- **The book's cover** is the player's picture, and the player takes its colours from it.
- **A bar through the chapter.** See how far into the chapter you are, and drag it to jump.
- **A speed button** that shows the speed and steps through 0.75×, 1×, 1.25×, 1.5× and 2×.
- **Previous and next go by chapter.** Previous goes back to the start of the chapter first, as a music player does.
- **The TomeVoice mark** sits top left. It used to show a play or pause sign the wrong way round, which looked like a second button that disagreed with the real one.
- Skipping from the player while paused keeps it up, paused, at the new chapter.

#### Fixed
- A web novel whose site isn't installed (for example one imported from NovelDokusha) showed a technical error when you pulled its page to check for new chapters. It now says the source isn't installed and offers to install it, and downloads do the same.
- The Download button in the chapter selection bar was cut off ("Dow…").

## 0.4.0 (2026-10-23)

Web novels you can listen to, a new look, and a shelf you can organise.

#### A shelf from the first launch
- A new install starts with *Pride and Prejudice* (public domain, Hugh Thomson's peacock cover) and two popular web novels, *Shadow Slave* and *Lord of the Mysteries*, with their covers and chapter lists. Remove any of them like any other book. Updating from an earlier version leaves your library as it is.

#### Web novels
- **Browse and search web novel sites.** Sources comes with LNReader's list of some 300 sites; install the ones you read (or add your own list), then search them all at once from Browse, or open one site's popular and latest novels.
- **Add a novel to your library** and listen to it like any book. Chapters are fetched as you go and a few ahead, and the reader continues into the next chapter by itself. Download any chapter with the button on its row, or the next 10, 50 or all of them from the novel's menu, and listen offline. Pull the novel's page down to check for new chapters.
- **New chapters.** TomeVoice checks the novels in your library when you open it (every 12 hours, daily, every 2 days, weekly, or never; Settings → Library) and lists what's new under Updates.
- **Sites behind Cloudflare** are read through the phone's own browser engine. If a site asks you to tick a box, the novel's page offers to open its check.
- **Import from NovelDokusha.** Settings → Library → Import from NovelDokusha takes its backup zip: novels, chapter lists, the chapters it had downloaded, and where you were.
- The sites belong to their owners.

#### New look
- Clean motion throughout: screens fade through, covers fly to the book's page, choices slide, and themes cross-fade.
- **Fashion-magazine type:** Bodoni Moda for titles, Figtree for everything you tap, and Newsreader for the page (or Literata, a sans, or your phone's font).
- One consistent design everywhere: the same corners, spacing, sliders, switches, menus and sheets on every screen. Light and dark both follow it.
- **Colour themes:** Forest, Lavender, Ocean, Black (pure black for OLED screens) and Paper (warm sepia). Pick one in Settings → Appearance. Light, dark or your phone's setting still applies to the themes that have both.

#### Library
- **Cover tiles.** Title, author, format, language, length and progress sit on a translucent band at the foot of each cover. The list view is still one tap away.
- **Categories.** Reading and Later to start, both renamable. Make as many as you like, reorder them, and set where new books go. Swipe sideways to move between them.
- **Pick chapters.** Long-press a chapter on a novel's page, tap more, then download or remove them together.
- **Select several books.** Long-press a book, tap more, then move or remove them together.
- **Continue where you stopped.** The books you're in the middle of wait at the bottom with a play button. Swipe between them.
- **Menu and settings.** The menu at the top left has History, Categories, Settings and About. Add books, view and Settings sit at the top right.

#### Each book has its own page
- Cover, description, category, and every chapter. **Continue** picks up where you stopped; any chapter opens the reader right there.
- **Each book can have its own voice.** Choose one on the book's page and hear a sample first.

#### Reading and listening
- **Reader settings in two tabs.** Listen: speed with − / + and presets, the sleep timer, voice, style and fine-tune. Read: text size, font, line spacing, margins, justified text, keep screen on, and the PDF page view.
- **Readable voice names.** "English (UK) · Voice 2" instead of engine codes, grouped by region. The list no longer jumps when you pick one.
- **Hear before you choose.** Picking a voice says a line in it, and changing speed or style plays a short sample when the book isn't already playing.
- **Calmer page.** Text fades under the bars instead of being cut off, and decorative ornaments no longer show as white strips.
- **History.** Everything you've opened, by day, with one-tap resume.

#### Fixed
- Landscape no longer leaves a dark strip by the camera.
- A stuck speech-engine call can no longer silence the rest of a book.

## 0.2.1 (2026-10-23)

Small fixes on top of 0.2.0.

#### Fixed
- **The shelf order follows the book you just closed.** Coming back from the reader, that book moves to the top and its progress is current straight away, instead of one step behind.
- **Search shows when it is active.** The search box gets an amber outline while you type.
- **No surprise keyboard.** Opening a book from a search no longer brings the keyboard back up when you return to the shelf.

## 0.2.0 (2026-10-22)

The first release of TomeVoice: any book, read aloud, on your phone.

#### What it does
- **Opens almost anything:** EPUB, PDF, DOCX, ODT, MOBI / AZW3, FB2, RTF, HTML, Markdown and TXT. Add several files at once, or open a book from any file manager with TomeVoice.
- **Reads it aloud** with the voices on your phone, choosing one in the book's language (a Bengali book gets a Bengali voice). The sentence being read is marked and the spoken word highlighted, timed from the audio itself.
- **Keeps reading with the screen off**, with pause and resume from the lock screen, notification or headset. It stops for calls and when headphones come out.
- **Pictures in ebooks** (illustrations, maps, covers) appear in the text; tap to zoom. **PDFs** can be read as text or shown as their real pages.
- **Finds the chapters** even when a file does not list them.
- **A shelf that says what each book is:** cover (the book's own, your own picture, or a plain title cover), author, format, language, listening time and where you left off.
- **Voice controls:** speed, pitch, sleep timer, styles, and the gap between words and pauses at punctuation.
