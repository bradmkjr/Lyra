import LyraKit
import SwiftUI

struct StationListView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: StationSheet?
    @State private var filter = ""
    @State private var renaming: Station?
    @State private var newName = ""
    @State private var deleting: Station?

    var body: some View {
        @Bindable var model = model
        List(model.sortedStations(matching: filter), selection: $model.selectedStationID) { station in
            StationRow(station: station, isPlaying: model.player.station?.id == station.id)
                .tag(station.id)
                .contextMenu { menu(for: station) }
        }
        .contextMenu(forSelectionType: Station.ID.self) { _ in } primaryAction: { ids in
            if let station = model.stations.first(where: { ids.contains($0.id) }) { model.play(station) }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter Stations")
        .overlay {
            if model.stations.isEmpty && !model.isLoadingStations {
                ContentUnavailableView("No Stations", systemImage: "radio",
                                       description: Text("Create a station to start listening."))
            } else if model.isLoadingStations && model.stations.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $model.stationSort) {
                        ForEach(StationSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                Button { sheet = .new } label: {
                    Label("New Station", systemImage: "plus")
                }
                .help("Create a new station")
            }
        }
        .alert("Rename Station", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let station = renaming { Task { await model.rename(station, to: newName) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.displayName ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Station", role: .destructive) {
                if let station = deleting { Task { await model.delete(station) } }
            }
        } message: {
            Text("This removes the station from your Pandora account.")
        }
    }

    @ViewBuilder
    private func menu(for station: Station) -> some View {
        Button("Play") { model.play(station) }
        Divider()
        Button("Edit Station…") { sheet = .edit(station) }
            .disabled(!station.canEdit)
        Button("Rename…") {
            newName = station.stationName
            renaming = station
        }
        .disabled(!station.canRename)
        Divider()
        Button("Delete…", role: .destructive) { deleting = station }
            .disabled(station.isQuickMix == true)
    }
}

private struct StationRow: View {
    let station: Station
    let isPlaying: Bool

    var body: some View {
        Label {
            Text(station.displayName).lineLimit(1)
        } icon: {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : station.isQuickMix == true ? "shuffle" : "radio")
                .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}
