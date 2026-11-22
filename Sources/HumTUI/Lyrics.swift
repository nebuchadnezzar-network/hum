import Foundation

/// Lyrics, with timings when the source has them.
///
/// Plex serves whatever is attached to the track: a `.lrc` sidecar or embedded
/// lyrics carry `[mm:ss.cc]` timings and can be followed along with playback; a
/// plain `.txt` cannot, and falls back to a scrolling pane.
public struct Lyrics: Sendable, Equatable {
    public struct Word: Sendable, Equatable {
        /// Seconds into the track at which this word starts.
        public let time: Double
        public let text: String
    }

    public struct Line: Sendable, Equatable {
        /// Nil for a line with no timing — a stanza break, or a plain-text file.
        public let time: Double?
        public let text: String
        /// Per-word timings from "enhanced" LRC, when present.
        public let words: [Word]

        public init(time: Double?, text: String, words: [Word] = []) {
            self.time = time
            self.text = text
            self.words = words
        }
    }

    public let lines: [Line]
    /// True when at least one line carries a timestamp.
    public let isTimed: Bool

    public init(lines: [Line]) {
        self.lines = lines
        self.isTimed = lines.contains { $0.time != nil }
    }

    public var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Where an untimed lyric should be scrolled to, 0...1, for a track that is
    /// `fraction` of the way through.
    ///
    /// Not a straight `fraction`: songs open with an intro and close with an
    /// outro, so mapping the words onto the whole track starts them moving
    /// immediately and leaves them running ahead of the music for the rest of
    /// the song. Holding at the top for the lead-in and reaching the end early
    /// is a better fit for almost everything, and costs nothing when wrong —
    /// this is an approximation either way, and it is labelled as one.
    public static func untimedProgress(forFraction fraction: Double) -> Double {
        let leadIn = 0.10
        let leadOut = 0.90
        let scaled = (fraction - leadIn) / (leadOut - leadIn)
        return min(max(scaled, 0), 1)
    }

    /// Index of the line that should be highlighted at `position` seconds.
    ///
    /// The last line whose timestamp has passed. Nil before the first one, which
    /// is the intro and should not highlight anything.
    public func activeLine(at position: Double) -> Int? {
        var result: Int?
        for (index, line) in lines.enumerated() {
            guard let time = line.time else { continue }
            if time <= position {
                result = index
            } else {
                break
            }
        }
        return result
    }

    /// How many words of `line` have been sung by `position`.
    ///
    /// Returns the full count for a line with no word timings, so callers can
    /// treat line-level and word-level lyrics the same way.
    public func sungWords(ofLine index: Int, at position: Double) -> Int {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        guard !line.words.isEmpty else { return line.words.count }
        return line.words.filter { $0.time <= position }.count
    }

    // MARK: - Parsing

