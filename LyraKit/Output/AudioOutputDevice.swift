import AudioToolbox
import CoreAudio
import Foundation

/// A Core Audio output device: built-in speakers, USB/display speakers, Bluetooth, or an
/// aggregate the user built in Audio MIDI Setup. AirPlay speakers aren't listed individually
/// by Core Audio; those are picked with the system AirPlay picker instead.
public struct AudioOutputDevice: Sendable, Hashable, Identifiable {
    /// `kAudioDevicePropertyDeviceUID`, stable across launches and reboots.
    public let id: String
    public let name: String
    public let kind: Kind
    public let hasVolumeControl: Bool
    let objectID: AudioObjectID

    public enum Kind: Sendable, Hashable {
        case builtIn, usb, display, bluetooth, airPlay, aggregate, virtual, other

        public var systemImage: String {
            switch self {
            case .builtIn: "macmini"
            case .usb: "hifispeaker"
            case .display: "display"
            case .bluetooth: "headphones"
            case .airPlay: "airplayaudio"
            case .aggregate: "hifispeaker.2"
            case .virtual: "waveform"
            case .other: "speaker.wave.2"
            }
        }
    }

    /// Aggregates can't be nested inside Lyra's multi-output device, so they play alone.
    public var canJoinGroup: Bool { kind != .aggregate }

    /// Lyra's own multi-output devices; hidden from the device list.
    static let lyraAggregatePrefix = "com.velpeo.Lyra.multi-output"

    // MARK: - Discovery

    /// All devices with at least one output stream, excluding Lyra's own aggregate.
    public static func outputDevices() -> [AudioOutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids: [AudioObjectID] = CoreAudioProperty.array(system, kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard CoreAudioProperty.dataSize(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(lyraAggregatePrefix) else { return nil }
            let name = CoreAudioProperty.string(id, kAudioObjectPropertyName) ?? uid
            let transport = CoreAudioProperty.uint32(id, kAudioDevicePropertyTransportType) ?? 0
            return AudioOutputDevice(id: uid, name: name, kind: Kind(transport: transport),
                                     hasVolumeControl: OutputVolume.isSettable(id), objectID: id)
        }
        .sorted { ($0.kind == .builtIn ? 0 : 1, $0.name, $0.id) < ($1.kind == .builtIn ? 0 : 1, $1.name, $1.id) }
        .numberingDuplicateNames()
    }

    /// Total output latency in seconds: device + safety offset + stream latency.
    var outputLatency: Double {
        let scope = kAudioObjectPropertyScopeOutput
        let frames = (CoreAudioProperty.uint32(objectID, kAudioDevicePropertyLatency, scope: scope) ?? 0)
            + (CoreAudioProperty.uint32(objectID, kAudioDevicePropertySafetyOffset, scope: scope) ?? 0)
            + streamLatency
        return Double(frames) / sampleRate
    }

    var sampleRate: Double {
        let rate = CoreAudioProperty.float64(objectID, kAudioDevicePropertyNominalSampleRate) ?? 0
        return rate > 0 ? rate : 48_000
    }

    private var streamLatency: UInt32 {
        let streams: [AudioObjectID] = CoreAudioProperty.array(objectID, kAudioDevicePropertyStreams,
                                                               scope: kAudioObjectPropertyScopeOutput)
        return streams.first.flatMap { CoreAudioProperty.uint32($0, kAudioStreamPropertyLatency) } ?? 0
    }
}

private extension Array where Element == AudioOutputDevice {
    /// Two identical displays both report "Studio Display Speakers"; number them so the
    /// list can tell them apart. Order follows the stable device UID.
    func numberingDuplicateNames() -> [AudioOutputDevice] {
        let counts = Dictionary(grouping: self, by: \.name).mapValues(\.count)
        var seen: [String: Int] = [:]
        return map { device in
            guard counts[device.name, default: 0] > 1 else { return device }
            seen[device.name, default: 0] += 1
            return AudioOutputDevice(id: device.id, name: "\(device.name) \(seen[device.name]!)", kind: device.kind,
                                     hasVolumeControl: device.hasVolumeControl, objectID: device.objectID)
        }
    }
}

extension AudioOutputDevice.Kind {
    init(transport: UInt32) {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .other
        }
    }
}

// MARK: - Per-device volume

/// Hardware volume of one output, used as the per-room volume. Lyra's own volume slider
/// still scales everything together.
public enum OutputVolume {
    private static func address() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func isSettable(_ id: AudioObjectID) -> Bool {
        var address = address()
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    /// 0...1, or nil if the device has no volume control.
    public static func get(_ device: AudioOutputDevice) -> Float? {
        var address = address()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public static func set(_ volume: Float, for device: AudioOutputDevice) {
        var address = address()
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(device.objectID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

// MARK: - Property helpers

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func dataSize(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var address = address(selector, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr ? size : 0
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func float64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Float64? {
        var address = address(selector, scope)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func array(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size = dataSize(id, selector, scope: scope)
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
