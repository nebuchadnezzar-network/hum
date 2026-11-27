```
\       _
 \     | |__  _   _ _ __ ___
  > )))| '_ \| | | | '_ ` _ \
 /     | | | | |_| | | | | | |
/      |_| |_|\__,_|_| |_| |_|
```

**hum** plays music from your own Plex server, in your terminal. macOS, Swift,
one binary.

Browse your library, stream it straight from the server, use the media keys,
read lyrics, see the cover art, and watch a spectrum analyser or oscilloscope —
inline, or on the GPU in its own window.

```
 >))) hum  ␣ play  ⏎ open  ⇥ pane  n/p skip  / search  m genres  V waveform  z viz  v window  L lyrics
┌─ artists · Demo… ─┐ ┌─ albums ────────────┐ ┌─ tracks ─────────────────┐ ┌─ selected ────────────────────┐
│▸ Aphex Twin       │ │▸ Selected Amb…  1992│ │▸  1 Xtal           ♪ 5:18│ │            ▀▀▀▀▀▀             │
│  Boards of Canada │ │  Richard D. J…  1996│ │   2 Tha              4:41│ │            ▀▀▀▀▀▀             │
│  Alice Coltrane   │ │                     │ │   3 Pulsewidth       4:20│ │            ▀▀▀▀▀▀             │
│  Talk Talk        │ │                     │ │   4 Ageispolis     ♪ 4:20│ │                               │
│  Hiroshi Yoshimura│ │                     │ │   5 i                3:27│ │ Xtal                          │
│  Sault            │ │                     │ │   6 Green Calx       4:20│ │ Aphex Twin                    │
│  Caterina Barbieri│ │                     │ │                          │ │ Selected Ambient Works 85–92  │
│  Pharoah Sanders  │ │                     │ │                          │ │ · 1992                        │
│                   │ │                     │ │                          │ │                               │
│                   │ │                     │ │                          │ │ track 1 · 5:18 · flac · 1024  │
│                   │ │                     │ │                          │ │ kbps                          │
│                   │ │                     │ │                          │ │                               │
│                   │ │                     │ │                          │ │         1–5 to rate           │
└───────────────────┘ └─────────────────────┘ └──────────────────────────┘ └───────────────────────────────┘

┌─ lyrics ─────────────────────────────────────────────────────────────────────────────────────────────────┐
│ L to fetch lyrics for this track, or press play                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ playing ────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ⏹ nothing playing                                                                                        │
│ 0:00 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 0:00   ⏮ ⏵ ⏭ ⤮ ↻  vol ▪▪▪▪▪▪▫▫ 70%│
```

## Install

```sh
brew tap nebuchadnezzar-network/hum https://github.com/nebuchadnezzar-network/hum.git
brew trust nebuchadnezzar-network/hum
brew install hum
```

Then run `hum`. It opens your browser once to sign in to Plex and remembers the
token in your keychain.

The URL is needed because the short `brew tap` form expects a repository named
`homebrew-hum`. `brew trust` is needed because Homebrew runs a formula's Ruby
and will not do that for a third-party tap unless you say so.

## Try it without a Plex account

```sh
hum demo
```

A fake library with real, generated audio — so the visualisations, media keys
and the rest work, with no Plex account and nothing to download. It is
synthesised on first play and cleaned up on exit.

## Keys

| | |
|---|---|
| `␣` | play / pause |
| `⏎` | open, and play once there is nothing left to open |
| `⇥` `h` `l` `←` `→` | move between panes |
| `j` `k` `↑` `↓` | move within a pane |
| `n` `p` | next / previous track |
| `/` | search |
| `m` | cycle artists, genres, styles, moods, labels, playlists, rated |
| `x` | play something at random |
| `X` | shuffle the whole library, without end |
| `a` | add the selection to a playlist |
| `1`–`5` | rate the track, `0` clears it |
| `L` | lyrics |
| `V` `z` | change visualisation, hide it |
| `+` `-` | volume |
| `?` | every key |
| `q` | quit |

Media keys and Control Center work too.

## Commands

| | |
|---|---|
| `hum` | browse and play |
| `hum demo` | the fake library |
| `hum login` | sign in again |
| `hum login --token` | sign in with a token from stdin, skipping the browser |
| `hum token` | print the stored token |
| `hum logout` | forget it |
| `hum servers` | list reachable servers |
| `hum lyrics [track]` | explain what the server holds for a track's lyrics |
| `hum artwork [album]` | explain how cover art was fetched and rendered |

## When something looks wrong

**Cover art is blocky or the colours are off.** hum detects what your terminal
can do and quantises to match. To override:

```sh
HUM_COLOR=truecolor hum      # or indexed256, basic16, none
HUM_ART=quadrant hum         # or halfBlock, ascii
HUM_DITHER=0 hum             # 0 to 1, default 0.6
```

**Lyrics do not appear.** `hum lyrics "some track"` writes a report to
`~/hum-lyrics-report` explaining what the server was asked and what it said.
Plex serves provider lyrics intermittently; `L` retries.

**Pick a server by hand**, skipping discovery:

```sh
HUM_PLEX_SERVER=http://10.0.0.5:32400 hum
```

## Build from source

Needs macOS 14+ and Swift 6.

```sh
bash Scripts/make-app-bundle.sh
./dist/hum
```

The binary is wrapped in a `.app` because macOS only gives media keys and Now
Playing to a process with bundle identity. It still behaves as a normal CLI.

```sh
swift test
```

## More

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers how it works: the threading,
the renderer, colour quantisation, the audio tap, and what was learned getting
lyrics and cover art to behave.

`branding/` holds the icon and the palette the interface uses:

| | |
|---|---|
| Ink | `#0E1116` |
| Panel | `#161B22` |
| Amber | `#F2A93B` |
| Amber-dark | `#B8700A` |
| Fog | `#C9D1D9` |
| Mute | `#8B949E` |

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).
