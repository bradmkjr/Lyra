import AVFoundation
import MediaToolbox
import os

/// Sees every decoded sample Lyra plays (an `MTAudioProcessingTap` on the player item):
/// hands a 16-bit stereo copy to `sink` for the AirPlay rooms, and can delay this Mac's own
/// output so local speakers play at the same moment as the AirPlay rooms.
///
/// The process callback runs on a real-time audio thread, so state lives behind a short
/// unfair lock and nothing in it allocates on the hot path except the outgoing copy.
final class PCMTap: @unchecked Sendable {
    struct Config {
        /// Receives interleaved 16-bit stereo at 44.1 kHz and the uptime (ns) of its first frame.
        var sink: (@Sendable ([Int16], UInt64) -> Void)?
        /// How long to hold back local output, in seconds (0 = pass through).
        var localDelay: TimeInterval = 0
    }

    private static let log = Logger(subsystem: "com.velpeo.Lyra", category: "playback")
    private static let maxDelaySeconds = 5.0

    private let config = OSAllocatedUnfairLock(initialState: Config())

    // Set in prepare; only touched from the tap's own callbacks afterwards.
    fileprivate var sampleRate: Double = 0
    fileprivate var channels = 0
    fileprivate var isFloat = false
    fileprivate var isInterleaved = false
    /// Per-channel delay lines for local output.
    fileprivate var delayLines: [[Float]] = []
    fileprivate var writeIndex = 0
    fileprivate var warnedRate = false

    func setSink(_ sink: (@Sendable ([Int16], UInt64) -> Void)?) {
        config.withLock { $0.sink = sink }
    }

    func setLocalDelay(_ seconds: TimeInterval) {
        config.withLock { $0.localDelay = seconds }
    }

    fileprivate var snapshot: Config { config.withLock { $0 } }

    /// Attaches a fresh tap to `item`'s audio track (loaded asynchronously).
    @MainActor
    func attach(to item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let tap = makeTap() else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    private func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if status != noErr { Self.log.error("Couldn't create audio tap: \(status)") }
        return tap
    }

    fileprivate func prepare(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        channels = Int(format.mChannelsPerFrame)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let length = Int(Self.maxDelaySeconds * max(sampleRate, 1))
        delayLines = Array(repeating: [Float](repeating: 0, count: length), count: max(channels, 1))
        writeIndex = 0
        Self.log.info("Audio tap: \(Int(self.sampleRate)) Hz, \(self.channels) ch, float=\(self.isFloat), interleaved=\(self.isInterleaved)")
    }

    fileprivate func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, isFloat, !isInterleaved, channels > 0, buffers.count >= channels else { return }
        let config = snapshot
        let channelData = (0..<channels).map { buffers[$0].mData!.assumingMemoryBound(to: Float.self) }

        // Copy out for AirPlay before delaying the local signal.
        if let sink = config.sink {
            if Int(sampleRate.rounded()) == RAOPFormat.sampleRate {
                var samples = [Int16](repeating: 0, count: frames * 2)
                let left = channelData[0]
                let right = channelData[min(1, channels - 1)]
                for frame in 0..<frames {
                    samples[frame * 2] = Self.int16(left[frame])
                    samples[frame * 2 + 1] = Self.int16(right[frame])
                }
                sink(samples, clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            } else if !warnedRate {
                warnedRate = true
                Self.log.error("Audio tap at \(Int(self.sampleRate)) Hz; AirPlay needs 44100, not sending")
            }
        }

        // Local output: write into the delay line, play what was written `delay` ago.
        let length = delayLines.first?.count ?? 0
        let delay = min(length - 1, Int(config.localDelay * sampleRate))
        guard length > 0 else { return }
        for channel in 0..<channels {
            let data = channelData[channel]
            delayLines[channel].withUnsafeMutableBufferPointer { line in
                var write = writeIndex
                for frame in 0..<frames {
                    line[write] = data[frame]
                    if delay > 0 {
                        var read = write - delay
                        if read < 0 { read += length }
                        data[frame] = line[read]
                    }
                    write += 1
                    if write == length { write = 0 }
                }
            }
        }
        writeIndex = (writeIndex + frames) % length
    }

    private static func int16(_ value: Float) -> Int16 {
        Int16(max(-1, min(1, value)) * 32_767)
    }
}

// MARK: - Tap callbacks (C function pointers; they reach the PCMTap through tap storage)

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                     _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<PCMTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                        _ format: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<PCMTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .prepare(format: format.pointee)
}

private func tapProcess(_ tap: MTAudioProcessingTap, _ frameCount: CMItemCount, _ flags: MTAudioProcessingTapFlags,
                        _ bufferList: UnsafeMutablePointer<AudioBufferList>,
                        _ framesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut) == noErr else {
        return
    }
    Unmanaged<PCMTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
}
