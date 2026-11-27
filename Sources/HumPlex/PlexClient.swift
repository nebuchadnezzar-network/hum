import Foundation

/// Talks to plex.tv (account, server list) and to a chosen Plex Media Server
/// (library browsing, stream URLs).
/// The one URLSession everything Plex-related should use.
///
/// `URLSession.shared` is not an option here. It carries a default *on-disk*
/// URLCache, and Plex puts `X-Plex-Token` in query strings — so artwork requests
/// alone were persisting the account token to `~/Library/Caches/hum/Cache.db`.
/// The cache was also a correctness hazard: a library server is live state, and
/// a cached negative answer sticks for the session.
public enum PlexSession {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

public struct PlexClient: Sendable {
    /// Delays before each retry of lyrics that every path refused.
    ///
    /// Provider-supplied lyrics — `com.plexapp.agents.lyricfind` and the like —
    /// are not files on disk. The server fetches them from the provider when
    /// first asked, and answers 404 until they arrive, after which they stay
    /// available. Observed directly: the identical URL returned a 404 in one
    /// run and 200 with 2856 bytes a few minutes later, with no client change.
    ///
    /// Spread over ~5s because a provider round trip is not instant, and
    /// because nothing is waiting on this — the pane shows "loading" meanwhile
    /// and a track is usually played for minutes.
    public static let defaultLyricsRetryDelays: [Double] = [1.5, 4.0]

    public let device: DeviceInfo
    public let token: String
    /// Injectable so tests do not sit through real retry delays.
    public var lyricsRetryDelays: [Double] = PlexClient.defaultLyricsRetryDelays
    private let session: URLSession

