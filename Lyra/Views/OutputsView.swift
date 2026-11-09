import LyraKit
import SwiftUI

/// Picks where Lyra plays: any mix of this Mac's outputs and AirPlay receivers, together.
struct OutputsView: View {
    @Environment(AppModel.self) private var model
    /// Hardware volume per device, read when the popover opens.
    @State private var volumes: [AudioOutputDevice.ID: Float] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers").font(.headline)
                Toggle(isOn: Binding(get: { model.isUsingSystemOutput },
                                     set: { if $0 { model.useSystemOutput() } })) {
                    Label("System Output", systemImage: "gearshape")
                }
                .disabled(model.isUsingSystemOutput)
                ForEach(model.outputs) { device in
                    row(for: device)
                }
                Text("Speakers you tick play together. Nearer speakers are held back to match AirPlay's delay so every room hears the same moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("AirPlay Rooms").font(.headline)
                if model.airPlayReceivers.isEmpty {
                    Text("Looking for Apple TVs and AirPlay speakers…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.airPlayReceivers) { receiver in
                    AirPlayRoomRow(receiver: receiver)
                }
                Text("Tick a room to play there. Test plays a short tone in that room; delay moves a room earlier or later to line it up with the others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: readVolumes)
        .onChange(of: model.outputs) { readVolumes() }
    }

    @ViewBuilder
    private func row(for device: AudioOutputDevice) -> some View {
        let isSelected = model.selectedOutputIDs.contains(device.id)
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in model.toggleOutput(device) })) {
                Label(device.name, systemImage: device.kind.systemImage)
                    .lineLimit(1)
            }
            .help(device.canJoinGroup ? "" : "Aggregate devices play on their own")
            if isSelected, device.hasVolumeControl, let volume = volumes[device.id] {
                Slider(value: Binding(get: { Double(volume) }, set: { newValue in
                    volumes[device.id] = Float(newValue)
                    OutputVolume.set(Float(newValue), for: device)
                }), in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .controlSize(.mini)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
        }
    }

    private func readVolumes() {
        volumes = Dictionary(uniqueKeysWithValues: model.outputs.compactMap { device in
            OutputVolume.get(device).map { (device.id, $0) }
        })
    }
}

/// One AirPlay receiver: a checkbox to play there, Test, status, and — once ticked — its
/// own volume and delay.
private struct AirPlayRoomRow: View {
    @Environment(AppModel.self) private var model
    let receiver: AirPlayReceiver

    var body: some View {
        let settings = model.roomSettings(receiver.id)
        let status = model.airPlayStatus[receiver.id] ?? .idle
        let isSelected = model.selectedAirPlayIDs.contains(receiver.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { isSelected }, set: { _ in model.toggleAirPlayRoom(receiver) })) {
                    Label(receiver.name, systemImage: receiver.systemImage)
                        .lineLimit(1)
                }
                .disabled(!receiver.isSupported)
                Spacer()
                switch status {
                case .connecting: ProgressView().controlSize(.small)
                case .playing: Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .idle: EmptyView()
                }
                Button("Test") { Task { await model.playTestTone(on: receiver) } }
                    .controlSize(.small)
                    .disabled(!receiver.isSupported || status == .connecting)
            }
            if !receiver.isSupported {
                Text(receiver.requiresPassword ? "Needs a password, which Lyra doesn't support yet."
                                               : "Uses an AirPlay format Lyra can't send.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let message) = status {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isSelected {
                Slider(value: Binding(get: { settings.volume }, set: { model.setRoomVolume($0, for: receiver.id) }),
                       in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .controlSize(.mini)
                .padding(.leading, 22)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Slider(value: Binding(get: { settings.delay },
                                          set: { model.setRoomDelay(($0 * 100).rounded() / 100, for: receiver.id) }),
                           in: AirPlayStreamer.delayRange)
                        .controlSize(.mini)
                    Text(settings.delay, format: .number.precision(.fractionLength(2)).sign(strategy: .always()))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    Text("s")
                }
                .font(.caption)
                .padding(.leading, 22)
                HStack(spacing: 6) {
                    Button {
                        Task { await model.calibrate(receiver) }
                    } label: {
                        Label("Calibrate", systemImage: "mic")
                    }
                    .controlSize(.small)
                    .disabled(!model.canCalibrate || model.calibratingID != nil || status != .playing)
                    .help(model.canCalibrate ? "Stand in this room: Lyra plays chirps here and sets the delay from what the microphone hears."
                                             : "Needs a Mac with a microphone. Set the delay by ear instead.")
                    if model.calibratingID == receiver.id { ProgressView().controlSize(.small) }
                    if let message = model.calibrationMessage[receiver.id] {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .foregroundStyle(receiver.isSupported ? .primary : .secondary)
    }
}
