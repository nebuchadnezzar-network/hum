import Foundation
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