    public init(device: DeviceInfo, token: String, session: URLSession? = nil) {
        self.device = device
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.httpMaximumConnectionsPerHost = 6
            // No HTTP cache, deliberately.
            //
            // There was a 16MB in-memory URLCache here, on the theory that
            // paging back up a list would be instant. It was not worth it: the
            // UI already holds loaded artists, albums and tracks in memory, so
            // nothing re-requests while browsing — and the cache made identical
            // requests return different answers over time. A *negative* result
            // is the dangerous one. One 404 for a lyrics stream, cached, and
            // that track reports "no lyrics" for the rest of the session, which
            // is exactly the "it worked, then it stopped" behaviour that took
            // several rounds to pin down.
            //
            // A library server is live state. Ask it.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Server discovery

    /// Every server on the account, each already paired with a reachable connection.
    /// Connections are probed in parallel with a short timeout; the first one to
    /// answer `/identity` within its preference tier wins.
    public func discoverServers() async throws -> [PlexServer] {
        var request = URLRequest(
            url: URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        )
        for (key, value) in device.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PlexError.badResponse(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let resources: [PlexResource]
        do {
            resources = try JSONDecoder().decode([PlexResource].self, from: data)
        } catch {
            throw PlexError.decoding(String(describing: error))
        }

        let servers = resources.filter(\.providesServer)
        guard !servers.isEmpty else { throw PlexError.noServerFound }

        var reachable: [PlexServer] = []
        for resource in servers {
            if let server = await firstReachableConnection(for: resource) {
                reachable.append(server)
            }
        }
        guard !reachable.isEmpty else { throw PlexError.noServerFound }
        return reachable.sorted { $0.preferenceRank < $1.preferenceRank }
    }

    /// Picks the best server: owned and local first, relay last.
    ///
    /// `HUM_PLEX_SERVER` skips discovery altogether — point it at the machine
    /// and nothing contacts plex.tv at all:
    ///
    ///     HUM_PLEX_SERVER=http://10.0.0.5:32400 hum
    ///
    /// Normal discovery only *asks* plex.tv which addresses exist; media and
    /// metadata already go straight to the server unless the chosen connection
    /// is a relay. This removes even that lookup, which is useful when the
    /// account side is misbehaving or simply unavailable.
    public func bestServer(preferring identifier: String? = nil) async throws -> PlexServer {
        if let override = ProcessInfo.processInfo.environment["HUM_PLEX_SERVER"],
           !override.isEmpty,
           let url = URL(string: override) {
            return PlexServer(
                name: url.host ?? "server",
                baseURL: url,
                accessToken: token,
                isLocal: true,
                isRelay: false,
                clientIdentifier: nil
            )
        }

        let servers = try await discoverServers()
        if let identifier, let match = servers.first(where: { $0.clientIdentifier == identifier }) {
            return match
        }
        guard let first = servers.first else { throw PlexError.noServerFound }
        return first
    }

    /// Every way to reach `resource`, best first.
    ///
    /// Extracted so it can be tested. The test that covered this previously
    /// rebuilt the ranking inline and asserted the result of its own copy, so
    /// it stayed green through a change of preference — the one thing it
    /// existed to catch.
    ///
    /// Rank 0 is a local HTTPS `plex.direct` URI, 1 the same machine's raw
    /// address over plain HTTP, 2 a remote URI, 3 the relay.
    ///
    /// Order used to be the other way round at the top: `https://10-0-0-5
    /// .<hash>.plex.direct:32400` sends its bytes to the same machine as
    /// `http://10.0.0.5:32400`, and the plain address needs neither Plex's
    /// DNS nor Plex's certificate to reach a box on the same switch. What that
    /// left out is that every request carries `X-Plex-Token`, which is full
    /// access to the library, and plain HTTP puts it on the wire in clear text.
    ///
    /// The server does not necessarily agree about the same switch, either. A
    /// connection hum treated as local was logged as
    /// `[10.0.0.100:63843 (Allowed Network (WAN))]`, while Plex's own web
    /// client was on `TLS GZIP` throughout.
    ///
    /// The raw address is still ranked, so a server whose certificate or DNS
    /// fails falls back to it rather than refusing to connect. It is just no
    /// longer the default.
    static func rankedConnections(for resource: PlexResource) -> [(PlexConnection, URL, Int)] {
        var candidates: [(PlexConnection, URL, Int)] = []
        for connection in resource.connections ?? [] {
            let isRelay = connection.relay == true
            let isLocal = connection.local == true

            if let uri = connection.uri, let url = URL(string: uri) {
                candidates.append((connection, url, isRelay ? 3 : (isLocal ? 0 : 2)))
            }
            if isLocal, !isRelay,
               let address = connection.address, let port = connection.port,
               let direct = URL(string: "http://\(address):\(port)") {
                candidates.append((connection, direct, 1))
            }
        }
        return candidates.sorted { $0.2 < $1.2 }
    }

    private func firstReachableConnection(for resource: PlexResource) async -> PlexServer? {
        let candidates = Self.rankedConnections(for: resource)

        let accessToken = resource.accessToken ?? token

        // Probe within a tier concurrently, but respect tier order: a LAN address
        // that takes 200ms still beats a relay that answers in 50ms.
        for rank in 0...3 {
            let tier = candidates.filter { $0.2 == rank }
            guard !tier.isEmpty else { continue }

            let winner = await withTaskGroup(
                of: (URL, PlexConnection)?.self,
                returning: (URL, PlexConnection)?.self
            ) { group in
                for (connection, url, _) in tier {
                    group.addTask {
                        await probe(url, token: accessToken) ? (url, connection) : nil
                    }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }

            if let (url, connection) = winner {
                return PlexServer(
                    name: resource.name ?? "Plex",
                    baseURL: url,
                    accessToken: accessToken,
                    isLocal: connection.local == true,
                    isRelay: connection.relay == true,
                    clientIdentifier: resource.clientIdentifier
                )
            }
        }
        return nil
    }

    private func probe(_ baseURL: URL, token: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("identity"))
        request.timeoutInterval = 3
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in device.headers where key != "Accept" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 500) < 400
        } catch {
            return false
        }
    }

    // MARK: - Library

    public func sections(on server: PlexServer) async throws -> [LibrarySection] {
        let envelope = try await get(path: "/library/sections", on: server)
        return (envelope.container.directories ?? []).compactMap(\.asLibrarySection)
    }

    public func musicSections(on server: PlexServer) async throws -> [LibrarySection] {
        try await sections(on: server).filter(\.isMusic)
    }

    /// One page of artists, plus how many there are in total.
    ///
    /// The whole list used to be fetched before the reader had touched
    /// anything. On a library of 788 artists that was 1.4MB in two requests,
    /// and it dwarfed everything else a browsing session did:
    ///
    /// ```
    /// GET …/all?type=8&sort=titleSort:asc  Page 0-499    880893 bytes  143ms
    /// GET …/all?type=8&sort=titleSort:asc  Page 500-999  544217 bytes   79ms
    /// ```
    ///
    /// Everything else in that session came to about 27KB.
    public func artistsPage(
        in section: LibrarySection,
        start: Int,
        size: Int,
        on server: PlexServer
    ) async throws -> (artists: [Artist], total: Int) {
        // No `includeFields` whitelist. It is documented on this endpoint and
        // the server accepts it without complaint — and ignores it: the same
        // page came back as 292011 bytes with it and 292012 without. A
        // parameter that changes nothing is noise in someone's log.
        let envelope = try await get(
            path: "/library/sections/\(section.id)/all",
            query: ["type": "8", "sort": "titleSort:asc"],
            start: start,
            size: size,
            on: server
        )
        let page = (envelope.container.metadata ?? []).compactMap(\.asArtist)
        // No `totalSize` means the server told us only what it sent, so treat
        // what we have as all there is rather than paging forever.
        let total = envelope.container.totalSize ?? (start + page.count)
        return (page, total)
    }

