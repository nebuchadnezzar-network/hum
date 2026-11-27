import AVFoundation
import Foundation
import HumPlex
import MediaPlayer

public struct PlaybackState: Sendable {
    public var track: Track?
    public var isPlaying = false
    public var isBuffering = false
    public var position: Double = 0
    public var duration: Double = 0
    public var volume: Float = 0.7
    public var queueCount = 0
    public var queueIndex = 0
    public var repeatQueue = false
    public var shuffle = false
    public var lastError: String?

    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    public init() {}
}

/// AVPlayer-backed playback with a queue, media-key handling and a spectrum tap.
///
/// All AVFoundation and MediaPlayer work happens on the main thread — both
/// frameworks expect a run loop and neither is thread-safe. The TUI runs on its
/// own thread and talks to the player through `perform`, which hops to main.
public final class Player: NSObject {
    public let analyzer = SpectrumAnalyzer()

    /// Resolves a track to a playable URL. Set by the app once a server is picked.
    public var streamURLProvider: ((Track) throws -> URL)?
    /// Optional artwork lookup for the Now Playing panel and Control Center.
    public var artworkURLProvider: ((Track) -> URL?)?
    /// Called on the main thread whenever playback state changes.
    public var onStateChange: ((PlaybackState) -> Void)?
    /// Called when a track starts, so the app can report progress to Plex.
    public var onTrackChange: ((Track) -> Void)?

    private let avPlayer = AVPlayer()
    private var queue: [Track] = []
    private var shuffledOrder: [Int] = []
    private var index = 0
    private var audioTap: AudioTap?
    private var tapAttached = false
    /// Fires if an item never becomes ready. See `startReadinessWatchdog`.
    private var readinessWatchdog: DispatchWorkItem?
    private var currentItem: AVPlayerItem?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    private let stateLock = UnfairLock()
    private var _state = PlaybackState()

    /// Updates the rating on the queued and playing copies of a track.
    ///
    /// The player holds its own copies, so a rating set while something is
    /// playing has to reach them or the metadata pane disagrees with the list
    /// it came from.
    public func applyRating(trackID: String, rating: Double?) {
        stateLock.withLock {
            if _state.track?.id == trackID {
                _state.track = _state.track?.withRating(rating)
            }
        }
        queue = queue.map { $0.id == trackID ? $0.withRating(rating) : $0 }
    }

    /// Thread-safe snapshot for the render loop.
    public var state: PlaybackState {
        stateLock.withLock { _state }
    }

    public override init() {
        super.init()
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        // Stay on the finished item and let `itemDidPlayToEnd` pick the next one:
        // hum owns the queue, and `.advance` is an AVQueuePlayer-only setting that
        // throws on a plain AVPlayer.
        avPlayer.actionAtItemEnd = .pause
        setUpTimeObserver()
        setUpRemoteCommands()
        observeRate()
    }

    deinit {
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
    }

    // MARK: - Transport

    /// Replaces the queue and starts playing at `startIndex`.
    public func play(_ tracks: [Track], startingAt startIndex: Int = 0) {
        onMain {
            guard !tracks.isEmpty else { return }
            self.queue = tracks
            self.index = min(max(startIndex, 0), tracks.count - 1)
            self.rebuildShuffleOrder()
            self.loadCurrentTrack(autoPlay: true)
        }
    }

    /// Appends to the queue without disturbing what is playing.
    public func enqueue(_ tracks: [Track]) {
        onMain {
            let wasEmpty = self.queue.isEmpty
            self.queue.append(contentsOf: tracks)
            self.rebuildShuffleOrder()
            if wasEmpty {
                self.index = 0
                self.loadCurrentTrack(autoPlay: true)
            } else {
                self.publish()
            }
        }
    }

    public func togglePlayPause() {
        onMain {
            if self.avPlayer.rate > 0 {
                self.avPlayer.pause()
            } else if self.currentItem != nil {
                self.avPlayer.play()
            } else if !self.queue.isEmpty {
                self.loadCurrentTrack(autoPlay: true)
            }
            self.publish()
        }
    }

