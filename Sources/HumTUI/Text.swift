import Foundation

/// Drops a leading `[mm:ss.cc]` tag from an LRC line, leaving the words.
///
/// Only a tag that actually looks like a timestamp is removed — a lyric line that
/// genuinely starts with a bracket (`[Chorus]`) keeps it.
public func stripLRCTimestamp(_ line: String) -> String {
    guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
    let tag = line[line.index(after: line.startIndex)..<close]
    guard tag.contains(":"), tag.first?.isNumber == true else { return line }
    return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
}

/// Greedy word wrap on display width.
///
/// Always returns at least one element, so blank lines in the source survive into
/// the output and stanza breaks are preserved.
public func wrap(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    if displayWidth(text) <= width { return [text] }

    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: false) {
        let candidate = current.isEmpty ? String(word) : current + " " + word
        if displayWidth(candidate) <= width {
            current = candidate
        } else {
            if !current.isEmpty { lines.append(current) }
            // A single word wider than the line gets hard-broken rather than
            // overflowing the pane.
            var remainder = String(word)
            while displayWidth(remainder) > width {
                var head = ""
                for character in remainder {
                    if displayWidth(head) + displayWidth(character) > width { break }
                    head.append(character)
                }
                lines.append(head)
                remainder = String(remainder.dropFirst(head.count))
            }
            current = remainder
        }
    }
    lines.append(current)
    return lines
}
