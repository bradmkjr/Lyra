import LyraKit
import SwiftUI

/// Rename a station and manage its seeds and thumbs (Hermes's StationController).
struct EditStationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let station: Station

    @State private var name = ""
    @State private var detail: StationDetail?
    @State private var tab = Tab.seeds

    enum Tab { case seeds, addSeed, likes, dislikes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Station Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .disabled(!station.canRename)
                    .onSubmit(rename)
                if let url = detail?.stationDetailUrl {
                    Button("View on Pandora") { openURL(url) }
                }
            }

            Picker("Section", selection: $tab) {
                Text("Seeds").tag(Tab.seeds)
                Text("Add Seed").tag(Tab.addSeed)
                Text("Likes").tag(Tab.likes)
                Text("Dislikes").tag(Tab.dislikes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .seeds: seedList
                case .addSeed: MusicSearchView(actionTitle: "Add", onPick: addSeed)
                case .likes: feedbackList(detail?.likes ?? [])
                case .dislikes: feedbackList(detail?.dislikes ?? [])
                }
            }
            .overlay { if detail == nil { ProgressView() } }

            HStack {
                Spacer()
                Button("Done") {
                    rename()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480, height: 500)
        .task {
            name = station.stationName
            await reload()
        }
    }

    private var seedList: some View {
        List(detail?.seeds ?? []) { seed in
            HStack {
                Text(seed.displayName)
                Spacer()
                Button("Remove", systemImage: "minus.circle") {
                    Task {
                        await model.attempt { try await model.client.deleteSeed(seed) }
                        await reload()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled((detail?.seeds.count ?? 0) <= 1)
                .help("A station needs at least one seed")
            }
        }
    }

    private func feedbackList(_ items: [Feedback]) -> some View {
        List(items) { feedback in
            HStack {
                VStack(alignment: .leading) {
                    Text(feedback.songName)
                    Text(feedback.artistName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", systemImage: "minus.circle") {
                    Task {
                        await model.attempt { try await model.client.deleteFeedback(feedback) }
                        await reload()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .overlay {
            if detail != nil && items.isEmpty { ContentUnavailableView("None", systemImage: "hand.thumbsup") }
        }
    }

    private func addSeed(_ musicToken: String) {
        Task {
            await model.attempt { try await model.client.addSeed(musicToken: musicToken, to: station) }
            await reload()
            tab = .seeds
        }
    }

    private func rename() {
        Task { await model.rename(station, to: name) }
    }

    private func reload() async {
        detail = await model.attempt { try await model.client.stationDetail(station) } ?? detail
    }
}