    /// Parses Plex's structured lyrics JSON, if that is what this is.
    ///
    /// Agent-supplied lyrics — LyricFind and friends — are not returned as an
    /// `.lrc` file but as JSON:
    ///
    /// ```
    /// MediaContainer.Lyrics[].Line[].Span[]   with millisecond startOffsets
    /// ```
    ///
    /// Each `Span` is a word or phrase with its own offset, which is exactly
    /// what the karaoke display wants — finer and more reliable than the
    /// `<mm:ss.cc>` markers of enhanced LRC. Decoded permissively with
    /// `JSONSerialization` rather than `Codable`: the shape is documented only
    /// informally, and a missing field should cost one line, not the whole set.
    public static func parsePlexJSON(_ raw: String) -> Lyrics? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any],
              let sets = container["Lyrics"] as? [[String: Any]],
              let first = sets.first,
              let rawLines = first["Line"] as? [[String: Any]]
        else { return nil }

        var lines: [Line] = []
        for rawLine in rawLines {
            let spans = (rawLine["Span"] as? [[String: Any]]) ?? []

            var words: [Word] = []
            var pieces: [String] = []
            for span in spans {
                guard let text = span["text"] as? String else { continue }
                pieces.append(text)
                if let offset = milliseconds(span["startOffset"]) {
                    words.append(Word(time: offset / 1000, text: text))
                }
            }

            // A line can carry its own offset, and does when the spans do not.
            let lineStart = milliseconds(rawLine["startOffset"]).map { $0 / 1000 }
                ?? words.first?.time

            let text = pieces.isEmpty
                ? (rawLine["text"] as? String ?? "")
                : pieces.joined(separator: " ")
            lines.append(Line(time: lineStart, text: text, words: words))
        }

        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines)
    }

    /// Offsets arrive as numbers or as quoted strings depending on the server.
    private static func milliseconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// Parses LRC, falling back to plain text.
    ///
    /// Handles the parts of the format that occur in practice: several
    /// timestamps sharing one line (a repeated chorus), `[offset:±ms]`, metadata
    /// tags, and the `<mm:ss.cc>` word markers of enhanced LRC.
    public static func parse(_ raw: String) -> Lyrics {
        // Plex serves agent lyrics as JSON and sidecar lyrics as file bytes
        // from the same endpoint, so the body decides which parser applies.
        if let structured = parsePlexJSON(raw) { return structured }

        var timed: [Line] = []
        var plain: [Line] = []
        var offset = 0.0

        // Normalise line endings first: `.whitespaces` does not include a
        // carriage return, so a CRLF file would otherwise carry a stray \r on
        // the end of every line and into every rendered row.
        let normalised = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var stamps: [Double] = []

            // Leading bracket groups are either timestamps or metadata.
            while remainder.hasPrefix("["), let close = remainder.firstIndex(of: "]") {
                let tag = remainder[remainder.index(after: remainder.startIndex)..<close]
                if let seconds = parseTimestamp(tag) {
                    stamps.append(seconds)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let value = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    // Positive offset means the lyrics are early and must shift later.
                    offset = (Double(value) ?? 0) / 1000
                } else if !tag.contains(":") {
                    // Not a tag at all — leave it in the text (`[Chorus]`).
                    break
                }
                remainder = remainder[remainder.index(after: close)...]
            }

            let (text, words) = parseWords(String(remainder).trimmingCharacters(in: .whitespaces))

            if stamps.isEmpty {
                plain.append(Line(time: nil, text: text))
            } else {
                for stamp in stamps {
                    timed.append(Line(time: stamp, text: text, words: words))
                }
            }
        }

        guard !timed.isEmpty else {
            // No timings anywhere: a plain lyrics file.
            return Lyrics(lines: plain)
        }

        let shifted = timed
            .map { line -> Line in
                Line(
                    time: (line.time ?? 0) + offset,
                    text: line.text,
                    words: line.words.map { Word(time: $0.time + offset, text: $0.text) }
                )
            }
            .sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        return Lyrics(lines: shifted)
    }

    /// `mm:ss`, `mm:ss.cc` (centiseconds), `mm:ss.mmm` (milliseconds), and the
    /// colon-separated variant `mm:ss:cc` that plenty of taggers emit.
    ///
    /// The colon form matters: rejecting it makes every line of such a file look
    /// untimed, so the whole file falls back to plain text and nothing follows
    /// playback — which looks exactly like "karaoke stopped working".
    private static func parseTimestamp(_ tag: Substring) -> Double? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let minutes = Int(parts[0]), minutes >= 0 else { return nil }

        // Three components mean the fraction was separated by a colon rather
        // than a dot. Hour-length LRC essentially does not occur, and reading
        // this as hh:mm:ss would put every cue wildly late.
        let secondsField = parts[1]
        let fractionField: Substring? = parts.count == 3 ? parts[2] : nil

        let pieces = secondsField.split(separator: ".", omittingEmptySubsequences: false)
        guard let seconds = Int(pieces[0]), seconds >= 0 else { return nil }

        var fraction = 0.0
        if pieces.count > 1, let value = Int(pieces[1]), !pieces[1].isEmpty {
            // Two digits are centiseconds, three are milliseconds.
            fraction = Double(value) / pow(10, Double(pieces[1].count))
        } else if let fractionField, let value = Int(fractionField), !fractionField.isEmpty {
            fraction = Double(value) / pow(10, Double(fractionField.count))
        }
        return Double(minutes) * 60 + Double(seconds) + fraction
    }

    /// Splits enhanced-LRC word markers out of a line, returning the plain text
    /// and the timed words.
    private static func parseWords(_ text: String) -> (String, [Lyrics.Word]) {
        guard text.contains("<") else { return (text, []) }

        var plain = ""
        var words: [Lyrics.Word] = []
        var pendingTime: Double?
        var buffer = ""

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            if let time = pendingTime, !trimmed.isEmpty {
                words.append(Lyrics.Word(time: time, text: trimmed))
            }
            buffer = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close]
                if let seconds = parseTimestamp(tag) {
                    flush()
                    pendingTime = seconds
                    index = text.index(after: close)
                    continue
                }
            }
            buffer.append(text[index])
            plain.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return (plain.trimmingCharacters(in: .whitespaces), words)
    }
}
