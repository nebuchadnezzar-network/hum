# hum — architecture

A terminal Plex music player for macOS. One Swift package, one binary, four
library targets plus the executable.

```
Sources/
├── HumTUI/          terminal: raw mode, cell-diff renderer, input, widgets
├── HumPlex/         plex.tv auth, server discovery, library API, Keychain
├── HumPlayer/       AVPlayer queue, media keys, audio tap, FFT
└── hum/             CLI entry, app wiring, the three-pane browser
```

Dependencies point one way: `hum` → everything; `HumPlayer` → `HumPlex`;
`HumTUI` depends on nothing but Foundation. Nothing below `hum` knows
about layout or key bindings.

## Threading

Three threads, each with one job. This is the central design decision and
everything else falls out of it.

```
┌─ main thread ────────────────────────────────────────────────┐
│ NSApplication.run()                                          │
│   · MPRemoteCommandCenter       (media keys)                 │
│   · MPNowPlayingInfoCenter      (Control Center)             │
│   · AVPlayer + its KVO/time observers                        │
│   · MTKView draw callbacks      (visualizer)                 │
└──────────────────────────────────────────────────────────────┘
┌─ hum.ui ─────────────────────────────────────────────────────┐
│ BrowserScreen.run()                                          │
│   drain events (≤1/30s while playing, ≤1/5s idle)            │
│   → apply to UI state → draw → write ANSI diff               │
└──────────────────────────────────────────────────────────────┘
┌─ hum.input ──────────────────────────────────────────────────┐
│ InputReader.next() blocked in read(2); posts .key events     │
└──────────────────────────────────────────────────────────────┘
```

AppKit and AVFoundation both want the main run loop, so the main thread is
theirs. The TUI cannot share it — it needs to block on its own cadence — so it
gets its own thread, and input gets a third so it can block in `read(2)`
indefinitely without burning CPU.

### How the threads talk

One direction each, and no shared mutable UI state:

- **Into the UI** — `EventQueue`, an `NSCondition`-guarded mailbox. Keystrokes,
  SIGWINCH resizes, playback state, and the results of every network request all
  arrive as `Event` values. `BrowserScreen` owns all UI state and only mutates it
  while applying an event, so the render path needs no locks at all.
- **Out of the UI** — direct calls on `HumApp` / `Player`, which hop to the main
  thread themselves (`Player.onMain`). The UI never has to know.

Async loads carry the id of what they were loading (`albumsLoaded(parentID:)`),
and the handler drops a result whose parent is no longer selected. That is what
keeps fast arrow-key scrolling from being overtaken by a slow response.

## Layout

```
title bar      ─ mark + key hints
visualisation  ─ spectrum bars | oscilloscope       (V switches, z hides)
browse panes   ─ collections │ albums │ tracks │ now playing
lyrics         ─ 4 rows of lyrics, follows the words (L hides)
transport      ─ track, scrubber, controls, volume
status         ─ transient messages, and the search prompt
```

Everything is laid out by splitting a `Rect` from the outside in, in that order,
so the browse panes absorb whatever is left. Two things drop out when space runs
short, in this order: the now-playing pane below 96 columns, then the
visualisation below 14 rows. The visualisation also drops out when nothing is
loaded — with no audio it is seven rows of empty box, and the browse panes can
put them to better use.

Visibility is a separate key from style on purpose. Folding "off" into the style
cycle means switching between two visualisations takes you through a blank panel
to get back, so `V` switches and `z` hides. The three browse panes are what you cannot work
without, so they are never the ones sacrificed.

## Visualisations

Two, because they answer different questions and are not two skins on one
dataset:

- **Spectrum** (`SpectrumMeter`) — *which frequencies are present*. Block glyphs,
  bars two columns wide with a gap, peak-hold caps.
- **Oscilloscope** (`ScopeMeter`) — *the shape of the signal*. Drawn on a Braille
  canvas: each cell carries 2×4 addressable dots, so the trace has eight times
  the vertical resolution of block glyphs and reads as a line rather than a
  staircase. Consecutive samples are joined with a vertical run so the trace is
  continuous.

The scope is trigger-aligned on a rising zero crossing, the way a hardware scope
is — without it the trace slides sideways every frame and is unreadable. It
auto-scales against its own released peak, separate from the spectrum's, because
it works on raw amplitude rather than band energy.

Braille needs a font that carries U+2800–U+28FF. Menlo, SF Mono, JetBrains Mono
and the Nerd Fonts all do; if yours does not, `V` cycles past it.

## Cover art

```
Plex /photo/:/transcode ──▶ ImageIO decode at target size ──▶ PixelImage ──▶ cells
```

Decoding goes straight to the cell grid the art will be drawn at, not to full
resolution. A 40×40 cover is 6KB, so the cache is free, and the expensive scaling
happens once per size rather than once per frame. The cache is keyed on size as
well as source, so a window resize re-decodes rather than re-downloads.

ImageIO rather than AppKit: no `NSImage`, no main-thread affinity, and it scales
during decode instead of after.

Rendering defaults to **half-block**: `▀` with the upper pixel as foreground and
the lower as background, two pixels per cell, each reproduced exactly.