    /// One page of tracks from a whole library.
    ///
    /// Sorted, and the sort matters: this exists so a caller can read a window
    /// at a random offset, and an unstable order would make an offset mean
    /// nothing between requests.
    public func tracksPage(
        in section: LibrarySection,
        start: Int,
        size: Int,
        on server: PlexServer
    ) async throws -> (tracks: [Track], total: Int) {
        let envelope = try await get(
            path: "/library/sections/\(section.id)/all",
            query: ["type": "10", "sort": "titleSort:asc"],
            start: start,
            size: size,
            on: server
        )
        let page = (envelope.container.metadata ?? []).compactMap(\.asTrack)
        let total = envelope.container.totalSize ?? (start + page.count)
        return (page, total)
    }

    public func artists(in section: LibrarySection, on server: PlexServer) async throws -> [Artist] {
        try await getPaged(
            path: "/library/sections/\(section.id)/all",
            query: ["type": "8", "sort": "titleSort:asc"],
            on: server
        ).compactMap(\.asArtist)
    }

    /// Albums in a library, optionally narrowed by a facet value.
    ///
    /// `facet` is the filter name Plex expects (`genre`, `mood`, `style`, `label`)
    /// and `facetID` the key from `facet(_:in:on:)`. Filtering server-side keeps
    /// hum from pulling an entire library down to narrow it locally.
    public func albums(
        in section: LibrarySection,
        facet: String? = nil,
        facetID: String? = nil,
        limit: Int? = nil,
        on server: PlexServer
    ) async throws -> [Album] {
        var query = ["type": "9", "sort": "artist.titleSort:asc,year:asc"]
        if let facet, let facetID {
            query[facet] = facetID
        }
        return try await getPaged(
            path: "/library/sections/\(section.id)/all",
            query: query,
            limit: limit,
            on: server
        ).compactMap(\.asAlbum)
    }

    public func albums(ofArtist artistID: String, on server: PlexServer) async throws -> [Album] {
        let envelope = try await get(path: "/library/metadata/\(artistID)/children", on: server)
        return (envelope.container.metadata ?? [])
            .compactMap(\.asAlbum)
            .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
    }

    /// Tracks on an album.
    ///
    /// Track titles and durations for an album. Not streams.
    ///
    /// Nothing here suppresses the on-the-fly media analysis, and `skipRefresh`
    /// is not the answer — it is deprecated, modern servers answer it with
    /// `QueryParser: Invalid field 'skipRefresh' found, ignoring.`, and it was
    /// rejected on every endpoint hum reads except `/library/metadata/{ids}`,
    /// where there was no analysis to suppress in the first place. The lever
    /// that exists is calling this once per album and not coming back.
    ///
    ///
    /// `includeStreams=1` was sent here for a while on the theory that it
    /// saved a round trip. The server ignores it: a response for sixteen
    /// tracks came back with no `Stream` array on any of them, which
    /// `hasStreamData` detected and the batch read had to cover anyway. The
    /// parameter is not in the specification for this endpoint either.
    ///
    /// This request is also what provokes the on-the-fly media analysis, and
    /// nothing suppresses that — `skipRefresh` is rejected here with
    /// `QueryParser: Invalid field`. The only lever left is to make the call
    /// once per album and not come back.
        public func tracks(ofAlbum albumID: String, on server: PlexServer) async throws -> [Track] {
        let envelope = try await get(
            path: "/library/metadata/\(albumID)/children",
            on: server
        )
        return (envelope.container.metadata ?? [])
            .compactMap(\.asTrack)
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
    }

    /// Audio playlists on the server.
    ///
    /// `playlistType=audio` filters out video and photo playlists, which hum
    /// has nothing to do with.
    public func audioPlaylists(on server: PlexServer) async throws -> [Playlist] {
        let envelope = try await get(
            path: "/playlists",
            query: ["playlistType": "audio"],
            on: server
        )
        return envelope.container.allMetadata.compactMap(\.asPlaylist)
    }

