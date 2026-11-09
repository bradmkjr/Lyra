import CoreAudio
import Foundation
import os

/// Turns a set of chosen outputs into one device the player can use. Two or more outputs
/// become a private multi-output ("stacked") aggregate device: the same thing Audio MIDI
/// Setup builds, but owned by Lyra and gone when it quits. macOS keeps the outputs' clocks
/// in step (drift compensation), and faster outputs are padded with extra latency so every
/// room hears the music at the same moment.
@MainActor
public final class OutputRouter {
    private static let log = Logger(subsystem: "com.velpeo.Lyra", category: "outputs")
    private var aggregateID: AudioObjectID?
    private var generation = 0

    public init() {}

    public enum RoutingError: LocalizedError {
        case aggregateFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .aggregateFailed(let status):
                "Couldn't combine the selected speakers (Core Audio error \(status))."
            }
        }
    }

    /// Returns the device UID the player should use: nil for the system default, the device
    /// itself for one output, or a new aggregate for several.
    public func route(to devices: [AudioOutputDevice]) throws -> String? {
        destroyAggregate()
        switch devices.count {
        case 0: return nil
        case 1: return devices[0].id
        default: return try makeAggregate(of: devices)
        }
    }

    /// Releases the aggregate. Private aggregates also vanish when the process exits.
    public func destroyAggregate() {
        guard let aggregateID else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        if status != noErr { Self.log.error("Destroying aggregate failed: \(status)") }
        self.aggregateID = nil
    }

    private func makeAggregate(of devices: [AudioOutputDevice]) throws -> String {
        // The built-in output is the steadiest clock; every other device follows it.
        let main = devices.first { $0.kind == .builtIn } ?? devices[0]
        let latencies = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.outputLatency) })
        let slowest = latencies.values.max() ?? 0

        let subdevices: [[String: Any]] = devices.map { device in
            let extraFrames = Int(((slowest - latencies[device.id, default: 0]) * device.sampleRate).rounded())
            return [
                kAudioSubDeviceUIDKey: device.id,
                kAudioSubDeviceDriftCompensationKey: device.id == main.id ? 0 : 1,
                kAudioSubDeviceExtraOutputLatencyKey: max(0, extraFrames),
            ]
        }

        // A fresh UID per configuration so AVPlayer never reuses a stale device.
        generation += 1
        let uid = "\(AudioOutputDevice.lyraAggregatePrefix).\(ProcessInfo.processInfo.processIdentifier).\(generation)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyra Multi-Output",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: main.id,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
        ]

        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else {
            Self.log.error("Creating aggregate failed: \(status)")
            throw RoutingError.aggregateFailed(status)
        }
        aggregateID = id
        Self.log.notice("Routing to \(devices.map(\.name).joined(separator: ", "), privacy: .public) via \(uid, privacy: .public)")
        return uid
    }
}

/// Calls `onChange` on the main actor when outputs are plugged in, removed, or renamed.
@MainActor
public final class OutputDeviceMonitor {
    private let onChange: @MainActor () -> Void
    private var listener: AudioObjectPropertyListenerBlock?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let block = Self.makeListener { [weak self] in self?.onChange() }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    /// Built outside the main actor: Core Audio calls the block on the queue we pass (main),
    /// but the block type isn't Sendable, so keep it nonisolated and hop explicitly.
    private nonisolated static func makeListener(
        _ changed: @escaping @Sendable @MainActor () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        { @Sendable _, _ in Task { @MainActor in changed() } }
    }

    // The monitor lives for the app's lifetime (owned by AppModel), so it isn't removed.
}
