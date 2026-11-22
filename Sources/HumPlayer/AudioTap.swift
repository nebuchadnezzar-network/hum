import AVFoundation
import Foundation
import MediaToolbox

/// `MTAudioProcessingTapCreate`, resolved rather than called directly.
///
/// Its out-parameter is annotated `CM_RETURNS_RETAINED_PARAMETER` only in
/// recent SDKs. With the annotation Swift imports it as a managed
/// `MTAudioProcessingTap?`; without it, as `Unmanaged<MTAudioProcessingTap>?`.
/// No single call site compiles against both, and the choice is not ours to
/// make: Homebrew builds against the SDK matching the formula's minimum macOS,
/// which is `MacOSX14.sdk` — unannotated — while a local `swift build` uses the
/// current one. The result compiled here and failed under brew with:
///
///     error: cannot convert value of type 'MTAudioProcessingTap?' to
///     expected argument type 'Unmanaged<MTAudioProcessingTap>?'
///
/// Resolving the symbol fixes one signature, the C ABI, which does not vary by
/// SDK. Verified building against both MacOSX14.4.sdk and MacOSX26.2.sdk.
private let mtAudioProcessingTapCreate: (@convention(c) (
    CFAllocator?,
    UnsafePointer<MTAudioProcessingTapCallbacks>,
    MTAudioProcessingTapCreationFlags,
    UnsafeMutablePointer<Unmanaged<MTAudioProcessingTap>?>
) -> OSStatus)? = {
    // RTLD_DEFAULT: MediaToolbox is already linked, so this searches images
    // that are loaded rather than opening anything.
    guard let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "MTAudioProcessingTapCreate"
    ) else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (
        CFAllocator?,
        UnsafePointer<MTAudioProcessingTapCallbacks>,
        MTAudioProcessingTapCreationFlags,
        UnsafeMutablePointer<Unmanaged<MTAudioProcessingTap>?>
    ) -> OSStatus).self)
}()

/// Taps the audio AVPlayer is already decoding and forwards samples to a
/// `SpectrumAnalyzer`.
///
/// This reads the real signal rather than re-decoding the file separately, so the
/// visualiser is frame-accurate against what you hear and costs no extra decode.
/// The trade-off: taps only attach to progressive assets. Plex direct-play hands
/// us plain files, so that holds — but if a server ever forces HLS, `attach`
/// returns false and the UI falls back to showing no spectrum.
public final class AudioTap {
    private let analyzer: SpectrumAnalyzer
    /// Held so the tap outlives the audio mix that references it.
    private var tap: MTAudioProcessingTap?

    public init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    /// Builds an audio mix carrying the tap and installs it on `item`.
    /// Returns false when the asset has no audio track we can tap.
    public func attach(to item: AVPlayerItem, track: AVAssetTrack) -> Bool {
        tap = nil

        // Retained here, released in the finalize callback: the tap outlives the
        // call that creates it and Core Media holds only this raw pointer.
        let clientInfo = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        var created: Unmanaged<MTAudioProcessingTap>?
        guard let create = mtAudioProcessingTapCreate else {
            Unmanaged<AudioTap>.fromOpaque(clientInfo).release()
            return false
        }
        let status = create(
            kCFAllocatorDefault,
            &callbacks,
            // PostEffects so the tap sees the signal after volume is applied —
            // the bars should shrink when you turn it down.
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &created
        )
        // Retained: the out-parameter is documented
        // `CM_RETURNS_RETAINED_PARAMETER`, so the caller owns it.
        guard status == noErr, let newTap = created?.takeRetainedValue() else {
            // Balance the retain above; finalize will never run to do it for us.
            Unmanaged<AudioTap>.fromOpaque(clientInfo).release()
            return false
        }
        tap = newTap

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = newTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return true
    }

    public func detach(from item: AVPlayerItem) {
        item.audioMix = nil
        tap = nil
    }

    // MARK: - Callbacks
    //
    // These are C function pointers, so they cannot capture context; the instance
    // arrives via the tap's storage pointer.

    private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
    }

    private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        Unmanaged<AudioTap>.fromOpaque(storage).release()
    }

    private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let instance = Unmanaged<AudioTap>.fromOpaque(storage).takeUnretainedValue()
        instance.analyzer.setSampleRate(format.pointee.mSampleRate)
    }

    private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

    private let tapProcess: MTAudioProcessingTapProcessCallback = {
        tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in

        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferListInOut,
            flagsOut,
            nil,
            numberFramesOut
        )
        guard status == noErr else { return }

        let storage = MTAudioProcessingTapGetStorage(tap)
        let instance = Unmanaged<AudioTap>.fromOpaque(storage).takeUnretainedValue()

        let frames = Int(numberFramesOut.pointee)
        guard frames > 0 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        guard let first = buffers.first, let rawLeft = first.mData else { return }

        if buffers.count >= 2, let rawRight = buffers[1].mData {
            // Deinterleaved stereo, the usual AVPlayer tap format.
            instance.analyzer.appendStereo(
                left: rawLeft.assumingMemoryBound(to: Float.self),
                right: rawRight.assumingMemoryBound(to: Float.self),
                count: frames
            )
        } else if first.mNumberChannels >= 2 {
            // Interleaved: take the left channel only, stepping over the others.
            instance.analyzer.append(
                rawLeft.assumingMemoryBound(to: Float.self),
                count: frames,
                stride: Int(first.mNumberChannels)
            )
        } else {
            instance.analyzer.append(
                rawLeft.assumingMemoryBound(to: Float.self),
                count: frames
            )
        }
    }
}
