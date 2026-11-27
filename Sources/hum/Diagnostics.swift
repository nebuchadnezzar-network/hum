import AVFoundation
import Foundation
import HumPlayer
import HumPlex
import HumTUI

/// `hum artwork [query]` — dumps everything about the cover-art pipeline.
///
/// Exists because artwork problems cannot be diagnosed from a paste: half-block
/// rendering is always the same glyph, so every pixel of information is in the
/// colour codes, and pasting into a chat window strips exactly those. This writes
/// the bytes, the decode and the render to files instead, each of which carries
/// its own evidence.
enum Diagnostics {
    static func dumpArtwork(preferences: Preferences, query: String?) -> Int32 {
        guard let token = CLI.ensureToken(preferences: preferences) else { return 1 }

        let device = DeviceInfo(clientIdentifier: preferences.clientIdentifier)
        let client = PlexClient(device: device, token: token)

        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("hum-artwork-report")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var report: [String] = []
        func log(_ line: String) {
            report.append(line)
            print(line)
        }

        log("hum \(humVersion) artwork report")
        log("")

        // Environment — the context a bug report cannot otherwise carry.
        let terminal = Terminal()
        let size = terminal.size
        let depth = ColorDepth.detected
        let style = ArtworkStyle.best(for: depth)
        log("terminal      \(size.columns)x\(size.rows)")
        log("TERM          \(ProcessInfo.processInfo.environment["TERM"] ?? "(unset)")")
        log("COLORTERM     \(ProcessInfo.processInfo.environment["COLORTERM"] ?? "(unset)")")
        log("TERM_PROGRAM  \(ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "(unset)")")
        log("colour depth  \(depth)")
        log("artwork style \(style)")
        log("")

        let album: Album
        let server: PlexServer
        do {
            server = try CLI.blocking { try await client.bestServer() }
            log("server        \(server.name) (\(server.isRelay ? "relay" : server.isLocal ? "local" : "remote"))")
            log("base URL      \(server.baseURL.absoluteString)")

            let found: Album?
            if let query, !query.isEmpty {
                found = try CLI.blocking { try await client.search(query, on: server) }.albums.first
            } else {
                let sections = try CLI.blocking { try await client.musicSections(on: server) }
                guard let section = sections.first else {
                    CLI.failure("no music libraries on this server")
                    return 1
                }
                // Enough to find one with artwork, not the whole library.
                found = try CLI.blocking {
                    try await client.albums(in: section, limit: 20, on: server)
                }
                    .first { $0.thumb != nil }
            }
            guard let found else {
                CLI.failure(query == nil ? "no albums found" : "nothing matched “\(query!)”")
                return 1
            }
            album = found
        } catch {
            CLI.failure(error.localizedDescription)
            return 1
        }

        log("album         \(album.artist) — \(album.title)")
        log("thumb path    \(album.thumb ?? "(none)")")

        guard let thumb = album.thumb else {
            CLI.failure("that album has no artwork on the server")
            return 1
        }
        guard let url = client.artworkURL(for: thumb, on: server, size: 600) else {
            CLI.failure("could not build an artwork URL")
            return 1
        }
        // Redacted: the token is account-equivalent and this file gets shared.
        let redacted = url.absoluteString.replacingOccurrences(
            of: server.accessToken, with: "<token>"
        )
        log("artwork URL   \(redacted)")
        log("")

        // 1. What the server actually sent.
        let data: Data
        do {
            let (bytes, response) = try CLI.blocking {
                try await PlexSession.shared.data(from: url)
            }
            let http = response as? HTTPURLResponse
            log("HTTP status   \(http?.statusCode ?? -1)")
            log("content type  \(http?.value(forHTTPHeaderField: "Content-Type") ?? "(none)")")
            log("bytes         \(bytes.count)")
            data = bytes
        } catch {
            CLI.failure("fetch failed: \(error.localizedDescription)")
            return 1
        }

        guard !data.isEmpty else {
            CLI.failure("the server returned no bytes — artwork cannot render")
            write(report, to: directory.appendingPathComponent("report.txt"))
            return 1
        }
        write(data, to: directory.appendingPathComponent("1-source-from-plex.bin"))

        // 2. What hum decoded. Opening this PNG settles whether the problem is
        //    upstream of the renderer or inside it.
        let cells = (width: min(size.columns - 4, 44), height: 0)
        let artWidth = max(8, cells.width)
        let artRows = artworkRows(forWidth: artWidth)
        let pixels = artworkPixelSize(cells: (artWidth, artRows), style: style)
        log("")
        log("render target \(artWidth)x\(artRows) cells  →  \(pixels.width)x\(pixels.height) pixels")

        guard let decoded = decodePixels(data, width: pixels.width, height: pixels.height) else {
            CLI.failure("could not decode those bytes as an image")
            write(report, to: directory.appendingPathComponent("report.txt"))
            return 1
        }
        log("decoded       \(decoded.width)x\(decoded.height)")

        if let png = encodePNG(decoded) {
            write(png, to: directory.appendingPathComponent("2-decoded-by-hum.png"))
        }
        // A larger decode too, to show the source is fine at size.
        if let large = decodePixels(data, width: 400, height: 400),
           let png = encodePNG(large) {
            write(png, to: directory.appendingPathComponent("3-decoded-at-400.png"))
        }

        // 3. What hum draws, in every style, with the colour codes intact.
        var renders: [String] = []
        for candidate in ArtworkStyle.allCases {
            let rows = artworkRows(forWidth: artWidth)
            let target = artworkPixelSize(cells: (artWidth, rows), style: candidate)
            guard let image = decodePixels(data, width: target.width, height: target.height) else { continue }
            let screen = Screen(columns: artWidth, rows: rows)
            screen.colorDepth = depth
            screen.clear()
            drawArtwork(image, in: screen.bounds, on: screen, style: candidate)

            renders.append("=== \(candidate) · \(artWidth)x\(rows) cells · \(depth) ===")
            renders.append(contentsOf: screen.styledLines())
            renders.append("")
        }
        write(renders.joined(separator: "\n") + "\n",
              to: directory.appendingPathComponent("4-rendered.txt"))

        log("")
        log("wrote \(directory.path)/")
        log("  1-source-from-plex.bin   raw bytes from the server")
        log("  2-decoded-by-hum.png     what hum will draw (open this)")
        log("  3-decoded-at-400.png     the same source at full size")
        log("  4-rendered.txt           every style, colour codes intact — `cat` it")
        log("  report.txt               this text")
        write(report.joined(separator: "\n") + "\n",
              to: directory.appendingPathComponent("report.txt"))
        return 0
    }