Resolution comes from giving the cover more *cells* — the now-playing pane scales
to 32% of the terminal width up to 54 columns — rather than from packing more
subcells into each one. More cells is the only kind of detail that introduces no
new artefacts, and on a wide terminal it dwarfs anything the palette work can
achieve: 110 columns gives a 33×16 cover, 180 columns gives 52×26, which is 2.6×
the subpixels.

**Quadrant blocks** (`▘▝▀▖▌▞▛▗▚▐▜▄▙▟█`) are available via `HUM_ART=quadrant` and
resolve 2×2 subcells, four source pixels per cell. They are not the default, and
the reason is worth recording because the obvious reasoning points the other way.

Measured as RMS error against the source at 24×12 cells:

| content | quadrant | halfBlock | ascii |
|---|---|---|---|
| photographic, truecolor | 3.0 | 3.8 | 109 |
| photographic, 256 colour | 13.7 | 13.8 | 108 |
| graphic / high contrast, truecolor | 12.2 | 54.6 | 144 |
| graphic / high contrast, 256 colour | 18.1 | 57.1 | 143 |

On graphic covers quadrant is three times more faithful and clearly worth it. On a
photograph the two are indistinguishable — so quadrant's 2×2 structure is pure
added texture, and it reads as dithering for no gain whatsoever. Most album art is
photographic, so half-block is the better default.

Getting here took two wrong turns, both worth remembering:

1. **Patterns were chosen by thresholding how different the four pixels were.**
   Film grain clears any such threshold, so photographic covers patterned 97% of
   cells — and since the lowest-error pattern for noise is a *diagonal*, the
   result was literally a checkerboard. Patterns are now chosen by whether they
   explain the cell better than a flat colour, penalised by how much structure
   each pattern invents (vertical splits ~free, diagonals heavily gated). That
   fix stands, and `ArtworkQualityTests` pins it.
2. **Then the glyph choice was tuned further, when the real problem was that
   quadrant's advantage does not exist for this content.** Every measurement up
   to that point was of glyph *choice* at `ColorDepth.none`. None of them measured
   fidelity, and none measured what the terminal's quantisation does. Measuring
   the actual reconstruction against the source answered in one run what tuning
   could not.

The lesson for anything else in this area: measure what the viewer sees, not what
the algorithm decided.

### The palette is the bottleneck, not the glyph

On an indexed-colour terminal — macOS Terminal.app, most tmux setups — the
limiting factor is the palette, and it took three rounds of tuning glyph
selection to notice. Measured on one dark cover at 22×11 cells:

| | distinct colours | cells with no top/bottom detail |
|---|---|---|
| truecolor | 225 | 0% |
| indexed-256, no dithering | **10** | **80%** |
| indexed-256, dithered | 42 | 24% |

The cause: the xterm-256 cube's dark end jumps straight from 0 to 95, so *every*
dark saturated colour is nearer the 24-step grey ramp than to any cube entry.
Dark artwork therefore collapses into a handful of near-identical greys, losing
both its colour and its structure. No amount of glyph cleverness can recover
that, which is why none of it helped.

The fix is Floyd–Steinberg error diffusion over the colours a half-block render
emits — its output grid is exactly one colour per subcell, which is what error
diffusion needs. Diffusion must land on real palette entries, or the renderer
quantises a second time and the carried error is wrong. The scan is **serpentine**
(alternating direction per row): always scanning left-to-right sends the error
the same way everywhere, which shows as diagonal worming across flat areas — very
visible when one cell is a large fraction of the picture. Propagated error is
bounded, because the palette has nothing at all in some regions and an unbounded
residue there becomes speckle rather than a better average.

### Judging dithering needs the right metric

Measuring dithering per-pixel says it makes things **worse**, and that is true and
beside the point: error diffusion trades per-pixel accuracy for a correct local
average. On a dark cover at 32×16 cells, Lab ΔE against the source:

| diffusion strength | per-pixel | after a one-cell blur |
|---|---|---|
| 0.0 (off) | 15.7 | 15.4 |
| 0.6 (default) | 20.1 | 7.9 |
| 1.0 (full) | 23.7 | 5.8 |

Full strength is nearly three times better once neighbours are integrated — *if*
they are. Here a "pixel" is half a terminal cell, which is large enough on screen
that the eye may resolve the pattern as grain rather than blending it. That makes
the right value a function of font size and viewing distance, which no
measurement in this repo can settle, so `HUM_DITHER=0...1` exposes it and the
default stops short of full strength. `DitherStrengthTests` pins the property
that justifies dithering at all, measured after a blur.

An earlier version of those tests mutated a shared global and ran in parallel,
producing numbers that contradicted each other run to run. The strength is a
parameter now.

### Flat regions are not dithered

Dithering a flat region is pure cost: there is no detail to resolve, so the
pattern is the only thing it adds. That matters most exactly where it hurts
most — the colour cube's levels are 40 apart at the saturated end, so a flat red
field checkerboarded between `#AF0000` and `#D70000`, which on an album cover of
saturated red on pitch black read as the picture exploding.

