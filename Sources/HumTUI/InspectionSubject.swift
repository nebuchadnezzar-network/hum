import Foundation

/// Decides whether the panes describe the row under the cursor or the track
/// that is playing.
///
/// Neither fixed order works:
///
/// - Playback always winning freezes the panes on the playing track, so
///   browsing never changes them.
/// - The cursor always winning breaks `n`/`p`, which advance playback without
///   moving the list — the panes stay on a track you have left behind.
///
/// So it is a claim, released by anything that means "the cursor is no longer
/// what you are pointing at". The rule used to be eight assignments spread
/// across the browser, each with slightly different intent, and the
/// disagreement shipped as *"the rating goes to the first song in the playlist,
/// not the one I'm listening to"*: a list reloaded with its selection at row 0,
/// something that was not the track list had claimed the cursor, and the rating
/// key wrote to a row nobody had chosen.
///
/// Reading the wrong track's lyrics is a glitch. Rating the wrong track is a
/// write to someone's server, which is why this is a type with tests rather
/// than a `Bool` set in eight places.
public struct InspectionSubject: Equatable, Sendable {
    public enum Preference: Equatable, Sendable {
        /// The row under the cursor, falling back to what is playing.
        case cursor
        /// What is playing, falling back to the row under the cursor.
        case playback
    }

    private var cursorClaimed: Bool

    public init() {
        // Nothing is selected at launch, so playback is the only candidate.
        cursorClaimed = false
    }

    public var preference: Preference { cursorClaimed ? .cursor : .playback }

    /// The cursor moved. Only the track list can claim the subject: moving
    /// through artists or albums changes *which list* you are looking at, not
    /// which track.
    public mutating func cursorMoved(inTrackList: Bool) {
        cursorClaimed = inTrackList
    }

    /// Focus moved between panes.
    public mutating func focusMoved(toTrackList: Bool) {
        cursorClaimed = toTrackList
    }

    /// Playback moved to a different track — `n`, `p`, or one track ending and
    /// the next starting. The reader did not move the cursor, so the panes have
    /// to follow the music.
    public mutating func playbackChangedTrack() {
        cursorClaimed = false
    }

    /// The lists were replaced: a mode change, a search, or a search cleared.
    ///
    /// Releases the claim, because the incoming list's selection starts at row
    /// 0 and nobody has chosen it yet. `landedOnTrackList` is for a search that
    /// puts the cursor straight into the results.
    public mutating func listsReplaced(landedOnTrackList: Bool = false) {
        cursorClaimed = landedOnTrackList
    }
}
