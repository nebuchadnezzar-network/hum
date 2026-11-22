import Foundation

/// Decides which track's lyrics should be on screen, and what to request.
///
/// Extracted from the browser because this bookkeeping produced a run of bugs
/// that were invisible to inspection and impossible to reproduce in demo mode —
/// demo lyrics resolve synchronously, so every ordering hazard here vanishes.
/// Keyed on track ids rather than tracks so it carries no Plex dependency and
/// can be driven directly by tests.
public struct LyricsCoordinator {
    public enum State: Equatable {
        /// Nothing selected or playing.
        case idle
        /// A fetch is outstanding.
        case loading
        /// The server has none for this track.
        case unavailable
        /// Lyrics are on screen.
        case ready
    }

    /// How long a browsed selection must hold still before it is fetched.

    public private(set) var lyrics: Lyrics?
    /// Track the loaded lyrics belong to.
    public private(set) var loadedTrackID: String?
    /// Track a fetch has been asked for.
    public private(set) var requestedTrackID: String?
    private var hasResolved = false


    public init() {}

    public var state: State {
        guard requestedTrackID != nil else { return .idle }
        if let lyrics, !lyrics.isEmpty { return .ready }
        return hasResolved ? .unavailable : .loading
    }

    /// Call every frame with the track being inspected.
    ///
    /// Returns the track id to fetch, or nil if nothing should be requested.
    /// The playing track is requested at once; a browsed selection waits out
    /// the debounce.
    /// The track whose lyrics should be fetched now, if any.
    ///
    /// Takes no clock: there is nothing left to time. Selection used to fetch
    /// after a 350ms settle, which meant moving down a track list pulled a
    /// `/library/streams/{id}` per row — lyrics for songs nobody had started.
    /// Browsing should not cost what playing costs.
    public mutating func update(subjectID: String?, isPlaying: Bool) -> String? {
        guard let subjectID, subjectID != requestedTrackID else { return nil }
        // Playing is the only thing that fetches on its own; see
        // `requestExplicitly` for the reader asking directly.
        guard isPlaying else { return nil }
        return beginRequest(subjectID)
    }

    /// Fetches for a track the reader asked about directly, playing or not.
    ///
    /// `force` re-asks for a track already attempted. That is the only way back
    /// from a failure, and it matters because this server's 404s on lyrics
    /// streams are intermittent — the same path has served 200 and 404 seconds
    /// apart. Automatic retries are bounded and not repeated; a person who can
    /// see it failed can ask again.
    public mutating func requestExplicitly(subjectID: String, force: Bool = false) -> String? {
        guard force || subjectID != requestedTrackID else { return nil }
        return beginRequest(subjectID)
    }

    private mutating func beginRequest(_ trackID: String) -> String {
        requestedTrackID = trackID
        // Clear immediately: showing the previous track's lyrics under a new
        // track's name is worse than showing nothing for a moment.
        lyrics = nil
        hasResolved = false
        return trackID
    }

    /// Call when a fetch completes.
    /// Why the last fetch came back empty, if it did.
    ///
    /// "No lyrics" and "the server refused the lyrics it says exist" look the
    /// same on screen unless the reason survives the trip.
    public private(set) var failureSummary: String?
    /// Whether asking again could plausibly work.
    public private(set) var failureIsWorthRetrying = false

    public mutating func received(
        trackID: String,
        text: String?,
        failureSummary: String? = nil,
        failureIsWorthRetrying: Bool = false
    ) {
        // A reply for a track we have already moved past must not land.
        guard trackID == requestedTrackID else { return }
        // Nor may a late failure clear lyrics already showing for this same
        // track: two requests can complete in either order, and a nil arriving
        // second would blank a working pane.
        if text == nil, loadedTrackID == trackID, lyrics != nil { return }

        loadedTrackID = trackID
        lyrics = text.map(Lyrics.parse)
        self.failureSummary = text == nil ? failureSummary : nil
        self.failureIsWorthRetrying = text == nil ? failureIsWorthRetrying : false
        hasResolved = true
    }

    /// Forgets everything, so the next subject is fetched afresh.
    public mutating func reset() {
        failureSummary = nil
        failureIsWorthRetrying = false
        lyrics = nil
        loadedTrackID = nil
        requestedTrackID = nil
        hasResolved = false
    }
}