Subcells whose source is uniform within a radius-2 window take the palette's best
single answer and neither accept nor emit error. The window is deliberately wide
and the tolerance tight (4 levels), so a slow gradient — which *does* want
dithering, and bands badly without it — is not mistaken for a flat field: a
gradient varies measurably across a wide window even when adjacent pixels look
identical.

Measured on a flat saturated red block: 2 colours alternating 52%/47% before, 1
colour at every diffusion strength after, while the block's edges still dither
because that is real detail.

This *is* dithering, and it is the right answer here: palette dithering between
cells is the standard response to a coarse palette. It is a different thing
entirely from structural patterning inside a cell, which is what makes terminal
artwork look like noise. Quadrant mode is not dithered — it has no one-colour-per-
subcell grid to diffuse over.

## Diagnosing artwork

Artwork problems cannot be diagnosed from a pasted terminal. Half-block rendering
emits the same glyph for every cell, so all the information is in the colour
codes — and pasting into a chat window or an issue strips exactly those, leaving
a uniform block of `▀` that looks identical whether the render is perfect or
completely broken.

Two instruments exist for this, and both write files that keep the escape codes:

- **`hum lyrics [query]`** writes `~/hum-lyrics-report/`: the raw track metadata
  both with and without `includeStreams=1`, every stream it found with its type
  and whether it has a `key`, the result of fetching each candidate path, and a
  scan of several albums reporting how many tracks carry a lyrics stream at all.
  That last number answers the only question that matters first — whether the
  server has lyrics to serve.
- **`hum artwork [query]`** writes `~/hum-artwork-report/`: the raw bytes from
  Plex, what hum decoded as a PNG (openable, so a decode bug is immediately
  visible), the render in every style with colour intact, and a report carrying
  the terminal size, `TERM`/`COLORTERM`/`TERM_PROGRAM`, detected colour depth and
  chosen style. The token is redacted, since the file is meant to be shared.
- **`S`** in the browser writes the current frame to `~/hum-frame.txt` with the
  same environment header. (Not `^S`: that is XOFF, and terminals and
  multiplexers routinely swallow it before the application sees it.)

Both are parseable. Reconstructing colour pairs from a snapshot is how the
palette problem above was finally identified — from a frame captured in a pty,
after three rounds of reasoning from the wrong measurements.

## Lyrics

Plex serves whatever is attached to the track as a stream of type 4 — an `.lrc`
sidecar or embedded lyrics carry `[mm:ss.cc]` timings, a plain `.txt` does not.
Fetching them needs `includeStreams=1`, since Plex omits the per-part `Stream`
list otherwise and that is where the lyrics stream lives; there is also a
fallback that re-reads the track's own metadata, because `/hubs/search` results
never carry streams at all.

Fetching has two traps, both of which cost a round of debugging.

**Plex populates a stream's `key` only for *sidecar* lyrics.** Embedded lyrics
arrive with an `id` and no `key`, so a client that looks only at `key` concludes
the track has none.

**A track can carry more than one lyrics stream** — a sidecar *and* an embedded
tag — and only the sidecar reliably fetches. Keeping just the first stream found
could pick the keyless one, which 404s, and the other was never tried. This was a
self-inflicted regression: widening the scan to all media and parts (correct in
itself) made `.first` likelier to land on the wrong one, turning working lyrics
into "no lyrics".

`Track.lyricsCandidatePaths` therefore collects **every** lyrics stream across
every media and part, keys first and id-derived paths after, deduplicated. The
fetch tries each in turn, skipping any that answers non-2xx or blank.

`Lyrics.parse` handles the parts of LRC that occur in practice: several
timestamps sharing one line (a repeated chorus), `[offset:±ms]`, metadata tags,
and the `<mm:ss.cc>` word markers of enhanced LRC. A bracket that is not a valid
tag stays in the text, so `[Chorus]` survives.

Timestamps come in four forms and all four must be accepted: `mm:ss`,
`mm:ss.cc`, `mm:ss.mmm`, and the colon-separated `mm:ss:cc` that plenty of
taggers emit. That last one is worth calling out — rejecting it makes *every*
line of such a file look untimed, so the file falls back to plain text and
nothing follows playback. The symptom is "karaoke stopped working", with no hint
that the cause is one character. Three colon-separated components are read as a
fraction rather than as hours, because hour-length LRC essentially does not occur
and the other reading puts every cue wildly late.

An untimed file **does** scroll, in proportion to track progress — a four-row
window on forty lines is unreadable otherwise. The round trip here is instructive:
scrolling it unlabelled drew the complaint "it's progressing without any reason",
and freezing it drew "the lyrics never scroll, making it difficult". Both were
right. The mapping also holds at the top for the first 10% of the track and
reaches the end by 90%: songs open with an intro, and a straight `fraction`
starts the text moving the instant playback does and then runs ahead of the music
for the rest of the song. The objection was never the motion but the absence of an explanation for
it, so the title now reads `no timings — scrolling by progress` and nothing is
highlighted, since claiming a current line would be the dishonest part. `,`/`.`
step a line, `<`/`>` page, `g` resumes.

## How precise is the following?

Error budget for the amber highlight, worst case:

