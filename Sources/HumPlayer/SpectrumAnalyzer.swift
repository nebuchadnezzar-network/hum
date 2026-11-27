import Accelerate
import Foundation

/// Turns a stream of audio samples into normalised spectrum magnitudes.
///
/// Three-stage split, each with a different thread discipline:
///
///  1. **Producer** (audio thread) — `append` only copies samples into a
///     preallocated ring buffer. No FFT, no allocation, no unbounded work.
///  2. **Compute** (whoever asks first, under `computeLock`) — windows the latest
///     samples, runs one FFT, and folds the bins into `bandCount` log-spaced
///     bands with attack/release smoothing. Rate-limited, so the smoothing
///     advances on wall-clock time rather than once per caller.
///  3. **Present** (any thread) — resamples those bands to whatever width the
///     caller wants.
///
/// The rate limit and the lock are both load-bearing. The compute path runs on
/// the audio thread while the present path runs on the UI thread, and the
/// spectrum panel and the oscilloscope ask at different widths: without the
/// lock they corrupt the shared scratch buffers, and without the rate limit the
/// smoothing runs at the sum of the callers' frame rates and the bars visibly
/// snap. A GPU window was once a third consumer, which is how the corruption
/// was found; the constraint did not leave with it.
public final class SpectrumAnalyzer {
    /// 1024 samples at 44.1kHz is ~23ms — fast enough to feel locked to the beat,
    /// long enough for ~43Hz bins at the bottom end.
    public static let fftSize = 1024
    private static let log2n = vDSP_Length(10)  // log2(1024)

    /// Internal resolution, fixed and wider than any terminal, so presenting is
    /// always a downsample and never an interpolation up.
    private static let bandCount = 256

    /// ~120Hz ceiling on recomputation. Cheaper than the fastest consumer asks
    /// for, and it decouples smoothing from how many consumers are watching.
    private static let minimumComputeInterval: UInt64 = 8_000_000  // nanoseconds

    /// Expands the bottom of the scale. A straight dB→height map puts almost
    /// every band near the top on real music, which draws as a solid block
    /// instead of a spectrum.
    private static let displayGamma = 1.8

    /// Auto-gain: the display normalises against a slowly-released running peak,
    /// so quiet tracks still use the full height and loud ones stop clipping.
    /// Floored so a near-silent passage cannot be amplified into a wall of noise.
    private static let gainFloor = 0.35
    private static let gainRelease = 0.0025
    private static let scopeFloor = 0.08
    private static let maximumGain = 2.8

    /// Oscilloscope window: ~46ms at 44.1kHz, which shows a few cycles of a bass
    /// note and plenty of a snare without the trace turning into a smear.
    private static let scopeWindowSize = 2048

    // MARK: Producer state

    private let capacity = 8192
    private var ring: [Float]
    private var writeIndex = 0
    private let ringLock = UnfairLock()

    // MARK: Compute state (all guarded by computeLock)

    private let computeLock = UnfairLock()
    private var window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var sampleWindow: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var bands: [Double]
    private var rawBands: [Double]
    private var gainReference = 1.0
    /// Separate auto-scale for the oscilloscope: it works on raw amplitude
    /// rather than band energy, so it needs its own reference.
    private var scopeReference = 0.3
    private var scopeWindow: [Float]
    private var lastComputeTime: UInt64 = 0
    private var _level: Double = 0

    private var _sampleRate: Double = 44100

    public var sampleRate: Double {
        computeLock.withLock { _sampleRate }
    }

    /// Peak level of the most recent window, 0...1. Useful for a VU meter when
    /// there isn't room for a full spectrum.
    public var level: Double {
        computeLock.withLock { _level }
    }

