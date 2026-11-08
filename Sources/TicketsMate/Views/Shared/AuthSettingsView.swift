import SwiftUI
import TicketsMateCore

/// Settings ▸ Authentication, grouped by where each credential comes from:
/// one card per provider (the `az` sign-in, the `gh` sign-in, single sign-on,
/// stored credentials), listing the systems that depend on it. One expired
/// `az` session shows as one problem on one card, with the systems it takes
/// down listed underneath, instead of the same failure repeated per system.
struct AuthSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // AuthManager is an ObservableObject of its own, and AppState does not
        // forward its changes, so observe it directly: the cards repaint as
        // each probe lands.
        AuthSettingsContent(auth: appState.authManager)
    }
}

private struct AuthSettingsContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var auth: AuthManager
    @State private var editingSystem: AuthSystemId?
    @AppStorage(FeedBodyView.loadExternalImagesKey) private var loadExternalTicketImages = false

    // Editable fields (populated when editing starts)
    @State private var editGraphTenantId = ""
    @State private var editDevicesGraphId = ""
    @State private var editDevicesGraphSecret = ""
    @State private var editSystemsGraphId = ""
    @State private var editSystemsGraphSecret = ""
    @State private var editSnipeUrl = ""
    @State private var editSnipeApiKey = ""
    @State private var editTdxBaseUrl = ""
    @State private var editTdxAppId = ""
    @State private var editTdxBeid = ""
    @State private var editTdxWebServicesKey = ""
    @State private var editDevopsOrg = ""
    @State private var editDevopsProject = ""
    @State private var editDevopsClientId = ""
    @State private var editDevopsTenantId = ""


    private var groups: [(provider: CredentialProvider, systems: [AuthSystemId])] {
        AuthProviderGrouping.group(auth.configuredSystems.map(\.systemId), config: appState.config)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if auth.hasServicePrincipalWarning {
                    spWarningBanner
                }

                ForEach(groups, id: \.provider) { group in
                    providerCard(group.provider, systems: group.systems)
                }

                HStack {
                    Spacer()
                    Button(action: refreshAll) {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .task {
            // Verify on open: a row is never left at "Configured" waiting for
            // someone to click Re-check.
            let unchecked = auth.systems.values.contains { $0.lastChecked == nil }
            if unchecked {
                refreshAll()
            } else if !auth.cliAccountsChecked {
                await auth.probeCliAccounts()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editAuthSystem)) { notification in
            if let systemId = notification.object as? AuthSystemId {
                startEditing(systemId)
            }
        }
    }

    // MARK: - SP Warning Banner

    private var spWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .appFont(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Service Principal Detected")
                    .appFont(.headline)
                Text("One or more systems are authenticated as a Service Principal. Actions will appear as the app identity, not your user account.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
        .cornerRadius(8)
    }

    // MARK: - Provider Card

    private func providerCard(_ provider: CredentialProvider, systems: [AuthSystemId]) -> some View {
        let summary = groupSummary(provider, systems: systems)
        // The gh sign-in has one dependent and no state of its own beyond the
        // account, so its card lists what uses it instead of a repeated row.
        let showRows = provider != .githubCli
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: provider.icon)
                    .appFont(.title2)
                    .foregroundColor(color(summary.tone))
                    .frame(width: 28)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.title).appFont(fixed: 14, weight: .semibold)
                        pill(summary.label, tone: summary.tone, spinning: summary.tone == .neutral)
                        Spacer()
                        providerActions(provider)
                    }
                    Text(provider.summary)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    providerDetail(provider)
                }
            }

            if showRows {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(systems.enumerated()), id: \.element) { index, id in
                        if index > 0 { Divider().padding(.leading, 40) }
                        if let system = auth.systems[id] {
                            systemRow(system)
                        }
                    }
                }
                .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                .cornerRadius(6)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }

    /// One row's status under the shared model.
    private func displayStatus(_ system: AuthSystemStatus) -> AuthDisplayStatus {
        return AuthDisplayStatus(state: effectiveState(system), lastChecked: system.lastChecked)
    }

    /// The state a row may claim. TeamDynamix reads Valid only while a usable
    /// session is held, so Valid never sits beside "Acting as Nobody".
    private func effectiveState(_ system: AuthSystemStatus) -> AuthTokenState {
        guard system.systemId == .tdx else { return system.state }
        return TdxAuthStatus.effectiveState(reported: system.state,
                                            hasUserSession: appState.tdxService.actingIdentityIsUser,
                                            hasServiceAccount: appState.tdxHasServiceAccount)
    }

    /// The CLI account's own status, for the providers that have one.
    private func accountStatus(_ provider: CredentialProvider) -> AuthDisplayStatus? {
        switch provider {
        case .azureCli:
            guard auth.cliAccountsChecked else { return .checking(nil) }
            guard let account = auth.azAccount else { return .needsSignIn }
            return account.isServicePrincipal ? .failed("Signed in as a service principal, so actions will not show as you.") : .valid
        case .githubCli:
            guard auth.cliAccountsChecked else { return .checking(nil) }
            return auth.ghAccount == nil ? .needsSignIn : .valid
        case .browserSso, .storedCredential:
            return nil
        }
    }

    /// The group pill: the sign-in itself plus every system under it.
    private func groupSummary(_ provider: CredentialProvider, systems: [AuthSystemId]) -> (label: String, tone: AuthDisplayStatus.Tone) {
        if provider == .githubCli, let account = accountStatus(provider) {
            return (account.label, account.tone)
        }
        var members = systems.compactMap { auth.systems[$0] }.map(displayStatus)
        if let account = accountStatus(provider) { members.insert(account, at: 0) }
        return AuthDisplayStatus.summary(members)
    }

    @ViewBuilder
    private func providerDetail(_ provider: CredentialProvider) -> some View {
        switch provider {
        case .browserSso, .storedCredential:
            EmptyView()
        default:
            EmptyView()
        }
    }


    @ViewBuilder
    private func providerActions(_ provider: CredentialProvider) -> some View {
        HStack(spacing: 6) {
            switch provider {
            case .browserSso, .storedCredential:
                EmptyView()
            default:
                EmptyView()
            }
        }
    }

    // MARK: - System Row

    private func systemRow(_ system: AuthSystemStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: system.systemId.icon)
                .appFont(.body)
                .foregroundColor(color(displayStatus(system).tone))
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(system.systemId.displayName)
                        .appFont(fixed: 13, weight: .semibold)
                    Text(AuthProviderGrouping.methodDescription(for: system.systemId, config: appState.config))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    statusPill(displayStatus(system))
                    Spacer()
                    actionButtons(for: system)
                }

                systemDetail(for: system)

                if editingSystem == system.systemId {
                    Divider().padding(.vertical, 4)
                    inlineEditForm(for: system.systemId)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }


    // MARK: - Per-System Detail

    @ViewBuilder
    private func systemDetail(for system: AuthSystemStatus) -> some View {
        let cfg = appState.config
        switch system.systemId {


        case .tdx:
            detailGrid {
                if let url = cfg.tdxBaseUrl { detailRow("Base URL", url) }
                let tApp = cfg.tdxTicketingAppId ?? cfg.tdxAppId
                let aApp = cfg.tdxAssetsAppId ?? cfg.tdxAppId
                if let a = tApp { detailRow("Ticketing app ID", String(a)) }
                if let a = aApp, a != tApp { detailRow("Assets app ID", String(a)) }
                // Say who writes will be attributed to, rather than implying a
                // signed-in user when the service account is doing the work.
                if appState.tdxService.actingIdentityIsUser {
                    let who = appState.tdxMe?.fullName ?? appState.tdxAuthenticatedUserName ?? "signed-in user"
                    detailRow("Acting as", who)
                } else if cfg.tdxBeid != nil || cfg.tdxUsername != nil {
                    detailRow("Acting as", "Service account — edits will not show your name")
                } else {
                    // No service account to fall back to, so this isn't
                    // "acting as the wrong identity" — it's no access at all.
                    detailRow("Acting as", "Nobody — not signed in, TDX calls will fail")
                }
                if cfg.tdxBeid != nil {
                    detailRow("Service account", cfg.tdxUsername ?? "configured")
                    detailRow("BEID", cfg.tdxBeid.map { shortId($0) } ?? "")
                }
                if case .failed(let msg) = system.state { errorRow(msg) }
                checkedRow(system.lastChecked)
            }
            Toggle("Load images from other sites in ticket comments", isOn: $loadExternalTicketImages)
                .help("Images hosted on TeamDynamix always load. Images from anywhere else wait for a click on the comment, because loading one tells that site you opened the ticket.")

        default:
            EmptyView()
        }
    }

    // MARK: - Detail Grid Helpers

    @ViewBuilder
    private func detailGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .appFont(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .frame(width: 130, alignment: .leading)
            Text(value)
                .appFont(.caption, design: .monospaced)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }


    /// A failure in full, wrapped, and selectable so it can be copied.
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Error")
                .appFont(.caption)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .frame(width: 130, alignment: .leading)
            Text(message)
                .appFont(.caption, design: .monospaced)
                .foregroundColor(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func checkedRow(_ date: Date?) -> some View {
        Group {
            if let d = date {
                HStack(alignment: .top, spacing: 0) {
                    Text("Last verified")
                        .appFont(.caption)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .frame(width: 130, alignment: .leading)
                    Text("\(d, style: .relative) ago  (\(d, formatter: timeFormatter))")
                        .appFont(.caption)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Show first 6 + "…" + last 6 characters of a token/key
    private func maskedToken(_ s: String) -> String {
        guard s.count > 16 else { return String(repeating: "●", count: min(s.count, 8)) }
        return "\(s.prefix(6))…\(s.suffix(6))"
    }

    /// Abbreviate a GUID: show first two segments then "…"
    private func shortId(_ s: String) -> String {
        let parts = s.split(separator: "-")
        guard parts.count >= 2 else {
            return s.count > 14 ? "\(s.prefix(14))…" : s
        }
        return "\(parts[0])-\(parts[1])…"
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }

    // MARK: - Status Badge

    private func statusPill(_ status: AuthDisplayStatus) -> some View {
        pill(status.label, tone: status.tone, spinning: status.isChecking)
    }

    /// The one coloured element on a row or group. Failures carry their
    /// detail in the row's Error line, so the pill stays short.
    private func pill(_ label: String, tone: AuthDisplayStatus.Tone, spinning: Bool) -> some View {
        HStack(spacing: 4) {
            if spinning {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color(tone)).frame(width: 7, height: 7)
            }
            Text(label)
                .appFont(.caption)
                .foregroundColor(tone == .neutral ? .secondary : color(tone))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color(tone).opacity(0.1))
        .cornerRadius(4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for system: AuthSystemStatus) -> some View {
        HStack(spacing: 6) {
            // Edit button for systems with editable credentials
            // Graph credentials are only editable in service-principal mode;
            // elevation needs nothing stored here.
            if [.snipe, .tdx, .devops].contains(system.systemId)
                || (system.systemId == .graph && !appState.config.graphUsesAze) {
                Button {
                    if editingSystem == system.systemId {
                        editingSystem = nil
                    } else {
                        startEditing(system.systemId)
                    }
                } label: {
                    Image(systemName: editingSystem == system.systemId ? "xmark" : "pencil")
                }
                .controlSize(.small)
                .help(editingSystem == system.systemId ? "Cancel editing" : "Edit credentials")
            }

            // SSO / auth action buttons
            switch system.systemId {

            case .tdx:
                if case .valid = effectiveState(system) {
                    EmptyView()
                } else if case .authenticating = system.state {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry SSO") { appState.attemptSilentTdxSso(useCache: false) }
                        .controlSize(.small)
                        .help("Sign in again in the background, without a window")
                    Button("Sign In…") { appState.signInToTdxInteractively() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Sign in again; opens a sign-in window only if the silent sign-in fails")
                }


            default:
                EmptyView()
            }

            // Every card gets a Re-check: sign-ins finish outside the app
            // (Terminal, browser), so the card has to be re-probeable on demand.
            if case .authenticating = system.state {
                EmptyView()
            } else {
                Button {
                    recheck(system.systemId)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Re-check status")
            }
        }
    }


    /// Re-probe one system so its card reflects a sign-in that just happened
    /// outside the app.
    private func recheck(_ id: AuthSystemId) {
        Task { await auth.probeSystem(id, tdxService: appState.tdxService) }
    }


    // MARK: - Colors

    /// Never red: orange only where the person has to act.
    private func color(_ tone: AuthDisplayStatus.Tone) -> Color {
        switch tone {
        case .positive: .green
        case .neutral: .secondary
        case .attention: .orange
        case .inactive: .gray
        }
    }

    // MARK: - Inline Edit

    private func startEditing(_ systemId: AuthSystemId) {
        let c = appState.config
        switch systemId {
        case .graph:
            editGraphTenantId = c.graphTenantId ?? ""
            editDevicesGraphId = c.devicesGraphId ?? ""
            editDevicesGraphSecret = c.devicesGraphSecret ?? ""
            editSystemsGraphId = c.systemsGraphId ?? ""
            editSystemsGraphSecret = c.systemsGraphSecret ?? ""
        case .snipe:
            editSnipeUrl = c.snipeUrl ?? ""
            editSnipeApiKey = c.snipeApiKey ?? ""
        case .tdx:
            editTdxBaseUrl = c.tdxBaseUrl ?? ""
            editTdxAppId = (c.tdxTicketingAppId ?? c.tdxAppId).map(String.init) ?? ""
            editTdxBeid = c.tdxBeid ?? ""
            editTdxWebServicesKey = c.tdxWebServicesKey ?? ""
        case .devops:
            editDevopsOrg = c.devopsOrganization ?? ""
            editDevopsProject = c.devopsProject ?? ""
            editDevopsClientId = c.devopsClientId ?? ""
            editDevopsTenantId = c.devopsTenantId ?? ""
        default: break
        }
        editingSystem = systemId
    }

    @ViewBuilder
    private func inlineEditForm(for systemId: AuthSystemId) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch systemId {
            case .graph:
                editField("Tenant ID", text: $editGraphTenantId)
                editField("Devices Client ID", text: $editDevicesGraphId)
                editSecureField("Devices Client Secret", text: $editDevicesGraphSecret)
                editField("Systems Client ID", text: $editSystemsGraphId)
                editSecureField("Systems Client Secret", text: $editSystemsGraphSecret)

            case .snipe:
                editField("Instance URL", text: $editSnipeUrl)
                editSecureField("API Key", text: $editSnipeApiKey)

            case .tdx:
                editField("Base URL", text: $editTdxBaseUrl)
                editField("Ticketing App ID", text: $editTdxAppId)
                editSecureField("BEID", text: $editTdxBeid)
                editSecureField("Web Services Key", text: $editTdxWebServicesKey)

            case .devops:
                editField("Organization", text: $editDevopsOrg)
                editField("Project", text: $editDevopsProject)
                editField("OAuth Client ID", text: $editDevopsClientId)
                editField("Tenant ID", text: $editDevopsTenantId)

            default:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel") { editingSystem = nil }
                    .controlSize(.small)
                Button("Save") { saveEdit(systemId) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private func editField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .appFont(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .frame(width: 130, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .appFont(.caption)
        }
    }

    private func editSecureField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .appFont(.caption)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .frame(width: 130, alignment: .leading)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
                .appFont(.caption)
        }
    }

    private func saveEdit(_ systemId: AuthSystemId) {
        var c = appState.config
        switch systemId {
        case .graph:
            c.graphTenantId = editGraphTenantId.nilIfEmpty
            c.devicesGraphId = editDevicesGraphId.nilIfEmpty
            c.devicesGraphSecret = editDevicesGraphSecret.nilIfEmpty
            c.systemsGraphId = editSystemsGraphId.nilIfEmpty
            c.systemsGraphSecret = editSystemsGraphSecret.nilIfEmpty
        case .snipe:
            c.snipeUrl = editSnipeUrl.nilIfEmpty?.ensureHttps
            c.snipeApiKey = editSnipeApiKey.nilIfEmpty
        case .tdx:
            c.tdxBaseUrl = editTdxBaseUrl.nilIfEmpty?.ensureHttps
            c.tdxAppId = Int(editTdxAppId)
            c.tdxTicketingAppId = Int(editTdxAppId)
            c.tdxBeid = editTdxBeid.nilIfEmpty
            c.tdxWebServicesKey = editTdxWebServicesKey.nilIfEmpty
        case .devops:
            c.devopsOrganization = editDevopsOrg.nilIfEmpty
            c.devopsProject = editDevopsProject.nilIfEmpty
            c.devopsClientId = editDevopsClientId.nilIfEmpty
            c.devopsTenantId = editDevopsTenantId.nilIfEmpty
        default: break
        }
        appState.saveConfig(c)
        editingSystem = nil
    }

    // MARK: - Refresh All

    private func refreshAll() {
        Task {
            await auth.probeAll(tdxService: appState.tdxService)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    var ensureHttps: String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
        return "https://\(trimmed)"
    }
}