| source | contribution | notes |
|---|---|---|
| LRC timestamp resolution | ±5ms | centiseconds; milliseconds if the file has three digits |
| player report interval | **0** | 250ms of staleness, entirely removed by extrapolation |
| time-observer dispatch latency | ~1–5ms | the observer runs on the main queue, so AppKit load shows up here |
| audio-vs-monotonic clock drift | <1ms | within a 250ms window; each report re-anchors it |
| frame quantisation at 60fps | 0–16.7ms | the dominant term |
| terminal draw | 5–20ms | outside hum's control |

So roughly **±20ms end to end**, dominated by the frame interval rather than by
anything in the timing path — about one video frame. `HUM_FPS=120` halves the
quantisation term if it matters.

Two caveats worth stating. Hand-authored LRC is commonly out by 100–300ms, which
dwarfs everything in that table; the limit in practice is the file, not the
player. And a busy main thread inflates the dispatch term, since AVPlayer's time
observer shares a queue with AppKit.

`PlaybackClockTests.errorBudget` simulates 200 report cycles with 5ms dispatch
latency and asserts the worst-case estimate error stays under one frame at 60fps.

The strip lives in the layout rather than as an overlay, directly above the
transport — which is where the eye already is while a track plays — and loads
itself on every track change rather than waiting to be asked.

Four rows of lyrics, with the active line on the second: one row of what has just
gone by, two of what is coming. Reading ahead matters more than looking back, but
one line of history makes the strip far easier to pick up again after glancing
away. The box is six terminal rows — the four plus its borders.

### Which track the panes describe

`inspectedTrack` is the single definition, shared by the now-playing pane and the
lyrics strip. It took four bugs to land on the rule, and every one of them was a
variation of putting the decision in the wrong place or fixing it in only one:

1. **Playback only** — pressing `L` while browsing showed nothing, where the
   overlay it replaced had worked on the selection.
2. **Two expressions in opposite orders** — the artwork pane preferred the
   selection, the lyrics strip preferred playback, so browsing while a track
   played updated one pane and not the other. That reads precisely as "the lyrics
   never refresh when I change track".
3. **Selection only** — broke `n`/`p`, which advance playback without moving the
   list, so the panes stayed on a track you had left behind.
4. **Wholesale selection assignments bypassed the handover** — search results and
   `m` assign `selection` directly rather than through `setSelection`, so
   searching never transferred precedence and the panes stayed stale.

The rule: precedence goes to whichever the user touched more recently. A playback
track change hands it to playback, any selection change hands it to the
selection. Requesting lyrics for a selection is debounced 350ms, since scrolling a
track list would otherwise fire one request per row; the playing track is
requested at once.

### No HTTP cache

`PlexClient` disables URL caching outright (`reloadIgnoringLocalCacheData`,
`urlCache = nil`). There was a 16MB in-memory `URLCache` here on the theory that
paging back up a list would be instant — which it already was, because the UI
holds loaded artists, albums and tracks in memory and never re-requests while
browsing.

What the cache did provide was identical requests returning different answers
over time, and the **negative** results are the dangerous ones: a single 404 for
a lyrics stream, cached, makes that track report "no lyrics" for the rest of the
session. That is the "it worked, then after another track it stopped" symptom,
and it is close to undiagnosable by reading code — the logic is correct and the
state lives in Foundation.

A library server is live state. Ask it.

`PlexSession.shared` exists so nothing reaches for `URLSession.shared` by habit.
That one carries a default **on-disk** URLCache, and Plex puts `X-Plex-Token` in
query strings — so artwork requests alone were persisting the account token to
`~/Library/Caches/hum/Cache.db`. Every Plex request, including artwork and the
auth flow, goes through the cache-free session.

### Request bookkeeping

`LyricsCoordinator` owns which track's lyrics should be on screen and what to
fetch. It was extracted from the browser after a run of bugs here that were
invisible to inspection and impossible to reproduce in demo mode — demo lyrics
resolve synchronously, so every ordering hazard disappears. It is keyed on track
ids rather than tracks, so it carries no Plex dependency and can be driven
directly by tests: stale replies, late failures, debounced selections, and ten
tracks alternating between having lyrics and not with replies delivered in
reverse order.

There is now exactly **one** place that issues a request — the per-frame
`updateLyricsRequest`. Previously the playback handler also issued one directly,
and two paths asking for lyrics is most of why this was so hard to reason about.
The playback handler now only hands precedence back to playback, which makes the
subject the playing track and therefore an immediate, undebounced request.

### The strip's state

Title, body, height and scroll behaviour all derive from one `LyricsState`.
They were computed separately and drifted — the title was decided before checking
whether any lyrics existed, so a track with none was announced as
"no timings — scrolling by progress" above a body reading "no lyrics returned".
One state that everything switches on cannot contradict itself.

When a track has no lyrics the strip collapses to a single line saying so rather
than disappearing. Hiding it was a mistake: it made a failed fetch
indistinguishable from a track that genuinely has none, which is precisely the
wrong behaviour when something is broken.

Three details make following feel right rather than nearly right:

- **The position is extrapolated.** `AVPlayer`'s time observer fires four times a
  second — ample for a scrubber, far too coarse to light up words against. The
  pane advances the last known position by elapsed wall time, clamped so a stall
  or a seek cannot run the estimate away.
