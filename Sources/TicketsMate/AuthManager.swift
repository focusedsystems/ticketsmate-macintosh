import Foundation
import TicketsMateCore

/// Centralized manager that tracks authentication state for every configured system.
/// Published on AppState so any view can observe status changes.
@MainActor
class AuthManager: ObservableObject {
    @Published var systems: [AuthSystemId: AuthSystemStatus] = [:]
    /// Who `az` and `gh` are signed in as (nil: not signed in or not checked).
    @Published var azAccount: CliAccount?
    @Published var ghAccount: CliAccount?
    /// True once the CLI accounts have been read at least once.
    @Published var cliAccountsChecked = false
    
    private(set) var config: TicketsMateConfig

    init(config: TicketsMateConfig) {
        self.config = config
        bootstrapFromConfig()
    }

    // MARK: - Bootstrap

    /// Populate initial states from config: configured systems get `.configured`,
    /// unconfigured ones are omitted entirely (as if they don't exist).
    func bootstrapFromConfig(with newConfig: TicketsMateConfig? = nil) {
        if let newConfig { config = newConfig }
        systems.removeAll()
        

        // Tickets — TDX. TicketsMate always lists it, unconfigured or not, so
        // its one system can be set up from this panel.
        let ticketsOnly = AppEdition.current.isTicketsOnly
        if config.isTdxConfigured || ticketsOnly {
            systems[.tdx] = AuthSystemStatus(
                systemId: .tdx,
                state: config.isTdxConfigured ? .configured : .notConfigured
            )
        }

    }
    
    // MARK: - State Updates
    
    func update(_ id: AuthSystemId, state: AuthTokenState) {
        guard systems[id] != nil else { return }
        systems[id]?.state = state
        systems[id]?.lastChecked = Date()
        if case .valid(let user, _) = state {
            systems[id]?.user = user
        }
    }

    /// Report that an *optional* auth path failed — a silent browser-SSO attempt,
    /// say — without contradicting a system that is already authenticated by some
    /// other means.
    ///
    /// These systems have more than one way in: Snipe-IT and ReportMate ride an
    /// OIDC bearer, and TeamDynamix a service-account JWT (its API supports no
    /// Entra/OAuth login at all, so browser SSO can never be the answer there).
    /// The cookie-SSO attempt runs anyway and, on failure, used to overwrite a
    /// perfectly good `.valid` with "Failed: Silent SSO failed" — the panel
    /// claiming TDX was broken while the row underneath said "signed in as
    /// Service Account" in green.
    func reportOptionalAuthFailure(_ id: AuthSystemId, message: String) {
        guard let current = systems[id]?.state else { return }
        if current.isHealthy {
            dbg.info("\(id.rawValue): optional SSO path failed (\(message)) — keeping the working auth state", category: "auth")
            return
        }
        update(id, state: .failed(message: message))
    }
    
    // MARK: - Queries
    
    /// All configured systems (those that appear in the UI).
    var configuredSystems: [AuthSystemStatus] {
        AuthSystemId.allCases.compactMap { systems[$0] }
    }
    
    /// Systems for a given category/tab.
    func systems(for category: AuthCategory) -> [AuthSystemStatus] {
        configuredSystems.filter { $0.systemId.category == category }
    }
    
    /// Overall health for a category (used for tab badge).
    func categoryHealth(_ category: AuthCategory) -> AuthTokenState {
        let items = systems(for: category)
        guard !items.isEmpty else { return .notConfigured }
        if items.allSatisfy({ $0.state.isHealthy }) { return .valid(user: nil, expiry: nil) }
        if items.contains(where: { if case .failed = $0.state { return true }; return false }) {
            return .failed(message: "")
        }
        if items.contains(where: { if case .servicePrincipal = $0.state { return true }; return false }) {
            return .servicePrincipal(name: "")
        }
        return .configured
    }
    
    /// True if any system is logged in as a Service Principal.
    var hasServicePrincipalWarning: Bool {
        systems.values.contains { if case .servicePrincipal = $0.state { return true }; return false }
    }
    
    // MARK: - Probe All

    /// Validate/probe each configured system asynchronously. Called once on launch
    /// and again whenever config is reloaded.
    /// True while `probeAll` runs, so opening Settings during a launch-time
    /// probe does not start a second one.
    @Published private(set) var isProbingAll = false

    func probeAll(tdxService: TdxService) async {
        guard !isProbingAll else { return }
        isProbingAll = true
        defer { isProbingAll = false }
        await probeSystem(.tdx, tdxService: tdxService)
    }

    /// Probe a single system, so a card's Re-check only spins that card.
    func probeSystem(_ id: AuthSystemId, tdxService: TdxService) async {
        guard systems[id] != nil, id == .tdx else { return }
        await probeTdx(tdxService: tdxService)
    }

    /// Read who `az` and `gh` are signed in as — one shared check behind
    /// every card that depends on either CLI.
    func probeCliAccounts() async {
        async let az = CliAccountProbe.azAccount()
        async let gh = CliAccountProbe.ghAccount()
        azAccount = await az
        ghAccount = await gh
        cliAccountsChecked = true
    }


    private func probeTdx(tdxService: TdxService) async {
        // A refused sign-in keeps its reason; a probe would only replace it
        // with a generic "not signed in".
        if let reason = tdxService.refusedSsoReason {
            update(.tdx, state: .failed(message: reason))
            return
        }
        update(.tdx, state: .authenticating)
        do {
            let search = TicketSearchRequest(maxResults: 1)
            _ = try await tdxService.searchTickets(search: search, maxResults: 1)
            let userName = tdxService.authenticatedUserName
            update(.tdx, state: .valid(user: userName ?? "Service Account", expiry: nil))
        } catch {
            update(.tdx, state: .failed(message: error.localizedDescription))
        }
    }
    
}
