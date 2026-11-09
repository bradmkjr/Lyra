import CoreAudio
import Foundation
import Testing
@testable import LyraKit

/// Uses the real Core Audio devices on the test machine; skips what the hardware can't cover.
@MainActor
struct OutputRouterTests {
    @Test func listsOutputsWithStableIDs() {
        let devices = AudioOutputDevice.outputDevices()
        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(!devices.contains { $0.id.hasPrefix(AudioOutputDevice.lyraAggregatePrefix) })
    }

    @Test func zeroOrOneOutputNeedsNoAggregate() throws {
        let router = OutputRouter()
        #expect(try router.route(to: []) == nil)
        if let device = AudioOutputDevice.outputDevices().first {
            #expect(try router.route(to: [device]) == device.id)
        }
    }

    @Test func severalOutputsBecomeOnePrivateMultiOutputDevice() throws {
        let groupable = AudioOutputDevice.outputDevices().filter { $0.canJoinGroup && $0.kind != .virtual }
        guard groupable.count >= 2 else { return }  // needs two real outputs
        let router = OutputRouter()
        defer { router.destroyAggregate() }

        let uid = try #require(try router.route(to: Array(groupable.prefix(2))))
        #expect(uid.hasPrefix(AudioOutputDevice.lyraAggregatePrefix))

        // Private aggregates are visible to the process that made them.
        let all: [AudioObjectID] = CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject),
                                                           kAudioHardwarePropertyDevices)
        let deviceID = try #require(all.first { CoreAudioProperty.string($0, kAudioDevicePropertyDeviceUID) == uid })
        #expect(CoreAudioProperty.uint32(deviceID, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate)
        let subdevices: [AudioObjectID] = CoreAudioProperty.array(deviceID, kAudioAggregateDevicePropertyActiveSubDeviceList)
        #expect(subdevices.count == 2)

        // Rebuilding replaces the old device rather than leaking it.
        let second = try #require(try router.route(to: Array(groupable.prefix(2))))
        #expect(second != uid)
    }
}