    /// The tracks in a playlist, in playlist order.
    ///
    /// Deliberately not sorted: a playlist's order is the point of it.
    public func playlistTracks(
        _ playlistID: String,
        limit: Int? = nil,
        on server: PlexServer
    ) async throws -> [Track] {
        // Paged, like every other list endpoint. Without the container headers
        // Plex applies a default size of its own, so a long playlist arrived
        // truncated — and then disagreed with the track count shown beside its
        // name, which is how this was noticed.
        try await getPaged(
            path: "/playlists/\(playlistID)/items",
            limit: limit,
            on: server
        ).compactMap(\.asTrack)
    }

    /// Tracks the viewer has rated, best first.
    ///
    /// Sorted server-side on `userRating` and filtered client-side, because the
    /// only documented way to narrow by rating on this endpoint is a generic
    /// `filters` expression whose syntax the specification does not give. With
    /// a descending sort the rated tracks are the first page, so one request
    /// does it.
    public func ratedTracks(
        in section: LibrarySection,
        limit: Int = 300,
        on server: PlexServer
    ) async throws -> [Track] {
        let envelope = try await get(
            path: "/library/sections/\(section.id)/all",
            query: ["type": "10", "sort": "userRating:desc,titleSort:asc"],
            start: 0,
            size: limit,
            on: server
        )
        return envelope.container.allMetadata
            .compactMap(\.asTrack)
            .filter { ($0.userRating ?? 0) > 0 }
    }

    /// Genres, moods, styles and labels all come back as `Directory` lists from
    /// the same shaped endpoint, so one function covers the lot.
    ///
    /// The name and the filter value are read through `displayName` and
    /// `facetValue` rather than from `title`/`key` directly: a facet listing
    /// does not use the same field names as a section listing, and reading the
    /// section names here returned an empty list for every facet — the
    /// genres, styles, moods and labels panes were simply blank.
    public func facet(
        _ facet: String,
        in section: LibrarySection,
        on server: PlexServer
    ) async throws -> [LibrarySection] {
        let envelope = try await get(path: "/library/sections/\(section.id)/\(facet)", on: server)
        return (envelope.container.directories ?? []).compactMap { directory in
            guard let value = directory.facetValue, let name = directory.displayName else {
                return nil
            }
            return LibrarySection(id: value, title: name, type: facet)
        }
    }

    /// A write, returning the decoded body where there is one.
    ///
    /// `rate(ratingKey:rating:on:)` hand-rolled this first; a second and third
    /// caller made it worth naming. Non-2xx is an error carrying the status and
    /// the start of the body, because Plex explains refusals in the body and a
    /// bare status code is not enough to tell a bad URI from a missing
    /// permission.
    private func write(
        method: String,
        path: String,
        query: [String: String],
        on server: PlexServer
    ) async throws -> PlexEnvelope? {
        var request = try self.request(path: path, query: query, on: server)
        request.httpMethod = method
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexError.badResponse(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.badResponse(
                status: http.statusCode,
                body: String(data: data.prefix(200), encoding: .utf8) ?? ""
            )
        }
        // A write need not return a body, and an empty one is not a failure.
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(PlexEnvelope.self, from: data)
    }

    /// Adds an item to an existing playlist.
    ///
    /// `PUT /playlists/{id}/items`, documented as:
    ///
    /// > With a dumb playlist, this adds the specified items to the playlist.
    ///
    /// A rating key is enough whether it names a track, an album or an artist:
    /// the server expands a container into its tracks. "Dumb" means a normal
    /// playlist — on a smart one the same call replaces the rules instead, so
    /// this refuses anything whose `smart` flag is set.
    ///
    /// Returns the playlist's new track count where the server reports one.
    @discardableResult
    public func addToPlaylist(
        _ playlistID: String,
        ratingKey: String,
        in section: LibrarySection,
        on server: PlexServer
    ) async throws -> Int? {
        guard let uri = section.contentURI(forRatingKey: ratingKey) else {
            throw PlexError.badResponse(
                status: -1,
                body: "this library has no UUID, so a playlist URI cannot be built"
            )
        }
        let envelope = try await write(
            method: "PUT",
            path: "/playlists/\(playlistID)/items",
            query: ["uri": uri],
            on: server
        )
        // The documented response is the playlist, whose leafCount is its track
        // count. Absent on servers that return an empty body.
        return envelope?.container.allMetadata.first?.leafCount
    }

    // No createPlaylist. `POST /playlists` is documented with exactly two
    // parameters — `uri` and `playQueueID` — and no `title` or `type`, so
    // creating one would mean inventing the parameters that name it. `smart`
    // appears in the specification only as a filter on `listPlaylists`.
    // Adding to a playlist that exists is fully documented, including the URI
    // format, so that is what hum does.

