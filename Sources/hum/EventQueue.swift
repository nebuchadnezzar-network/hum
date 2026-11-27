import Foundation
import HumPlayer
import HumPlex
import HumTUI

/// Everything the UI thread can be woken up by.
enum Event {
    case key(Key)
    case resize(Terminal.Size)
    /// Render-loop heartbeat; drives the spectrum and the scrubber.
    case tick
    case playback(PlaybackState)
    case status(String, isError: Bool)
    case connected(PlexServer, [LibrarySection])
    case sectionLoaded(sectionID: String, collections: [CollectionItem])
    /// A further page of the collection list, appended to what is already shown.
    case sectionPageLoaded(sectionID: String, collections: [CollectionItem], total: Int)
    case albumsLoaded(parentID: String, albums: [Album])
    case tracksLoaded(albumID: String, tracks: [Track])
    /// The same tracks, re-read with their media streams, so the lyrics flag is
    /// accurate. Merged without disturbing the selection.
    case tracksEnriched(albumID: String, tracks: [Track])
    /// `failure` is nil on success, and a human-readable reason otherwise —
    /// "no lyrics for this track" reads very differently from "the server
    /// refused the lyrics (HTTP 404)".
    case lyricsLoaded(
        trackID: String,
        text: String?,
        failure: String? = nil,
        retryable: Bool = false
    )
    case searchResults(query: String, results: SearchResults)
    /// A random landing: replaces all three panes and starts playing.
    case landed(Landing)
    /// Playlists fetched for the "add to playlist" picker.
    case playlistChoices([CollectionItem])
    /// A random mix drawn from the whole library. `replacing` distinguishes
    /// starting one from topping up the one already playing.
    case shuffleAll(tracks: [Track], replacing: Bool)
    /// A browse request finished, successfully or not, and is no longer on the
    /// wire. Keeps the in-flight bookkeeping on the UI thread.
    /// A track's rating changed — optimistically, or reverted after a refusal.
    case ratingChanged(trackID: String, rating: Double?)
    case collectionsSettled
    case albumsSettled(parentID: String)
    case tracksSettled(albumID: String)
    case artworkLoaded(source: String, width: Int, height: Int, image: PixelImage?)
    /// Raw bytes arrived for a cover. Separate from `artworkLoaded` because one
    /// fetch can serve several cell sizes — see `ArtworkLoader`.
    case artworkFetched(source: String, data: Data?)
    case quit
}

extension Event {
    /// Whether this event should be drawn the instant it arrives.
    ///
    /// Anything the user did, or any new content to show, redraws immediately so
    /// input always feels instant. Playback ticks do not: they arrive far faster
    /// than the display needs and are what the frame budget exists to pace.
    var demandsImmediateRedraw: Bool {
        switch self {
        case .playback, .tick:
            return false
        default:
            return true
        }
    }
}

/// Thread-safe mailbox. The UI thread owns all state and only ever mutates it in
/// response to events drained from here, which keeps a 60fps render loop and a
/// pile of concurrent network tasks from needing a single lock between them.
final class EventQueue {
    private var events: [Event] = []
    private let condition = NSCondition()

    func post(_ event: Event) {
        condition.lock()
        events.append(event)
        condition.signal()
        condition.unlock()
    }

    /// Waits up to `timeout` seconds for at least one event, then drains all of
    /// them. Returns empty on timeout so the caller can still redraw.
    func drain(timeout: TimeInterval) -> [Event] {
        condition.lock()
        if events.isEmpty {
            condition.wait(until: Date().addingTimeInterval(timeout))
        }
        let drained = events
        events.removeAll(keepingCapacity: true)
        condition.unlock()
        return drained
    }
}

/// A row in the leftmost pane: an artist, or a facet value like a genre.
struct CollectionItem: Hashable {
    let id: String
    let title: String
    let detail: String?
}