    public func pause() {
        onMain {
            self.avPlayer.pause()
            self.publish()
        }
    }

    public func resume() {
        onMain {
            guard self.currentItem != nil else { return }
            self.avPlayer.play()
            self.publish()
        }
    }

    public func next() {
        onMain { self.advance(by: 1) }
    }

    /// Restarts the track if more than three seconds in, otherwise goes back one —
    /// the behaviour every other music player has trained people to expect.
    public func previous() {
        onMain {
            if self.avPlayer.currentTime().seconds > 3 {
                self.seek(to: 0)
            } else {
                self.advance(by: -1)
            }
        }
    }

    public func seek(to seconds: Double) {
        onMain {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            self.avPlayer.seek(
                to: time,
                toleranceBefore: PlaybackAsset.seekTolerance,
                toleranceAfter: PlaybackAsset.seekTolerance
            ) { _ in
                self.publish()
            }
        }
    }

    public func seekRelative(_ delta: Double) {
        onMain {
            let current = self.avPlayer.currentTime().seconds
            guard current.isFinite else { return }
            self.seek(to: current + delta)
        }
    }

    public func setVolume(_ volume: Float) {
        onMain {
            let clamped = min(max(volume, 0), 1)
            self.avPlayer.volume = clamped
            // Mirror it into the published state: the UI reads the snapshot, not
            // the AVPlayer, so skipping this pins the meter at its initial value
            // however much the actual volume moves.
            self.stateLock.withLock { self._state.volume = clamped }
            self.publish()
        }
    }

    public func adjustVolume(_ delta: Float) {
        onMain { self.setVolume(self.avPlayer.volume + delta) }
    }

    public func toggleRepeat() {
        onMain {
            self.stateLock.withLock { self._state.repeatQueue.toggle() }
            self.publish()
        }
    }

    public func toggleShuffle() {
        onMain {
            self.stateLock.withLock { self._state.shuffle.toggle() }
            self.rebuildShuffleOrder()
            self.publish()
        }
    }

    public func stop() {
        onMain {
            self.avPlayer.pause()
            self.teardownCurrentItem()
            self.queue = []
            self.index = 0
            self.analyzer.reset()
            self.stateLock.withLock {
                self._state = PlaybackState()
                self._state.volume = self.avPlayer.volume
            }
            self.updateNowPlaying()
            self.publish()
        }
    }

    /// The queue as it stands. Only valid to read from the main thread, which is
    /// where every mutation happens.
    public var currentQueue: [Track] { queue }

    // MARK: - Queue plumbing

    private func rebuildShuffleOrder() {
        guard stateLock.withLock({ _state.shuffle }) else {
            shuffledOrder = Array(queue.indices)
            return
        }
        // Keep the current track first so toggling shuffle never cuts the song off.
        var rest = Array(queue.indices).filter { $0 != index }
        rest.shuffle()
        shuffledOrder = [index] + rest
    }

    private func advance(by delta: Int) {
        guard !queue.isEmpty else { return }
        let isShuffling = stateLock.withLock { _state.shuffle }
        let repeating = stateLock.withLock { _state.repeatQueue }

        if isShuffling {
            let position = shuffledOrder.firstIndex(of: index) ?? 0
            var target = position + delta
            if target >= shuffledOrder.count {
                guard repeating else { return finishQueue() }
                rebuildShuffleOrder()
                target = 0
            }
            if target < 0 { target = shuffledOrder.count - 1 }
            index = shuffledOrder[target]
        } else {
            var target = index + delta
            if target >= queue.count {
                guard repeating else { return finishQueue() }
                target = 0
            }
            if target < 0 { target = repeating ? queue.count - 1 : 0 }
            index = target
        }

        loadCurrentTrack(autoPlay: true)
    }

    private func finishQueue() {
        avPlayer.pause()
        seek(to: 0)
        publish()
    }

