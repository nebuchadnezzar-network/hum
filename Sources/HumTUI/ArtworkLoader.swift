import Foundation

/// Fetches cover art and decodes it straight to the cell grid it will be drawn
/// at, then caches the result.
///
/// Decoding to the target size rather than full resolution keeps the cache tiny
/// (a 40×40 cover is 6KB) and means the expensive scaling happens once per size
/// rather than once per frame.
///
/// Two caches, because fetching and decoding depend on different things. The
/// bytes depend only on the source URL; the pixels depend on the cell grid as
/// well. Keying both on `(source, width, height)` meant a pane that changed
/// height re-fetched identical bytes, which a server log caught doing it three
/// times in 700ms as the layout settled:
///
/// ```
/// #32 GET /photo/:/transcode?width=512&height=512&url=…/127819/thumb/… 42486 bytes
/// #40 GET /photo/:/transcode?width=512&height=512&url=…/127819/thumb/… 42486 bytes
/// #41 GET /photo/:/transcode?width=512&height=512&url=…/127819/thumb/… 42486 bytes
/// ```
public final class ArtworkLoader {
    private struct Key: Hashable {
        let source: String
        let width: Int
        let height: Int
    }

    /// Where a decoded image goes. A closure rather than the app's event queue:
    /// this type's whole job is de-duplication, and that was untestable while it
    /// could only be built inside the running executable.
    private let onDecoded: (String, Int, Int, PixelImage?) -> Void
    /// Where fetched bytes go, to be handed back via `received` on the UI thread.
    private let onFetched: (String, Data?) -> Void

    private var cache: [Key: PixelImage] = [:]
    private var order: [Key] = []
    private let limit = 48

    /// Bytes already fetched, keyed on the URL alone — the only thing the fetch
    /// depends on. A resize decodes again from these rather than asking the
    /// server for the same JPEG a second time.
    private var bytes: [String: Data] = [:]
    private var bytesOrder: [String] = []
    private let bytesLimit = 24

    /// Decodes in flight, so a frame drawn mid-fetch does not start another.
    private var decoding: Set<Key> = []
    /// Fetches in flight, keyed like `bytes`. Separate from `decoding`: two cell
    /// sizes wanting the same URL must share one request.
    private var fetching: Set<String> = []
    /// Cell sizes waiting on a URL, so they can all decode when it arrives.
    private var waiting: [String: Set<Key>] = [:]

    /// Supplies the bytes for a source string. Swapped out in demo mode.
    public var fetch: (String) async -> Data?

    public init(
        fetch: @escaping (String) async -> Data?,
        onFetched: @escaping (String, Data?) -> Void,
        onDecoded: @escaping (String, Int, Int, PixelImage?) -> Void
    ) {
        self.fetch = fetch
        self.onFetched = onFetched
        self.onDecoded = onDecoded
    }

    /// Returns the image if it is already decoded, otherwise starts work and
    /// returns nil. Call it every frame; it de-duplicates.
    public func artwork(source: String?, width: Int, height: Int) -> PixelImage? {
        guard let source, !source.isEmpty, width > 0, height > 0 else { return nil }
        let key = Key(source: source, width: width, height: height)

        if let cached = cache[key] { return cached }
        guard !decoding.contains(key) else { return nil }

        // Already have the bytes: decode at this size, no network.
        if let data = bytes[source] {
            decoding.insert(key)
            Task { [weak self] in
                guard let self else { return }
                let image = decodePixels(data, width: width, height: height)
                self.onDecoded(source, width, height, image)
            }
            return nil
        }

        decoding.insert(key)
        waiting[source, default: []].insert(key)

        // One fetch per URL, however many sizes are asking for it.
        guard !fetching.contains(source) else { return nil }
        fetching.insert(source)

        Task { [weak self] in
            guard let self else { return }
            let data = await self.fetch(source)
            self.onFetched(source, data)
        }
        return nil
    }

    /// Called from the UI thread when a fetch completes. Decodes for every cell
    /// size that asked while it was in flight.
    public func received(source: String, data: Data?) {
        fetching.remove(source)
        let pending = waiting.removeValue(forKey: source) ?? []

        guard let data else {
            for key in pending { decoding.remove(key) }
            return
        }
        storeBytes(data, for: source)

        for key in pending {
            Task { [weak self] in
                guard let self else { return }
                let image = decodePixels(data, width: key.width, height: key.height)
                self.onDecoded(source, key.width, key.height, image)
            }
        }
    }

    /// Called from the UI thread when a decode completes.
    public func store(source: String, width: Int, height: Int, image: PixelImage?) {
        let key = Key(source: source, width: width, height: height)
        decoding.remove(key)
        guard let image else { return }
        if cache[key] == nil {
            order.append(key)
            // Plain FIFO eviction: browsing moves forward, and an LRU's bookkeeping
            // is not worth it for a few dozen thumbnails.
            while order.count > limit {
                cache.removeValue(forKey: order.removeFirst())
            }
        }
        cache[key] = image
    }

    private func storeBytes(_ data: Data, for source: String) {
        if bytes[source] == nil { bytesOrder.append(source) }
        bytes[source] = data
        while bytesOrder.count > bytesLimit {
            bytes.removeValue(forKey: bytesOrder.removeFirst())
        }
    }
}