- **Monotonicity is maintained by `update`, not by the accessor.** An earlier
  version raised the floor inside the read, so switching the UI to the
  "safe-looking" non-mutating accessor silently disabled the guarantee and the
  highlight could step backwards at a word boundary — which reads as the lyrics
  sticking. Reading the clock is now pure, and there is only one way to read it.
- **Wrapping happens before scrolling.** Lines are wrapped to screen rows first,
  so centring and scrolling work in rows rather than in source lines. Otherwise
  the two drift apart on a narrow pane and the active line wanders off-centre.

- **Stale responses are dropped.** Lyrics are requested per track id and the
  result is discarded unless it matches the track still wanted, so a slow reply
  for a track you have skipped past cannot replace the lyrics for the one now
  playing. The request id is tracked separately from the loaded id, so a playback
  event arriving four times a second does not re-request the same lyrics. A late
  *failure* for a track whose lyrics are already showing is also ignored — two
  requests can land in either order, and a nil arriving second would blank a
  working pane.
- **The viewport clamps to the last full screenful**, not to the last row.
  Clamping to the last row let it slide off the end, so the closing lines of a
  song drew with most of the strip blank. The symptom reads as "the lyrics
  disappeared mid-song", which sounds like a fetch problem and is not one.

Fetching retries against the track's own metadata when the paths taken from a
list endpoint all fail, rather than concluding there are none — list endpoints
hand out stream ids that can be stale or absent, and giving up on them reported
"no lyrics" for tracks that plainly had them.

`PlexClient.lyrics` is deliberately **non-throwing**, and every path is attempted
independently. The bug that forced this: a non-2xx from the metadata retry threw
straight out of the function, the caller's `try?` turned it into nil, and a track
whose lyrics were one path away reported having none. "No lyrics" and "the lookup
errored" are indistinguishable to a caller anyway, so surfacing the error gains
nothing and costs the remaining paths.

### Two lyrics formats from one endpoint

`GET {stream.key}` serves both kinds, and the body decides which:

| source | body |
|---|---|
| sidecar `.lrc` / `.txt` | the raw file bytes |
| agent (LyricFind et al.) | JSON: `MediaContainer.Lyrics[].Line[].Span[]`, millisecond `startOffset`s |

`Lyrics.parse` sniffs for the JSON shape before falling back to LRC. The spans
are better than enhanced LRC for karaoke — a per-word offset straight from the
provider rather than hand-authored `<mm:ss.cc>` markers.

Requests do **not** override `Accept`. An earlier version demanded
`text/plain`, which asks for a representation agent lyrics do not have.