    private func loadCurrentTrack(autoPlay: Bool) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]

        guard let provider = streamURLProvider else {
            setError("No Plex server connected yet.")
            return
        }

        let url: URL
        do {
            url = try provider(track)
        } catch {
            setError(error.localizedDescription)
            // A single unplayable track shouldn't stall the queue.
            if queue.count > 1 { advance(by: 1) }
            return
        }

        teardownCurrentItem()

        let asset = PlaybackAsset.make(url: url)
        let item = AVPlayerItem(asset: asset)
        // A larger buffer than the default: Plex over WAN stalls otherwise, and a
        // stall is the one thing that breaks the "instant" feel.
        item.preferredForwardBufferDuration = 10
        currentItem = item

        observe(item: item)
        startReadinessWatchdog(for: item, track: track)
        avPlayer.replaceCurrentItem(with: item)

        analyzer.reset()
        prepareTap()

        stateLock.withLock {
            _state.track = track
            _state.position = 0
            _state.duration = track.duration
            _state.queueCount = queue.count
            _state.queueIndex = index
            _state.isBuffering = true
            _state.lastError = nil
        }

        if autoPlay { avPlayer.play() }
        updateNowPlaying()
        publish()
        onTrackChange?(track)
    }

    /// Reports an item that never becomes ready.
    ///
    /// `.failed` is observed and surfaced, but an item can also sit in
    /// `.unknown` indefinitely — a request that hangs, or an asset the player
    /// cannot finish parsing. Nothing fired then, so a track sat at 0:00 in
    /// silence with no error, which is indistinguishable from hum ignoring the
    /// keypress. Asking for precise duration on remote FLAC did exactly this
    /// for a whole library.
    ///
    /// Reports rather than skipping: advancing would walk the queue in silence,
    /// and the reader can press `n` themselves.
    private func startReadinessWatchdog(for item: AVPlayerItem, track: Track) {
        readinessWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, self.currentItem === item else { return }
            guard item.status == .unknown else { return }
            self.setError("“\(track.title)” did not start. The server may be busy.")
            self.stateLock.withLock { self._state.isBuffering = false }
            self.publish()
        }
        readinessWatchdog = work
        // Long enough not to fire on a slow connection, short enough that
        // nobody sits watching a still clock wondering whether it is broken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// Prepares the spectrum tap for an item. Attachment happens once the item
    /// is ready to play — see `attachTapIfReady`.
    private func prepareTap() {
        audioTap = AudioTap(analyzer: analyzer)
        tapAttached = false
    }

    /// Attaches the tap using tracks the player has already parsed.
    ///
    /// The previous version kicked off its own `asset.loadTracks`, which starts
    /// a *second* read of the asset header over the network — queued behind the
    /// player's own buffering on the same host. The visualiser stayed empty for
    /// about a second after the music began. By `readyToPlay` the player has
    /// necessarily parsed the tracks already, so asking for them here returns
    /// immediately and the bars start with the sound.
    private func attachTapIfReady(_ item: AVPlayerItem) {
        guard !tapAttached, let tap = audioTap, item.status == .readyToPlay else { return }
        tapAttached = true
        Task { [weak self] in
            let tracks = try? await item.asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks?.first else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentItem === item else { return }
                // Failure here is not fatal: it just means no spectrum for this item.
                _ = tap.attach(to: item, track: audioTrack)
            }
        }
    }

    private func teardownCurrentItem() {
        readinessWatchdog?.cancel()
        readinessWatchdog = nil
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        statusObservation = nil
        bufferObservation = nil
        if let currentItem {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemDidPlayToEndTime,
                object: currentItem
            )
            audioTap?.detach(from: currentItem)
        }
        audioTap = nil
        currentItem = nil
    }

    // MARK: - Observation

    private func setUpTimeObserver() {
        // Four times a second: enough for a smooth scrubber, cheap enough to
        // ignore. The spectrum is driven by the render loop, not by this.
        let interval = CMTime(value: 1, timescale: 4)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self else { return }
            let duration = self.currentItem?.duration.seconds ?? 0
            self.stateLock.withLock {
                self._state.position = time.seconds.isFinite ? time.seconds : 0
                if duration.isFinite, duration > 0 { self._state.duration = duration }
            }
            self.publish()
        }
    }

    private func observeRate() {
        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let playing = player.rate > 0
            self.stateLock.withLock { self._state.isPlaying = playing }
            // When paused, let the bars sink rather than freeze.
            if !playing { self.analyzer.decay(factor: 0.5) }
            self.updateNowPlaying()
            self.publish()
        }
    }

    private func observe(item: AVPlayerItem) {
        // `.initial` as well as `.new`: a locally-cached item can already be
        // ready by the time we observe it, and with `.new` alone that callback
        // never fires — no duration, and no spectrum.
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .failed:
                let message = item.error?.localizedDescription ?? "Playback failed."
                self.setError(message)
            case .readyToPlay:
                self.readinessWatchdog?.cancel()
                self.readinessWatchdog = nil
                // The player has parsed the asset by now, so the tap can be
                // attached without a second network read.
                self.attachTapIfReady(item)
                let duration = item.duration.seconds
                self.stateLock.withLock {
                    self._state.isBuffering = false
                    if duration.isFinite, duration > 0 { self._state.duration = duration }
                }
                self.updateNowPlaying()
                self.publish()
            default:
                break
            }
        }

        bufferObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) {
            [weak self] item, _ in
            guard let self else { return }
            self.stateLock.withLock { self._state.isBuffering = !item.isPlaybackLikelyToKeepUp }
            self.publish()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    @objc private func itemDidPlayToEnd(_ notification: Notification) {
        onMain { self.advance(by: 1) }
    }

    // MARK: - Media keys and Now Playing

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seekRelative(15)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seekRelative(-15)
            return .success
        }
    }

    private func updateNowPlaying() {
        let snapshot = state
        let center = MPNowPlayingInfoCenter.default()

        guard let track = snapshot.track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let number = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = number
        }
        // Keep any artwork already loaded for this track so the panel doesn't flash.
        if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork],
           center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == track.title {
            info[MPMediaItemPropertyArtwork] = existing
        }

        center.nowPlayingInfo = info
        center.playbackState = snapshot.isPlaying ? .playing : .paused

        loadArtwork(for: track)
    }

    /// The Now Playing cover already fetched, or being fetched.
    ///
    /// `updateNowPlaying` runs on every rate, status and track change, and each
    /// run used to re-fetch the cover unconditionally. A server log caught
    /// three fetches of one 42KB JPEG inside two seconds:
    ///
    /// ```
    /// #25a …&width=512&height=512&url=…/127819/thumb/…  42486 bytes
    /// #25c …&width=512&height=512&url=…/127819/thumb/…  42486 bytes  (+3ms)
    /// #25d …&width=512&height=512&url=…/127819/thumb/…  42486 bytes  (+1.6s)
    /// ```
    ///
    /// Keyed on the URL, not the track, so moving between tracks on one album
    /// reuses the cover it already has.
    private var loadedArtworkURL: URL?

    private func loadArtwork(for track: Track) {
        guard let url = artworkURLProvider?(track) else { return }
        guard url != loadedArtworkURL else { return }
        loadedArtworkURL = url

        Task.detached { [weak self] in
            // Not URLSession.shared: it persists responses — and the token in
            // their URLs — to an on-disk cache.
            guard let (data, _) = try? await PlexSession.shared.data(from: url) else {
                // Let a transient failure be retried rather than wedging this
                // cover shut for the rest of the session.
                await MainActor.run { [weak self] in
                    guard let self, self.loadedArtworkURL == url else { return }
                    self.loadedArtworkURL = nil
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.state.track?.id == track.id else { return }
                self.setArtwork(data: data)
            }
        }
    }

    // Split out so the AppKit import stays in one place.
    private func setArtwork(data: Data) {
        guard let artwork = makeArtwork(from: data) else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - State

    private func setError(_ message: String) {
        stateLock.withLock {
            _state.lastError = message
            _state.isBuffering = false
        }
        publish()
    }

    private func publish() {
        let snapshot = state
        if Thread.isMainThread {
            onStateChange?(snapshot)
        } else {
            DispatchQueue.main.async { self.onStateChange?(snapshot) }
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
