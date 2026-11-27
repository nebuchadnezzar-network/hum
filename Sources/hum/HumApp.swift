import AppKit
import Foundation
import HumPlayer
import HumPlex
import HumTUI

/// What the leftmost pane is listing. Artists are the default; the facets cover
/// genres, styles, moods and labels by filtering albums server-side.
///
/// Which facets exist is a property of the *metadata type*, not of the
/// library. From the specification, on a `Filter`'s `key`:
///
/// > This provides the endpoint where the possible range of values for the
/// > filter can be retrieved [...] This will include a `type` argument that
/// > matches the metadata type of the Type element.
///
/// So `label` filters albums (type 9) but not tracks (type 10) — and these
/// facets narrow albums, which is why it belongs here. This list is still
/// hardcoded, which is the remaining guess: `hum tags` reports the server's
/// own `Meta.Type[].Filter[]` so it can be driven from that instead.
enum CollectionMode: CaseIterable {
    case artists, genres, styles, moods, labels, playlists, rated

    var title: String {
        switch self {
        case .artists: return "artists"
        case .genres: return "genres"
        case .styles: return "styles"
        case .moods: return "moods"
        case .labels: return "labels"
        case .playlists: return "playlists"
        case .rated: return "rated"
        }
    }

    /// Whether choosing an item in this mode yields tracks directly, with no
    /// album in between.
    ///
    /// A playlist is a flat list and its order is the point of it; grouping it
    /// by album would destroy that. "Rated" is one list by construction. Both
    /// skip the middle pane rather than inventing a level for it.
    var isFlat: Bool {
        switch self {
        case .playlists, .rated: return true
        case .artists, .genres, .styles, .moods, .labels: return false
        }
    }

    /// The singular noun, for prompts like "press ⏎ on a genre".
    var singular: String {
        switch self {
        case .artists: return "artist"
        case .genres: return "genre"
        case .styles: return "style"
        case .moods: return "mood"
        case .labels: return "label"
        case .playlists: return "playlist"
        case .rated: return "track"
        }
    }

    /// What the leftmost pane says when it has nothing.
    ///
    /// Naming the mode rather than saying "nothing here": an empty pane is the
    /// signal that a facet is unsupported or returned nothing, and "no moods"
    /// says that where "nothing here" hides it.
    var collectionsEmptyMessage: String {
        "no \(title)"
    }

    /// What the albums pane says when it has nothing.
    ///
    /// "nothing here" was shown whenever the pane was empty, which read as "this
    /// library has no albums" at the exact moment the truth was "pick something
    /// on the left first". A facet mode does not load albums until a value is
    /// chosen, so the pane is empty by design right after `m`.
    func albumsEmptyMessage(hasCollections: Bool, isSearching: Bool) -> String {
        if isSearching { return "no matching albums" }
        if isFlat { return "\(title) go straight to tracks" }
        if !hasCollections { return collectionsEmptyMessage }
        // Artists load their albums as the cursor moves, so an empty pane there
        // is a real answer rather than a missing step.
        if facet == nil { return "no albums" }
        return "press ⏎ on a \(singular)"
    }

    /// What the tracks pane says when it has nothing.
    func tracksEmptyMessage(hasCollections: Bool, hasAlbums: Bool, isSearching: Bool) -> String {
        if isSearching { return "no matching tracks" }
        if !hasCollections { return collectionsEmptyMessage }
        if isFlat { return "press ⏎ on a \(singular)" }
        if !hasAlbums { return albumsEmptyMessage(hasCollections: hasCollections, isSearching: isSearching) }
        return "press ⏎ on an album"
    }

    /// The Plex facet endpoint and filter name. Nil for artists, which are items
    /// rather than a facet.
    var facet: String? {
        switch self {
        case .artists, .playlists, .rated: return nil
        case .genres: return "genre"
        case .styles: return "style"
        case .moods: return "mood"
        case .labels: return "label"
        }
    }