    /// Walks arbitrary JSON reporting every key or string value that mentions
    /// lyrics, with the path it was found at.
    private static func findLyricsMentions(_ value: Any, path: String, into hits: inout [String]) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if key.lowercased().contains("lyric") {
                    hits.append("found: \(childPath) = \(describe(child))")
                }
                findLyricsMentions(child, path: childPath, into: &hits)
            }
        case let array as [Any]:
            for (index, child) in array.enumerated() {
                findLyricsMentions(child, path: "\(path)[\(index)]", into: &hits)
            }
        case let text as String:
            if text.lowercased().contains("lyric") {
                hits.append("found: \(path) = \"\(text)\"")
            }
        default:
            break
        }
    }

    private static func describe(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return "{\(dictionary.keys.sorted().joined(separator: ", "))}"
        }
        if let array = value as? [Any] {
            return "[\(array.count) item(s)]"
        }
        return String(describing: value)
    }

    private static func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func write(_ lines: [String], to url: URL) {
        write(lines.joined(separator: "\n") + "\n", to: url)
    }

    private static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Lyrics

extension Diagnostics {
    /// `hum lyrics [query]` — shows exactly what the server holds for a track.
    ///
    /// Answers the question that cannot be answered from hum's own output: does
    /// this server expose lyrics at all? Plex carries them as a stream of type 4
    /// inside `Media > Part > Stream`, and if nothing in the library has one then
    /// no amount of client work will produce lyrics.
    /// Reports why a track will not play.
    ///
    /// Browsing uses hum's own URLSession; playback hands a URL to AVPlayer,
    /// which makes its own connection with its own TLS, App Transport Security
    /// and codec rules. So "the library loads but nothing plays" is normal
    /// enough to need its own report, and the symptom worth separating is a
    /// stall from a failure: the player sets an error message when an item
    /// reaches `.failed`, and shows nothing at all when the item sits in
    /// `.unknown` forever because the request is hanging.
    ///
    /// Three answers, in order: does the track carry a part to stream, what
    /// does the server say to a plain HTTP request for it, and what does
    /// AVPlayer make of the same URL.
    static func dumpStream(preferences: Preferences, query: String?) -> Int32 {
        guard let token = CLI.ensureToken(preferences: preferences) else { return 1 }
        let device = DeviceInfo(clientIdentifier: preferences.clientIdentifier)
        let client = PlexClient(device: device, token: token)

        func log(_ line: String = "") { print(line) }
        log("hum \(humVersion) stream report")
        log()

        let server: PlexServer
        let track: Track
        do {
            server = try CLI.blocking { try await client.bestServer() }
            log("server     \(server.name)")
            // The scheme and host matter: App Transport Security refuses plain
            // HTTP by default from inside a bundle, and a relay connection is
            // bandwidth-capped in a way that looks like stalling.
            log("connection \(server.baseURL.scheme ?? "?")://\(server.baseURL.host ?? "?")"
                + ":\(server.baseURL.port.map(String.init) ?? "")"
                + "  \(server.isRelay ? "relay" : (server.isLocal ? "local" : "remote"))")

            let sections = try CLI.blocking { try await client.musicSections(on: server) }
            guard let section = sections.first else {
                CLI.failure("no music libraries on this server")
                return 1
            }

            var found: Track?
            if let query, !query.isEmpty {
                found = try CLI.blocking { try await client.search(query, on: server) }.tracks.first
            } else {
                // Several albums, and the first track that carries stream data
                // with a real title. Picking album one, track one found an
                // untitled file by an unknown artist — plausibly damaged, and a
                // damaged file tells you nothing about whether playback works.
                let albums = try CLI.blocking { try await client.albums(in: section, limit: 5, on: server) }
                for album in albums {
                    let tracks = try CLI.blocking {
                        try await client.tracks(ofAlbum: album.id, on: server)
                    }
                    if let candidate = tracks.first(where: {
                        $0.partKey != nil && $0.title != "(untitled)"
                    }) {
                        found = candidate
                        break
                    }
                    if found == nil { found = tracks.first }
                }
            }
            guard let first = found else {
                CLI.failure("no track found to test")
                return 1
            }
            track = first
        } catch {
            CLI.failure("\(error)")
            return 1
        }

        log()
        log("track      \(track.title) — \(track.artist)")
        log("ratingKey  \(track.id)")
        log("partKey    \(track.partKey ?? "MISSING — nothing to stream")")
        log()

        // Enrichment: /children does not reliably carry Part data on every
        // server, so a track can arrive unplayable and become playable after a
        // second call. Worth knowing which one this is.
        if track.partKey == nil {
            log("The track has no part, so hum would report “No playable media”.")
            log("Trying the per-track endpoint, which is where hum gets it from:")
            if let enriched = try? CLI.blocking({
                try await client.trackDetails(id: track.id, on: server)
            }) ?? nil {
                log("  partKey  \(enriched.partKey ?? "still missing")")
            } else {
                log("  that call failed too")
            }
            return 0
        }

        let url: URL
        do {
            url = try client.streamURL(for: track, on: server)
        } catch {
            log("stream URL could not be built: \(error.localizedDescription)")
            return 1
        }
        // The token is in the query string, and this report is meant to be
        // pasted somewhere.
        var shown = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let redacted = shown?.queryItems?.map {
            $0.name == "X-Plex-Token" ? URLQueryItem(name: $0.name, value: "REDACTED") : $0
        }
        shown?.queryItems = redacted
        log("stream URL \(shown?.url?.absoluteString ?? "?")")
        log()

        // What the server says, asking the way any HTTP client would.
        log("plain request for the first 64KB")
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let semaphore = DispatchSemaphore(value: 0)
        var summary = "no response"
        PlexSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                summary = "failed: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                let type = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
                let length = http.value(forHTTPHeaderField: "Content-Length") ?? "?"
                summary = "status \(http.statusCode), \(type), Content-Length \(length)"
                    + ", \(data?.count ?? 0) bytes received"
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        log("  \(summary)")

        // Without a Range header, so the server reports the whole file. A
        // zero-length or truncated file is "Cannot Open" too, and looks like a
        // player fault until you see the size.
        var whole = URLRequest(url: url)
        whole.httpMethod = "HEAD"
        whole.timeoutInterval = 20
        let headDone = DispatchSemaphore(value: 0)
        var headSummary = "no response"
        PlexSession.shared.dataTask(with: whole) { _, response, error in
            if let error {
                headSummary = "failed: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                headSummary = "status \(http.statusCode)"
                    + ", Content-Length \(http.value(forHTTPHeaderField: "Content-Length") ?? "?")"
                    + ", Accept-Ranges \(http.value(forHTTPHeaderField: "Accept-Ranges") ?? "none")"
            }
            headDone.signal()
        }.resume()
        _ = headDone.wait(timeout: .now() + 25)
        log("  whole file: \(headSummary)")
        log()

        // And what AVPlayer makes of it, which is the part hum actually uses.
        log("AVPlayer, 12 seconds")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.play()
        let deadline = Date().addingTimeInterval(12)
        var lastStatus = -1
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if item.status.rawValue != lastStatus {
                lastStatus = item.status.rawValue
                let name = ["unknown", "readyToPlay", "failed"][min(lastStatus, 2)]
                log("  status      \(name)")
                if let error = item.error {
                    log("  error       \(error.localizedDescription)")
                    // "Cannot Open" is AVFoundation's wording for several
                    // different faults; the domain and code separate them, and
                    // the underlying error is usually the specific one.
                    let detail = error as NSError
                    log("  domain      \(detail.domain) \(detail.code)")
                    if let underlying = detail.userInfo[NSUnderlyingErrorKey] as? NSError {
                        log("  underlying  \(underlying.domain) \(underlying.code)"
                            + "  \(underlying.localizedDescription)")
                    }
                    if let reason = detail.localizedFailureReason {
                        log("  reason      \(reason)")
                    }
                }
            }
            if item.status == .failed { break }
        }
        log("  time        \(String(format: "%.1f", item.currentTime().seconds))s played")
        log("  keep up     \(item.isPlaybackLikelyToKeepUp)")
        if let log_ = item.errorLog(), !log_.events.isEmpty {
            log("  error log")
            for event in log_.events.prefix(4) {
                log("    \(event.errorStatusCode) \(event.errorComment ?? "")")
            }
        }
        player.pause()

