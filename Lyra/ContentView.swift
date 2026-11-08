import LyraKit
import SwiftUI

enum StationSheet: Identifiable, Hashable {
    case new
    case edit(Station)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let station): "edit-\(station.id)"
        }
    }
}

extension FocusedValues {
    @Entry var stationSheet: Binding<StationSheet?>?
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.session {
            case .signedOut, .signingIn:
                LoginView()
            case .signedIn:
                MainView()
            }
        }
        .alert("Lyra", isPresented: Binding(
            get: { model.errorMessage != nil || model.player.lastError != nil },
            set: { if !$0 { model.errorMessage = nil; model.player.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? model.player.lastError ?? "")
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: StationSheet?
    @State private var showsHistory = false

    var body: some View {
        NavigationSplitView {
            StationListView(sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            HStack(spacing: 0) {
                PlayerView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsHistory {
                    Divider()
                    HistoryView()
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $showsHistory.animation()) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .help("Show song history")
                }
            }
        }
        .focusedSceneValue(\.stationSheet, $sheet)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .new: NewStationView()
            case .edit(let station): EditStationView(station: station)
            }
        }
        .onKeyPress(.space) {
            model.player.playPause()
            return .handled
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel.shared)
}