    var next: CollectionMode {
        let all = CollectionMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// Where `x` landed: the whole three-pane state plus what to play.
///
/// One value rather than a sequence of load events, because a random landing is
/// atomic — the panes, the selections and the track that starts all describe the
/// same choice, and posting them separately would show the reader three
/// unrelated jumps while the next request was still in flight.
struct Landing {
    var mode: CollectionMode
    var collections: [CollectionItem]
    var collectionIndex: Int
    var albums: [Album]
    var albumIndex: Int?
    var tracks: [Track]
    var trackIndex: Int

    var describedChoice: String {
        guard collections.indices.contains(collectionIndex) else { return mode.title }
        let chosen = collections[collectionIndex].title
        // "rated tracks" already names itself; "track · rated tracks" does not
        // read as anything.
        guard mode != .rated else { return chosen }
        return "\(mode.singular) · \(chosen)"
    }
}


/// Owns the Plex connection, the player and all the async loading. Knows nothing
/// about layout or key handling — it only posts events for the UI thread to apply.
final class HumApp {
    let events = EventQueue()
    let player = Player()

    private(set) var client: PlexClient
    private(set) var server: PlexServer?
    private(set) var sections: [LibrarySection] = []
    private var preferences: Preferences

    /// Non-nil in `hum demo`: every loader short-circuits to synthetic data and
    /// nothing touches the network.
    private let demo: DemoLibrary?

    /// Guards against a slow response for an old selection overwriting a new one.
    private var loadGeneration = 0

    /// Recent lyrics lookups, newest last, for the `S` snapshot. Written from
    /// fetch tasks and read by the UI thread, so it is lock-guarded.
    private let lyricsTraceLock = UnfairLock()
    private var lyricsTraceLines: [String] = []

    /// Lyrics that have been fetched successfully this session, by track id.
    ///
    /// Deliberately an application cache of *successes only*, not an HTTP cache
    /// — the URL cache this replaced stored failures too, and a cached 404
    /// poisoned a track for the whole session.
    ///
    /// It exists because the server is unreliable but correct when it answers:
    /// the identical request returns 200 with 9441 bytes in one run and 404
    /// seconds later. Lyrics for a track do not change while hum is open, so
    /// having fetched them once there is no reason to risk asking again — and
    /// re-asking is precisely what turned a flaky server into a feature that
    /// "sometimes works".
    private let lyricsCacheLock = UnfairLock()
    private var lyricsCache: [String: String] = [:]
    private var lyricsCacheOrder: [String] = []
    private static let lyricsCacheLimit = 128

    private func cachedLyrics(for trackID: String) -> String? {
        lyricsCacheLock.withLock { lyricsCache[trackID] }
    }

    private func cacheLyrics(_ text: String, for trackID: String) {
        lyricsCacheLock.withLock {
            if lyricsCache[trackID] == nil {
                lyricsCacheOrder.append(trackID)
                while lyricsCacheOrder.count > Self.lyricsCacheLimit {
                    lyricsCache.removeValue(forKey: lyricsCacheOrder.removeFirst())
                }
            }
            lyricsCache[trackID] = text
        }
    }

    private func recordLyricsTrace(_ lines: [String]) {
        // Stamped so the ordering of interleaved lookups is unambiguous — which
        // request came first matters more than any single line.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let stamp = formatter.string(from: Date())
        let stamped = lines.enumerated().map { index, line in
            index == 0 ? "\(stamp)  \(line)" : "              \(line)"
        }
        lyricsTraceLock.withLock {
            lyricsTraceLines.append(contentsOf: stamped)
            // A handful of lookups is plenty to see a pattern.
            if lyricsTraceLines.count > 60 {
                lyricsTraceLines.removeFirst(lyricsTraceLines.count - 60)
            }
        }
    }

    /// The recent lyrics trace, for diagnostics.
    var lyricsTrace: [String] {
        lyricsTraceLock.withLock { lyricsTraceLines }
    }

    init(preferences: Preferences, token: String, demoMode: Bool = false) {
        self.preferences = preferences
        let device = DeviceInfo(clientIdentifier: preferences.clientIdentifier)
        self.client = PlexClient(device: device, token: token)
        self.demo = demoMode
            ? DemoLibrary(events: events)
            : nil
        wirePlayer()
    }

    var isDemo: Bool { demo != nil }

    /// Supplies cover-art bytes for a Plex thumb path. In demo mode the covers
    /// are generated locally so the pane has something to show offline.
    func artworkFetcher() -> (String) async -> Data? {
        if let demo {
            return { source in demo.coverArt(for: source) }
        }
        return { [weak self] source in
            guard let self, let server = self.server,
                  let url = self.client.artworkURL(for: source, on: server, size: 400)
            else { return nil }
            return try? await PlexSession.shared.data(from: url).0
        }
    }

    // MARK: - Player wiring

    private func wirePlayer() {
        player.setVolume(preferences.volume)

        player.streamURLProvider = { [weak self] track in
            guard let self else { throw PlexError.notAuthenticated }
            // Demo mode plays real audio, generated on first use. Without it
            // nothing downstream of AVPlayer runs — no tap, no spectrum, no
            // media keys — so the demo could not show most of what it is for.
            if self.demo != nil {
                guard let url = DemoAudio.url(for: track) else {
                    throw PlexError.notAuthenticated
                }
                return url
            }
            guard let server = self.server else { throw PlexError.notAuthenticated }
            return try self.client.streamURL(for: track, on: server)
        }

        player.artworkURLProvider = { [weak self] track in
            guard let self, self.demo == nil, let server = self.server else { return nil }
            return self.client.artworkURL(for: track.thumb, on: server, size: 512)
        }

        player.onStateChange = { [weak self] state in
            self?.events.post(.playback(state))
            self?.topUpShuffleAll(state)
        }

        // Tell the server what we're playing so Plex's own clients stay in sync.
        player.onTrackChange = { [weak self] track in
            guard let self else { return }
            self.playedSeconds = 0
            self.lastPlayingSample = Date()
            // No report here. The run loop reports on every play/pause
            // transition, and starting a track is one, so reporting from both
            // put two identical timelines on the wire 400ms apart:
            //
            //     16:45:41.683  …&state=playing&time=0&…
            //     16:45:42.098  …&state=playing&time=0&playbackTime=414&…
            _ = track
        }
    }

    /// Audio actually heard since this track started, as distinct from where
    /// the playhead sits. Plex's web client reports both; hum reported only the
    /// playhead, and the server cannot tell a listen from a seek with one.
    private var playedSeconds: Double = 0
    private var lastPlayingSample: Date?

    /// Advances `playedSeconds` to now. Reports happen on state changes and on
    /// a ten-second timer, which is a fine enough grain for a listen counter.
    private func sampleListeningTime(isPlaying: Bool) {
        let now = Date()
        if let last = lastPlayingSample {
            playedSeconds += now.timeIntervalSince(last)
        }
        lastPlayingSample = isPlaying ? now : nil
    }

    /// Reports the current position to Plex. Called from the UI loop on a timer
    /// rather than on every tick — the timeline endpoint is not free.
    func reportProgress() {
        guard demo == nil else { return }
        guard let server, let track = player.state.track else { return }
        let state = player.state
        sampleListeningTime(isPlaying: state.isPlaying)
        let played = playedSeconds
        Task {
            await client.reportProgress(
                track: track,
                positionSeconds: state.position,
                state: state.isPlaying ? "playing" : "paused",
                playedSeconds: played,
                on: server
            )
        }
    }

    /// Tells the server the session is over, and waits briefly for it to land.
    ///
    /// Called on the way out, where "fire and forget" means "never sent" — the
    /// process exits before the task runs.
    func reportStopped() {
        guard demo == nil, let server, let track = player.state.track else { return }
        let position = player.state.position
        sampleListeningTime(isPlaying: false)
        let played = playedSeconds
        let finished = DispatchSemaphore(value: 0)
        Task { [client] in
            await client.reportProgress(
                track: track, positionSeconds: position, state: "stopped",
                playedSeconds: played, on: server
            )
            finished.signal()
        }
        // Quitting must not hang on an unreachable server.
        _ = finished.wait(timeout: .now() + 2)
    }

    /// Clears the in-flight marker. Posted through the event queue so it lands
    /// on the UI thread, where the set is read.
    func albumsSettled(parentID: String) { albumsInFlight.remove(parentID) }
    func tracksSettled(albumID: String) { tracksInFlight.remove(albumID) }

    /// Sets the viewer's rating on a track, 0–5 whole stars.
    ///
    /// Optimistic: the star appears at once and is put back if the server
    /// refuses. A rating is a judgement someone just made, and waiting a round
    /// trip to show it makes the keypress feel ignored — but a star that stayed
    /// on screen while the server rejected it would be a lie, so the failure
    /// path restores the old value and says so.
    func rate(track: Track, stars: Int) {
        let rating = Rating.fromStars(stars)
        guard rating != (track.userRating ?? 0) else { return }
        let previous = track.userRating

        events.post(.ratingChanged(trackID: track.id, rating: rating > 0 ? rating : nil))
        guard demo == nil else { return }
        guard let server else {
            events.post(.status("not connected; rating not saved", isError: true))
            events.post(.ratingChanged(trackID: track.id, rating: previous))
            return
        }

        Task { [self] in
            do {
                try await client.rate(ratingKey: track.id, rating: rating, on: server)
                events.post(.status(
                    stars == 0
                        ? "rating cleared — \(track.title)"
                        : "rated \(stars)★ — \(track.title)",
                    isError: false
                ))
            } catch {
                events.post(.ratingChanged(trackID: track.id, rating: previous))
                events.post(.status(
                    "could not rate: \(error.localizedDescription)", isError: true
                ))
            }
        }
    }

    /// Applies a rating to every copy of the track hum is holding.
    ///
    /// There are three: the list on screen, the per-album cache, and whatever
    /// is playing. Updating one and not the others is how a star appears in the
    /// track list and then vanishes when you walk away and come back.
    func applyRating(trackID: String, rating: Double?) {
        for (albumID, cached) in trackCache where cached.contains(where: { $0.id == trackID }) {
            trackCache[albumID] = cached.map {
                $0.id == trackID ? $0.withRating(rating) : $0
            }
        }
        player.applyRating(trackID: trackID, rating: rating)
    }

    func persistVolume(_ volume: Float) {
        preferences.volume = volume
        try? preferences.save()
    }

    // MARK: - Connection

    /// Finds the best server and its music libraries.
    func connect() {
        if let demo {
            let (server, sections) = demo.connection()
            self.server = server
            self.sections = sections
            events.post(.connected(server, sections))
            return
        }
        Task { [self] in
            do {
                let server = try await client.bestServer(preferring: preferences.lastServerIdentifier)
                let sections = try await client.musicSections(on: server)
                self.server = server
                self.sections = sections

                preferences.lastServerIdentifier = server.clientIdentifier
                try? preferences.save()

                events.post(.connected(server, sections))
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    var preferredSection: LibrarySection? {
        if let id = preferences.lastSectionID, let match = sections.first(where: { $0.id == id }) {
            return match
        }
        return sections.first
    }

    func rememberSection(_ section: LibrarySection) {
        preferences.lastSectionID = section.id
        try? preferences.save()
    }

    // MARK: - Loading

    /// Artists per page.
    ///
    /// Small enough that startup is cheap, large enough that a page covers
    /// several screenfuls of scrolling. 788 artists came to 1.4MB; 150 is about
    /// 260KB, and most sessions never ask for a second page.
    static let collectionPageSize = 150

    /// Stands in for "every rated track" in the collections pane.
    static let ratedCollectionID = "hum:rated"

    private var collectionTotal = 0
    private var collectionSection: String?
    private var collectionsInFlight = false

    private static func collectionItem(_ artist: Artist) -> CollectionItem {
        CollectionItem(id: artist.id, title: artist.title, detail: artist.genres.first)
    }

    /// True while there are artists the reader has not been sent yet.
    func hasMoreCollections(loaded: Int) -> Bool { loaded < collectionTotal }

    /// Fetches the page after `loaded` items, if there is one.
    func loadMoreCollections(section: LibrarySection, mode: CollectionMode, loaded: Int) {
        guard demo == nil, mode.facet == nil else { return }
        guard let server, section.id == collectionSection else { return }
        guard !collectionsInFlight, loaded < collectionTotal else { return }
        collectionsInFlight = true
        let generation = loadGeneration

        Task { [self] in
            defer { events.post(.collectionsSettled) }
            do {
                let page = try await client.artistsPage(
                    in: section, start: loaded, size: Self.collectionPageSize, on: server
                )
                guard generation == loadGeneration else { return }
                collectionTotal = page.total
                events.post(
                    .sectionPageLoaded(
                        sectionID: section.id,
                        collections: page.artists.map(Self.collectionItem),
                        total: page.total
                    )
                )
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    func collectionsSettled() { collectionsInFlight = false }

    // MARK: - Playlists

    /// Fetches the audio playlists, for the picker behind `a`.
    ///
    /// Deliberately not cached: a playlist added from a phone a minute ago
    /// should be in the list, and this runs only when the reader asks.
    func loadPlaylistChoices() {
        if demo != nil {
            events.post(.status("demo mode cannot write to a server", isError: true))
            return
        }
        guard let server else { return }
        Task { [self] in
            do {
                let playlists = try await client.audioPlaylists(on: server)
                guard !playlists.isEmpty else {
                    // hum cannot create one — `POST /playlists` is documented
                    // without the parameters that would name it — so say where
                    // to make one rather than offering an empty list.
                    events.post(.status(
                        "no playlists yet — make one in a Plex client first",
                        isError: true
                    ))
                    return
                }
                events.post(.playlistChoices(playlists.map { list in
                    CollectionItem(id: list.id, title: list.title, detail: list.count.map { "\($0)" })
                }))
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    /// Adds one item — a track, an album or an artist — to a playlist.
    ///
    /// A rating key is all the server needs for any of the three: it expands a
    /// container into its tracks.
    func addToPlaylist(
        _ playlistID: String,
        playlistTitle: String,
        ratingKey: String,
        describing label: String,
        section: LibrarySection
    ) {
        guard let server else { return }
        Task { [self] in
            do {
                let count = try await client.addToPlaylist(
                    playlistID, ratingKey: ratingKey, in: section, on: server
                )
                let tail = count.map { " (\($0) tracks)" } ?? ""
                events.post(.status("added \(label) to \(playlistTitle)\(tail)", isError: false))
            } catch {
                events.post(.status("could not add: \(error.localizedDescription)", isError: true))
            }
        }
    }

    // MARK: - Shuffle all

    /// The library a random mix is being drawn from, or nil when not shuffling
    /// everything. Also the flag that keeps the mix topped up.
    private var shuffleAllSection: LibrarySection?
    private var shuffleAllTotal = 0
    private var shuffleAllTopUpInFlight = false

    /// Tracks per batch, and how few may remain before another is fetched.
    ///
    /// 24 is a few minutes of listening, so the top-up happens while something
    /// is playing rather than between tracks; 6 remaining is enough runway that
    /// a slow request does not end the music.
    private static let shuffleBatch = 24
    private static let shuffleRunway = 6
    /// Tracks per request. A batch read one at a time is 24 requests.
    private static let shuffleWindow = 8

    /// Plays a random mix of the whole library, topped up as it goes.
    ///
    /// Shuffle on `s` reorders the queue you have; this one has no end.
    func shuffleAll(section: LibrarySection) {
        if let demo {
            // Every demo track, in one go — the whole library is in memory and
            // there is nothing to page.
            var all: [Track] = []
            for item in demo.collections(mode: .artists) {
                for album in demo.albums(for: item, mode: .artists) {
                    all.append(contentsOf: demo.tracks(albumID: album.id))
                }
            }
            all.shuffle()
            guard !all.isEmpty else {
                events.post(.status("nothing to shuffle", isError: true))
                return
            }
            events.post(.shuffleAll(tracks: all, replacing: true))
            return
        }

        guard let server else { return }
        events.post(.status("gathering a random mix…", isError: false))
        Task { [self] in
            do {
                // A page of one, only to learn totalSize.
                let head = try await client.tracksPage(in: section, start: 0, size: 1, on: server)
                guard head.total > 0 else {
                    events.post(.status("no tracks in this library", isError: true))
                    return
                }
                shuffleAllTotal = head.total
                let mix = try await randomTracks(section: section, on: server)
                guard !mix.isEmpty else {
                    events.post(.status("could not draw a mix", isError: true))
                    return
                }
                shuffleAllSection = section
                events.post(.shuffleAll(tracks: mix, replacing: true))
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    /// Re-arms the mix after `play` cleared it.
    ///
    /// Starting the mix goes through `play`, which clears the flag because
    /// choosing something is how you normally leave a random mix. The caller
    /// that *is* the mix says so with this.
    func resumeShuffleAll(section: LibrarySection) {
        shuffleAllSection = section
    }

    /// Reads a few windows at random offsets and shuffles what comes back.
    private func randomTracks(
        section: LibrarySection,
        on server: PlexServer
    ) async throws -> [Track] {
        let offsets = ShuffleOffsets.pick(
            total: shuffleAllTotal,
            window: Self.shuffleWindow,
            count: Self.shuffleBatch
        )
        var picked: [Track] = []
        var seen = Set<String>()
        for start in offsets {
            let page = try await client.tracksPage(
                in: section, start: start, size: Self.shuffleWindow, on: server
            )
            for track in page.tracks where !seen.contains(track.id) {
                seen.insert(track.id)
                picked.append(track)
            }
        }
        picked.shuffle()
        return picked
    }

    /// Adds another batch when the mix is running out.
    ///
    /// Driven from playback rather than a timer: the only thing that consumes
    /// the queue is tracks finishing.
    private func topUpShuffleAll(_ state: PlaybackState) {
        guard let section = shuffleAllSection, let server else { return }
        guard !shuffleAllTopUpInFlight else { return }
        guard state.queueCount - state.queueIndex <= Self.shuffleRunway else { return }
        shuffleAllTopUpInFlight = true
        Task { [self] in
            defer { shuffleAllTopUpInFlight = false }
            do {
                let more = try await randomTracks(section: section, on: server)
                guard !more.isEmpty else { return }
                events.post(.shuffleAll(tracks: more, replacing: false))
            } catch {
                // A failed top-up is not worth interrupting the music for; the
                // next track finishing will try again.
            }
        }
    }

    // MARK: - Random

    /// Picks a mode, a value within it, an album and a track — all at random —
    /// and starts playing.
    ///
    /// Modes are tried in shuffled order and a mode that yields nothing is
    /// skipped, so this works on a library with no moods, no playlists and
    /// nothing rated as long as *something* is there. Each step is a plain
    /// `await` rather than the event-posting loaders: the panes should jump once,
    /// to a finished choice, not three times as the requests land.
    func surpriseMe(section: LibrarySection) {
        if let demo {
            let modes = CollectionMode.allCases.shuffled()
            for mode in modes {
                let items = demo.collections(mode: mode)
                guard let index = items.indices.randomElement() else { continue }
                let pick = items[index]
                if mode.isFlat {
                    let tracks = demo.flatTracks(for: pick.id)
                    guard let track = tracks.indices.randomElement() else { continue }
                    events.post(.landed(Landing(
                        mode: mode, collections: items, collectionIndex: index,
                        albums: [], albumIndex: nil, tracks: tracks, trackIndex: track
                    )))
                    return
                }
                let albums = demo.albums(for: pick, mode: mode)
                guard let albumIndex = albums.indices.randomElement() else { continue }
                let tracks = demo.tracks(albumID: albums[albumIndex].id)
                guard let track = tracks.indices.randomElement() else { continue }
                events.post(.landed(Landing(
                    mode: mode, collections: items, collectionIndex: index,
                    albums: albums, albumIndex: albumIndex, tracks: tracks, trackIndex: track
                )))
                return
            }
            events.post(.status("nothing to play", isError: true))
            return
        }

        guard let server else { return }
        events.post(.status("finding something…", isError: false))
        Task { [self] in
            for mode in CollectionMode.allCases.shuffled() {
                do {
                    if let landing = try await land(in: mode, section: section, on: server) {
                        events.post(.landed(landing))
                        return
                    }
                } catch {
                    // A mode that errors is a mode this server does not support
                    // — an unsupported facet is the whole reason for trying
                    // several. Keep going rather than reporting it.
                    continue
                }
            }
            events.post(.status("found nothing to play", isError: true))
        }
    }

    private func land(
        in mode: CollectionMode,
        section: LibrarySection,
        on server: PlexServer
    ) async throws -> Landing? {
        let items: [CollectionItem]
        switch mode {
        case .artists:
            let page = try await client.artistsPage(
                in: section, start: 0, size: Self.collectionPageSize, on: server
            )
            items = page.artists.map(Self.collectionItem)
        case .playlists:
            items = try await client.audioPlaylists(on: server).map { list in
                CollectionItem(id: list.id, title: list.title, detail: list.count.map { "\($0)" })
            }
        case .rated:
            items = [CollectionItem(id: Self.ratedCollectionID, title: "rated tracks", detail: nil)]
        case .genres, .styles, .moods, .labels:
            guard let facet = mode.facet else { return nil }
            items = try await client.facet(facet, in: section, on: server)
                .map { CollectionItem(id: $0.id, title: $0.title, detail: nil) }
        }
        guard let index = items.indices.randomElement() else { return nil }
        let pick = items[index]

        if mode.isFlat {
            let tracks = mode == .rated
                ? try await client.ratedTracks(in: section, on: server)
                : try await client.playlistTracks(pick.id, on: server)
            guard let track = tracks.indices.randomElement() else { return nil }
            return Landing(
                mode: mode, collections: items, collectionIndex: index,
                albums: [], albumIndex: nil, tracks: tracks, trackIndex: track
            )
        }

        let albums: [Album]
        if let facet = mode.facet {
            albums = try await client.albums(
                in: section, facet: facet, facetID: pick.id, on: server
            )
        } else {
            albums = try await client.albums(ofArtist: pick.id, on: server)
        }
        guard let albumIndex = albums.indices.randomElement() else { return nil }
        let tracks = try await client.tracks(ofAlbum: albums[albumIndex].id, on: server)
        guard let track = tracks.indices.randomElement() else { return nil }
        return Landing(
            mode: mode, collections: items, collectionIndex: index,
            albums: albums, albumIndex: albumIndex, tracks: tracks, trackIndex: track
        )
    }

    func loadCollections(section: LibrarySection, mode: CollectionMode) {
        if let demo {
            events.post(.sectionLoaded(sectionID: section.id, collections: demo.collections(mode: mode)))
            return
        }
        guard let server else { return }
        loadGeneration += 1
        let generation = loadGeneration

        Task { [self] in
            do {
                let items: [CollectionItem]
                if let facet = mode.facet {
                    items = try await client.facet(facet, in: section, on: server)
                        .map { CollectionItem(id: $0.id, title: $0.title, detail: nil) }
                } else if mode == .playlists {
                    let playlists = try await client.audioPlaylists(on: server)
                    guard generation == loadGeneration else { return }
                    collectionTotal = playlists.count
                    collectionSection = section.id
                    events.post(
                        .sectionLoaded(
                            sectionID: section.id,
                            collections: playlists.map { list in
                                let tracks = list.count.map { "\($0)" }
                                return CollectionItem(id: list.id, title: list.title, detail: tracks)
                            }
                        )
                    )
                    return
                } else if mode == .rated {
                    // One synthetic row: the whole rated set is a single list,
                    // so there is nothing to choose between.
                    collectionTotal = 1
                    collectionSection = section.id
                    events.post(
                        .sectionLoaded(
                            sectionID: section.id,
                            collections: [
                                CollectionItem(id: Self.ratedCollectionID, title: "rated tracks", detail: nil)
                            ]
                        )
                    )
                    return
                } else {
                    // One page only. The rest arrives as the reader scrolls
                    // towards it — see `loadMoreCollections`.
                    let page = try await client.artistsPage(
                        in: section, start: 0, size: Self.collectionPageSize, on: server
                    )
                    guard generation == loadGeneration else { return }
                    collectionTotal = page.total
                    collectionSection = section.id
                    events.post(
                        .sectionLoaded(
                            sectionID: section.id,
                            collections: page.artists.map(Self.collectionItem)
                        )
                    )
                    return
                }
                guard generation == loadGeneration else { return }
                // Facets are short lists — genres, moods — and arrive whole.
                collectionTotal = items.count
                collectionSection = section.id
                events.post(.sectionLoaded(sectionID: section.id, collections: items))
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    /// Albums already fetched, keyed by the row that asked for them.
    ///
    /// Arrowing down a list and back up re-asked the server for each row passed
    /// over a second time. Bounded, because a library here has 788 artists and
    /// none of this is worth unbounded memory.
    private var albumCache: [String: [Album]] = [:]
    private var albumCacheOrder: [String] = []
    private static let browseCacheLimit = 64

    /// Requests on the wire. The cache alone is not enough: it only fills when
    /// a response arrives, so anything asking again in the meantime saw an
    /// empty cache and asked the server a second time. A server log caught it
    /// 8ms apart, on two connections, for byte-identical results:
    ///
    ///     16:45:39.251 #24 [61725] GET /library/metadata/33191/children  10869 bytes
    ///     16:45:39.259 #20 [61747] GET /library/metadata/33191/children  10869 bytes
    ///
    /// Arrow to a row (which schedules a load), then Tab before it lands: the
    /// pane is still empty, so `ensureLoaded` asks too.
    private var albumsInFlight: Set<String> = []
    private var tracksInFlight: Set<String> = []

    private func cacheAlbums(_ albums: [Album], for key: String) {
        if albumCache[key] == nil { albumCacheOrder.append(key) }
        albumCache[key] = albums
        while albumCacheOrder.count > Self.browseCacheLimit {
            albumCache.removeValue(forKey: albumCacheOrder.removeFirst())
        }
    }

    func loadAlbums(for item: CollectionItem, section: LibrarySection, mode: CollectionMode) {
        if let demo {
            events.post(.albumsLoaded(parentID: item.id, albums: demo.albums(for: item, mode: mode)))
            return
        }
        if let cached = albumCache[item.id] {
            events.post(.albumsLoaded(parentID: item.id, albums: cached))
            return
        }
        guard let server, !albumsInFlight.contains(item.id) else { return }
        albumsInFlight.insert(item.id)
        Task { [self] in
            defer { events.post(.albumsSettled(parentID: item.id)) }
            do {
                let albums: [Album]
                if let facet = mode.facet {
                    albums = try await client.albums(
                        in: section,
                        facet: facet,
                        facetID: item.id,
                        on: server
                    )
                } else {
                    albums = try await client.albums(ofArtist: item.id, on: server)
                }
                cacheAlbums(albums, for: item.id)
                events.post(.albumsLoaded(parentID: item.id, albums: albums))
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    /// Tracks already fetched, keyed by album. Stores the enriched copy, so a
    /// revisit does not repeat the `/children` read *or* the batch stream read
    /// behind it.
    private var trackCache: [String: [Track]] = [:]
    private var trackCacheOrder: [String] = []

    private func cacheTracks(_ tracks: [Track], for albumID: String) {
        if trackCache[albumID] == nil { trackCacheOrder.append(albumID) }
        trackCache[albumID] = tracks
        while trackCacheOrder.count > Self.browseCacheLimit {
            trackCache.removeValue(forKey: trackCacheOrder.removeFirst())
        }
    }

    /// Loads the tracks a flat collection item stands for — a playlist's
    /// contents, or every rated track.
    func loadFlatTracks(for item: CollectionItem, section: LibrarySection, mode: CollectionMode) {
        if let demo {
            events.post(.tracksLoaded(albumID: item.id, tracks: demo.flatTracks(for: item.id)))
            return
        }
        if let cached = trackCache[item.id] {
            events.post(.tracksLoaded(albumID: item.id, tracks: cached))
            return
        }
        guard let server, !tracksInFlight.contains(item.id) else { return }
        tracksInFlight.insert(item.id)

        Task { [self] in
            defer { events.post(.tracksSettled(albumID: item.id)) }
            do {
                let tracks: [Track]
                switch mode {
                case .playlists:
                    tracks = try await client.playlistTracks(item.id, on: server)
                case .rated:
                    tracks = try await client.ratedTracks(in: section, on: server)
                default:
                    return
                }
                cacheTracks(tracks, for: item.id)
                events.post(.tracksLoaded(albumID: item.id, tracks: tracks))
                await enrichStreams(of: tracks, source: item.id, on: server)
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    /// Fills in the stream data a track list arrived without, so the ♪ lyrics
    /// flag can be shown.
    ///
    /// `/children` and `/playlists/{id}/items` both return tracks with no
    /// `Stream` arrays on this server, so the flag needs one batch read of
    /// `/library/metadata/{ids}?includeStreams=1`. It used to run only for
    /// albums, which is why playlists and the rated list showed no ♪ at all.
    ///
    /// Skipped entirely when the list already carries streams — a server that
    /// honours `includeStreams` should not pay for a second request.
    private func enrichStreams(
        of tracks: [Track],
        source: String,
        on server: PlexServer
    ) async {
        guard !tracks.isEmpty, tracks.allSatisfy({ !$0.hasStreamData }) else { return }
        guard let enriched = try? await client.trackDetails(ids: tracks.map(\.id), on: server),
              enriched.contains(where: { $0.hasLyrics })
        else { return }

        // Keep the original order; the batch endpoint does not promise one, and
        // for a playlist the order is the point of it.
        let byID = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = tracks.map { byID[$0.id] ?? $0 }
        cacheTracks(merged, for: source)
        events.post(.tracksEnriched(albumID: source, tracks: merged))
    }

    func loadTracks(albumID: String) {
        if let demo {
            events.post(.tracksLoaded(albumID: albumID, tracks: demo.tracks(albumID: albumID)))
            return
        }
        if let cached = trackCache[albumID] {
            events.post(.tracksLoaded(albumID: albumID, tracks: cached))
            return
        }
        guard let server, !tracksInFlight.contains(albumID) else { return }
        tracksInFlight.insert(albumID)
        Task { [self] in
            defer { events.post(.tracksSettled(albumID: albumID)) }
            do {
                let tracks = try await client.tracks(ofAlbum: albumID, on: server)
                cacheTracks(tracks, for: albumID)
                events.post(.tracksLoaded(albumID: albumID, tracks: tracks))

                await enrichStreams(of: tracks, source: albumID, on: server)
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    /// Always asks the server, even when our copy of the track says it has no
    /// lyrics: `hasLyrics` is only as good as the endpoint the track came from,
    /// and `client.lyrics` re-reads the metadata when it needs to.
    // There was a `lyricsExhausted` set here, so a track whose every path had
    // 404'd would not be asked about again. It was added when a failure looked
    // permanent, and it is wrong: these failures are intermittent, and
    // reproduce on Plex's own web client with identical parameters minutes
    // apart —
    //
    //     17:38:49  GET /library/streams/516253?format=xml  200, 2025 bytes
    //     17:49:31  GET /library/streams/516253?format=xml  404,  504 bytes
    //
    // — so remembering a miss converts a transient one into a permanent one.
    // Skipping away from a track and back found nothing, and `L` "fixed" it
    // only because forcing cleared the set. Successes are still cached; misses
    // are not.

    func loadLyrics(for track: Track) {
        if let demo {
            events.post(.lyricsLoaded(trackID: track.id, text: demo.lyrics(for: track)))
            return
        }
        guard let server else {
            events.post(.lyricsLoaded(trackID: track.id, text: nil))
            return
        }
        // A track whose lyrics are already in hand is never re-fetched: the
        // server answers inconsistently, and asking again can only turn a
        // working pane into an empty one.
        if let cached = cachedLyrics(for: track.id) {
            recordLyricsTrace(["track \(track.id) “\(track.title)” — from this session's cache"])
            events.post(.lyricsLoaded(trackID: track.id, text: cached))
            return
        }

        Task { [self] in
            let result = await client.lyrics(for: track, on: server, trace: nil)
            var trace = result.trace
            // Record how the body parsed, not just that it arrived. "Lyrics
            // fetched" and "lyrics usable" are different claims, and only the
            // second one matters on screen.
            if let text = result.text {
                cacheLyrics(text, for: track.id)
                let structured = Lyrics.parsePlexJSON(text) != nil
                let parsed = Lyrics.parse(text)
                let timedLines = parsed.lines.filter { $0.time != nil }.count
                let withWords = parsed.lines.filter { !$0.words.isEmpty }.count
                trace.append(
                    "   parsed as \(structured ? "Plex JSON" : "LRC/plain"): "
                        + "\(parsed.lines.count) lines, \(timedLines) timed, \(withWords) with word spans"
                )
                if let longest = parsed.lines.map(\.text.count).max() {
                    trace.append("   longest line \(longest) chars")
                }
            }
            recordLyricsTrace(trace)
            events.post(.lyricsLoaded(
                trackID: track.id,
                text: result.text,
                failure: result.failure?.summary,
                retryable: result.failure?.isWorthRetrying ?? false
            ))
        }
    }

    func search(_ query: String) {
        if let demo {
            events.post(.searchResults(query: query, results: demo.search(query)))
            return
        }
        guard let server, !query.isEmpty else { return }
        Task { [self] in
            do {
                let results = try await client.search(query, on: server)
                events.post(.searchResults(query: query, results: results))
            } catch {
                events.post(.status(error.localizedDescription, isError: true))
            }
        }
    }

    // MARK: - Playback entry points
    //
    // Routed through here so demo mode can stand in for AVPlayer without the UI
    // needing to know which it is talking to.

    func play(_ tracks: [Track], startingAt index: Int) {
        // Choosing something is leaving the random mix. Without this, a queue
        // the reader picked would keep growing with random tracks behind it.
        shuffleAllSection = nil
        player.play(tracks, startingAt: index)
    }

    func togglePlayPause() {
        player.togglePlayPause()
    }

    func enqueue(_ tracks: [Track]) {
        player.enqueue(tracks)
    }

    func next() {
        player.next()
    }

    func previous() {
        player.previous()
    }

    func seekRelative(_ delta: Double) {
        player.seekRelative(delta)
    }

    func adjustVolume(_ delta: Float) {
        player.adjustVolume(delta)
    }

    func toggleShuffle() {
        player.toggleShuffle()
    }

    func toggleRepeat() {
        player.toggleRepeat()
    }
}