    public init() {
        ring = Array(repeating: 0, count: capacity)
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.fftSize,
            isHalfWindow: false
        )
        guard let fft = vDSP.FFT(log2n: Self.log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("vDSP could not create a \(Self.fftSize)-point FFT setup")
        }
        self.fft = fft
        sampleWindow = Array(repeating: 0, count: Self.fftSize)
        real = Array(repeating: 0, count: Self.fftSize)
        imaginary = Array(repeating: 0, count: Self.fftSize)
        magnitudes = Array(repeating: 0, count: Self.fftSize / 2)
        bands = Array(repeating: 0, count: Self.bandCount)
        rawBands = Array(repeating: 0, count: Self.bandCount)
        scopeWindow = Array(repeating: 0, count: Self.scopeWindowSize)
    }

    public func setSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        computeLock.withLock { _sampleRate = rate }
    }

    // MARK: - Producer side (audio thread)

    /// Appends mono or strided samples. Called from the audio tap; does only
    /// bounded copying under a very short lock.
    public func append(_ samples: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        guard count > 0 else { return }
        ringLock.lock()
        var index = writeIndex
        for i in 0..<count {
            ring[index] = samples[i * stride]
            index += 1
            if index == capacity { index = 0 }
        }
        writeIndex = index
        ringLock.unlock()
    }

    /// Mixes two channels to mono as it appends, which is what the visualiser wants.
    public func appendStereo(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        count: Int
    ) {
        guard count > 0 else { return }
        ringLock.lock()
        var index = writeIndex
        for i in 0..<count {
            ring[index] = (left[i] + right[i]) * 0.5
            index += 1
            if index == capacity { index = 0 }
        }
        writeIndex = index
        ringLock.unlock()
    }

    /// Fades the ring towards silence. Called when playback pauses so the bars
    /// settle instead of freezing mid-transient.
    public func decay(factor: Float = 0.6) {
        ringLock.lock()
        vDSP.multiply(factor, ring, result: &ring)
        ringLock.unlock()
    }

    public func reset() {
        ringLock.lock()
        vDSP.fill(&ring, with: 0)
        writeIndex = 0
        ringLock.unlock()

        computeLock.lock()
        for index in bands.indices { bands[index] = 0 }
        for index in rawBands.indices { rawBands[index] = 0 }
        gainReference = 1
        scopeReference = 0.3
        for index in scopeWindow.indices { scopeWindow[index] = 0 }
        _level = 0
        lastComputeTime = 0
        computeLock.unlock()
    }

    // MARK: - Consumer side (any thread)

    /// The current spectrum as `bars` values in 0...1, low frequency first.
    ///
    /// Safe to call concurrently from as many consumers as you like, at any width.
    public func spectrum(bars: Int) -> [Double] {
        guard bars > 0 else { return [] }
        return resample(currentBands(), to: bars)
    }

    /// The raw waveform as `points` samples in -1...1, for the oscilloscope.
    ///
    /// Trigger-aligned on a rising zero crossing, the way a real scope is: without
    /// it the trace slides sideways every frame and is unreadable. Auto-scaled
    /// against a released peak so quiet passages still show a shape.
    public func waveform(points: Int) -> [Double] {
        guard points > 0 else { return [] }

        computeLock.lock()
        defer { computeLock.unlock() }

        copyScopeWindow()

        var peak: Float = 0
        vDSP_maxmgv(scopeWindow, 1, &peak, vDSP_Length(Self.scopeWindowSize))
        if Double(peak) > scopeReference {
            scopeReference = Double(peak)
        } else {
            scopeReference = max(Self.scopeFloor, scopeReference - Self.gainRelease)
        }
        guard peak > 1e-5 else { return Array(repeating: 0, count: points) }
        let scale = 1.0 / max(scopeReference, Self.scopeFloor)

        // Trigger: first upward zero crossing in the first quarter of the window,
        // leaving the rest as the span we actually draw.
        let searchLimit = Self.scopeWindowSize / 4
        var start = 0
        for index in 1..<searchLimit where scopeWindow[index - 1] <= 0 && scopeWindow[index] > 0 {
            start = index
            break
        }
        let span = Self.scopeWindowSize - searchLimit

        var result = [Double](repeating: 0, count: points)
        for index in 0..<points {
            let low = start + index * span / points
            let high = max(low + 1, start + (index + 1) * span / points)
            // Signed peak within the bucket, so transients survive downsampling
            // instead of averaging away.
            var extreme: Float = 0
            for position in low..<min(high, Self.scopeWindowSize) {
                if abs(scopeWindow[position]) > abs(extreme) { extreme = scopeWindow[position] }
            }
            result[index] = min(max(Double(extreme) * scale, -1), 1)
        }
        return result
    }

    private func copyScopeWindow() {
        ringLock.lock()
        let end = writeIndex
        for i in 0..<Self.scopeWindowSize {
            var index = end - Self.scopeWindowSize + i
            if index < 0 { index += capacity }
            scopeWindow[i] = ring[index]
        }
        ringLock.unlock()
    }

    /// Returns the smoothed bands, recomputing at most once per
    /// `minimumComputeInterval`.
    private func currentBands() -> [Double] {
        computeLock.lock()
        defer { computeLock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastComputeTime >= Self.minimumComputeInterval {
            lastComputeTime = now
            advanceBands()
        }
        return bands
    }

    /// Bands are log-spaced in frequency, so a plain proportional remap is the
    /// right thing here; taking the peak of each group preserves the transients
    /// that make the display worth looking at.
    ///
    /// `count` above `bandCount` stair-steps rather than interpolating — that
    /// needs a terminal wider than 256 columns to notice.
    private func resample(_ source: [Double], to count: Int) -> [Double] {
        guard count != source.count else { return source }
        var result = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let low = index * source.count / count
            let high = max(low + 1, (index + 1) * source.count / count)
            var peak = 0.0
            for position in low..<min(high, source.count) {
                peak = max(peak, source[position])
            }
            result[index] = peak
        }
        return result
    }

    /// One FFT, folded into `bands`. Caller holds `computeLock`.
    private func advanceBands() {
        copyLatestWindow()

        guard computeMagnitudes() else {
            // Silence: let the bars fall away, but they must reach *exactly* zero.
            // An asymptotic decay produces a forever-changing frame and the TUI
            // would redraw at 30fps with nothing playing.
            for index in bands.indices {
                bands[index] = bands[index] < 0.004 ? 0 : bands[index] * 0.82
            }
            _level = _level < 0.004 ? 0 : _level * 0.82
            return
        }

        let binCount = magnitudes.count
        let nyquist = _sampleRate / 2
        let logMinimum = log2(40.0)
        let logMaximum = log2(min(16000.0, nyquist))

        // -72dB floor: quiet enough to show detail in soft passages without
        // turning dither noise into a visible carpet.
        let floorDB = -72.0

        for band in 0..<Self.bandCount {
            let fraction = Double(band) / Double(Self.bandCount)
            let nextFraction = Double(band + 1) / Double(Self.bandCount)
            let lowFrequency = pow(2, logMinimum + (logMaximum - logMinimum) * fraction)
            let highFrequency = pow(2, logMinimum + (logMaximum - logMinimum) * nextFraction)

            let lowBin = max(0, min(binCount - 1, Int(lowFrequency / nyquist * Double(binCount))))
            let highBin = max(lowBin + 1, min(binCount, Int(highFrequency / nyquist * Double(binCount))))

            // Peak within the band, not mean: a mean across a wide high band
            // buries every transient that makes the display worth watching.
            var peak: Float = 0
            for bin in lowBin..<highBin { peak = max(peak, magnitudes[bin]) }

            let decibels = 20 * log10(max(Double(peak), 1e-9))
            var value = min(max((decibels - floorDB) / -floorDB, 0), 1)
            value = pow(value, Self.displayGamma)

            // Gentle tilt: real music loses roughly 3dB per octave going up, and
            // without this the right-hand half of the display barely moves.
            rawBands[band] = min(1, value * (1.0 + 0.45 * fraction))
        }

        // Auto-gain against a running peak, so the tallest bar reaches the top of
        // the display whatever the programme level.
        let frameMax = rawBands.max() ?? 0
        if frameMax > gainReference {
            gainReference = frameMax
        } else {
            gainReference = max(Self.gainFloor, gainReference - Self.gainRelease)
        }
        let gain = min(Self.maximumGain, 1.0 / max(gainReference, Self.gainFloor))

        for band in 0..<Self.bandCount {
            let target = min(1, rawBands[band] * gain)

            // Fast attack, slow release, snapping to zero at the bottom.
            let previous = bands[band]
            let next = target > previous
                ? previous + (target - previous) * 0.6
                : previous + (target - previous) * 0.18
            bands[band] = next < 0.004 ? 0 : next
        }
    }

    private func copyLatestWindow() {
        ringLock.lock()
        let end = writeIndex
        for i in 0..<Self.fftSize {
            var index = end - Self.fftSize + i
            if index < 0 { index += capacity }
            sampleWindow[i] = ring[index]
        }
        ringLock.unlock()
    }

    /// Returns false when the window is effectively silent, so the caller can
    /// skip the rest of the work and just decay.
    private func computeMagnitudes() -> Bool {
        var peak: Float = 0
        vDSP_maxmgv(sampleWindow, 1, &peak, vDSP_Length(Self.fftSize))
        _level = min(1, Double(peak))
        guard peak > 1e-6 else { return false }

        vDSP.multiply(sampleWindow, window, result: &real)
        vDSP.fill(&imaginary, with: 0)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var complex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                fft.forward(input: complex, output: &complex)
                // Only the first half is meaningful for a real-valued input.
                vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        // Normalise by the transform length so magnitudes stay comparable to the
        // input amplitude regardless of FFT size.
        vDSP.divide(magnitudes, Float(Self.fftSize / 2), result: &magnitudes)
        return true
    }
}
