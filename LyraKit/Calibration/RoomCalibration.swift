import Accelerate
import AVFoundation
import Foundation
import os

/// Measures how far a room's audio is from where Lyra's clock says it should be, using the
/// Mac's microphone: Lyra plays short chirps through that room only, records them, and
/// finds each one by cross-correlation. Run it standing in the room you're calibrating.
public enum RoomCalibration {
    /// Chirps per measurement, and the gap between their starts.
    static let chirpCount = 3
    static let chirpSpacing: TimeInterval = 1.0
    static let chirpDuration: TimeInterval = 0.25

    public struct Result: Sendable {
        /// Seconds the room sounded later (+) or earlier (−) than intended, per chirp heard.
        public let errors: [TimeInterval]
        /// The median error; subtract it from the room's delay.
        public var error: TimeInterval { errors.sorted()[errors.count / 2] }
    }

    public enum CalibrationError: LocalizedError {
        case noMicrophone, microphoneDenied, notHeard

        public var errorDescription: String? {
            switch self {
            case .noMicrophone: "This Mac has no microphone. Set the delay by ear instead."
            case .microphoneDenied: "Lyra needs microphone access to calibrate (System Settings → Privacy & Security → Microphone)."
            case .notHeard: "Couldn't hear the room's chirps. Stand closer to its speakers, turn them up, and try again."
            }
        }
    }

    /// Plays chirps to `receiverID` via `streamer` and measures their timing error. The room
    /// must already be connected; `delay` is its current delay setting.
    public static func measure(streamer: AirPlayStreamer, receiverID: String,
                               delay: TimeInterval) async throws -> Result {
        let recorder = try await MicrophoneRecorder.start()
        // Let the microphone settle before the first chirp.
        try await Task.sleep(for: .milliseconds(300))

        let signal = chirpTrain(sampleRate: Double(RAOPFormat.sampleRate))
        let stereo = signal.flatMap { sample -> [Int16] in
            let value = Int16(sample * 32_767 * 0.6)
            return [value, value]
        }
        let start = await streamer.play(samples: stereo, only: receiverID)

        let listen = AirPlayStreamer.baseLatency + max(0, delay) + Double(chirpCount) * chirpSpacing + 1.0
        try await Task.sleep(for: .seconds(listen))
        let recording = recorder.stop()

        let template = chirp(sampleRate: recording.sampleRate)
        var errors: [TimeInterval] = []
        for index in 0..<chirpCount {
            let intended = Double(start) / 1e9 + Double(index) * chirpSpacing + AirPlayStreamer.baseLatency + delay
            // Search ±0.75 s around where the chirp should be heard.
            let center = (intended - recording.startSeconds) * recording.sampleRate
            let window = Int(0.75 * recording.sampleRate)
            let lastStart = recording.samples.count - template.count
            let range = max(0, Int(center) - window)..<min(lastStart, Int(center) + window)
            guard !range.isEmpty else { continue }
            guard let found = ArrivalDetector.find(template, in: recording.samples, range: range) else { continue }
            let heard = recording.startSeconds + Double(found) / recording.sampleRate
            errors.append(heard - intended)
        }
        guard errors.count >= 2 else { throw CalibrationError.notHeard }
        return Result(errors: errors)
    }

    /// A rising sweep, 600 Hz → 6 kHz with a Hann window: easy to find precisely in a recording.
    static func chirp(sampleRate: Double) -> [Float] {
        let count = Int(chirpDuration * sampleRate)
        let f0 = 600.0, f1 = 6000.0
        return (0..<count).map { n in
            let t = Double(n) / sampleRate
            let phase = 2 * .pi * (f0 * t + (f1 - f0) / (2 * chirpDuration) * t * t)
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(n) / Double(count - 1))
            return Float(sin(phase) * window)
        }
    }

    /// `chirpCount` chirps, `chirpSpacing` apart, with silence between.
    static func chirpTrain(sampleRate: Double) -> [Float] {
        let one = chirp(sampleRate: sampleRate)
        let spacing = Int(chirpSpacing * sampleRate)
        var train = [Float](repeating: 0, count: spacing * (chirpCount - 1) + one.count)
        for index in 0..<chirpCount {
            train.replaceSubrange((index * spacing)..<(index * spacing + one.count), with: one)
        }
        return train
    }
}

/// Finds where a known signal occurs in a recording (matched filter / cross-correlation).
enum ArrivalDetector {
    /// Index in `signal` where `template` starts, searching starts in `range`; nil if no clear peak.
    static func find(_ template: [Float], in signal: [Float], range: Range<Int>) -> Int? {
        let lags = range.count
        guard lags > 0, range.lowerBound >= 0, range.upperBound - 1 + template.count <= signal.count else { return nil }
        var correlation = [Float](repeating: 0, count: lags)
        signal.withUnsafeBufferPointer { signal in
            vDSP_conv(signal.baseAddress! + range.lowerBound, 1, template, 1,
                      &correlation, 1, vDSP_Length(lags), vDSP_Length(template.count))
        }
        var magnitudes = correlation.map(abs)
        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(magnitudes, 1, &peak, &peakIndex, vDSP_Length(lags))
        // A real arrival stands well clear of the correlation's background level.
        magnitudes.sort()
        let median = magnitudes[magnitudes.count / 2]
        guard peak > 0, peak > median * 12 else { return nil }
        return range.lowerBound + Int(peakIndex)
    }
}

/// Records mono audio from the default input, timestamped on the same uptime clock Lyra
/// stamps AirPlay audio with.
final class MicrophoneRecorder: Sendable {
    struct Recording {
        let samples: [Float]
        let sampleRate: Double
        /// Uptime (seconds) when `samples[0]` reached the microphone.
        let startSeconds: Double
    }

    private let engine: AVAudioEngine
    private let captured = OSAllocatedUnfairLock(initialState: (samples: [Float](), start: Double?.none))
    private let sampleRate: Double
    private let inputLatency: Double

    private init(engine: AVAudioEngine, sampleRate: Double, inputLatency: Double) {
        self.engine = engine
        self.sampleRate = sampleRate
        self.inputLatency = inputLatency
    }

    static func start() async throws -> MicrophoneRecorder {
        guard AVCaptureDevice.default(for: .audio) != nil else { throw RoomCalibration.CalibrationError.noMicrophone }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RoomCalibration.CalibrationError.microphoneDenied }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RoomCalibration.CalibrationError.noMicrophone }
        let recorder = MicrophoneRecorder(engine: engine, sampleRate: format.sampleRate,
                                          inputLatency: input.presentationLatency)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: recorder.makeTapBlock())
        try engine.start()
        return recorder
    }

    /// Built outside any actor: AVAudioEngine calls it on its own thread.
    private func makeTapBlock() -> AVAudioNodeTapBlock {
        let captured = captured
        let inputLatency = inputLatency
        return { @Sendable buffer, time in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            captured.withLock { state in
                if state.start == nil, let hostSeconds { state.start = hostSeconds - inputLatency }
                state.samples += frames
            }
        }
    }

    func stop() -> Recording {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let state = captured.withLock { $0 }
        return Recording(samples: state.samples, sampleRate: sampleRate, startSeconds: state.start ?? 0)
    }
}
