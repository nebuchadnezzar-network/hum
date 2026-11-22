import Foundation
import HumPlex

/// Generates the audio demo mode plays.
///
/// Synthesised rather than shipped: a bundled recording means a third-party
/// licence to track and a binary blob in the repository, for a file whose only
/// job is to make the meters move.
///
/// It matters that demo mode makes real sound. Everything downstream of
/// `AVPlayer` — the audio tap, the spectrum, the oscilloscope, media keys, the
/// playback clock, the window title — is unreachable without it, so none of it
/// could be exercised without a Plex server to hand.
public enum DemoAudio {
    private static let sampleRate = 44_100.0
    private static let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hum-demo-audio")

    /// A WAV for `track`, written once and reused.
    ///
    /// Deterministic in the track's id, so a track sounds the same every run
    /// and two tracks do not sound alike.
    public static func url(for track: Track) -> URL? {
        let name = track.id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "|", with: "-")
        let url = directory.appendingPathComponent("\(name).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try render(seed: seed(for: track.id), seconds: track.duration).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Removes the generated files. Demo audio is scratch, and leaving a few
    /// megabytes per track in the temp directory is untidy.
    public static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func seed(for id: String) -> UInt64 {
        // FNV-1a: stable across runs, unlike `hashValue`, which is seeded per
        // process and would give a track a different voice every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A drone with a pentatonic arpeggio over it.
    ///
    /// Pentatonic because any note of it sits acceptably against any other, so
    /// a sequence picked by a hash cannot land on something sour. The partials
    /// and the moving filter are what give the spectrum something to show;
    /// a plain sine would be one bar.
    public static func render(seed: UInt64, seconds: Double) -> Data {
        let frames = Int(sampleRate * max(1, min(seconds, 600)))
        var random = SplitMix64(seed: seed)

        // A minor pentatonic rooted somewhere comfortable.
        let root = 110.0 * pow(2.0, Double(random.next(upTo: 5)) / 12.0)
        let steps = [0.0, 3.0, 5.0, 7.0, 10.0, 12.0]
        let noteLength = 0.28 + Double(random.next(upTo: 3)) * 0.06

        var samples = [Int16]()
        samples.reserveCapacity(frames)

        // Chosen up front so the melody repeats rather than wanders.
        let phrase = (0..<16).map { _ in steps[Int(random.next(upTo: UInt64(steps.count)))] }

        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            var value = 0.0

            // Drone: root and fifth, quiet, with slow detune so it is not static.
            value += 0.10 * sin(2 * .pi * root * t)
            value += 0.07 * sin(2 * .pi * root * 1.5 * (t + 0.0005 * sin(2 * .pi * 0.07 * t)))

            // Arpeggio with a plucked envelope.
            let index = Int(t / noteLength) % phrase.count
            let into = t.truncatingRemainder(dividingBy: noteLength)
            let envelope = exp(-into * 6.0) * (1 - exp(-into * 400))
            let note = root * 2 * pow(2.0, phrase[index] / 12.0)
            // Three partials, falling away — enough spread for the analyser to
            // draw something across the band rather than one spike.
            value += envelope * 0.22 * sin(2 * .pi * note * t)
            value += envelope * 0.09 * sin(2 * .pi * note * 2 * t)
            value += envelope * 0.04 * sin(2 * .pi * note * 3 * t)

            // A slow sweep so the picture keeps changing while a track plays.
            let sweep = 0.5 + 0.5 * sin(2 * .pi * 0.03 * t)
            value += 0.05 * sweep * sin(2 * .pi * (root * 8 + root * 6 * sweep) * t)

            // Fade the first and last half-second: a hard start clicks, and
            // the click is the loudest thing in the spectrum when it happens.
            let fade = min(1.0, min(t, Double(frames) / sampleRate - t) / 0.5)
            value *= max(0, fade)

            samples.append(Int16(max(-1, min(1, value)) * 32_000))
        }

        return wav(samples)
    }

    /// 16-bit mono PCM in a RIFF container. AVFoundation reads this directly,
    /// so there is nothing to decode or convert.
    private static func wav(_ samples: [Int16]) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)

        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append32(16)                                   // PCM header length
        append16(1)                                    // PCM, uncompressed
        append16(1)                                    // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)               // byte rate
        append16(2)                                    // block align
        append16(16)                                   // bits per sample
        append("data")
        append32(UInt32(dataBytes))
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Small deterministic generator, so the same track sounds the same every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: UInt64) -> UInt64 {
        bound == 0 ? 0 : next() % bound
    }
}
