import LyraKit
import SwiftUI

struct NewStationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.search
    @State private var genres: [GenreCategory] = []
    @State private var isCreating = false

    enum Tab { case search, genres }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Station").font(.title2.weight(.semibold))
            Picker("Source", selection: $tab) {
                Text("Search").tag(Tab.search)
                Text("Genres").tag(Tab.genres)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .search:
                MusicSearchView(actionTitle: "Create", onPick: create)
            case .genres:
                genreList
            }

            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 460, height: 480)
        .disabled(isCreating)
    }

    private var genreList: some View {
        List(genres) { category in
            DisclosureGroup(category.categoryName) {
                ForEach(category.stations) { station in
                    HStack {
                        Text(station.stationName)
                        Spacer()
                        Button("Create") { create(station.stationToken) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .overlay { if genres.isEmpty { ProgressView() } }
        .task {
            guard genres.isEmpty else { return }
            genres = await model.attempt { try await model.client.genreStations() } ?? []
        }
    }

    private func create(_ musicToken: String) {
        isCreating = true
        Task {
            let station = await model.createStation(musicToken: musicToken)
            isCreating = false
            if station != nil { dismiss() }
        }
    }
}