    /// Full metadata for a single track, streams included.
    ///
    /// Used as a fallback when a track arrived from an endpoint that omits
    /// streams — `/hubs/search` does, and older servers ignore `includeStreams`
    /// on `/children`.
    /// Full metadata for one track.
    ///
    /// `augmentMetadata` asks the server to go and fetch what it does not have
    /// yet. From the specification, on `getMetadataItem`:
    ///
    /// > **asyncAugmentMetadata** — Add metadata augmentations. An activity is
    /// > created to indicate progress. Option will be ignored if specified by
    /// > non-admin or **if multiple metadata items are requested**. Default is
    /// > false.
    ///
    /// Single item only, which is why the batch read cannot use it and this can.
    public func trackDetails(
        id: String,
        augmentMetadata: Bool = false,
        on server: PlexServer
    ) async throws -> Track? {
        guard augmentMetadata else { return try await trackDetails(ids: [id], on: server).first }
        let envelope = try await get(
            path: "/library/metadata/\(id)",
            query: ["includeStreams": "1", "asyncAugmentMetadata": "1"],
            on: server
        )
        return envelope.container.allMetadata.compactMap(\.asTrack).first
    }

    /// Full metadata for several tracks in one request.
    ///
    /// Plex accepts comma-separated rating keys, so a whole album costs one
    /// round trip. Worth having because `/children` does not reliably honour
    /// `includeStreams` — on some servers it returns no `Stream` arrays at all,
    /// which leaves every track looking as though it has no lyrics even when the
    /// per-track endpoint says otherwise.
    public func trackDetails(ids: [String], on server: PlexServer) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let envelope = try await get(
            path: "/library/metadata/\(ids.joined(separator: ","))",
            query: ["includeStreams": "1"],
            on: server
        )
        return envelope.container.allMetadata.compactMap(\.asTrack)
    }

    /// Searches the server and returns artists, albums and tracks separately.
    ///
    /// Returning all three matters: searching an artist's name usually matches no
    /// *track* title at all, so a track-only search looks broken exactly when you
    /// would most expect a hit.
    public func search(
        _ query: String,
        on server: PlexServer,
        limit: Int = 50
    ) async throws -> SearchResults {
        let envelope = try await get(
            path: "/hubs/search",
            query: [
                "query": query,
                "limit": String(limit),
                // Lets the track hubs carry their lyrics stream, so the `·`
                // marker in search results is accurate.
                "includeStreams": "1",
            ],
            on: server
        )

        var results = SearchResults()
        for item in envelope.container.allMetadata {
            switch item.type {
            case "artist":
                if let artist = item.asArtist { results.artists.append(artist) }
            case "album":
                if let album = item.asAlbum { results.albums.append(album) }
            case "track":
                if let track = item.asTrack { results.tracks.append(track) }
            default:
                continue
            }
        }
        return results
    }

    // MARK: - Playback

