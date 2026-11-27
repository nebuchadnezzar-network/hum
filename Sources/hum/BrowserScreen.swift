import Dispatch
import Foundation
import HumPlayer
import HumPlex
import HumTUI

/// The three-pane library browser and status line.
///
/// Single-threaded by design: this object owns every piece of UI state and only
/// mutates it while applying events from `HumApp.events`. Network results arrive
/// as events too, so there is no shared mutable state and no locking in the hot
/// render path.
final class BrowserScreen {
    private enum Pane: Int, CaseIterable {
        case collections, albums, tracks
    }

    private enum Overlay {
        case none
        case help
        case search(String)
        /// Choosing a playlist to add the pending item to.
        case playlists([CollectionItem], selected: Int)
    }

    /// What `a` is about to add, and how to describe it once added.
    private var pendingAdd: (ratingKey: String, label: String)?

    private let app: HumApp
    private let terminal: Terminal
    private var screen: Screen
    private let input = InputReader()

    private var mode: CollectionMode = .artists
    private var section: LibrarySection?
    private var collections: [CollectionItem] = []
    private var albums: [Album] = []
    private var tracks: [Track] = []
    /// Set while the panes are showing search results rather than the library.
    /// Escape clears it and reloads normally.
    private var searchQuery: String?

    private var selection: [Int] = [0, 0, 0]
    private var offsets: [Int] = [0, 0, 0]
    private var focus: Pane = .collections

    private var playback = PlaybackState()
    /// Last volume written to preferences, so a playback event every 250ms does
    /// not rewrite the file.
    private var persistedVolume: Float = -1

    /// Estimates the position between the player's four-per-second updates.
    private var clock = PlaybackClock()
    private var statusMessage: String?
    private var statusIsError = false
    private var statusExpiry = Date.distantPast

    private var overlay: Overlay = .none
    /// All the request/response bookkeeping, extracted and tested — see
    /// `LyricsCoordinator`.
    private var lyricsCoordinator = LyricsCoordinator()
    private var lyricsScroll = 0
    private var lyricsVisible = true
    /// Set once the reader scrolls the strip, suspending auto-follow until the
    /// track changes or `g` resumes it.
    private var lyricsManualScroll = false
    /// True while the selection is more recent than the last playback change.
    /// Whether the panes describe the cursor's row or the playing track.
    /// See `InspectionSubject` — the rule lives there, with tests.
    private var subject = InspectionSubject()

    /// Rows of lyrics the strip shows. The box is this plus its two borders.
    private static let lyricsContentRows = 4

    private var visualization: Visualization = .bars
    private var visualizationVisible = true
    private var meter = SpectrumMeter()
    private var scope = ScopeMeter()
    private let artwork: ArtworkLoader
    private var isConnecting = true
    private var running = true

    /// Target frame rate while something is playing and a visualisation is up.
    /// 60 is comfortable: the diff renderer only emits cells that changed, so a
    /// spectrum frame is a few KB rather than a full repaint.
    private let targetFPS: Double = {
        if let raw = ProcessInfo.processInfo.environment["HUM_FPS"], let value = Double(raw) {
            return min(120, max(5, value))
        }
        return 60
    }()

    /// Smoothed cost of draw-plus-write, used to back off on a slow terminal.
    private var frameCost = 0.0

    /// Frames actually painted in the last second, shown in the title bar when
    /// `HUM_FPS_DEBUG` is set. Worth having: the achievable rate depends on the
    /// terminal, so "is it really running faster" needs an answer from the
    /// terminal rather than from the loop's intentions.
    private let showFrameRate = ProcessInfo.processInfo.environment["HUM_FPS_DEBUG"] != nil
    private var framesThisSecond = 0
    private var frameRate = 0
    private var frameWindowStart = Date()

    init(app: HumApp, terminal: Terminal, artwork: ArtworkLoader) {
        self.app = app
        self.terminal = terminal
        self.artwork = artwork
        let size = terminal.size
        self.screen = Screen(columns: size.columns, rows: size.rows)
    }

    // MARK: - Run loop

    func run() {
        terminal.enterRawMode()
        terminal.enterAlternateScreen()
        terminal.onResize { [weak self] size in
            self?.app.events.post(.resize(size))
        }

        // Input lives on its own thread so it can block in read(2) while the
        // render loop keeps its own cadence.
        let inputThread = Thread { [weak self] in
            while let self, self.running {
                if let key = self.input.next() {
                    self.app.events.post(.key(key))
                }
            }
        }
        inputThread.name = "hum.input"
        inputThread.stackSize = 1 << 19
        inputThread.start()

        app.connect()
        draw()

        var lastReport = Date.distantPast
        var lastReportedPlaying = false
        var lastReportedTrackID: String?
        var lastWindowTitle = ""
        var nextFrame = monotonicNanoseconds()

        while running {
            let interval = frameInterval()
            let intervalNanoseconds = Int64(interval * 1_000_000_000)

            // Collect events until this frame is due. The wait is the time
            // *remaining* until the deadline, not a fresh full interval — waiting
            // a whole interval and then drawing makes every period
            // interval-plus-draw-time, which is how 60fps became 35.
            var urgent = false
            while running {
                let remaining = Double(nextFrame - monotonicNanoseconds()) / 1_000_000_000
                if remaining <= 0.0005 { break }
                let events = app.events.drain(timeout: remaining)
                if events.isEmpty { break }
                for event in events {
                    apply(event)
                    urgent = urgent || event.demandsImmediateRedraw
                }
                // Anything the user did gets drawn now rather than at the deadline.
                if urgent { break }
            }
            guard running else { break }

            let started = monotonicNanoseconds()
            draw()
            let finished = monotonicNanoseconds()
            let cost = Double(finished - started) / 1_000_000_000
            frameCost = frameCost == 0 ? cost : frameCost * 0.9 + cost * 0.1

            // Advance from the deadline so a single slow frame does not push the
            // cadence back permanently; resync if we have fallen behind entirely.
            nextFrame += intervalNanoseconds
            if nextFrame < finished { nextFrame = finished + intervalNanoseconds }

            framesThisSecond += 1
            if Date().timeIntervalSince(frameWindowStart) >= 1 {
                frameRate = framesThisSecond
                framesThisSecond = 0
                frameWindowStart = Date()
            }

            // Report on transitions, and on a timer only while actually
            // playing. The old condition was `track != nil`, which kept posting
            // to `/:/timeline` every ten seconds for as long as a track was
            // loaded — paused, finished, or sitting untouched overnight. A
            // paused player has nothing new to tell the server.
            flushPendingBrowse()

            // Only on change: this runs every frame, and the title is one of
            // the few things hum writes that the terminal cannot diff away.
            let title = windowTitle
            if title != lastWindowTitle {
                terminal.setWindowTitle(title)
                lastWindowTitle = title
            }

            if let trackID = playback.track?.id {
                let isPlaying = playback.isPlaying
                // A new track is as much a change as play/pause — and it is not
                // a play/pause transition, so watching only `isPlaying` left a
                // track change unreported until the next ten-second tick.
                let changed = isPlaying != lastReportedPlaying || trackID != lastReportedTrackID
                let due = isPlaying && Date().timeIntervalSince(lastReport) > 10
                if changed || due {
                    app.reportProgress()
                    lastReport = Date()
                    lastReportedPlaying = isPlaying
                    lastReportedTrackID = trackID
                }
            }
        }

        // Close the session out. Without this hum walks away from a timeline it
        // last described as "playing", and the server holds that session open
        // until it times out on its own.
        app.reportStopped()
        terminal.restore()
    }

    /// Playback position, extrapolated to *now*.
    ///
    /// See `PlaybackClock`: the player reports four times a second, which is far
    /// too coarse to light up words against.
    private var livePosition: Double {
        guard playback.duration > 0 else { return playback.position }
        return min(playback.duration, clock.position(at: monotonicNanoseconds()))
    }

