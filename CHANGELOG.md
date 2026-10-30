# Changelog

What changed in each release of TomeVoice, newest first, as each release told it.
Every release has its APK on [Releases](https://github.com/Sayandeep1013/TomeVoice/releases).

## Not yet released

On the `next` branch, waiting for a phone check:

- **Save as audio:** a chapter, or a whole book as an M4B audiobook with its chapters marked, or as an MP3 with its chapters too. Swiped away from Recents, it goes on saving.
- **A voice for each character** (experimental): a book's page lists who speaks in it, found from its speech tags, and each one's lines can have a voice of their own, aloud and in Save as audio. English books; a line it cannot place stays in the dialogue voice.
- **Reading from outside the app:** swiped away from Recents, the book reads on; the media card and a headset's Play pick it up with the app closed; Android Auto lists your books. Battery help in Settings → Listening.
- **Web novels that look after themselves:** new chapters checked with the app closed, a download queue that keeps going, each site in its own sandbox off your home network with its code checked, and a changed chapter list never deletes downloads.
- **Reads anything you share:** links read as articles, shared words as books, Paste a link or text.
- **Highlights** in four colours with Markdown export, **Read notes aloud**, **OPDS catalogues**, **automatic backups**, and opt-in **sync** through WebDAV or a KOReader server.
- **OCR** for scanned PDFs, on the phone, Bengali included.
- **Natural voices in 42 languages**, about 180 of them, with Kokoro and Kitten for fast phones.
- A PDF's real pages zoom and go dark at night; accessibility and contrast fixes; an error log and Report a problem; quicker jumps with natural voices; nothing running while paused; a settable streak goal.
- Thirteen reading fixes found by a new set of real books in the tests: front and back matter, Gutenberg licences, Markdown, ODT and FB2.

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