This was settled by [reading the
documentation](https://github.com/TheZupZup/Linthra/blob/main/docs/plex.md), not
by probing the server. An earlier version of the diagnostic guessed at ten
endpoints; `/library/parts/{id}/anything` serves the **media file** whatever the
trailing path says, so it downloaded 30MB three times and reported it as
working lyrics. Endpoint guessing is now removed outright: every path hum
requests comes from the server's own metadata.

### Being a good guest on someone's server

A server log from a real session turned up two things hum was doing wrong, and
neither was visible from the client side.

**Unpaginated list requests.** Plex logs a warning:

```
WARN  Missing X-Plex-Container-Size header. This will fail with status code 400 in the future.
GET /library/sections/6/all?type=9  →  1370ms, 3,071,835 bytes, 11,083 items
```

List endpoints now send `X-Plex-Container-Start`/`-Size` and page in 500s, and
callers that want a handful of albums say so rather than pulling the library.

**`includeStreams=1` triggers media analysis.**

```
GET /library/metadata/131116/children?includeStreams=1
  Media Analyzer: Performing on-the-fly analysis on 16 items.
  JobRunner: Plex Media Scanner --analyze --item 131117,131119,…
```

A scanner process per album browsed, to list track titles. Worse, the log also
shows `Item 131117 is already in progress` — **streams are in flux while
analysis runs**, which is a credible mechanism for the intermittent 404s on
lyrics streams, since a stream id read mid-analysis may not survive it.

`/children` no longer asks for streams. They arrive from a single batch
`/library/metadata/{id1,id2,…}?includeStreams=1` instead: the same information,
one round trip, and analysis provoked once rather than on every browse.

The general lesson is that a client cannot see its own cost. Everything here
looked fine from hum's side — correct responses, reasonable latency — while the
server was spawning scanner jobs and warning about a future hard failure. Ask
for the server log early.

### The server answers inconsistently

Two `hum lyrics` runs seconds apart, same track, same build:

```
run A   Accept: text/plain        → 206, 2856 bytes   (plain text)
        Accept: application/json  → 200, 9441 bytes   (structured, timed)

run B   Accept: text/plain        → 404
        Accept: application/json  → 404
```

Within a run both Accept values agree; across runs they both flip. So the
Accept header is **not** the discriminator — the resource genuinely comes and
goes, server-side, and no client change fixes that. Five seconds of retries did
not ride out the gap in run B.

Three hypotheses were wrong before this controlled comparison settled it: a
response cache, the endpoint being incorrect, and the Accept header. Each was
plausible, each was argued from past runs, and none survived two requests made
one second apart. Reasoning over intermittent evidence is how a bug like this
eats an afternoon.

What *is* in hum's control is not asking twice — see the session cache below.

### Lyrics are cached for the session

Successful lookups are kept in memory by track id, capped at 128 entries.
**Successes only, never failures** — the HTTP cache this replaces stored both,
and a cached 404 poisoned a track for the rest of the session.

Lyrics do not change while hum is open, so once a track's have been fetched
there is no reason to ask again — and re-asking is exactly what turned an
unreliable server into a feature that "sometimes works". It also cuts request
volume, which matters on a server that may already dislike being asked.

### Provider lyrics are fetched on demand

Lyrics attached by an agent — `com.plexapp.agents.lyricfind` and friends — are
not files on disk. The server retrieves them from the provider the first time
they are asked for, and answers **404 until they arrive**, after which they stay
available.

This was observed directly rather than inferred: the identical URL returned

```
GET /library/streams/516253 → 404  (generic HTML page)
GET /library/streams/516253 → 200, 2856 bytes      ← minutes later, no code change
```

Two things made this hard to pin down. The 404 body is a generic HTML page
rather than Plex's XML error, which reads as "this route does not exist" — the
stream `key` the server itself advertised looked wrong when it was merely not
ready. And the failure is temporal, so it reproduces only sometimes and never in
demo mode.

The fetch therefore retries at 0.6s, 1.5s and 3s before concluding a track has no
lyrics. Nothing is waiting on it — the pane shows "loading", and a track usually
plays for minutes. Giving up on the first refusal turns "not ready yet" into a
permanent "this track has no lyrics", which is what made the feature look
intermittent on exactly the tracks that do have them.

The delays are injectable so tests do not sit through them.

### Request budget

A lyrics lookup costs at most **five** requests: each candidate once, then the
preferred path only on each of two retries, plus one metadata re-read. It was
nine (every candidate on every round), which is far more traffic than a lyrics
lookup deserves.

This is a correctness concern, not only politeness. A client that fires nine
requests at a media server for one track looks like misbehaviour from the
server's side, and invites a protective response that is then indistinguishable
from a genuine failure — which is exactly the ambiguity that made this bug take
so long to pin down. `LyricsFetchTests` asserts the budget.

For the record, Plex's documented throttling surfaces as **HTTP 429** from
plex.tv, not as a 404 from PMS, so the 404s here are not known to be
rate-limiting. The budget was cut because nine requests was indefensible on its
own terms.

### Tracing the fetch

`PlexClient.lyrics(for:on:trace:)` returns a record of every path tried, its
status and byte count, alongside the result. `HumApp` keeps the last 60 lines and
the `S` snapshot appends them, so a failure that only occurs against a real
library arrives as evidence rather than as a description. A decoded result cannot
say which of several candidates answered what.

### Testing the fetch

`LyricsFetchTests` stubs `URLProtocol` and drives the whole fetch against
scripted Plex responses. This existed nowhere before, and its absence is why the
lyrics fetch was rewritten four times largely by inference — each change could
only be verified against somebody's real library, so a regression stayed
invisible until they ran into it. The stub caught the throw-propagation bug on
its first run, after reasoning about the same code had failed to.

Anything that talks to Plex and cannot be exercised by the demo belongs behind a
stub like this.

## Glyph sets

Transport glyphs all come from one Unicode block, and this is not cosmetic
pedantry: `▶` lives in Geometric Shapes and `⏸` in Miscellaneous Technical, and
the two blocks have different design metrics, so mixing them leaves the play icon
visibly off the baseline that pause sits on. The media-control set U+23E8–U+23FA
(`⏵ ⏸ ⏹ ⏮ ⏭`) is designed as a family and stays aligned.

Every glyph hum uses reports `wcwidth == 1`, including the quadrant and Braille
blocks — worth checking before adopting one, because a glyph the grid thinks is
one column and the font draws as two shears every row below it.

## Frame pacing

The UI loop schedules on **absolute deadlines**, not sleep intervals:

```
nextFrame = now
loop:
  collect events until (nextFrame - now) elapses   ← wait the REMAINING time
  draw
  nextFrame += interval                            ← advance from the deadline
```

Both details are load-bearing, and both were bugs first:

- **Wait the remaining time, not a fresh interval.** Waiting a full interval and
  then drawing makes every period `interval + drawTime`. At a nominal 60fps that
  measured 35.
- **Advance from the deadline, not from now.** Otherwise one slow frame pushes
  the cadence back permanently. If it falls too far behind it resyncs rather than
  trying to catch up.

Rate is also *not* allowed to be whatever rate events happen to arrive at — a
playback tick every 11ms would otherwise drive the render loop. Events are split
into those that demand an immediate redraw (anything the user did, any new
content) and those that do not (playback ticks, the heartbeat). The first kind
draws at once so input always feels instant; the second waits for the deadline.

Three tiers: full rate with a live visualisation, 10fps when only the scrubber
moves, 5fps when nothing plays. On a terminal that cannot keep up, the smoothed
cost of draw-plus-write becomes a floor on the interval.

A consequence worth remembering: anything that animates must be expressed **per
second, not per frame**. The spectrum's peak-hold decay was per-frame and started
falling twice as fast the moment the loop sped up.

## Rendering

`Screen` is a double-buffered grid of `Cell`s. Drawing writes into the back
buffer; `render()` walks it against the front buffer and emits only the cells
that changed, as cursor-address + SGR + text runs, then swaps. A full-screen
frame costs a few hundred bytes instead of ~2000 styled cells.

Two consequences worth knowing:

- `render()` returning `""` means "nothing changed", and the caller skips the
  write entirely. That is what lets an idle hum sit at zero output.
- Because of the above, anything that animates must eventually *stop*. The
  spectrum analyser snaps its bars to exactly zero below a threshold rather than
  decaying asymptotically — otherwise a silent hum would redraw 30 times a second
  forever.

### Colour

`Style` holds 24-bit colours and quantises on the way out, per `ColorDepth`.
Emitting truecolor unconditionally is a trap: a terminal that only understands
`38;5;N` and receives `38;2;242;169;59` consumes the `2` as the colour *index* —
and index 2 is green, so the entire amber palette renders green. macOS
Terminal.app does exactly this. Detection reads `COLORTERM`, `TERM` and
`TERM_PROGRAM`, with `HUM_COLOR` as an override because those are set by the
terminal and go missing over ssh.

Quantisation is **perceptual**, not RGB. Distance in RGB is not distance to the
eye, and the practical consequence on a 256-colour terminal is specific: a
channel-weighted RGB metric sends every dark warm tone to the grey ramp, because
the cube's dark end jumps 0 → 95 and nothing warm sits nearby in RGB terms. Lab
keeps lightness and chroma apart, so a slightly-wrong lightness with the right
hue can beat an exact lightness with no hue at all. Measured on a dark warm
cover, 14% of pixels now reach a coloured cube entry where previously none did.

Scoring all 240 entries per cell would be far too slow for the render loop, so
candidates are generated in O(1) — the 3×3×3 cube entries around the per-channel
nearest, plus the three nearest greys, plus black and white — and only those are
scored in Lab. The true match is always inside that neighbourhood.

Wide glyphs occupy two cells, the second marked `isContinuation` so the diff
never splits a character. `displayWidth` uses `wcwidth`, which needs a UTF-8
`LC_CTYPE`; `HumTUI` forces one at first use, because a bare `LANG` (common over
ssh) would otherwise report CJK titles as single-width and shear the grid.

## Audio and the spectrum

```
AVPlayer ──decode──▶ MTAudioProcessingTap ──samples──▶ SpectrumAnalyzer
   │                   (audio thread)                      │
   └──▶ speakers                                           └──▶ TUI block bars
                                                                and oscilloscope
```

The tap reads the signal AVPlayer is *already* decoding, post-effects, so the
display is frame-accurate against what you hear and costs no second decode.

It is attached when the item reaches `readyToPlay`, not before. The first version
kicked off its own `asset.loadTracks` alongside the player's, which starts a
**second** read of the asset header over the network, queued behind the player's
buffering on the same host — the visualiser stayed empty for about a second after
the music started. By `readyToPlay` the player has necessarily parsed the tracks,
so asking for them costs nothing and the bars start with the sound. The status
observation uses `.initial` as well as `.new`, because an item that is already
ready when observed would otherwise never fire the callback at all.

`SpectrumAnalyzer` is split three ways because three different threads touch it:

1. **Producer** (audio thread) — `append` only copies into a preallocated ring
   buffer. No FFT, no allocation, nothing unbounded. Real-time safe.
2. **Compute** (first consumer to ask, under a lock) — windows the latest 1024
   samples, one 1024-point `vDSP` FFT, folds 512 bins into 256 log-spaced bands
   with fast-attack/slow-release smoothing. **Rate-limited to ~120Hz**: the
   smoothing has to advance on wall-clock time, not once per consumer, or two
   consumers at 60fps would advance it at 120 and the bars would visibly snap.
3. **Present** (any thread) — resamples those bands to the caller's width.

Both visualisers read the same instance, so they can never disagree. The lock on
the compute path is not optional: without it the two consumers corrupt the shared
scratch buffers and double-free.

Bands are log-spaced in frequency with a gentle upward tilt. Linear FFT bins
would give five bars to everything below 1kHz and the rest to cymbals; without
the tilt, the right-hand half of the display barely moves on real music.

Two more corrections are what make it look like a spectrum rather than a block:

- **Gamma (1.8).** A straight dB→height map puts almost every band near the top
  on real programme material. The gamma expands the bottom of the scale so there
  is visible spread between a loud band and a quiet one.
- **Auto-gain.** Levels are normalised against a running peak with a fast attack
  and a slow release, floored so a near-silent passage cannot be amplified into a
  wall of noise. The tallest bar reaches the top of the display whatever the
  track's level.

`SpectrumMeter` draws the inline version: bars two columns wide with a
one-column gap (one bar per column with no gaps draws as a solid wall), plus
peak-hold caps that only appear once they have pulled clear of their own bar. Its
peak decay snaps to exactly zero for the same reason the analyser's does.

## Search

`/hubs/search` does **not** return a flat `Metadata` list — it groups results into
`Hub` objects, one per result kind (artists, albums, tracks, playlists), each with
its own `Metadata`. Decoding only `Metadata` therefore yields nothing at all, and
silently: no error, just zero results on every query against every real server.
`PlexEnvelope.Container.allMetadata` flattens both shapes, and items are
partitioned on their own `type` rather than on the hub they arrived in, since Plex
is not consistent about which shape an endpoint uses.

Results fill all three browse panes rather than just the tracks pane. Searching an
artist's name usually matches no *track* title at all, so a track-only search
looks broken exactly when you would most expect a hit. Focus lands on whichever
pane actually has results, and `esc` drops them and reloads the library.

Worth noting for future work: demo mode has its own search over a local
catalogue. That is useful for exercising the UI, but it meant this bug survived
testing — the UI path was correct and only the wire format was wrong.

## Plex

Sign-in is the plex.tv **PIN flow**: request a PIN, open `app.plex.tv/auth` in
the browser with it, poll until the PIN comes back carrying a token. No password
ever reaches hum. The token goes in the login keychain (`com.hum.plex`), not a
dotfile — it is equivalent to account access.

Server selection probes every connection on the account in **preference tiers**:

| rank | connection |
|---|---|
| 0 | raw LAN address, plain HTTP — `http://10.0.0.5:32400` |
| 1 | the `plex.direct` name for the same LAN machine |
| 2 | direct WAN |
| 3 | plex.tv relay |

Within a tier the probes race; across tiers they do not. A LAN address that
answers in 200ms still beats a relay that answers in 50, because relay bandwidth
is capped and nothing about it feels instant.

Ranks 0 and 1 are the same machine. `https://10-0-0-5.<hash>.plex.direct:32400`
sends its bytes straight to 10.0.0.5, but resolving that name needs Plex's
DNS and validating it needs Plex's certificate — two remote dependencies in the
path to a machine on the same switch, and two more things that can fail
intermittently. The raw address has neither. It is *ranked*, not forced: it is
only used if it answers, so a server with "secure connections: required" falls
back to the `plex.direct` entry untouched.

`HUM_PLEX_SERVER=http://10.0.0.5:32400` skips discovery entirely, so nothing
contacts plex.tv at all. Normal discovery only *asks* plex.tv which addresses
exist — media and metadata already go straight to the server unless the chosen
connection is a relay — but the override removes even that lookup.

Playback is **direct play** — the original file handed to AVFoundation, no
transcode. Faster to start, better sounding, and it is what makes the audio tap
possible.

`X-Plex-Client-Identifier` must be stable across launches or the account accrues
a new "device" every run, so it lives in
`~/Library/Application Support/hum/preferences.json` alongside the last server,
last library and volume.

## Rebuilding while hum is running

Safe — the running process keeps its own open inode — but hum has to be
restarted to pick up a new build.

`make-app-bundle.sh` stages the bundle at `dist/.hum.app.staging` and swaps it in
with a single rename. Writing into a live bundle is how a running
ad-hoc-signed app gets killed: macOS re-validates pages against the on-disk
signature, and a half-written binary fails that check. The script also notes when
an instance is running from `dist/`.

## Why a bundle

macOS only hands media keys and Now Playing to a process with bundle identity. A
bare SwiftPM executable has none: `.build/debug/hum` plays audio fine, but F8/F9
and Control Center do nothing. `Scripts/make-app-bundle.sh` wraps the binary in
`hum.app` (`LSUIElement`, so no Dock icon) and ad-hoc signs it. The binary inside
still works as an ordinary CLI — `Bundle.main` resolves to the `.app` however it
is launched — so the bundle is how hum ships and `dist/hum` is a symlink into it.

## Testing

`swift test` covers the parts that can be tested without a server or a terminal:

- **Screen diffing** — that an unchanged frame emits nothing, that a one-cell
  change emits one cell, that out-of-bounds writes are dropped.
- **Input decoding** — a pipe is `dup2`'d over stdin, so the escape-sequence
  parser is tested against the exact bytes terminals send (CSI, SS3, tilde keys,
  a bare ESC, split UTF-8).
- **Plex decoding** — real response shapes, including the optional-everything
  cases and items that must be dropped rather than defaulted.
- **Server ranking** — local before remote before relay.
- **Spectrum** — that a known sine peaks in the expected band, that rising
  frequency moves the peak monotonically rightwards, that silence reaches exactly
  zero, that the rate limit holds, and that three concurrent consumers at
  different widths stay safe.

For the UI itself, `hum demo` runs the whole browser against a synthetic library
with a synthetic playback thread feeding the analyser. No Plex account, no
network. It is how the layout, the spectrum and the status line get checked.

## Scope

Music libraries only. Podcasts are deliberately out of scope — Plex exposes them
through the provider/`/hubs` API rather than as a library section, so they would
need a second browsing model rather than another section type.

## Known gaps

- **Swift 6 concurrency.** Targets build in language mode v5. The TUI loop,
  AVPlayer and the audio tap share state in ways strict concurrency wants
  reworked; the locking is deliberate and correct, but not yet expressed in the
  type system.
- **Artwork in the terminal.** No sixel/iTerm2 inline images. Artwork is fetched
  only for Control Center.