    /// Monotonic clock as signed nanoseconds, so deadline arithmetic cannot wrap.
    private func monotonicNanoseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds)
    }

    /// How long to wait for the next event before redrawing.
    ///
    /// Three tiers: full rate for a live visualisation, a lazy 10fps when only
    /// the scrubber is moving, and 5fps when nothing is playing at all — an idle
    /// hum should not be waking up 60 times a second.
    private func frameInterval() -> Double {
        guard playback.isPlaying else { return 0.2 }
        guard visualizationVisible else { return 1.0 / 10.0 }
        // Never spend more than half the frame drawing. On a terminal that cannot
        // keep up, stretching the interval keeps keystrokes responsive instead of
        // queueing frames behind them.
        return max(1.0 / targetFPS, frameCost * 2)
    }

    // MARK: - Events

    private func apply(_ event: Event) {
        switch event {
        case .key(let key):
            handle(key)

        case .resize(let size):
            screen.resize(columns: size.columns, rows: size.rows)

        case .tick:
            break

        case .playback(let state):
            let previousTrack = playback.track?.id
            playback = state
            if state.track?.id != previousTrack {
                clock.reset(to: state.position)
            }
            clock.update(
                position: state.position,
                isPlaying: state.isPlaying,
                now: monotonicNanoseconds()
            )
            if state.track?.id != previousTrack {
                // Skipping with n/p moves playback but not the list selection,
                // so the panes have to follow playback again here. The request
                // itself is left to `updateLyricsRequest`, which runs every
                // frame — two paths asking for lyrics is what made this
                // bookkeeping so hard to reason about.
                subject.playbackChangedTrack()
            }
            if state.volume != persistedVolume {
                persistedVolume = state.volume
                app.persistVolume(state.volume)
            }
            if let error = state.lastError {
                setStatus(error, isError: true)
            }

        case .status(let message, let isError):
            setStatus(message, isError: isError)

        case .connected(let server, let sections):
            isConnecting = false
            guard !sections.isEmpty else {
                setStatus("No music libraries on \(server.name).", isError: true)
                return
            }
            let route = server.isRelay ? "relay" : (server.isLocal ? "local" : "remote")
            setStatus("\(server.name) · \(route)", isError: false)
            section = app.preferredSection
            if let section {
                app.rememberSection(section)
                app.loadCollections(section: section, mode: mode)
            }

        case .sectionLoaded(let sectionID, let items):
            guard sectionID == section?.id else { return }
            collections = items
            selection[Pane.collections.rawValue] = 0
            offsets[Pane.collections.rawValue] = 0
            albums = []
            tracks = []
            // Deliberately no cascade. Loading the first artist's first
            // album's tracks at startup is two requests for something nobody
            // asked to see, and whichever album sorts first gets them on every
            // single launch. On one library that was an entry with no title and
            // sixteen tracks with no metadata, so the server re-ran
            // `Plex Media Scanner --analyze` over them every time hum started.
            // Plex's own clients do not browse anywhere until told to.

        case .albumsLoaded(let parentID, let loaded):
            guard parentID == selectedCollection?.id else { return }
            albums = loaded
            selection[Pane.albums.rawValue] = 0
            offsets[Pane.albums.rawValue] = 0
            tracks = []
            // Deliberately no cascade into tracks. Arrowing onto an artist used
            // to cost four requests — the artist's albums, the first album's
            // tracks, a batch read of every one of those tracks for the lyrics
            // flag, and the album artwork — of which only the first was asked
            // for. On a 41-track album the batch also made the server
            // auto-select an audio stream forty-one times.
            //
            // Tracks load when focus moves into the pane that shows them.

        case .tracksEnriched(let albumID, let enriched):
            // Same tracks, better metadata: refresh in place without moving the
            // selection the user may already have made.
            guard albumID == trackSourceID, enriched.count == tracks.count else { return }
            tracks = enriched

        case .tracksLoaded(let albumID, let loaded):
            guard albumID == trackSourceID else { return }
            tracks = loaded
            selection[Pane.tracks.rawValue] = 0
            offsets[Pane.tracks.rawValue] = 0
            correctFlatCount(for: albumID, loaded: loaded.count)

        case .lyricsLoaded(let trackID, let text, let failure, let retryable):
            lyricsCoordinator.received(
                trackID: trackID,
                text: text,
                failureSummary: failure,
                failureIsWorthRetrying: retryable
            )
            lyricsScroll = 0


        case .playlistChoices(let playlists):
            // Dropped if the reader cancelled while the request was in flight,
            // so a late response cannot reopen an overlay they dismissed.
            guard pendingAdd != nil else { return }
            overlay = .playlists(playlists, selected: 0)

        case .shuffleAll(let mix, let replacing):
            if replacing {
                searchQuery = nil
                tracks = mix
                selection[Pane.tracks.rawValue] = 0
                offsets[Pane.tracks.rawValue] = 0
                focus = .tracks
                subject.listsReplaced(landedOnTrackList: true)
                app.play(mix, startingAt: 0)
                // play() clears the shuffle-all flag, since choosing something
                // is normally how you leave the mix. Set it going again.
                if let section = section { app.resumeShuffleAll(section: section) }
                setStatus("shuffling \(mix.count) tracks from the library", isError: false)
            } else {
                // A top-up: the queue grows behind what is playing, so the pane
                // has to grow with it or the two disagree about track numbers.
                tracks.append(contentsOf: mix)
                app.enqueue(mix)
            }

        case .landed(let landing):
            // Clears any search: the landing replaces what the panes describe,
            // and leaving "albums · results" in the titles would label it as a
            // search result.
            searchQuery = nil
            mode = landing.mode
            collections = landing.collections
            albums = landing.albums
            tracks = landing.tracks
            selection = [landing.collectionIndex, landing.albumIndex ?? 0, landing.trackIndex]
            offsets = [0, 0, 0]
            focus = .tracks
            // The cursor is on the track that is about to play, so it is also
            // what the panes should describe.
            subject.listsReplaced(landedOnTrackList: true)
            app.play(landing.tracks, startingAt: landing.trackIndex)
            setStatus(landing.describedChoice, isError: false)

        case .searchResults(let query, let results):
            guard !results.isEmpty else {
                setStatus("Nothing found for “\(query)”.", isError: false)
                return
            }
            searchQuery = query
            collections = results.artists.map {
                CollectionItem(id: $0.id, title: $0.title, detail: $0.genres.first)
            }
            albums = results.albums
            tracks = results.tracks
            selection = [0, 0, 0]
            offsets = [0, 0, 0]
            // Land on whichever pane actually has hits — searching an artist
            // name often matches no track title at all.
            focus = !results.tracks.isEmpty
                ? .tracks
                : (!results.albums.isEmpty ? .albums : .collections)
            subject.listsReplaced(landedOnTrackList: focus == .tracks)

            func counted(_ count: Int, _ noun: String) -> String? {
                guard count > 0 else { return nil }
                return "\(count) \(noun)\(count == 1 ? "" : "s")"
            }
            let parts = [
                counted(results.artists.count, "artist"),
                counted(results.albums.count, "album"),
                counted(results.tracks.count, "track"),
            ].compactMap { $0 }
            setStatus("“\(query)”: \(parts.joined(separator: ", "))  ·  esc to clear", isError: false)

        case .artworkLoaded(let source, let width, let height, let image):
            artwork.store(source: source, width: width, height: height, image: image)

        case .artworkFetched(let source, let data):
            artwork.received(source: source, data: data)

        case .sectionPageLoaded(let sectionID, let page, _):
            guard sectionID == section?.id else { return }
            // Appended, never replaced: the reader's position in the list must
            // not move because more of it arrived.
            let known = Set(collections.map(\.id))
            collections.append(contentsOf: page.filter { !known.contains($0.id) })

        case .ratingChanged(let trackID, let rating):
            // The list on screen, then the caches and the player behind it.
            if let index = tracks.firstIndex(where: { $0.id == trackID }) {
                tracks[index] = tracks[index].withRating(rating)
            }
            app.applyRating(trackID: trackID, rating: rating)

        case .collectionsSettled:
            app.collectionsSettled()

        case .albumsSettled(let parentID):
            app.albumsSettled(parentID: parentID)

        case .tracksSettled(let albumID):
            app.tracksSettled(albumID: albumID)

        case .quit:
            running = false
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
        statusExpiry = Date().addingTimeInterval(isError ? 8 : 4)
    }

    // MARK: - Selection

    private var selectedCollection: CollectionItem? {
        let index = selection[Pane.collections.rawValue]
        return collections.indices.contains(index) ? collections[index] : nil
    }

    private var selectedAlbum: Album? {
        let index = selection[Pane.albums.rawValue]
        return albums.indices.contains(index) ? albums[index] : nil
    }

    private var selectedTrack: Track? {
        let index = selection[Pane.tracks.rawValue]
        return tracks.indices.contains(index) ? tracks[index] : nil
    }

    private func rowCount(for pane: Pane) -> Int {
        switch pane {
        case .collections: return collections.count
        case .albums: return albums.count
        case .tracks: return tracks.count
        }
    }

    /// Browsing follows the cursor, and the cursor moves faster than the
    /// server should be asked to keep up: holding `j` through 788 artists fired
    /// one `/children` request per row passed over. A request is only worth
    /// making once the cursor has settled.
    private var pendingBrowse: Pane?
    private var pendingBrowseAt: Date?
    private static let browseSettleDelay: TimeInterval = 0.25

    private func scheduleBrowse(_ pane: Pane) {
        pendingBrowse = pane
        pendingBrowseAt = Date().addingTimeInterval(Self.browseSettleDelay)
    }

    private func browseNow(_ pane: Pane) {
        pendingBrowse = nil
        pendingBrowseAt = nil
        switch pane {
        case .collections: break
        case .albums: loadAlbumsForSelection()
        case .tracks: loadTracksForSelection()
        }
    }

    /// Called once per frame from the run loop.
    func flushPendingBrowse() {
        guard let pane = pendingBrowse, let at = pendingBrowseAt, Date() >= at else { return }
        browseNow(pane)
    }

    /// Focus moving into an empty pane is an explicit request for its contents,
    /// so it loads immediately rather than waiting out the settle delay.
    /// The next focusable pane in `direction`.
    ///
    /// Skips the albums pane in a flat mode, where it is neither drawn nor
    /// meaningful — tabbing into an invisible pane is how focus disappears.
    private func pane(after current: Pane, by direction: Int) -> Pane {
        var next = current.rawValue + direction
        while let candidate = Pane(rawValue: next), candidate == .albums, mode.isFlat {
            next += direction
        }
        return Pane(rawValue: min(max(next, 0), Pane.allCases.count - 1)) ?? current
    }

    private func ensureLoaded(for pane: Pane) {
        switch pane {
        case .collections: break
        case .albums: if albums.isEmpty { browseNow(.albums) }
        case .tracks:
            guard tracks.isEmpty else { return }
            // In a flat mode the tracks come from the collection item, which
            // `loadAlbumsForSelection` is the entry point for.
            browseNow(mode.isFlat ? .albums : .tracks)
        }
    }

    private func loadAlbumsForSelection() {
        guard let section, let item = selectedCollection else {
            albums = []
            tracks = []
            return
        }
        // Playlists and the rated list have no album level — see
        // `CollectionMode.isFlat`. Their tracks come straight off the item.
        if mode.isFlat {
            albums = []
            app.loadFlatTracks(for: item, section: section, mode: mode)
            return
        }
        app.loadAlbums(for: item, section: section, mode: mode)
    }

    private func loadTracksForSelection() {
        guard let album = selectedAlbum else {
            tracks = []
            return
        }
        app.loadTracks(albumID: album.id)
    }

    // MARK: - Input

    private func handle(_ key: Key) {
        // Overlays swallow input while they are up.
        switch overlay {
        case .search(let query):
            handleSearchKey(key, query: query)
            return
        case .help:
            // Any key dismisses the cheat sheet.
            overlay = .none
            return
        case .playlists(let playlists, let selected):
            handlePlaylistKey(key, playlists: playlists, selected: selected)
            return
        case .none:
            break
        }

        switch key {
        case .character("q"), .control("c"):
            running = false

        case .character(" "):
            app.togglePlayPause()

        case .enter:
            activateSelection()

        case .tab, .character("l"), .right:
            focus = pane(after: focus, by: 1)
            subject.focusMoved(toTrackList: focus == .tracks)
            ensureLoaded(for: focus)

        case .backTab, .character("h"), .left:
            focus = pane(after: focus, by: -1)
            subject.focusMoved(toTrackList: focus == .tracks)

        case .character("j"), .down:
            moveSelection(by: 1)

        case .character("k"), .up:
            moveSelection(by: -1)

        case .pageDown:
            moveSelection(by: 10)

        case .pageUp:
            moveSelection(by: -10)

        case .character(","):
            lyricsScroll = max(0, lyricsScroll - 1)
            lyricsManualScroll = true

        case .character("."):
            lyricsScroll += 1
            lyricsManualScroll = true

        // Shifted pair pages by a strip-full, for reading through a long lyric.
        case .character("<"):
            lyricsScroll = max(0, lyricsScroll - Self.lyricsContentRows)
            lyricsManualScroll = true

        case .character(">"):
            lyricsScroll += Self.lyricsContentRows
            lyricsManualScroll = true

        case .home, .character("g"):
            // Also hands the lyrics strip back to auto-follow.
            lyricsManualScroll = false
            setSelection(0)

        case .end, .character("G"):
            setSelection(rowCount(for: focus) - 1)

        case .character("n"):
            app.next()

        case .character("p"):
            app.previous()

        case .character("]"):
            app.seekRelative(10)

        case .character("["):
            app.seekRelative(-10)

        case .character("+"), .character("="):
            adjustVolume(0.05)

        case .character("-"), .character("_"):
            adjustVolume(-0.05)

        // `playback` still holds the pre-toggle state — the new one arrives as an
        // event — so these read inverted on purpose.
        case .character("s"):
            app.toggleShuffle()
            setStatus(playback.shuffle ? "shuffle off" : "shuffle on", isError: false)

        case .character("r"):
            app.toggleRepeat()
            setStatus(playback.repeatQueue ? "repeat off" : "repeat on", isError: false)

        case .character("e"):
            enqueueSelection()

        case .character(let digit) where digit.isNumber && digit.isASCII:
            // 1–5 set whole stars, 0 clears. The target is the same track the
            // lyrics strip and the metadata pane describe, so what gets rated
            // is always the thing on screen.
            guard let stars = digit.wholeNumberValue, stars <= 5 else { break }
            guard let subject = inspectedTrack else {
                setStatus("select or play a track to rate it", isError: false)
                break
            }
            app.rate(track: subject, stars: stars)

        case .character("m"):
            cycleMode()

        case .character("X"):
            if let section = section {
                app.shuffleAll(section: section)
            } else {
                setStatus("no library yet", isError: true)
            }

        case .character("x"):
            // Not `r` or `R`: `r` is repeat, and a mis-shifted keystroke that
            // abandoned what you were browsing and started unrelated music
            // would be a worse bug than an unmemorable binding.
            if let section = section {
                app.surpriseMe(section: section)
            } else {
                setStatus("no library yet", isError: true)
            }

        case .character("V"):
            visualization = visualization.next
            setStatus(visualization.title, isError: false)
            screen.invalidate()

        case .character("z"):
            visualizationVisible.toggle()
            setStatus(
                visualizationVisible ? "visualization shown" : "visualization hidden",
                isError: false
            )
            screen.invalidate()

        case .character("L"):
            // Three steps, in the order a reader wants them: reveal the strip,
            // then fetch for whatever is selected, then put it away. Browsing no
            // longer fetches on its own, so there has to be a way to ask.
            if !lyricsVisible {
                lyricsVisible = true
                setStatus(
                    lyricsSubject == nil
                        ? "select or play a track to see its lyrics"
                        : "lyrics shown",
                    isError: false
                )
            } else if let subject = lyricsSubject,
                      lyricsState == .notRequested || lyricsState == .unavailable {
                // `.unavailable` retries rather than hides: this server serves
                // the same lyrics path as 200 and as 404 seconds apart, so a
                // failure is worth asking about again, and the automatic
                // retries are deliberately bounded.
                let retrying = lyricsState == .unavailable
                if lyricsCoordinator.requestExplicitly(
                    subjectID: subject.id, force: retrying
                ) != nil {
                    lyricsManualScroll = false
                    lyricsScroll = 0
                    app.loadLyrics(for: subject)
                    setStatus(retrying ? "retrying lyrics…" : "fetching lyrics…", isError: false)
                }
            } else {
                lyricsVisible = false
                setStatus("lyrics hidden", isError: false)
            }
            screen.invalidate()

        case .character("/"):
            overlay = .search("")

        // Plain `S`: Ctrl-S is XOFF flow control and terminals and multiplexers
        // routinely swallow it before the application ever sees it.
        case .character("S"):
            saveSnapshot()

        case .character("a"):
            beginAddToPlaylist()

        case .character("?"):
            overlay = .help

        case .escape:
            if searchQuery != nil {
                clearSearch()
            }

        default:
            break
        }
    }

    private func handleSearchKey(_ key: Key, query: String) {
        switch key {
        case .escape:
            overlay = .none
        case .enter:
            overlay = .none
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                setStatus("search cancelled", isError: false)
            } else {
                setStatus("searching…", isError: false)
                app.search(trimmed)
            }
        case .backspace:
            overlay = .search(String(query.dropLast()))
        case .character(let character):
            overlay = .search(query + String(character))
        case .control("c"):
            overlay = .none
        default:
            break
        }
    }

    private func moveSelection(by delta: Int) {
        setSelection(selection[focus.rawValue] + delta)
    }

    /// Rows from the end of the loaded list at which the next page is fetched.
    ///
    /// Far enough ahead that the page arrives before the cursor reaches the
    /// bottom, so scrolling does not visibly stall.
    private static let collectionPrefetchMargin = 40

    private func prefetchCollectionsIfNeeded() {
        guard focus == .collections, let section else { return }
        guard app.hasMoreCollections(loaded: collections.count) else { return }
        let distanceToEnd = collections.count - selection[Pane.collections.rawValue]
        guard distanceToEnd <= Self.collectionPrefetchMargin else { return }
        app.loadMoreCollections(section: section, mode: mode, loaded: collections.count)
    }

    private func setSelection(_ target: Int) {
        let count = rowCount(for: focus)
        guard count > 0 else { return }
        let clamped = min(max(target, 0), count - 1)
        guard clamped != selection[focus.rawValue] else { return }
        selection[focus.rawValue] = clamped
        subject.cursorMoved(inTrackList: focus == .tracks)

        // Moving in one pane invalidates everything to its right.
        switch focus {
        case .collections:
            albums = []
            tracks = []
            scheduleBrowse(.albums)
        case .albums:
            tracks = []
            scheduleBrowse(.tracks)
        case .tracks:
            break
        }

        prefetchCollectionsIfNeeded()
    }

    /// Enter drills right through the panes, and plays once there is nothing left
    /// to drill into.
    private func activateSelection() {
        switch focus {
        case .collections:
            guard selectedCollection != nil else { return }
            focus = mode.isFlat ? .tracks : .albums
            subject.focusMoved(toTrackList: focus == .tracks)
            ensureLoaded(for: focus)
        case .albums:
            guard selectedAlbum != nil else { return }
            focus = .tracks
            subject.focusMoved(toTrackList: true)
            ensureLoaded(for: .tracks)
        case .tracks:
            guard !tracks.isEmpty else { return }
            app.play(tracks, startingAt: selection[Pane.tracks.rawValue])
        }
    }

    private func enqueueSelection() {
        switch focus {
        case .tracks:
            guard let track = selectedTrack else { return }
            app.enqueue([track])
            setStatus("queued \(track.title)", isError: false)
        case .albums, .collections:
            guard !tracks.isEmpty else {
                setStatus("nothing loaded to queue yet", isError: false)
                return
            }
            app.enqueue(tracks)
            setStatus("queued \(tracks.count) tracks", isError: false)
        }
    }

    /// No toast: the transport box has a volume meter, and the level is persisted
    /// from the player's published state rather than re-derived here — deriving it
    /// locally is what made the display disagree with the actual volume.
    private func adjustVolume(_ delta: Float) {
        app.adjustVolume(delta)
    }

    /// Drops search results and reloads the library listing.
    private func clearSearch() {
        searchQuery = nil
        subject.listsReplaced()
        collections = []
        albums = []
        tracks = []
        selection = [0, 0, 0]
        offsets = [0, 0, 0]
        focus = .collections
        setStatus("search cleared", isError: false)
        if let section {
            app.loadCollections(section: section, mode: mode)
        }
    }

    private func cycleMode() {
        mode = mode.next
        searchQuery = nil
        subject.listsReplaced()
        collections = []
        albums = []
        tracks = []
        selection = [0, 0, 0]
        offsets = [0, 0, 0]
        focus = .collections
        setStatus("browsing \(mode.title)", isError: false)
        if let section {
            app.loadCollections(section: section, mode: mode)
        }
    }

    /// Keeps the loaded lyrics pointed at the current subject.
    ///
    /// Called every frame; the coordinator decides whether anything is actually
    /// due, including debouncing a browsed selection so that scrolling a track
    /// list does not fire one request per row.
    private func updateLyricsRequest() {
        guard lyricsVisible else { return }
        let subject = lyricsSubject
        guard let trackID = lyricsCoordinator.update(
            subjectID: subject?.id,
            isPlaying: lyricsSubjectIsPlaying
        ) else { return }
        guard let subject, subject.id == trackID else { return }

        lyricsManualScroll = false
        lyricsScroll = 0
        app.loadLyrics(for: subject)
    }

    // MARK: - Drawing

    private func draw() {
        screen.clear(style: Style(fg: Palette.fog, bg: Palette.ink))

        var area = screen.bounds
        guard area.width >= 40, area.height >= 10 else {
            screen.put("terminal too small", x: 0, y: 0, style: Style(fg: Palette.amber, bg: Palette.ink))
            flush()
            return
        }

        // Top to bottom: title bar, visualisation, panes, transport, status.
        let (titleRect, belowTitle) = area.splitTop(1)
        drawTitleBar(in: titleRect)
        area = belowTitle

        let (statusRect, aboveStatus) = area.splitBottom(1)
        area = aboveStatus

        // Transport is a box of its own: border, two content rows, border.
        let transportHeight = min(4, area.height)
        let (transportRect, aboveTransport) = area.splitBottom(transportHeight, gap: 1)
        area = aboveTransport

        // Lyrics sit directly above the transport, which is where the eye
        // already is while a track plays.
        updateLyricsRequest()

        var lyricsRect: Rect?
        let stripRows = lyricsStripRows
        if stripRows > 0, area.height >= stripRows + 7 {
            let (strip, remaining) = area.splitBottom(stripRows, gap: 1)
            lyricsRect = strip
            area = remaining
        }

        // The visualisation only earns its rows when there is something to draw
        // and the panes still have room. With nothing loaded it is seven rows of
        // empty box, which the browse panes can put to better use.
        if visualizationVisible, playback.track != nil, area.height >= 14 {
            let inner = min(8, max(4, area.height / 5))
            let (visualRect, remaining) = area.splitTop(inner + 2, gap: 1)
            drawVisualization(in: visualRect)
            area = remaining
        }

        if isConnecting && collections.isEmpty {
            drawSplash(in: area, on: screen, subtitle: "connecting to Plex…")
        } else {
            drawPanes(in: area)
        }

        if let lyricsRect {
            drawLyricsStrip(in: lyricsRect)
        }
        drawTransport(in: transportRect)
        drawStatusLine(in: statusRect)

        if case .help = overlay {
            drawHelpOverlay()
        }
        if case .search(let query) = overlay {
            drawSearchPrompt(in: statusRect, query: query)
        }
        if case .playlists(let playlists, let selected) = overlay {
            drawPlaylistOverlay(playlists, selected: selected)
        }

        flush()
    }

    /// What the terminal's window title should read.
    ///
    /// The track, not the program's name — the terminal already shows that.
    private var windowTitle: String {
        guard let track = playback.track else { return "hum" }
        let state = playback.isPlaying ? "" : "paused · "
        return "\(state)\(track.artist) — \(track.title)"
    }

    private func flush() {
        let output = screen.render()
        if !output.isEmpty { terminal.write(output) }
    }

    private func drawPanes(in area: Rect) {
        // Separate cards, each with its own frame and a column of space between
        // them.
        //
        // This was briefly one shared frame with `┬ │ ┴` junctions, on the
        // reasoning that two borders at a seam is one too many. The actual
        // complaint it was meant to fix turned out to be elsewhere: the corners
        // were `╭ ╮ ╰ ╯`, which are *arcs*, and in Menlo and SF Mono the arc's
        // stroke does not meet the adjacent `─` and `│`. Sharp corners fixed
        // that — see `BorderStyle` — and separate cards read cleanly with them.
        //
        // The cost is honest: each card spends 2 columns on borders where a
        // shared frame spent 1 per seam, so four cards give up 3 columns of
        // content. That is the price of the look.
        let wantsNowPlaying = area.width >= 96
        // No album level in a flat mode, so no card for it: the width goes to
        // the track list, which is the thing being browsed.
        let wantsAlbums = !mode.isFlat
        let count = (wantsNowPlaying ? 3 : 2) + (wantsAlbums ? 1 : 0)
        // Two border columns per card, and a one-column gutter between each.
        let chrome = count * 2 + (count - 1)
        let available = max(0, area.width - chrome)

        var budget = available
        var nowPlayingWidth = 0
        if wantsNowPlaying {
            // Capped generously: on a large terminal the cover is the cheapest
            // resolution available — more cells, no new artefacts, and nothing
            // the palette can do competes with simply having more of them.
            nowPlayingWidth = max(26, min(54, available * 32 / 100))
            budget -= nowPlayingWidth
        }
        let collectionsWidth = max(16, min(32, budget * 30 / 100))
        budget -= collectionsWidth
        let albumsWidth = wantsAlbums ? max(18, min(40, budget * 46 / 100)) : 0
        budget -= albumsWidth
        let tracksWidth = max(0, budget)

        // Each entry is a card: its title, whether it has focus, and the
        // content width inside its borders.
        var cards: [(title: String, focused: Bool, width: Int, draw: (Rect) -> Void)] = [
            (collectionsTitle, focus == .collections, collectionsWidth, drawCollections),
        ]
        if wantsAlbums {
            cards.append((albumsTitle, focus == .albums, albumsWidth, drawAlbums))
        }
        cards.append((tracksTitle, focus == .tracks, tracksWidth, drawTracks))
        if wantsNowPlaying {
            cards.append((nowPlayingTitle, false, nowPlayingWidth, drawNowPlaying))
        }

        var remaining = area
        for (index, card) in cards.enumerated() {
            let outerWidth = card.width + 2
            let isLast = index == cards.count - 1
            // The gutter belongs between cards, not after the last one.
            let (frame, rest) = isLast
                ? (remaining, remaining)
                : remaining.splitLeft(outerWidth, gap: 1)
            remaining = rest

            let inner = Panel(title: card.title, isFocused: card.focused)
                .draw(in: isLast ? frame : Rect(
                    x: frame.minX, y: frame.minY, width: outerWidth, height: frame.height
                ), on: screen)
            card.draw(inner)
        }
    }

    /// Cover art plus the metadata for whatever is playing — or, when nothing is,
    /// whatever is selected, so the pane is useful while browsing too.
    private var nowPlayingTitle: String {
        let track = inspectedTrack
        return track != nil && track?.id == playback.track?.id ? "now playing" : "selected"
    }

    /// `Album title · 1992`, from the track rather than from whatever album is
    /// selected. In a playlist or the rated list nothing is selected, and the
    /// year came out blank.
    private func albumLine(for track: Track) -> String {
        guard let year = track.albumYear ?? yearOfSelectedAlbum(matching: track) else {
            return track.album
        }
        return "\(track.album) · \(year)"
    }

    /// Fallback for servers or endpoints that omit `parentYear`: the selected
    /// album, but only when it is unambiguously the track's own.
    private func yearOfSelectedAlbum(matching track: Track) -> Int? {
        guard let album = selectedAlbum, album.id == track.albumID else { return nil }
        return album.year
    }

    /// Rows the metadata block under the cover needs, wrapping included.
    ///
    /// Kept beside `drawNowPlaying`, which must draw exactly these lines in
    /// this order — if one gains a row, this has to know.
    private func metadataRowCount(for track: Track, width: Int) -> Int {
        guard width > 0 else { return 0 }
        // Mirrors drawNowPlaying's own composition.
        let album = albumLine(for: track)
        var rows = wrap(track.title, width: width).count
            + wrap(track.artist, width: width).count
            + wrap(album, width: width).count
        rows += 1          // gap before the facts
        rows += 1          // track number · duration · codec · bitrate
        rows += 1          // gap before the rating
        rows += 1          // the rating line, drawn whether rated or not
        if track.hasLyrics { rows += 1 }
        rows += 1          // the blank row between cover and text
        return rows
    }

    private func drawNowPlaying(in inner: Rect) {
        // Shared with the lyrics strip, so the two panes always describe the
        // same track. See `inspectedTrack`.
        let track = inspectedTrack
        guard !inner.isEmpty else { return }
        guard let track else {
            screen.putTruncated(
                "nothing selected",
                x: inner.minX + 1,
                y: inner.minY,
                style: Style(fg: Palette.mute, bg: Palette.ink).with(.italic),
                maxWidth: inner.width - 2
            )
            return
        }

        var cursor = inner
        let style = ArtworkStyle.best(for: screen.colorDepth)

        // Square cover: terminal cells are about twice as tall as they are wide,
        // so the row count is derived from the width rather than matching it.
        // When the pane is too short for that, narrow the cover as well —
        // clamping rows alone squashes the image vertically.
        // Count the rows the text below will actually take, rather than
        // guessing. This was a hard-coded 5 against a block that draws the
        // title, artist and album — any of which can wrap — plus two gaps, the
        // facts line, the rating line and sometimes the lyrics hint. The cover
        // took the difference, and the last rows fell off the bottom of the
        // pane: first "lyrics available — L", then the rating.
        let metadataRows = metadataRowCount(for: track, width: inner.width - 2)
        let availableRows = max(0, inner.height - metadataRows)
        var artWidth = min(inner.width, 56)
        var artRows = artworkRows(forWidth: artWidth)
        if artRows > availableRows {
            artRows = availableRows
            artWidth = min(artWidth, artRows * 2)
        }

        let artworkSource = selectedTrack?.thumb
            ?? selectedAlbum?.thumb
            ?? playback.track?.thumb
        if artRows > 0, let source = artworkSource {
            let pixels = artworkPixelSize(cells: (artWidth, artRows), style: style)
            if let image = artwork.artwork(source: source, width: pixels.width, height: pixels.height) {
                let x = inner.minX + max(0, (inner.width - artWidth) / 2)
                drawArtwork(
                    image,
                    in: Rect(x: x, y: inner.minY, width: artWidth, height: artRows),
                    on: screen,
                    style: style
                )
            } else {
                drawArtworkPlaceholder(
                    in: Rect(
                        x: inner.minX + max(0, (inner.width - artWidth) / 2),
                        y: inner.minY,
                        width: artWidth,
                        height: artRows
                    )
                )
            }
            (_, cursor) = inner.splitTop(artRows + 1)
        }

        let width = cursor.width - 2
        var y = cursor.minY
        func line(_ text: String, _ lineStyle: Style) {
            guard y < cursor.maxY, !text.isEmpty else { return }
            for wrapped in wrap(text, width: width) {
                guard y < cursor.maxY else { return }
                screen.putTruncated(wrapped, x: cursor.minX + 1, y: y, style: lineStyle, maxWidth: width)
                y += 1
            }
        }

        line(track.title, Style(fg: Palette.amber, bg: Palette.ink).with(.bold))
        line(track.artist, Style(fg: Palette.fog, bg: Palette.ink))

        line(albumLine(for: track), Style(fg: Palette.mute, bg: Palette.ink))

        y += 1
        var facts: [String] = []
        if let number = track.trackNumber { facts.append("track \(number)") }
        facts.append(formatTime(track.duration))
        if let codec = track.codec { facts.append(codec) }
        if let bitrate = track.bitrate, bitrate > 0 { facts.append("\(bitrate) kbps") }
        line(facts.joined(separator: " · "), Style(fg: Palette.mute, bg: Palette.ink))

        // Always a rating line, rated or not, so the keys are discoverable and
        // the pane does not jump by a row the first time something is rated.
        y += 1
        if let rating = track.userRating, rating > 0 {
            line(
                "\(Rating.stars(rating))   0–5 to change",
                Style(fg: Palette.amber, bg: Palette.ink)
            )
        } else {
            line(
                "\(Rating.stars(nil))   1–5 to rate",
                Style(fg: Palette.mute, bg: Palette.ink)
            )
        }

        if track.hasLyrics {
            line("lyrics available — L", Style(fg: Palette.amberDark, bg: Palette.ink))
        }
    }

    /// Shown while the cover is still downloading, so the pane does not jump when
    /// it lands. The mark is the one from the branding file.
    private func drawArtworkPlaceholder(in rect: Rect) {
        screen.fill(rect, style: Style(fg: Palette.border, bg: Palette.panel))
        guard rect.height >= 3 else { return }
        let mark = ">)))"
        screen.put(
            mark,
            x: rect.minX + max(0, (rect.width - displayWidth(mark)) / 2),
            y: rect.minY + rect.height / 2,
            style: Style(fg: Palette.amberDark, bg: Palette.panel)
        )
    }

    private var collectionsTitle: String {
        if let searchQuery { return "artists · “\(searchQuery)”" }
        return section.map { "\(mode.title) · \($0.title)" } ?? mode.title
    }

    private func drawCollections(in inner: Rect) {

        // The facet detail is the first thing to drop: an unreadable artist name
        // costs more than a missing genre.
        let showDetail = inner.width >= 28
        var list = ListView(
            rows: collections.map { ListView.Row(text: $0.title, detail: showDetail ? $0.detail : nil) },
            selected: selection[Pane.collections.rawValue],
            isFocused: focus == .collections,
            offset: offsets[Pane.collections.rawValue],
            emptyMessage: mode.collectionsEmptyMessage
        )
        list.scrollToSelection(viewportHeight: inner.height)
        offsets[Pane.collections.rawValue] = list.offset
        list.draw(in: inner, on: screen)
    }

    private var albumsTitle: String {
        searchQuery == nil ? "albums" : "albums · results"
    }

    private func drawAlbums(in inner: Rect) {

        var list = ListView(
            rows: albums.map { album in
                ListView.Row(
                    text: album.title,
                    detail: album.year.map(String.init)
                )
            },
            selected: selection[Pane.albums.rawValue],
            isFocused: focus == .albums,
            offset: offsets[Pane.albums.rawValue],
            emptyMessage: mode.albumsEmptyMessage(
                hasCollections: !collections.isEmpty,
                isSearching: searchQuery != nil
            )
        )
        list.scrollToSelection(viewportHeight: inner.height)
        offsets[Pane.albums.rawValue] = list.offset
        list.draw(in: inner, on: screen)
    }

    private var tracksTitle: String {
        searchQuery == nil ? "tracks" : "tracks · results"
    }

    /// Whether the track list has room for a rating column.
    private var showsRatingColumn = false

    /// Cells a row spends on things that are not the title: the selection
    /// marker, five stars and a space, the lyrics flag, and `m:ss`.
    private static let trackRowChrome = 2 + 6 + 2 + 5

    /// Below this many cells for the title, the stars are not worth their
    /// width — a truncated title costs more than a hidden rating, and the
    /// rating is still in the card to the right.
    private static let minimumTitleWidth = 14

    private func drawTracks(in inner: Rect) {
        // Stated as "what is left for the title" rather than a bare total.
        // It was `inner.width >= 32`, which was loose arithmetic: separate
        // cards spend three more columns on borders than one shared frame, and
        // the track list landed on 31 — so the ratings silently disappeared the
        // moment the layout changed.
        showsRatingColumn = inner.width - Self.trackRowChrome >= Self.minimumTitleWidth

        let playingID = playback.track?.id
        var list = ListView(
            rows: tracks.map { track in
                let isPlaying = track.id == playingID
                let number = track.trackNumber.map { String(format: "%2d ", $0) } ?? ""
                // A track number only means something inside its album. In
                // search results and in a flat list — a playlist, or the rated
                // set — it is noise, and the same "2" repeated down the column
                // reads as a bug. The artist is what tells those rows apart.
                let flat = searchQuery != nil || mode.isFlat
                let label = flat
                    ? "\(track.title) · \(track.artist)"
                    : "\(number)\(track.title)"
                // The lyrics flag gets its own column rather than sharing the
                // accent with the playing marker — they are not mutually
                // exclusive, and sharing meant a playing track lost its flag.
                let lyricsFlag = track.hasLyrics ? "♪ " : "  "
                // Stars are the first thing to drop on a narrow pane: a
                // truncated track title costs more than a hidden rating, and
                // the rating is always legible in the pane to the right.
                let stars = showsRatingColumn ? Rating.stars(track.userRating) + " " : ""
                return ListView.Row(
                    text: label,
                    detail: stars + lyricsFlag + formatTime(track.duration),
                    // The playing track stays amber even when the pane is unfocused.
                    style: isPlaying
                        ? Style(fg: Palette.amber, bg: Palette.ink).with(.bold)
                        : nil,
                    accent: isPlaying ? Character(Glyph.play) : nil
                )
            },
            selected: selection[Pane.tracks.rawValue],
            isFocused: focus == .tracks,
            offset: offsets[Pane.tracks.rawValue],
            emptyMessage: mode.tracksEmptyMessage(
                hasCollections: !collections.isEmpty,
                hasAlbums: !albums.isEmpty,
                isSearching: searchQuery != nil
            )
        )
        list.scrollToSelection(viewportHeight: inner.height)
        offsets[Pane.tracks.rawValue] = list.offset
        list.draw(in: inner, on: screen)
    }

    /// Rows the strip should occupy, borders included. Zero hides it.
    ///
    /// Collapses to a single line of explanation rather than disappearing when a
    /// track has no lyrics. Hiding it entirely was a mistake: it made a *failed*
    /// fetch indistinguishable from a track that genuinely has none, so there was
    /// no way to tell whether anything was wrong. One row is cheap enough to
    /// always say what happened.
    /// The track the now-playing pane and the lyrics strip both describe.
    ///
    /// One definition on purpose. These were two expressions in opposite orders —
    /// the artwork pane preferred the selection, the lyrics strip preferred
    /// playback — so browsing while a track played updated one pane and not the
    /// other. That reads exactly like "the lyrics never refresh when I change
    /// track", and it is the kind of bug that comes back the moment the rule
    /// lives in two places.
    ///
    /// Precedence goes to whichever the user touched more recently. Neither
    /// fixed order works:
    ///
    /// - Playback always winning froze both panes on the playing track, so
    ///   browsing never changed them.
    /// - Selection always winning broke `n`/`p`, which advance playback without
    ///   moving the list — the panes would stay on a track you had left behind.
    ///
    /// The flag is claimed only by the track list: by moving within it, or by
    /// focus entering it. Moving through artists or albums releases it, and so
    /// does a track change, a mode change or dropping a search. Claiming it
    /// anywhere a *list* changed meant the subject became row 0 of whatever had
    /// just loaded — a row nobody chose. That shipped as "the rating goes to the
    /// first song in the playlist, not the one I'm listening to".
    private var inspectedTrack: Track? {
        switch subject.preference {
        case .cursor:   return selectedTrack ?? playback.track
        case .playback: return playback.track ?? selectedTrack
        }
    }

    /// Replaces a flat collection row's count with the number of tracks hum
    /// actually has.
    ///
    /// The number shown before opening comes from the playlist's `leafCount`,
    /// which is the server's own figure and can disagree with what the items
    /// endpoint returns — a smart playlist's count is computed, and the list
    /// was also being truncated by Plex's default container size. Showing a
    /// count beside a list of a different length is worse than showing none,
    /// so once the tracks are in hand the row says what is in it.
    private func correctFlatCount(for sourceID: String, loaded: Int) {
        guard mode.isFlat,
              let index = collections.firstIndex(where: { $0.id == sourceID })
        else { return }
        collections[index] = CollectionItem(
            id: collections[index].id,
            title: collections[index].title,
            detail: "\(loaded)"
        )
    }

    /// What the track list is currently a list *of*.
    ///
    /// An album, normally. In a flat mode it is the collection item itself —
    /// a playlist, or the rated set — because there is no album in between.
    /// Responses are matched against this to drop stale ones, and matching
    /// only against the selected album silently discarded every flat load.
    private var trackSourceID: String? {
        mode.isFlat ? selectedCollection?.id : selectedAlbum?.id
    }

    private var lyricsSubject: Track? { inspectedTrack }

    /// What the lyrics strip is currently doing.
    ///
    /// Derived in one place because the title and the body were computed
    /// separately and drifted: the title was decided before checking whether any
    /// lyrics existed, so a track with none was announced as "no timings —
    /// scrolling by progress" above a body reading "no lyrics returned". A single
    /// state both switch on cannot contradict itself.
    private enum LyricsState {
        /// Selected, never fetched, and nobody asked. Distinct from `.loading`,
        /// which previously swallowed it and left the strip claiming to be
        /// loading something it was never going to request.
        case notRequested
        case loading
        case unavailable
        case following        // timed, playing, auto-scrolling
        case untimedProgress // no cues, scrolling with the track
        case scrolled        // the reader took over
        case selected        // a browsed track, not the one playing
    }

    private var lyricsState: LyricsState {
        switch lyricsCoordinator.state {
        case .idle:
            return lyricsSubjectIsPlaying ? .loading : .notRequested
        case .loading:
            return .loading
        case .unavailable:
            return .unavailable
        case .ready:
            if lyricsManualScroll { return .scrolled }
            guard lyricsSubjectIsPlaying else { return .selected }
            return lyricsCoordinator.lyrics?.isTimed == true ? .following : .untimedProgress
        }
    }

    /// True when the subject is the track actually playing, so its position can
    /// be followed.
    private var lyricsSubjectIsPlaying: Bool {
        playback.track != nil && lyricsSubject?.id == playback.track?.id
    }

    private var lyricsStripRows: Int {
        guard lyricsVisible, lyricsSubject != nil else { return 0 }
        switch lyricsState {
        case .notRequested, .loading, .unavailable: return 3
        default: return Self.lyricsContentRows + 2
        }
    }

    /// The compact lyrics strip that sits directly above the transport.
    ///
    /// Four rows of lyrics, with the line being sung on the second: one line of
    /// what has just gone by, and two of what is coming. Reading ahead matters
    /// more than looking back, but a single line of history makes the strip much
    /// easier to follow when you glance away and back.
    private func drawLyricsStrip(in rect: Rect) {
        let state = lyricsState
        let title: String
        switch state {
        case .notRequested:
            title = "lyrics"
        case .loading:
            title = "lyrics"
        case .unavailable:
            // An error is not an absence.
            title = lyricsCoordinator.failureIsWorthRetrying ? "lyrics · error" : "lyrics · none"
        case .following:
            title = "lyrics · following"
        case .untimedProgress:
            // An untimed file does scroll, because a four-row window on forty
            // lines is unreadable otherwise — but it says *why* it is moving,
            // and highlights nothing. Unexplained motion was the original
            // complaint; claiming a current line would be the worse one.
            title = "lyrics · no timings — scrolling by progress"
        case .scrolled:
            title = "lyrics · scrolled (g to resume)"
        case .selected:
            title = "lyrics · selected (, . to scroll)"
        }
        let inner = Panel(title: title, isFocused: false).draw(in: rect, on: screen)
        guard !inner.isEmpty else { return }

        switch state {
        case .notRequested, .loading, .unavailable:
            // Say which of the two it is. "No lyrics for this track" is final;
            // "the server refused the lyrics (HTTP 404)" is an error, and the
            // one this server hands out intermittently for streams it has
            // itself advertised — the same URL serves minutes later. Showing
            // both as "no lyrics returned" made a fault look like an absence.
            let message: String
            switch state {
            case .unavailable:
                let reason = lyricsCoordinator.failureSummary
                    ?? "no lyrics returned for this track"
                message = lyricsCoordinator.failureIsWorthRetrying
                    ? "\(reason) — L to try again"
                    : "\(reason) — run `hum lyrics` to see why"
            case .notRequested:
                message = "L to fetch lyrics for this track, or press play"
            default:
                message = "loading lyrics…"
            }
            screen.putTruncated(
                message,
                x: inner.minX + 1,
                y: inner.minY,
                style: Style(fg: Palette.mute, bg: Palette.ink).with(.italic),
                maxWidth: inner.width - 2
            )
            return
        default:
            break
        }
        guard let lyrics = lyricsCoordinator.lyrics else { return }

        // Wrap first, so scrolling works in screen rows rather than source
        // lines — otherwise the two drift apart on a narrow pane and the active
        // line wanders out of view.
        let width = inner.width - 2
        var rows: [(source: Int, text: String, isContinuation: Bool)] = []
        for (index, line) in lyrics.lines.enumerated() {
            let pieces = line.text.isEmpty ? [""] : wrap(line.text, width: width)
            for (offset, piece) in pieces.enumerated() {
                rows.append((index, piece, offset > 0))
            }
        }
        guard !rows.isEmpty else { return }

        let position = livePosition
        var active: Int?

        switch state {
        case .following:
            active = lyrics.activeLine(at: position)
            if let active, let row = rows.firstIndex(where: { $0.source == active }) {
                // One row of history above the active line, the rest ahead of it.
                lyricsScroll = max(0, row - 1)
            }
        case .untimedProgress:
            // No cues to follow, so walk the text in step with the track. An
            // approximation, labelled as one; without it the strip shows the
            // same four lines for the whole song.
            let span = max(0, rows.count - inner.height)
            let progress = Lyrics.untimedProgress(forFraction: playback.fraction)
            lyricsScroll = Int((Double(span) * progress).rounded())
        case .scrolled, .selected, .notRequested, .loading, .unavailable:
            break
        }
        // Clamp to the last *full* screenful, not to the last row. Clamping to
        // the last row let the viewport slide off the end, so the closing lines
        // of a song were drawn with most of the strip blank — it looked as
        // though the lyrics had vanished.
        let lastFullOffset = max(0, rows.count - inner.height)
        lyricsScroll = min(max(0, lyricsScroll), lastFullOffset)
        lyricsScroll = min(max(0, lyricsScroll), max(0, rows.count - 1))

        for offset in 0..<inner.height {
            let index = lyricsScroll + offset
            guard index < rows.count else { break }
            let row = rows[index]
            let y = inner.minY + offset
            let isActive = active != nil && row.source == active

            if isActive, !row.isContinuation, !lyrics.lines[row.source].words.isEmpty {
                drawKaraokeLine(
                    lyrics.lines[row.source],
                    at: position,
                    x: inner.minX + 1,
                    y: y,
                    width: width
                )
                continue
            }

            // Sung lines recede to grey, the current line is amber, what is
            // coming stays in fog.
            let style: Style
            if isActive {
                style = Style(fg: Palette.amber, bg: Palette.ink).with(.bold)
            } else if let active, row.source < active {
                style = Style(fg: Palette.mute, bg: Palette.ink)
            } else {
                style = Style(fg: Palette.fog, bg: Palette.ink)
            }
            screen.putTruncated(row.text, x: inner.minX + 1, y: y, style: style, maxWidth: width)
        }
    }

    /// Draws one line of enhanced LRC, with the words sung so far lit up.
    private func drawKaraokeLine(
        _ line: Lyrics.Line,
        at position: Double,
        x: Int,
        y: Int,
        width: Int
    ) {
        var cursor = x
        let limit = x + width
        for word in line.words {
            guard cursor < limit else { break }
            let sung = word.time <= position
            let style = sung
                ? Style(fg: Palette.amber, bg: Palette.ink).with(.bold)
                : Style(fg: Palette.fog, bg: Palette.ink)
            cursor += screen.put(word.text, x: cursor, y: y, style: style, maxWidth: limit - cursor)
            if cursor < limit {
                cursor += screen.put(" ", x: cursor, y: y, style: style)
            }
        }
    }

    private func drawVisualization(in rect: Rect) {
        let inner = Panel(title: visualization.title, isFocused: false).draw(in: rect, on: screen)
        guard !inner.isEmpty else { return }

        switch visualization {
        case .bars:
            let count = meter.barCount(forWidth: inner.width)
            guard count > 0 else { return }
            meter.draw(in: inner, on: screen, magnitudes: app.player.analyzer.spectrum(bars: count))
        case .scope:
            let count = scope.sampleCount(forWidth: inner.width)
            scope.draw(in: inner, on: screen, samples: app.player.analyzer.waveform(points: count))
        }
    }

    /// The status line from `branding/text-icons.txt`:
    /// `>))) hum  ▶ Artist — Track   02:14 ━━━━ 05:29  vol 70%`
    /// Top row: the branding mark on the left, the key hints on the right.
    /// These used to live at the bottom; up here they read as a menu bar and the
    /// bottom of the screen belongs to the transport.
    /// Writes the current frame to `~/hum-frame.txt` with its colour codes
    /// intact.
    ///
    /// Pasting a terminal into a chat window strips the escape codes, and for
    /// half-block artwork every pixel of information lives in exactly those
    /// codes — the glyph is always `▀`. A file keeps them.
    private func saveSnapshot() {
        let environment = ProcessInfo.processInfo.environment
        // Overridable so automated runs write somewhere disposable instead of
        // overwriting — or deleting — a snapshot the user is about to send.
        let url: URL
        if let override = environment["HUM_SNAPSHOT_PATH"], !override.isEmpty {
            url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("hum-frame.txt")
        }
        var lines = [
            "hum \(humVersion) frame snapshot",
            "terminal      \(screen.columns)x\(screen.rows)",
            "TERM          \(environment["TERM"] ?? "(unset)")",
            "COLORTERM     \(environment["COLORTERM"] ?? "(unset)")",
            "TERM_PROGRAM  \(environment["TERM_PROGRAM"] ?? "(unset)")",
            "colour depth  \(screen.colorDepth)",
            "artwork style \(ArtworkStyle.best(for: screen.colorDepth))",
            "visualisation \(visualizationVisible ? visualization.title : "hidden")",
            "",
        ]
        lines.append(contentsOf: screen.styledLines())

        let trace = app.lyricsTrace
        if !trace.isEmpty {
            lines.append("")
            lines.append("recent lyrics lookups:")
            lines.append(contentsOf: trace.map { "  " + $0 })
        }

        do {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
            // The full path, so there is no guessing where it went.
            setStatus("wrote \(url.path)", isError: false)
        } catch {
            setStatus("could not write snapshot: \(error.localizedDescription)", isError: true)
        }
    }

    private func drawTitleBar(in rect: Rect) {
        screen.fill(rect, style: Style(fg: Palette.mute, bg: Palette.panel))
        let base = Style(fg: Palette.mute, bg: Palette.panel)

        var x = rect.minX + 1
        x += screen.put(">)))", x: x, y: rect.minY, style: base.fg(Palette.amber).with(.bold))
        x += 1
        x += screen.put("hum", x: x, y: rect.minY, style: base.fg(Palette.fog).with(.bold))
        x += 2

        if showFrameRate {
            x += screen.put("\(frameRate)fps", x: x, y: rect.minY, style: base.fg(Palette.amberDark))
            x += 2
        }

        let hints: [(String, String)] = [
            ("␣", "play"),
            ("⏎", "open"),
            ("⇥", "pane"),
            ("n/p", "skip"),
            ("/", "search"),
            ("m", mode.next.title),
            ("V", visualization.next.title),
            ("z", "viz"),
            ("v", "window"),
            ("L", "lyrics"),
            ("0–5", "rate"),
            ("?", "keys"),
            ("q", "quit"),
        ]

        // Right-align the hints when they fit, so the bar does not look ragged.
        let needed = hints.reduce(0) { $0 + displayWidth($1.0) + displayWidth($1.1) + 3 }
        if needed <= rect.maxX - x - 1 {
            x = rect.maxX - needed - 1
        }

        for (key, label) in hints {
            let width = displayWidth(key) + displayWidth(label) + 3
            if x + width > rect.maxX { break }
            x += screen.put(key, x: x, y: rect.minY, style: base.fg(Palette.amber))
            x += 1
            x += screen.put(label, x: x, y: rect.minY, style: base)
            x += 2
        }
    }

    /// Transport glyphs all come from the same Unicode block.
    ///
    /// This matters more than it sounds: `▶` lives in Geometric Shapes and `⏸` in
    /// Miscellaneous Technical, and the two blocks have different design metrics —
    /// mixing them makes the play icon sit visibly off the baseline that pause
    /// sits on. U+23E8–U+23FA are a purpose-built media-control set.
    private enum Glyph {
        static let play = "⏵"      // U+23F5
        static let pause = "⏸"     // U+23F8
        static let stopped = "⏹"   // U+23F9
        static let previous = "⏮"  // U+23EE
        static let next = "⏭"      // U+23ED
        static let buffering = "⋯"
    }

    private var transportGlyph: String {
        if playback.isBuffering && playback.track != nil { return Glyph.buffering }
        if playback.isPlaying { return Glyph.play }
        if playback.track != nil { return Glyph.pause }
        return Glyph.stopped
    }

    /// The transport box at the bottom: what is playing, and the controls acting
    /// on it. Two content rows inside a panel of its own.
    private func drawTransport(in rect: Rect) {
        let inner = Panel(title: "playing", isFocused: false).draw(in: rect, on: screen)
        guard !inner.isEmpty else { return }
        let base = Style(fg: Palette.fog, bg: Palette.ink)

        // Row one: state glyph, artist — track, album on the right. No ">)))"
        // here: the title bar already carries the mark.
        var x = inner.minX + 1
        x += screen.put(transportGlyph, x: x, y: inner.minY, style: base.fg(Palette.amber))
        x += 1

        if let track = playback.track {
            let album = track.album
            let albumWidth = min(displayWidth(album), max(0, inner.width / 3))
            let titleWidth = max(0, inner.maxX - x - albumWidth - 2)
            screen.putTruncated(
                "\(track.artist) — \(track.title)",
                x: x,
                y: inner.minY,
                style: base,
                maxWidth: titleWidth
            )
            if albumWidth > 0 {
                screen.putTruncated(
                    album,
                    x: inner.maxX - albumWidth,
                    y: inner.minY,
                    style: base.fg(Palette.mute),
                    maxWidth: albumWidth
                )
            }
        } else {
            screen.putTruncated(
                "nothing playing",
                x: x,
                y: inner.minY,
                style: base.fg(Palette.mute),
                maxWidth: inner.width - 2
            )
        }

        guard inner.height >= 2 else { return }
        drawTransportControls(in: Rect(x: inner.minX, y: inner.minY + 1, width: inner.width, height: 1))
    }

    /// Row two of the transport: elapsed, scrubber, total, then the controls and
    /// the volume meter, right-aligned.
    private func drawTransportControls(in rect: Rect) {
        let base = Style(fg: Palette.fog, bg: Palette.ink)
        let elapsed = formatTime(playback.position)
        let total = formatTime(playback.duration)
        let volumeText = "\(Int((playback.volume * 100).rounded()))%"

        // Controls read as buttons; the active one is amber.
        let controls: [(String, Bool)] = [
            (Glyph.previous, false),
            (playback.isPlaying ? Glyph.pause : Glyph.play, playback.isPlaying),
            (Glyph.next, false),
            ("⤮", playback.shuffle),
            ("↻", playback.repeatQueue),
        ]
        let controlsWidth = controls.reduce(0) { $0 + displayWidth($1.0) + 1 }
        let volumeBars = 8
        let rightWidth = controlsWidth + 2 + 4 + volumeBars + 1 + displayWidth(volumeText)

        var x = rect.minX + 1
        x += screen.put(elapsed, x: x, y: rect.minY, style: base.fg(Palette.fog))
        x += 1

        let barWidth = max(0, rect.maxX - x - displayWidth(total) - rightWidth - 3)
        if barWidth > 0 {
            drawProgressBar(
                in: Rect(x: x, y: rect.minY, width: barWidth, height: 1),
                on: screen,
                fraction: playback.fraction,
                background: Palette.ink
            )
            x += barWidth + 1
        }
        x += screen.put(total, x: x, y: rect.minY, style: base.fg(Palette.mute))

        var right = rect.maxX - displayWidth(volumeText)
        screen.put(volumeText, x: right, y: rect.minY, style: base.fg(Palette.mute))

        // Volume as a little stepped meter rather than a number alone.
        right -= volumeBars + 1
        let filled = Int((Double(volumeBars) * Double(playback.volume)).rounded())
        for index in 0..<volumeBars {
            let on = index < filled
            screen.put(
                on ? "▪" : "▫",
                x: right + index,
                y: rect.minY,
                style: base.fg(on ? Palette.amber : Palette.border)
            )
        }
        right -= 4
        screen.put("vol", x: right, y: rect.minY, style: base.fg(Palette.mute))

        right -= controlsWidth + 1
        var controlX = right
        for (glyph, active) in controls {
            screen.put(
                glyph,
                x: controlX,
                y: rect.minY,
                style: base.fg(active ? Palette.amber : Palette.mute)
            )
            controlX += displayWidth(glyph) + 1
        }
    }

    /// Bottom row: transient messages, and where the search prompt appears.
    private func drawStatusLine(in rect: Rect) {
        screen.fill(rect, style: Style(fg: Palette.mute, bg: Palette.ink))
        guard let statusMessage, Date() < statusExpiry else { return }
        screen.putTruncated(
            statusMessage,
            x: rect.minX + 1,
            y: rect.minY,
            style: Style(fg: statusIsError ? Palette.amber : Palette.mute, bg: Palette.ink),
            maxWidth: rect.width - 2
        )
    }

    private func drawSearchPrompt(in rect: Rect, query: String) {
        screen.fill(rect, style: Style(fg: Palette.fog, bg: Palette.ink))
        var x = rect.minX + 1
        x += screen.put("/", x: x, y: rect.minY, style: Style(fg: Palette.amber, bg: Palette.ink).with(.bold))
        x += screen.put(
            query,
            x: x,
            y: rect.minY,
            style: Style(fg: Palette.fog, bg: Palette.ink),
            maxWidth: rect.width - 4
        )
        screen.put("▏", x: x, y: rect.minY, style: Style(fg: Palette.amber, bg: Palette.ink).with(.bold))
    }

    /// What the cursor is pointing at, as something a playlist can hold.
    ///
    /// A playlist takes any of the three: the server expands an album or an
    /// artist into its tracks. The facet panes are the exception — a genre is
    /// not an item, so there is nothing to add.
    private func addableSelection() -> (ratingKey: String, label: String)? {
        switch focus {
        case .tracks:
            let index = selection[Pane.tracks.rawValue]
            guard tracks.indices.contains(index) else { return nil }
            return (tracks[index].id, "“\(tracks[index].title)”")
        case .albums:
            let index = selection[Pane.albums.rawValue]
            guard albums.indices.contains(index) else { return nil }
            return (albums[index].id, "the album “\(albums[index].title)”")
        case .collections:
            let index = selection[Pane.collections.rawValue]
            guard mode == .artists, collections.indices.contains(index) else { return nil }
            return (collections[index].id, "everything by \(collections[index].title)")
        }
    }

    private func beginAddToPlaylist() {
        guard section != nil else {
            setStatus("no library yet", isError: true)
            return
        }
        guard let candidate = addableSelection() else {
            setStatus(
                focus == .collections && mode != .artists
                    ? "a \(mode.singular) is not something a playlist can hold"
                    : "nothing selected to add",
                isError: true
            )
            return
        }
        pendingAdd = candidate
        setStatus("fetching playlists…", isError: false)
        app.loadPlaylistChoices()
    }

    private func handlePlaylistKey(_ key: Key, playlists: [CollectionItem], selected: Int) {
        switch key {
        case .escape, .character("q"):
            pendingAdd = nil
            overlay = .none
            setStatus("", isError: false)

        case .down, .character("j"):
            overlay = .playlists(playlists, selected: min(selected + 1, playlists.count - 1))

        case .up, .character("k"):
            overlay = .playlists(playlists, selected: max(selected - 1, 0))

        case .enter:
            defer {
                pendingAdd = nil
                overlay = .none
            }
            guard let pending = pendingAdd,
                  let section = section,
                  playlists.indices.contains(selected) else { return }
            let chosen = playlists[selected]
            app.addToPlaylist(
                chosen.id,
                playlistTitle: chosen.title,
                ratingKey: pending.ratingKey,
                describing: pending.label,
                section: section
            )

        default:
            break
        }
    }

    private func drawPlaylistOverlay(_ playlists: [CollectionItem], selected: Int) {
        let titleWidth = playlists.map { displayWidth($0.title) }.max() ?? 0
        let width = min(screen.columns - 4, max(titleWidth + 10, 28))
        let height = min(screen.rows - 4, playlists.count + 2)
        let rect = Rect(
            x: (screen.columns - width) / 2,
            y: (screen.rows - height) / 2,
            width: width,
            height: height
        )

        screen.fill(rect, style: Style(fg: Palette.fog, bg: Palette.panel))
        let inner = Panel(
            title: pendingAdd.map { "add \($0.label)" } ?? "add to playlist",
            isFocused: true,
            style: Style(fg: Palette.amber, bg: Palette.panel),
            titleStyle: Style(fg: Palette.amber, bg: Palette.panel)
        ).draw(in: rect, on: screen)

        var list = ListView(
            rows: playlists.map { ListView.Row(text: $0.title, detail: $0.detail) },
            selected: selected,
            isFocused: true,
            emptyMessage: "no playlists"
        )
        list.scrollToSelection(viewportHeight: inner.height)
        list.draw(in: inner, on: screen)
    }

    private func drawHelpOverlay() {
        let entries: [(String, String)] = [
            ("space", "play / pause"),
            ("enter", "drill into pane, play track"),
            ("tab ⇧tab / h l ← →", "move between panes"),
            ("j k ↑ ↓", "move selection"),
            ("g G", "first / last"),
            ("n p", "next / previous track"),
            ("[ ]", "seek ∓10s"),
            ("- +", "volume"),
            ("s r", "shuffle / repeat"),
            ("e", "queue selection"),
            ("m", "cycle artists / genres / styles / moods / labels"),
            ("x", "play something at random"),
            ("X", "shuffle the whole library, without end"),
            ("a", "add the selection to a playlist"),
            ("/", "search the library"),
            ("L", "show or hide the lyrics strip"),
            (", .", "scroll the lyrics strip a line at a time"),
            ("< >", "page the lyrics strip (g resumes following)"),
            ("V", "switch spectrum / waveform"),
            ("z", "show or hide the visualisation"),
            ("esc", "close overlay or search results"),
            ("S", "write ~/hum-frame.txt (colour intact)"),
            ("q ^C", "quit"),
        ]

        let keyWidth = entries.map { displayWidth($0.0) }.max() ?? 0
        let labelWidth = entries.map { displayWidth($0.1) }.max() ?? 0
        let width = min(screen.columns - 4, keyWidth + labelWidth + 7)
        let height = min(screen.rows - 4, entries.count + 2)
        let rect = Rect(
            x: (screen.columns - width) / 2,
            y: (screen.rows - height) / 2,
            width: width,
            height: height
        )

        screen.fill(rect, style: Style(fg: Palette.fog, bg: Palette.panel))
        let inner = Panel(
            title: "keys",
            isFocused: true,
            style: Style(fg: Palette.amber, bg: Palette.panel),
            titleStyle: Style(fg: Palette.amber, bg: Palette.panel)
        ).draw(in: rect, on: screen)

        for (row, entry) in entries.enumerated() {
            let y = inner.minY + row
            guard y < inner.maxY else { break }
            screen.putTruncated(
                entry.0,
                x: inner.minX + 1,
                y: y,
                style: Style(fg: Palette.amber, bg: Palette.panel),
                maxWidth: keyWidth
            )
            screen.putTruncated(
                entry.1,
                x: inner.minX + keyWidth + 3,
                y: y,
                style: Style(fg: Palette.fog, bg: Palette.panel),
                maxWidth: inner.width - keyWidth - 4
            )
        }
    }
}