    /// Direct-play URL for a track. No transcode: hum hands the original file to
    /// AVFoundation, which is both faster to start and better sounding.
    public func streamURL(for track: Track, on server: PlexServer) throws -> URL {
        guard let partKey = track.partKey else {
            throw PlexError.noPlayableMedia(track.title)
        }
        guard var components = URLComponents(
            url: server.baseURL.appendingPathComponent(partKey.hasPrefix("/") ? String(partKey.dropFirst()) : partKey),
            resolvingAgainstBaseURL: false
        ) else {
            throw PlexError.noPlayableMedia(track.title)
        }
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: server.accessToken)]
        guard let url = components.url else { throw PlexError.noPlayableMedia(track.title) }
        return url
    }

    public func artworkURL(for path: String?, on server: PlexServer, size: Int = 320) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var components = URLComponents(
            url: server.baseURL.appendingPathComponent("photo/:/transcode"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "width", value: String(size)),
            URLQueryItem(name: "height", value: String(size)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
        ]
        return components?.url
    }

    /// Lyrics for a track, or nil if the server has none.
    ///
    /// Deliberately **non-throwing**. Every step is attempted independently, so
    /// one failing path cannot abort the others — which is precisely the bug this
    /// replaced: a non-2xx from the metadata retry threw straight out of the
    /// function, the caller's `try?` turned it into nil, and a track whose lyrics
    /// were one path away reported having none. "No lyrics" and "the lookup
    /// errored" are indistinguishable to a caller, so there is nothing to gain by
    /// surfacing the error and a working path to lose.
    public func lyrics(for track: Track, on server: PlexServer) async -> String? {
        await lyrics(for: track, on: server, trace: nil).text
    }

    /// Lyrics plus a record of how they were (or were not) found.
    ///
    /// The trace exists because this path kept failing in ways that could not be
    /// reproduced outside the user's own library, and a decoded result cannot
    /// say which of several candidates answered what.
    public func lyrics(
        for track: Track,
        on server: PlexServer,
        trace log: ((String) -> Void)?
    ) async -> (text: String?, failure: LyricsFailure?, trace: [String]) {
        var trace: [String] = []
        var failure: LyricsFailure?
        func note(_ line: String) {
            trace.append(line)
            log?(line)
        }

        note("track \(track.id) “\(track.title)”  hasLyrics=\(track.hasLyrics) candidates=\(track.lyricsCandidatePaths)")

        // Ask the server to fetch the lyrics, then ask for them.
        //
        // `provider=com.plexapp.agents.lyricfind` streams are a record Plex
        // holds from a metadata refresh; the words come from an online service,
        // and Plex's documentation says "an internet connection is required in
        // order to view these lyrics". The response times give it away — across
        // every log of this:
        //
        //     404 → 8ms, 10ms, 14ms, 36ms, 39ms      ← declined without trying
        //     200 → 159ms, 179ms, 186ms              ← actually fetched
        //
        // A 404 that fast is not a lookup. Asking for the words without asking
        // the server to obtain them only ever worked when something else had
        // already triggered it.
        //
        // Plex's own web client asks. Its traffic for one track:
        //
        //     GET /library/metadata/144021?…&asyncAugmentMetadata=1&…
        //       Activity: registered new activity … "Refreshing"
        //     GET /library/streams/516253?format=xml   200, 2025 bytes, 179ms
        //
        // So the read comes first, and it does double duty: `asyncAugmentMetadata`
        // is ignored for multi-item requests, so the batch read the browser uses
        // cannot carry it *and* often returns no streams at all — this is where
        // the authoritative path list comes from too.
        //
        // `format=xml` is deliberately not copied: hum sends
        // `Accept: application/json` and parses Plex's JSON.
        let detailed = try? await trackDetails(id: track.id, augmentMetadata: true, on: server)
        if detailed == nil {
            note("metadata read failed; falling back to the paths we were given")
        }

        // The read's own list first — it is the fresher of the two — then
        // anything only the caller knew about.
        var paths = detailed?.lyricsCandidatePaths ?? []
        for path in track.lyricsCandidatePaths where !paths.contains(path) {
            paths.append(path)
        }
        guard !paths.isEmpty else {
            note("→ no lyrics stream on this track; no lyrics")
            return (nil, .noStream, trace)
        }
        note("paths to try: \(paths)")

        if let text = await attemptLyrics(
            paths: paths, on: server, failure: &failure, note: note
        ) {
            note("→ \(text.count) bytes")
            return (text, nil, trace)
        }

        // The augmentation is asynchronous — hence the activity in the server
        // log — so the retry delays are not dead time, they are what gives it a
        // chance to land. The web client left ~2.7s between its two requests.
        //
        // Only the preferred path is retried: the pass above established that
        // none of them serve, so a retry is a question about time, not about
        // which URL.
        if let primary = paths.first {
            for (attempt, delay) in lyricsRetryDelays.enumerated() {
                note("refused; retry \(attempt + 1) of \(lyricsRetryDelays.count) in \(delay)s")
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                if let text = await attemptLyrics(
                    paths: [primary], on: server, failure: &failure, note: note
                ) {
                    note("→ \(text.count) bytes on retry \(attempt + 1)")
                    return (text, nil, trace)
                }
            }
        }
        note("→ no lyrics after augmenting and \(lyricsRetryDelays.count) retries")
        return (nil, failure ?? .noStream, trace)
    }


    /// Whether a response body could plausibly be a lyrics file.
    ///
    /// Not paranoia: some Plex paths answer 200 with the *audio file*, and
    /// handing 30MB of FLAC to the LRC parser would be slow, pointless and
    /// confusing. Real lyrics are a few kilobytes of UTF-8 text.
    public static func looksLikeLyrics(_ body: Data) -> Bool {
        guard !body.isEmpty, body.count <= 256 * 1024 else { return false }
        // Binary formats carry NUL bytes within the first block; text does not.
        guard !body.prefix(1024).contains(0) else { return false }
        return String(data: body, encoding: .utf8) != nil
    }

    /// Tries each path in turn, skipping anything that errors, answers non-2xx,
    /// or returns nothing usable.
    private func attemptLyrics(
        paths: [String],
        on server: PlexServer,
        failure: inout LyricsFailure?,
        note: (String) -> Void
    ) async -> String? {
        for path in paths {
            // No `Accept: text/plain` override. Plex serves agent-supplied
            // lyrics as structured JSON and sidecars as raw file bytes from the
            // same path; demanding plain text asks for a representation that
            // may not exist. The default `application/json` is what Plex's own
            // clients send, and the parser handles both shapes.
            let response: (status: Int, contentType: String?, body: Data)
            do {
                response = try await raw(path: path, on: server)
            } catch {
                // Name it. "Transport error" hides whether this was a timeout,
                // a dropped connection or a TLS failure, and those want
                // different responses.
                note("  GET \(path) → \(error.localizedDescription)")
                failure = .unreachable(error.localizedDescription)
                continue
            }
            let usable = (200..<300).contains(response.status)
                && PlexClient.looksLikeLyrics(response.body)
            let text = usable ? String(data: response.body, encoding: .utf8) : nil
            let blank = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true

            var detail = "  GET \(path) → \(response.status), \(response.body.count) bytes"
            if !usable || blank {
                // The body of a refusal usually says why, and that is the whole
                // question when a path 404s on one server and works on another.
                let body = String(data: response.body.prefix(160), encoding: .utf8) ?? ""
                let collapsed = body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                detail += collapsed.isEmpty ? " (empty body)" : "  body: \(collapsed)"
            }
            note(detail)

            guard let text, !blank else {
                // The most specific reason wins: a refusal says more than an
                // unusable body, which says more than a transport error on some
                // other path.
                if !(200..<300).contains(response.status) {
                    failure = .refused(status: response.status)
                } else if case .refused = failure {
                    // keep it
                } else {
                    failure = .unusable
                }
                continue
            }
            return text
        }
        return nil
    }

    /// Why a lyrics fetch came back empty.
    ///
    /// "No lyrics" and "the server would not serve the lyrics it says exist"
    /// are different situations and want different words on screen. The second
    /// is the intermittent LyricFind case: the stream is real, the server
    /// declines, and the same URL serves minutes later — including for Plex's
    /// own web client.
    public enum LyricsFailure: Equatable, Sendable {
        /// The track advertises no lyrics stream at all. Final.
        case noStream
        /// A stream exists and the server refused it, with this status.
        case refused(status: Int)
        /// A stream exists and the server served something unusable — binary,
        /// or an error page with a 200 on it.
        case unusable
        /// The request did not complete: timeout, dropped connection, TLS.
        case unreachable(String)

        /// One line for the lyrics strip.
        public var summary: String {
            switch self {
            case .noStream:
                return "no lyrics for this track"
            case .refused(let status):
                return "the server refused the lyrics (HTTP \(status))"
            case .unusable:
                return "the server returned something that is not lyrics"
            case .unreachable(let reason):
                return "could not reach the server — \(reason)"
            }
        }

        /// Whether asking again could plausibly succeed.
        ///
        /// A refusal and an unreachable server are both worth retrying; this
        /// server answers 404 and 200 for the same stream minutes apart. No
        /// stream at all is not.
        public var isWorthRetrying: Bool {
            switch self {
            case .noStream: return false
            case .refused, .unusable, .unreachable: return true
            }
        }
    }

    /// Sets the viewer's rating on an item.
    ///
    /// From the specification, on `/:/rate`:
    ///
    /// > Set the rating on an item. **This API does respond to the GET verb but
    /// > applications should use PUT.**
    ///
    /// `rating` is Plex's own 0–10, where 0 clears it. `identifier` names the
    /// media provider and is required.
    ///
    /// This is the only thing hum writes to the server besides play progress.
    /// It touches the viewer's own rating and nothing else — no media file, no
    /// library metadata.
    ///
    /// Throws on a non-2xx so the caller can put the old value back: the
    /// documented failures are 400 (bad parameters) and 404 (no such provider
    /// or rating key), both of which mean the rating did not take.
    public func rate(
        ratingKey: String,
        rating: Double,
        on server: PlexServer
    ) async throws {
        let clamped = min(max(rating, Rating.range.lowerBound), Rating.range.upperBound)
        var request = try self.request(
            path: "/:/rate",
            query: [
                "identifier": "com.plexapp.plugins.library",
                "key": ratingKey,
                // Whole numbers as integers: Plex accepts both, and "6" reads
                // better than "6.0" in someone's server log.
                "rating": clamped == clamped.rounded()
                    ? String(Int(clamped))
                    : String(clamped),
            ],
            on: server
        )
        request.httpMethod = "PUT"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexError.badResponse(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.badResponse(
                status: http.statusCode,
                body: String(data: data.prefix(200), encoding: .utf8) ?? ""
            )
        }
    }

    /// Tells the server what we're playing, so Plex's "continue listening" and
    /// scrobbling stay in sync with hum.
    public func reportProgress(
        track: Track,
        positionSeconds: Double,
        state: String,
        playedSeconds: Double = 0,
        on server: PlexServer
    ) async {
        var query: [String: String] = [
            "ratingKey": track.id,
            "key": "/library/metadata/\(track.id)",
            "identifier": "com.plexapp.plugins.library",
            "state": state,
            "time": String(Int(positionSeconds * 1000)),
            "duration": String(Int(track.duration * 1000)),
        ]
        // How much audio has actually been heard this session, as distinct from
        // where the playhead sits. Plex's own web client sends it on every
        // report:
        //
        //     …&playbackTime=15024&…&time=64000&duration=237000
        //
        // hum sent nothing, and the server logged `playbackTime=0ms` while
        // marking a track played from a single report at 54% (`scrobble: 1`).
        // Position alone cannot tell a listen from a seek.
        if playedSeconds > 0 {
            query["playbackTime"] = String(Int(playedSeconds * 1000))
        }
        guard var request = try? self.request(path: "/:/timeline", query: query, on: server) else { return }
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    // MARK: - Plumbing

    private func request(
        path: String,
        query: [String: String] = [:],
        on server: PlexServer
    ) throws -> URLRequest {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: server.baseURL.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: false
        ) else {
            throw PlexError.decoding("bad path \(path)")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw PlexError.decoding("bad path \(path)") }

        var request = URLRequest(url: url)
        for (key, value) in device.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    /// The untouched response for a path — status, headers and bytes.
    ///
    /// For diagnostics: when decoding finds nothing, the question is almost
    /// always what the server actually sent, and that cannot be answered from a
    /// decoded model.
    public func raw(
        path: String,
        query: [String: String] = [:],
        accept: String? = nil,
        on server: PlexServer
    ) async throws -> (status: Int, contentType: String?, body: Data) {
        // No `Range` header. It existed to keep endpoint probing from pulling a
        // whole media file, and the probing is gone; what it did to the requests
        // that remained was draw this out of the server:
        //
        //     WARN - Overzealous client asked for end range of 8191,
        //            content size is 3522; we'll clip.
        //
        // Lyrics are a few KB. Asking for a range of them is all cost.
        var request = try self.request(path: path, query: query, on: server)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return (
            http?.statusCode ?? -1,
            http?.value(forHTTPHeaderField: "Content-Type"),
            data
        )
    }

    /// Page size for list endpoints.
    ///
    /// Plex warns that requests without `X-Plex-Container-Size` "will fail with
    /// status code 400 in the future", and an unpaginated music library is not
    /// a small ask: one album listing here was 3MB and 11,083 items in a single
    /// 1.4s response.
    static let pageSize = 500

    private func get(
        path: String,
        query: [String: String] = [:],
        start: Int? = nil,
        size: Int? = nil,
        on server: PlexServer
    ) async throws -> PlexEnvelope {
        var request = try self.request(path: path, query: query, on: server)
        if let size {
            request.setValue(String(start ?? 0), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(size), forHTTPHeaderField: "X-Plex-Container-Size")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexError.badResponse(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.badResponse(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(PlexEnvelope.self, from: data)
        } catch {
            throw PlexError.decoding(String(describing: error))
        }
    }

    /// Fetches a list endpoint page by page, stopping at `limit` items.
    ///
    /// Paginated for two reasons: Plex requires the container headers, and a
    /// caller that only needs a handful of albums should not pull eleven
    /// thousand to find them.
    private func getPaged(
        path: String,
        query: [String: String] = [:],
        limit: Int? = nil,
        on server: PlexServer
    ) async throws -> [PlexMetadata] {
        var collected: [PlexMetadata] = []
        var start = 0
        while true {
            let size = min(Self.pageSize, limit.map { $0 - collected.count } ?? Self.pageSize)
            guard size > 0 else { break }

            let envelope = try await get(
                path: path, query: query, start: start, size: size, on: server
            )
            let page = envelope.container.metadata ?? []
            collected.append(contentsOf: page)

            let total = envelope.container.totalSize ?? collected.count
            start += page.count
            if page.isEmpty || collected.count >= total { break }
            if let limit, collected.count >= limit { break }
        }
        return collected
    }
}
