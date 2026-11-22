import Foundation

/// Estimates the playback position between the player's updates.
///
/// `AVPlayer`'s periodic time observer fires four times a second. That is ample
/// for a scrubber and hopeless for lighting up words, so the position is
/// extrapolated from the last known value using the monotonic clock.
///
/// Three properties matter, and each exists because the naive version gets it
/// wrong:
///
/// - **Never goes backwards.** Extrapolation overshoots as often as it
///   undershoots, so a fresh update can land *behind* the estimate. Letting the
///   position drop un-highlights a word that was just lit, and a flicker at every
///   word boundary is far more noticeable than a few milliseconds of lag.
/// - **Bounded.** If updates stop — a stall, a wedged main thread — the estimate
///   must stop too rather than running away from the audio.
/// - **Snaps on a seek.** A deliberate jump is not drift, and must be allowed to
///   move the position backwards.
public struct PlaybackClock: Sendable {
    /// How far the estimate may run past the last real update. Four updates a
    /// second means a healthy stream never needs more than ~0.25s; a full second
    /// tolerates a hiccup without letting a dead stream drift.
    public static let maximumExtrapolation = 1.0

    /// A discrepancy larger than this is a seek or a track change, not drift.
    public static let seekThreshold = 0.5

    private var anchorPosition = 0.0
    private var anchorTime: Int64 = 0
    private var isPlaying = false
    private var hasAnchor = false
    private var floor = 0.0

    public init() {}

    /// Records a real position report from the player.
    public mutating func update(position: Double, isPlaying playing: Bool, now: Int64) {
        let previousEstimate = extrapolated(at: now)
        let drifted = hasAnchor && playing && isPlaying
            && abs(position - previousEstimate) > Self.seekThreshold

        if !hasAnchor || !playing || !isPlaying || drifted {
            // Trust the player: either nothing to compare against, a pause, or a
            // jump too large to be drift.
            floor = position
        } else {
            // Carry the estimate we were already showing. Re-anchoring to a
            // report that is a few milliseconds behind would otherwise walk the
            // position backwards, and the floor has to be raised *here* — a
            // read must not have to mutate the clock to stay monotonic.
            floor = max(floor, previousEstimate)
        }
        anchorPosition = position
        anchorTime = now
        isPlaying = playing
        hasAnchor = true
    }

    /// Resets to a known position, for a track change.
    public mutating func reset(to position: Double = 0) {
        anchorPosition = position
        anchorTime = 0
        isPlaying = false
        hasAnchor = false
        floor = position
    }

    private func extrapolated(at now: Int64) -> Double {
        guard hasAnchor, isPlaying else { return anchorPosition }
        let elapsed = Double(now - anchorTime) / 1_000_000_000
        return anchorPosition + min(max(elapsed, 0), Self.maximumExtrapolation)
    }

    /// The best estimate of the position now. Monotonic between seeks, and
    /// non-mutating — the floor is maintained by `update`, so reading the clock
    /// has no side effects and callers cannot accidentally disable monotonicity
    /// by choosing the "safe-looking" accessor.
    public func position(at now: Int64) -> Double {
        max(extrapolated(at: now), floor)
    }
}
