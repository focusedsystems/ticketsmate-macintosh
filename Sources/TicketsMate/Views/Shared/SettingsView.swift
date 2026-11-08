import SwiftUI
import TicketsMateCore

/// Settings window tabs. Every tab needs an explicit tag: a tab without one
/// can never become the selection, so clicking it left the pane blank.
enum SettingsTab {
    static let general = 0
    static let authentication = 1
    static let appearance = 2
    static let manage = 3
    static let about = 4
    static let enrollment = 6
    static let agent = 7
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    /// TicketsMate has no General tab, so it opens on Authentication.
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = AppEdition.current.isTicketsOnly ? SettingsTab.authentication : SettingsTab.general
    private let ticketsOnly = AppEdition.current.isTicketsOnly

    var body: some View {
        TabView(selection: $selectedTabIndex) {
            // General switches modules on and off; TicketsMate has one.

            AuthSettingsView()
                .environmentObject(appState)
                .tabItem { Label("Authentication", systemImage: "lock.shield") }
                .tag(SettingsTab.authentication)

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                .tag(SettingsTab.appearance)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 600, maxWidth: 700, minHeight: 700, idealHeight: 900, maxHeight: 1100)
    }
}

// MARK: - General Settings Tab (Module Toggles)


extension Notification.Name {
    static let editAuthSystem = Notification.Name("editAuthSystem")
}

#if DEBUG
#Preview {
    SettingsView()
        .environmentObject(AppState())
}
#endif

extension View {
    /// Explanatory text under a Settings group: leading-aligned, footnote
    /// size, secondary colour, as a native grouped Form footer reads. Without
    /// the explicit frame a multi-line footer centres or trails ragged.
    func settingsFooter() -> some View {
        self.font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
