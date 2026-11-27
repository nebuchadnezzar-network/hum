import AVFoundation
import Foundation

/// Builds the asset the player streams from.
///
/// Its own file so the diagnostics can construct exactly what playback
/// constructs. When they drifted apart, `hum stream` reported a URL as
/// playable that the player could not play.
public enum PlaybackAsset {
    /// `AVURLAsset` rather than `AVPlayerItem(url:)` so the spectrum tap can be
    /// attached to a concrete audio track once the asset reports one.
    ///
    /// Notably *without* `AVURLAssetPreferPreciseDurationAndTimingKey`. That was
    /// set, and it stopped a library of FLAC from playing at all: FLAC carries
    /// no duration index, so "precise" means reading the file to find out how
    /// long it is — over HTTP, for a 21MB track, the item never reached
    /// `.readyToPlay`. It never reached `.failed` either, so nothing was
    /// reported and a track simply sat at 0:00 in silence.
    ///
    /// Nothing needed it. Duration comes from Plex's own metadata and is only
    /// refined from the asset if the asset happens to know better.
    public static func make(url: URL) -> AVURLAsset {
        AVURLAsset(url: url)
    }

    /// How far a seek may land from where it was asked to.
    ///
    /// Zero tolerance asks for sample-exact positioning, which has the same
    /// problem from the other end: without a duration index the player has to
    /// hunt for the position. A quarter of a second is inaudible when the seek
    /// keys move ten seconds at a time.
    public static let seekTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
}