        log()

        // The same URL through `PlaybackAsset.make`, which is what the player
        // uses — shared rather than copied, because when the diagnostic built
        // its asset differently it called a URL playable that hum could not
        // play. This is the comparison that found
        // AVURLAssetPreferPreciseDurationAndTimingKey stalling a FLAC library.
        log("AVPlayer again, built the way hum builds it, 12 seconds")
        let humItem = AVPlayerItem(asset: PlaybackAsset.make(url: url))
        humItem.preferredForwardBufferDuration = 10
        let humPlayer = AVPlayer(playerItem: humItem)
        humPlayer.volume = 0
        humPlayer.play()
        let humDeadline = Date().addingTimeInterval(12)
        var humLast = -1
        while Date() < humDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if humItem.status.rawValue != humLast {
                humLast = humItem.status.rawValue
                log("  status      \(["unknown", "readyToPlay", "failed"][min(humLast, 2)])")
                if let error = humItem.error {
                    let detail = error as NSError
                    log("  error       \(error.localizedDescription)")
                    log("  domain      \(detail.domain) \(detail.code)")
                }
            }
            if humItem.status == .failed { break }
        }
        log("  time        \(String(format: "%.1f", humItem.currentTime().seconds))s played")
        log("  keep up     \(humItem.isPlaybackLikelyToKeepUp)")
        log()

        if item.status == .readyToPlay, humItem.status != .readyToPlay {
            log("The plain item played and hum's did not, with the same URL — so")
            log("this is hum's asset options, not the server or the network.")
            log("AVURLAssetPreferPreciseDurationAndTimingKey is the suspect.")
        } else if item.status == .readyToPlay, humItem.currentTime().seconds == 0 {
            log("Both became ready, but hum's played nothing — the difference is")
            log("in starting playback rather than in opening the asset.")
        }

        if item.status == .readyToPlay, item.currentTime().seconds > 0 {
            log("Plain AVPlayer played this URL, so the stream path is working.")
        } else if item.status == .unknown {
            log("The item never became ready and never failed — the request is")
            log("hanging rather than being refused. Compare the plain request")
            log("above: a 200 there with a stall here points at AVPlayer's own")
            log("connection, not at the URL.")
        }
        return 0
    }

    /// Reports what the server returns for each tag facet.
    ///
    /// The facet panes — genres, styles, moods, labels — read `Directory`
    /// entries from `/library/sections/{id}/{facet}`, and a facet listing does
    /// not use the same field names as a section listing. The specification
    /// documents `tag`/`id`/`filter` for `/label` and `/tags`, and documents no
    /// `/genre`, `/mood` or `/style` path at all, so what any given server
    /// sends has to be looked at rather than assumed.
    ///
    /// This prints the raw field names alongside what hum derives from them,
    /// then filters albums by the first facet it found — so a blank pane can be
    /// told apart from an endpoint that is not there.
    static func dumpTags(preferences: Preferences) -> Int32 {
        guard let token = CLI.ensureToken(preferences: preferences) else { return 1 }
        let device = DeviceInfo(clientIdentifier: preferences.clientIdentifier)
        let client = PlexClient(device: device, token: token)

        var requests = 0
        func log(_ line: String = "") { print(line) }

        log("hum \(humVersion) tag report")
        log()

        let server: PlexServer
        let section: LibrarySection
        do {
            server = try CLI.blocking { try await client.bestServer() }
            requests += 1
            log("server   \(server.name)")
            let sections = try CLI.blocking { try await client.musicSections(on: server) }
            requests += 1
            guard let first = sections.first else {
                CLI.failure("no music libraries on this server")
                return 1
            }
            section = first
            log("library  \(section.title)  (id \(section.id))")
            log()
        } catch {
            CLI.failure("\(error)")
            return 1
        }

        // The authoritative answer to "which facets exist", and it is per
        // metadata type rather than per library. From the specification, on a
        // Filter's `key`:
        //
        //   This provides the endpoint where the possible range of values for
        //   the filter can be retrieved [...] This will include a `type`
        //   argument that matches the metadata type of the Type element.
        //
        // Which is why `label` filters albums but not tracks. `includeMeta=1`
        // adds the Meta object carrying these, so the list below comes from the
        // server rather than from a hardcoded guess.
        for (label, type) in [("albums", "9"), ("tracks", "10")] {
            log("filters for \(label) (type \(type))")
            do {
                let response = try CLI.blocking {
                    try await client.raw(
                        path: "/library/sections/\(section.id)/all",
                        query: ["type": type, "includeMeta": "1", "X-Plex-Container-Size": "0"],
                        on: server
                    )
                }
                requests += 1
                log("  status      \(response.status), \(response.body.count) bytes")
                guard response.status == 200,
                      let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                      let container = object["MediaContainer"] as? [String: Any] else { continue }
                guard let meta = container["Meta"] as? [String: Any] else {
                    log("  Meta        absent — this server ignored includeMeta=1")
                    continue
                }
                let types = meta["Type"] as? [[String: Any]] ?? []
                for entry in types {
                    let filters = entry["Filter"] as? [[String: Any]] ?? []
                    let name = entry["title"] as? String ?? entry["type"] as? String ?? "?"
                    log("  \(name): \(filters.count) filter(s)")
                    for filter in filters {
                        let key = filter["filter"] as? String ?? "?"
                        let title = filter["title"] as? String ?? "?"
                        let kind = filter["filterType"] as? String ?? ""
                        log("    \(key.padding(toLength: max(key.count, 14), withPad: " ", startingAt: 0)) \(title)\(kind.isEmpty ? "" : "  [\(kind)]")")
                    }
                }
            } catch {
                log("  failed      \(error)")
            }
            log()
        }

        var firstUsable: (facet: String, value: String, name: String)?

        // `label` is probed although it is no longer a browse mode: confirming
        // it stays empty for music is the point, and a server that does support
        // it would show up here.
        for facet in ["genre", "mood", "style", "label"] {
            log("/library/sections/\(section.id)/\(facet)")
            do {
                let response = try CLI.blocking {
                    try await client.raw(path: "/library/sections/\(section.id)/\(facet)", on: server)
                }
                requests += 1
                log("  status      \(response.status), \(response.body.count) bytes")
                if response.status == 200,
                   let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                   let container = object["MediaContainer"] as? [String: Any] {
                    let entries = container["Directory"] as? [[String: Any]] ?? []
                    log("  entries     \(entries.count)")
                    if let sample = entries.first {
                        log("  fields      \(sample.keys.sorted().joined(separator: ", "))")
                        log("  sample      \(describe(sample))")
                    }
                }
            } catch {
                log("  failed      \(error)")
            }

            // The real code path, so the pane's contents are not inferred.
            do {
                let derived = try CLI.blocking { try await client.facet(facet, in: section, on: server) }
                requests += 1
                log("  hum reads   \(derived.count) item(s)")
                if let sample = derived.first {
                    log("  first       \(sample.title) -> ?\(facet)=\(sample.id)")
                    if firstUsable == nil {
                        firstUsable = (facet, sample.id, sample.title)
                    }
                } else {
                    log("  first       none — this pane would be blank")
                }
            } catch {
                log("  hum reads   failed: \(error)")
            }
            log()
        }

        // Documented, admin-only, and returns every tag type at once with a
        // `tagType` to tell them apart. Worth knowing whether it is available
        // as a fallback for whichever per-facet paths a server lacks.
        log("/library/sections/\(section.id)/tags")
        do {
            let response = try CLI.blocking {
                try await client.raw(path: "/library/sections/\(section.id)/tags", on: server)
            }
            requests += 1
            log("  status      \(response.status), \(response.body.count) bytes")
            if response.status == 200,
               let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let container = object["MediaContainer"] as? [String: Any] {
                let entries = container["Directory"] as? [[String: Any]] ?? []
                var byType: [String: Int] = [:]
                for entry in entries {
                    byType["\(entry["tagType"] ?? "none")", default: 0] += 1
                }
                log("  entries     \(entries.count)")
                log("  tagType     \(byType.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
            }
        } catch {
            log("  failed      \(error)")
        }
        log()

        // End to end: a facet value is only useful if filtering by it returns
        // something. A pane that fills and then shows no albums is the same
        // bug one step later.
        if let usable = firstUsable {
            log("albums where \(usable.facet)=\(usable.value)  (\(usable.name))")
            do {
                let albums = try CLI.blocking {
                    try await client.albums(
                        in: section,
                        facet: usable.facet,
                        facetID: usable.value,
                        limit: 5,
                        on: server
                    )
                }
                requests += 1
                log("  albums      \(albums.count)")
                for album in albums.prefix(5) {
                    log("              \(album.title) — \(album.artist ?? "?")")
                }
                if albums.isEmpty {
                    log("              none — the value is not what this filter expects")
                }
            } catch {
                log("  failed      \(error)")
            }
        } else {
            log("no facet returned a usable value, so filtering was not tried")
        }

        log()
        log("\(requests) requests made.")
        return 0
    }

    static func dumpLyrics(preferences: Preferences, query: String?) -> Int32 {
        guard let token = CLI.ensureToken(preferences: preferences) else { return 1 }
        let device = DeviceInfo(clientIdentifier: preferences.clientIdentifier)
        let client = PlexClient(device: device, token: token)

        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("hum-lyrics-report")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var report: [String] = []
        func log(_ line: String = "") {
            report.append(line)
            print(line)
        }

        log("hum \(humVersion) lyrics report")
        log()

        let server: PlexServer
        let track: Track
        let section: LibrarySection
        do {
            server = try CLI.blocking { try await client.bestServer() }
            log("server        \(server.name)  \(server.baseURL.absoluteString)")

            let sections = try CLI.blocking { try await client.musicSections(on: server) }
            guard let first = sections.first else {
                CLI.failure("no music libraries on this server")
                return 1
            }
            section = first

            let found: Track?
            if let query, !query.isEmpty {
                found = try CLI.blocking { try await client.search(query, on: server) }.tracks.first
            } else {
                let albums = try CLI.blocking {
                    try await client.albums(in: section, limit: 1, on: server)
                }
                guard let album = albums.first else {
                    CLI.failure("no albums in \(section.title)")
                    return 1
                }
                found = try CLI.blocking { try await client.tracks(ofAlbum: album.id, on: server) }.first
            }
            guard let found else {
                CLI.failure(query == nil ? "no tracks found" : "nothing matched “\(query!)”")
                return 1
            }
            track = found
        } catch {
            CLI.failure(error.localizedDescription)
            return 1
        }

        log("library       \(section.title)")
        log("track         \(track.artist) — \(track.title)   (ratingKey \(track.id))")
        log("hum thinks    hasLyrics=\(track.hasLyrics)  candidates=\(track.lyricsCandidatePaths)")
        log()

        // 1. The raw metadata — once. Every later section reads this same
        //    response back rather than asking the server again.
        //
        //    This used to make four reads of one track: a plain one and an
        //    `includeStreams=1` one to compare, a third through `trackDetails`,
        //    and a fourth with `includeExtras`. A report that queries the server
        //    four times to describe a single track is not measuring the player,
        //    it is measuring itself.
        var lyricsStreams: [[String: Any]] = []
        var metadataBody: Data?
        log("GET /library/metadata/\(track.id)?includeStreams=1")
        do {
            let response = try CLI.blocking {
                try await client.raw(
                    path: "/library/metadata/\(track.id)",
                    query: ["includeStreams": "1"],
                    on: server
                )
            }
            log("  status \(response.status)   \(response.body.count) bytes")
            metadataBody = response.body
            try? response.body.write(
                to: directory.appendingPathComponent("1-metadata.json"), options: .atomic
            )
            lyricsStreams = describeStreams(response.body, log: log)
        } catch {
            log("  failed: \(error.localizedDescription)")
        }
        log()

        // 2. Fetch the lyrics, trying every path every lyrics stream offers.
        //    Trying only the first was a real defect here: a track can carry an
        //    LRC *and* a TXT stream, and reporting failure after one of them
        //    404s says nothing about the other.
        if lyricsStreams.isEmpty {
            log("No stream of type 4 (lyrics) on this track.")
            log()
        } else {
            var candidates: [String] = []
            for stream in lyricsStreams {
                if let key = stream["key"] as? String, !key.isEmpty, !candidates.contains(key) {
                    candidates.append(key)
                }
            }
            for stream in lyricsStreams {
                if let id = stream["id"] as? Int {
                    let byID = "/library/streams/\(id)"
                    if !candidates.contains(byID) { candidates.append(byID) }
                }
            }
            log("\(lyricsStreams.count) lyrics stream(s), \(candidates.count) path(s) the player would try")
            log()

            // Run the *player's* fetch, not a parallel copy of it. An earlier
            // version of this report reimplemented the logic, drifted from it,
            // tried only the first stream and printed a conclusion the data
            // above contradicted. A diagnostic that does not exercise the real
            // path is worth very little.
            //
            // `track` already came from a response carrying streams, so a
            // `trackDetails` re-read here produced a byte-identical object at
            // the cost of another request. The Accept-header A/B that ran next
            // has had its answer — both headers behave the same — and it cost
            // two ranged requests against the lyrics stream on every run, which
            // is what drew `Overzealous client asked for end range of 8191`
            // out of the server.
            let subject = track

            log("fetching exactly as the player does (retries included):")
            let result = (try? CLI.blocking {
                await client.lyrics(for: subject, on: server, trace: nil)
            }) ?? (text: nil, failure: nil, trace: ["(the fetch could not be run)"])
            for line in result.trace { log("  \(line)") }

            if let text = result.text {
                try? Data(text.utf8).write(
                    to: directory.appendingPathComponent("3-lyrics-body.txt"), options: .atomic
                )
                let structured = Lyrics.parsePlexJSON(text) != nil
                let parsed = Lyrics.parse(text)
                log()
                log("WORKS — \(parsed.isTimed ? "TIMED, karaoke will follow" : "no timings")")
                log("  body format   \(structured ? "Plex structured JSON" : "LRC or plain text")")
                log("  lines         \(parsed.lines.count)")
                log("  timed lines   \(parsed.lines.filter { $0.time != nil }.count)")
                log("  word spans    \(parsed.lines.filter { !$0.words.isEmpty }.count) lines")
                log("  longest line  \(parsed.lines.map(\.text.count).max() ?? 0) chars")
                log("  first parsed lines:")
                for line in parsed.lines.prefix(6) {
                    let stamp = line.time.map { String(format: "[%6.2f] ", $0) } ?? "[      ] "
                    log("    \(stamp)\(line.text.prefix(80))")
                }
            } else {
                log()
                log("The player's own fetch found nothing, retries included.")
                if let failure = result.failure {
                    log("REASON: \(failure.summary)")
                    log(failure.isWorthRetrying
                        ? "  Worth asking again — this one is not final."
                        : "  Final: the server reports no lyrics stream on this track.")
                }
                log("Every path above comes from the server's own metadata — hum")
                log("does not guess at endpoints.")
            }
            log()
        }

        // 3. Anything anywhere in the payload mentioning lyrics. Plex has more
        //    than one lyrics mechanism — a file stream is only the obvious one,
        //    and a Plex Pass provider may attach them somewhere else entirely.
        //    A recursive search finds it whatever shape it takes.
        log("searching the whole payload for anything lyrics-related…")
        if let metadataBody {
            if let object = try? JSONSerialization.jsonObject(with: metadataBody) {
                var hits: [String] = []
                findLyricsMentions(object, path: "", into: &hits)
                if hits.isEmpty {
                    log("  nothing in this track's metadata mentions lyrics at all")
                } else {
                    for hit in hits.prefix(40) { log("  \(hit)") }
                }
                // Also list the top-level field names, so an unfamiliar one is visible.
                if let root = object as? [String: Any],
                   let container = root["MediaContainer"] as? [String: Any],
                   let metadata = (container["Metadata"] as? [[String: Any]])?.first {
                    log("  track metadata fields: \(metadata.keys.sorted().joined(separator: ", "))")
                }
            }
        } else {
            log("  (the metadata request above failed, so there is nothing to search)")
        }
        log()

        // There used to be a step 4 here: a scan of the first few albums in the
        // library to answer "does this server have lyrics at all?". It was
        // scaffolding from before the answer was known, and it cost an
        // `/library/sections/{id}/all` page plus a `/children` on each of three
        // albums the user never asked about — whichever ones sort first. On one
        // library the album that sorts first has sixteen tracks with no
        // metadata, so every run of `hum lyrics` made the server fork
        // `Plex Media Scanner --analyze` over them.
        //
        // A report about one track should ask about that track.
        if lyricsStreams.isEmpty {
            log("CONCLUSION: this track exposes no lyrics stream. Plex only serves")
            log("lyrics it has — a .lrc/.txt sidecar beside the audio, tags embedded")
            log("in the file, or the Plex Pass lyrics agent. Check that the library")
            log("has been scanned since lyrics were added.")
            log()
        }

        log()
        log("wrote \(directory.path)/")
        write(report.joined(separator: "\n") + "\n",
              to: directory.appendingPathComponent("report.txt"))
        return 0
    }

    /// Walks the raw JSON rather than a decoded model, so fields hum does not
    /// know about still show up. Returns any lyrics streams found.
    private static func describeStreams(_ data: Data, log: (String) -> Void) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any],
              let metadata = (container["Metadata"] as? [[String: Any]])?.first
        else {
            log("  (could not read a Metadata object out of that response)")
            return []
        }

        guard let media = metadata["Media"] as? [[String: Any]], !media.isEmpty else {
            log("  no Media array — nothing to carry a stream")
            return []
        }

        var lyrics: [[String: Any]] = []
        for (mediaIndex, entry) in media.enumerated() {
            guard let parts = entry["Part"] as? [[String: Any]] else { continue }
            for (partIndex, part) in parts.enumerated() {
                guard let streams = part["Stream"] as? [[String: Any]] else {
                    log("  Media[\(mediaIndex)] Part[\(partIndex)]: no Stream array")
                    continue
                }
                log("  Media[\(mediaIndex)] Part[\(partIndex)]: \(streams.count) stream(s)")
                for stream in streams {
                    let type = stream["streamType"] as? Int ?? -1
                    // 1 video, 2 audio, 3 subtitle, 4 lyrics.
                    let kind = ["?", "video", "audio", "subtitle", "lyrics"]
                    let name = type >= 0 && type < kind.count ? kind[type] : "type \(type)"
                    var bits = ["streamType=\(type) (\(name))"]
                    for key in ["id", "codec", "format", "key", "displayTitle", "title"] {
                        if let value = stream[key] { bits.append("\(key)=\(value)") }
                    }
                    if type == 4, stream["key"] == nil {
                        bits.append("← no `key`: embedded, fetch by id")
                    }
                    log("    \(bits.joined(separator: "  "))")
                    if type == 4 { lyrics.append(stream) }
                }
            }
        }
        return lyrics
    }
}
