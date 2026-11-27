import Foundation

/// Picks where to read from when drawing random tracks out of a library.
///
/// `sort=random` is not in the Plex specification; paging is. So a random mix
/// is windows read at random offsets into a stable sort, which is why this is
/// arithmetic worth testing rather than a `randomElement()` at the call site:
/// an offset past the end returns nothing, and a window that runs off the end
/// returns a short page, so a mix built from the tail of the library would come
/// back smaller than asked for every time.
public struct ShuffleOffsets {
    /// Start offsets for windows of `window` tracks, covering `count` tracks in
    /// total, within a library of `total`.
    ///
    /// Windows rather than single tracks because a batch of 24 individually is
    /// 24 requests, and a handful of windows is three or four. They may overlap
    /// — the caller is deduplicating on track id anyway, and refusing to
    /// overlap would skew a small library towards an even spread, which is the
    /// opposite of random.
    public static func pick(
        total: Int,
        window: Int,
        count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [Int] {
        guard total > 0, window > 0, count > 0 else { return [] }
        // A library smaller than one window is one read from the start; asking
        // for an offset in an empty range traps.
        guard total > window else { return [0] }

        let windows = Int((Double(count) / Double(window)).rounded(.up))
        let highest = total - window
        return (0..<windows).map { _ in Int.random(in: 0...highest, using: &generator) }
    }

    /// The same, with the system generator.
    public static func pick(total: Int, window: Int, count: Int) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return pick(total: total, window: window, count: count, using: &generator)
    }
}
