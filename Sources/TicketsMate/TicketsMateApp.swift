import SwiftUI
import Combine
import TicketsMateCore

struct TicketsMateApp: App {
    @StateObject private var appState = AppState()
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default

    init() {
        // Ensure app appears in Dock and can be activated
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // TicketsMate is one window with six modes, not a document app. Leaving
        // automatic tabbing on put "Show Tab Bar" and "Show All Tabs" (⌘\) at
        // the top of the View menu, promising document tabs that don't exist —
        // directly above the ⌘1–⌘6 items that do the switching.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Settings ▸ Appearance ▸ Theme, applied before the first window draws.
        MainActor.assumeIsolated { AppTheme.stored.apply() }

        // An install from before the helper had its own bundle left a job
        // that runs this executable; point it at the helper straight away.
        MainActor.assumeIsolated { InboxAgent.migrateLegacyRegistration() }
    }

    private var mainContent: ContentView {
        ContentView()
    }

    var body: some Scene {
        // One window, not a group: TicketsMate is a single window, and a
        // ticketsmate:// link sent to a WindowGroup opens a new window each time.
        Window(AppEdition.current.displayName, id: "main") {
            mainContent
                .environmentObject(appState)
                .appFontScale(fontScale)
                .onOpenURL { url in appState.open(url) }
                .task {
                    await appState.preloadAllData()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            TicketsMateCommands(appState: appState)
        }

        // What TicketsMate asked each service to do: Window ▸ Activity Log (⌥⌘L).
        Window("Activity Log", id: ActivityLogView.windowId) {
            ActivityLogView()
                .appFontScale(fontScale)
        }
        .defaultSize(width: 1000, height: 600)

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .appFontScale(fontScale)
        }
        #endif
    }
}

/// State of the aze elevation sessions Graph rides on, surfaced in the UI.
enum AzeSessionState {
    case direct   // not using aze (TICKETSMATE_GRAPH_TRANSPORT=direct)
    case warming  // container cold start in progress (~30s)
    case warm     // ready
    case failed   // warm attempt failed; first real call will retry
}

/// Receives the Apple Event a `ticketsmate://` link arrives as.
@MainActor
class AppState: ObservableObject {
    @Published var config: TicketsMateConfig
    @Published var azeSessionState: AzeSessionState = .direct
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var secretsConfigured = false
    
    // MARK: - Onboarding
    @Published var showOnboardingWizard = false


    // MARK: - Tab Navigation (set by Dashboard to switch tabs)

    /// The visible tab. Lives here rather than in `ContentView` so the ⌘1–⌘6
    /// menu commands, which are built in the `App` scene, can both read it (to
    /// decide whether ⌘N means "ticket" or "work item") and set it.
    ///
    /// The didSet logs each change with its call stack: the app has been seen
    /// jumping to Inventory with no user action, and only three code paths
    /// write tab state — none of them targeting Inventory. Until the jump is
    /// reproduced with this in place, the log is the only way to name the
    /// caller. Cheap enough to keep (fires only on actual changes).
    @Published var selectedTab: AppTab = AppTab.launchTab() {
        didSet {
            guard oldValue != selectedTab else { return }
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(5)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " | ")
            dbg.info("Tab \(oldValue.rawValue) → \(selectedTab.rawValue) via: \(frames)", category: "tabs")
            // Browser-style history: any organic navigation pushes the old tab
            // and clears the forward stack; Back/Forward set the flag so their
            // own writes don't re-record.
            if !isNavigatingTabHistory {
                tabBackStack.append(oldValue)
                tabForwardStack.removeAll()
            }
        }
    }

    // MARK: - Tab history (Back / Forward, ⌘[ / ⌘])

    private var tabBackStack: [AppTab] = []
    private var tabForwardStack: [AppTab] = []
    private var isNavigatingTabHistory = false

    var canGoBack: Bool { !tabBackStack.isEmpty }
    var canGoForward: Bool { !tabForwardStack.isEmpty }

    func goBack() {
        guard let previous = tabBackStack.popLast() else { return }
        isNavigatingTabHistory = true
        tabForwardStack.append(selectedTab)
        selectedTab = previous
        isNavigatingTabHistory = false
    }

    func goForward() {
        guard let next = tabForwardStack.popLast() else { return }
        isNavigatingTabHistory = true
        tabBackStack.append(selectedTab)
        selectedTab = next
        isNavigatingTabHistory = false
    }
    @Published var navigateToTab: AppTab? {
        didSet {
            guard let tab = navigateToTab else { return }
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(5)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " | ")
            dbg.info("navigateToTab ← \(tab.rawValue) via: \(frames)", category: "tabs")
        }
    }
    /// The most recent menu command, for the visible tab to act on.
    /// See `AppCommand` for why this is a broadcast rather than a direct call.
    @Published var pendingCommand: AppCommandRequest?

    @Published var navigateToDeviceId: String?
    @Published var navigateToTicketId: Int?
    @Published var navigateToFilter: String?
    /// Text dropped into the Inventory search field on arrival — how global
    /// search lands on a specific asset (serial / tag / name), distinct from
    /// `navigateToFilter` which drives the status filter.
    @Published var navigateToInventorySearch: String?
    /// Snipe-IT asset to open in the Inventory tab on arrival — the exact
    /// deep link from Recent Activity and global search.
    @Published var navigateToAssetId: Int?
    /// DevOps work item to open in the Projects tab on arrival.
    @Published var navigateToWorkItemId: Int?
    /// GitHub twin of navigateToWorkItemId: the issue's web URL, which is
    /// how the Projects tab identifies a GitHub task.
    @Published var navigateToGitHubIssueUrl: String?
    /// A `ticketsmate://` pull, commit or pipeline link for Development to open.
    @Published var pendingDevelopmentLink: TicketsMateLink?
    /// Bumped by ⌘K; the toolbar search field takes focus on each change.
    @Published var globalSearchFocusRequest = 0
    /// Bumped by ⌘F; the toolbar search field takes focus filtering the tab.
    @Published var tabSearchFocusRequest = 0
    /// The open tab's list filter, which the toolbar search field drives.
    @Published var tabSearch: TabSearchRegistration?
    @Published var tabSearchText = ""
    /// Why the last `ticketsmate://` link could not be opened.
    @Published var linkError: String?

    /// Route a `ticketsmate://` link to the tab that shows it.
    func open(_ url: URL) {
        do {
            guard url.scheme?.lowercased() == AppEdition.current.linkScheme else {
                throw TicketsMateLinkError.notTicketsMate(url.absoluteString)
            }
            let link = try TicketsMateLink.parse(url)
            dbg.info("Opening link \(url.absoluteString)", category: "links")
            switch link {
            case .ticket(let id):
                navigateToTicketId = id
                navigateToTab = .tickets
            default:
                throw TicketsMateLinkError.unknownRoute(url.host ?? url.absoluteString)
            }
        } catch {
            linkError = error.localizedDescription
        }
    }
    /// A filter to apply in a module tab on arrival — how dashboard chart
    /// wedges/bars deep-link into their section pre-filtered.
    @Published var navigateToModuleFilter: ModuleFilterLink?
    
    // MARK: - Auth Manager
    @Published var authManager: AuthManager
    
    // MARK: - TDX SSO State
    @Published var showTdxSsoLogin = false
    @Published var tdxSsoAuthenticated = false
    @Published var tdxAuthenticatedUserName: String?
    private var ssoViewModel: TdxSsoLoginViewModel?
    /// True when silent renewal has given up and only the person can sign
    /// in: drives the Tickets sign-in banner.
    @Published var tdxNeedsSignIn = false
    /// Consecutive failed silent sign-ins, for the renewal backoff.
    @Published var tdxRenewalFailures = 0
    var tdxLastRenewalAttempt: Date?
    /// A silent sign-in is running; another request waits for it.
    var tdxSignInInFlight = false
    var tdxSignInWaiters: [CheckedContinuation<Bool, Never>] = []
    var tdxRenewalTask: Task<Void, Never>?
    /// Set on wake, unlock or a network change: renew now if the session
    /// is gone, without waiting out the backoff.
    var tdxRenewalKick = false
    var tdxRenewalObservers: [Any] = []
    var tdxPathMonitor: AnyObject?
    
    
    // MARK: - Cached Data
    // Data caches with timestamps to avoid reloading on tab switches
    
    @Published var cachedTickets: [TdxTicket] = []
    /// Where the automatic TDX sign-in has got to, from its start until the
    /// first ticket list arrives; nil otherwise. Drives the launch progress.
    @Published var tdxSignInStage: TdxSignInStage?
    var isTdxSigningIn: Bool { tdxSignInStage != nil }
    private var isPreloadingAllData = false
    private var preloadAllDataRequested = false


    // Cache timestamps
    private var ticketsCacheTime: Date?
    
    /// Cache duration in seconds (from config.cacheMinutes)
    private var cacheDuration: TimeInterval {
        TimeInterval(config.cacheMinutes * 60)
    }

    // Services (lazy initialization)

    /// Modules switched off in Settings ▸ General. Disabled modules hide from
    /// the tab bar; Enrollment also stops reading enrollment records.
    @Published var modules: ModuleEnablement = .load() {
        didSet {
            guard modules != oldValue else { return }
            modules.save()
        }
    }

    lazy var tdxService: TdxService = makeTdxService(config: config)

    init() {
        dbg.info("AppState init starting", category: "startup")

        // Load config - secrets are loaded from secrets.yaml automatically
        let loadedConfig: TicketsMateConfig
        do {
            loadedConfig = try TicketsMateConfig.load()
            dbg.info("Config loaded OK", category: "startup")
        } catch {
            loadedConfig = TicketsMateConfig()
            dbg.error("Config load FAILED: \(error.localizedDescription)", category: "startup")
        }
        self.config = loadedConfig
        self.authManager = AuthManager(config: loadedConfig)

        // Log configuration status
        dbg.info("Graph configured:  \(config.isGraphConfigured)  (tenantId=\(config.graphTenantId != nil), devicesGraphId=\(config.devicesGraphId != nil), systemsGraphId=\(config.systemsGraphId != nil))", category: "config")
        dbg.info("DevOps configured: \(config.isDevOpsConfigured) (org=\(config.devopsOrganization ?? "nil"), project=\(config.devopsProject ?? "nil"), clientId=\(config.devopsClientId != nil), tenantId=\(config.devopsTenantId != nil))", category: "config")
        dbg.info("TDX configured:    \(config.isTdxConfigured)    (baseUrl=\(config.tdxBaseUrl != nil), appId=\(config.tdxAppId != nil), authMethod=\(config.tdxAuthMethod))", category: "config")
        dbg.info("Snipe configured:  \(config.isSnipeConfigured)  (url=\(config.snipeUrl != nil), apiKey=\(config.snipeApiKey != nil))", category: "config")

        // Tasks providers
        if let tasks = config.tasks {
            let azdo = tasks.providers.azdevops
            let gh = tasks.providers.github
            let gitea = tasks.providers.gitea
            dbg.info("Tasks providers: azdevops.enabled=\(azdo?.enabled ?? false) github.enabled=\(gh?.enabled ?? false) gitea.enabled=\(gitea?.enabled ?? false)", category: "config")
            if let az = azdo {
                dbg.info("  azdevops: org=\(az.organization ?? "nil") project=\(az.project ?? "nil")", category: "config")
            }
            if let g = gh {
                dbg.info("  github: org=\(g.organization ?? "nil") owner=\(g.owner ?? "nil") repo=\(g.repo ?? "nil") projectNumber=\(g.projectNumber.map(String.init) ?? "nil")", category: "config")
            }
        } else {
            dbg.warn("No tasks section in config", category: "config")
        }

        // Check if secrets are configured based on loaded config
        secretsConfigured = config.isGraphConfigured || 
                           config.isSnipeConfigured || 
                           config.isTdxConfigured
        if !secretsConfigured {
            showOnboardingWizard = true
        }
        dbg.info("secretsConfigured = \(secretsConfigured)", category: "startup")

        // Show the last session's tickets straight away; they are replaced
        // as soon as sign-in finishes and a fresh list loads. The cache time
        // stays unset, so that load still happens.
        if config.isTdxConfigured, !InboxAgent.isAgentProcess {
            cachedTickets = TicketSnapshot.load()
            if !cachedTickets.isEmpty {
                dbg.info("Showing \(cachedTickets.count) tickets from the last session", category: "startup")
            }
        }
        dbg.info("Log file: \(dbg.logFilePath)", category: "startup")
        dockBadge = DockBadgeController.make(for: self)
    }

    /// Save credential fields to Keychain and reload services.
    func saveConfig(_ updated: TicketsMateConfig) {
        do {
            dbg.info("[SaveConfig] Saving to keychain...", category: "config")
            try TicketsMateConfig.saveToKeychain(updated)
            dbg.info("[SaveConfig] Keychain save OK, reloading...", category: "config")
            reloadConfig()
            dbg.info("[SaveConfig] Reload complete. TDX configured: \(config.isTdxConfigured), Snipe configured: \(config.isSnipeConfigured)", category: "config")
        } catch {
            let msg = "Failed to save config: \(error.localizedDescription)"
            dbg.error("[SaveConfig] \(msg)", category: "config")
            errorMessage = msg
        }
    }

    func reloadConfig() {
        do {
            let previous = config
            config = try TicketsMateConfig.load()
            
            // Check if secrets are configured
            secretsConfigured = config.isGraphConfigured ||
                               config.isSnipeConfigured ||
                               config.isTdxConfigured ||
                               config.isDevOpsConfigured
            
            // Reinitialize services
            tdxService = makeTdxService(config: config)
            errorMessage = nil


            // Re-bootstrap auth manager with updated config
            authManager.bootstrapFromConfig(with: config)
            
            // Clear caches on config reload
            invalidateAllCaches()
        } catch {
            errorMessage = "Failed to reload config: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Menu Commands

    /// Broadcast a menu command to whichever tab is on screen.
    func perform(_ command: AppCommand) {
        pendingCommand = AppCommandRequest(command: command)
    }

    // MARK: - Cache Helpers

    /// Check if cache is valid (not expired)
    func isCacheValid(_ cacheTime: Date?) -> Bool {
        guard let cacheTime = cacheTime else { return false }
        return Date().timeIntervalSince(cacheTime) < cacheDuration
    }
    
    /// Invalidate all caches
    func invalidateAllCaches() {
        ticketsCacheTime = nil
        cachedTickets = []
    }
    
    // MARK: - Data Loading with Caching
    
    
    /// Check if tickets cache is valid
    var isTicketsCacheValid: Bool { isCacheValid(ticketsCacheTime) }
    
    
    /// Update tickets cache
    func updateTicketsCache(_ tickets: [TdxTicket]) {
        cachedTickets = tickets
        ticketsCacheTime = Date()
        TicketSnapshot.save(tickets)
        if tdxSignInStage == .tickets { tdxSignInStage = nil }
    }
    
    
    /// Invalidate tickets cache
    func invalidateTicketsCache() { ticketsCacheTime = nil }
    
    
    // MARK: - Background Preloading

    /// Warm the aze elevation sessions (Intune → devices, Entra → identity) so
    /// the ~30s container cold start is paid once at launch rather than on the
    /// user's first action. No-op outside aze mode.
    /// Fill the tickets cache for the Dashboard. Safe to call again: a call
    /// made before TDX sign-in finishes fails quietly and the sign-in retries.
    func preloadTickets() async {
        guard config.isTdxConfigured else { return }
        dbg.info("Preloading tickets...", category: "preload")
        do {
            var search = TicketSearchRequest(maxResults: 500)
            if let groupId = config.tdxResponsibleGroupId {
                search.responsibleGroupIds = [groupId]
            }
            let tickets = try await tdxService.searchTickets(search: search, maxResults: 500)
            updateTicketsCache(tickets)
            dbg.info("Tickets preloaded: \(tickets.count) tickets", category: "preload")
            if tdxSignInStage == .tickets { tdxSignInStage = nil }
        } catch {
            dbg.error("Tickets preload FAILED: \(error)", category: "preload")
            if tdxSignInStage == .tickets { tdxSignInStage = nil }
        }
    }


    /// Preload all data sources concurrently in the background
    func preloadAllData() async {
        guard !isPreloadingAllData else {
            preloadAllDataRequested = true
            dbg.info("preloadAllData already running; queued one reconciliation", category: "preload")
            return
        }

        isPreloadingAllData = true
        defer {
            isPreloadingAllData = false
            if preloadAllDataRequested {
                preloadAllDataRequested = false
                Task { @MainActor in
                    await self.preloadAllData()
                }
            }
        }

        dbg.info("preloadAllData starting", category: "preload")
        dbg.info("  TDX configured:    \(config.isTdxConfigured), cache valid: \(isTicketsCacheValid)", category: "preload")

        await withTaskGroup(of: Void.self) { group in
            
            // Preload tickets
            if config.isTdxConfigured && !isTicketsCacheValid {
                group.addTask { @MainActor in
                    await self.preloadTickets()
                }
            }

            // Resolve who "me" is in TDX, so Assign to me is ready on first use
            if config.isTdxConfigured && tdxMe == nil {
                group.addTask { @MainActor in
                    await self.resolveTdxMe()
                }
            }

        }
        dbg.info("preloadAllData finished", category: "preload")

        await authManager.probeAll(tdxService: tdxService)
    }
    

    // MARK: - TDX SSO Authentication
    
    /// Check if TDX SSO login is required
    var requiresTdxSsoLogin: Bool {
        return tdxService.requiresSsoLogin && !tdxSsoAuthenticated
    }
    
    /// Phase 1: Attempt silent SSO authentication (no UI).
    /// Tries a URLSession-only check — succeeds when a valid Shibboleth/Platform
    /// SSO session is already present in the system.
    /// If it fails, does NOT show any UI. The interactive Phase 2 sheet is
    /// triggered later, only when the user navigates to a tab that needs auth.
    /// Put the device's Entra PRT cookie into shared storage so the silent SAML
    /// chain authenticates without a prompt. No-op when the broker declines.
    func primeEntraPrtCookies() async {
        guard let entraUrl = URL(string: "https://login.microsoftonline.com/\(config.effectiveAzureTenantId)/saml2") else { return }
        let cookies = await EntraPrtCookieProvider().ssoCookies(for: entraUrl)
        guard !cookies.isEmpty else { return }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        dbg.info("[PRT] Installed \(cookies.count) PRT cookie(s) for the silent SAML chain", category: "tdx-sso")
    }

    func attemptSilentTdxSso(useCache: Bool = true) {
        guard !tdxSignInInFlight, ssoViewModel == nil else { return }
        tdxSignInInFlight = true
        startTdxRenewal()
        tdxSignInStage = .account
        dbg.info("[SSO Phase 1] Starting silent TDX SSO attempt (authMethod=\(config.tdxAuthMethod), ssoEnabled=\(config.tdxSsoEnabled))", category: "tdx-sso")

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Resolve the sign-in address before the flow starts. Entra's page
            // needs a username to advance, `app-sso` doesn't reliably supply
            // one, and arriving with it late means the attempt has already
            // timed out onto the service account.
            await self.primeTdxSsoUpn()
            self.tdxService.sharedSessionUpn = TdxSsoLoginViewModel.fallbackUpn
            self.tdxSignInStage = .microsoft

            // A saved sign-in verified for this same address skips the chain.
            if useCache, self.restoreTdxSession() { return }

            // Phase 0: ask the Entra broker for the device's PRT cookie and put
            // it in shared cookie storage, which the silent URLSession chain
            // below already reads from. Without it Entra answers that chain with
            // its interactive sign-in page, because the SSO plug-in acts only on
            // requests an app actually makes — it does not intercept traffic.
            await self.primeEntraPrtCookies()

            let viewModel = TdxSsoLoginViewModel(config: self.config)
            self.ssoViewModel = viewModel

            self.tdxSignInStage = .teamDynamix
            let silentSuccess = await viewModel.performSilentAuthentication()
            self.ssoViewModel = nil

            if silentSuccess,
               let result = viewModel.authResult,
               result.success,
               let token = result.token {
                // Got JWT from cached session — fully silent
                let expiry = Self.tdxSessionExpiry(for: token)
                dbg.info("[SSO Phase 1] Silent SSO SUCCEEDED — user=\(result.userName ?? "unknown") email=\(result.userEmail ?? "unknown")", category: "tdx-sso")
                self.handleTdxSsoSuccess(
                    token: token,
                    expiry: expiry,
                    userId: result.userEmail,
                    userName: result.userName
                )
            } else if let result = viewModel.authResult, result.isIdentityRefused {
                // Final: the headless browser would reach the same account.
                self.rejectTdxSsoIdentity(result)
            } else {
                dbg.warn("[SSO Phase 1] Silent SSO FAILED — will attempt headless WKWebView (Phase 1.5)", category: "tdx-sso")
                // Phase 1.5: Try headless WKWebView SSO before falling back to interactive sheet
                self.attemptHeadlessTdxSso()
            }
        }
    }
    
    /// Phase 1.5: Attempt SSO using a hidden WKWebView.
    /// The Enterprise SSO Extension can intercept WKWebView requests (but not plain URLSession),
    /// so this may complete silently where Phase 1 failed.
    func attemptHeadlessTdxSso() {
        guard ssoViewModel == nil else {
            finishTdxSignIn(succeeded: false)
            return
        }
        tdxSignInStage = .browser
        dbg.info("[SSO Phase 1.5] Starting headless WKWebView SSO attempt", category: "tdx-sso")

        let viewModel = TdxSsoLoginViewModel(config: config)
        ssoViewModel = viewModel

        // Create a hidden off-screen window to host the WKWebView
        let hiddenWindow = NSWindow(
            contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        hiddenWindow.isReleasedWhenClosed = false
        hiddenWindow.orderOut(nil)

        // Attach the WebView to the hidden window so SSO Extension can intercept
        let webView = viewModel.webView
        hiddenWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        // Start the WebView-based SSO flow
        viewModel.startAuthentication()

        // Watch for completion with a timeout
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Wait up to 95 seconds for headless SSO to complete. 25s was
            // calibrated for a chain that either completes or doesn't; it
            // guillotined any method that involves the person's phone — an
            // Authenticator push needs the fallback script to request it
            // (~10-20s in) plus however long a human takes to tap approve.
            let deadline = Date().addingTimeInterval(95)
            while Date() < deadline {
                if let result = viewModel.authResult {
                    self.ssoViewModel = nil
                    hiddenWindow.close()
                    if result.success, let token = result.token {
                        let expiry = Self.tdxSessionExpiry(for: token)
                        dbg.info("[SSO Phase 1.5] Headless WKWebView SSO SUCCEEDED — user=\(result.userName ?? "unknown")", category: "tdx-sso")
                        self.handleTdxSsoSuccess(
                            token: token,
                            expiry: expiry,
                            userId: result.userEmail,
                            userName: result.userName
                        )
                        return
                    }
                    if result.isIdentityRefused {
                        self.rejectTdxSsoIdentity(result)
                        return
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s poll
            }

            self.ssoViewModel = nil
            hiddenWindow.close()
            // Deliberately does NOT touch the TDX auth badge here: probeAll
            // verifies TDX independently, and reporting a failure from this
            // racing task is how the panel once showed "Failed: Silent SSO
            // failed" directly above a green "signed in" row.
            // Not "unaffected" any more: with no service account configured,
            // this is the only way in, so a failure here means no TDX access
            // until someone signs in.
            dbg.warn("[SSO Phase 1.5] Headless WKWebView SSO FAILED or timed out — renewal will retry on its backoff", category: "tdx-sso")
            self.tdxSignInStage = nil
            self.finishTdxSignIn(succeeded: false)
        }
    }

    /// Phase 2: Trigger interactive TDX SSO login (shows WebView sheet).
    /// Called when the user navigates to a tab that requires TDX authentication
    /// and silent Phase 1 didn't succeed.
    func triggerTdxSsoLogin() {
        showTdxSsoLogin = true
    }

    /// Tear down any in-progress silent SSO attempt
    private func cleanupSsoWindow() {
        ssoViewModel = nil
    }
    
    /// Reuse the last sign-in is only done from an installed, signed copy:
    /// a build run from anywhere else has a different signature and would
    /// raise a keychain prompt.
    static var isTdxSessionCacheEnabled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Restore the last sign-in from the keychain when it still has an hour
    /// left — the app or the background helper wrote it — so launch skips the
    /// silent SSO chain. A session TDX no longer accepts is dropped and the
    /// normal sign-in runs.
    private func restoreTdxSession() -> Bool {
        guard Self.isTdxSessionCacheEnabled, let cached = TdxSessionCache.load() else { return false }
        guard cached.matches(expectedUpn: TdxSsoLoginViewModel.fallbackUpn, baseUrl: config.tdxBaseUrl) else {
            if cached.isFresh {
                dbg.warn("[SSO] Saved TDX session is for another account or tenant; discarding", category: "tdx-sso")
                TdxSessionCache.clear()
            }
            return false
        }
        dbg.info("[SSO] Reusing saved TDX session (expires \(cached.expiry))", category: "tdx-sso")

        for cookie in cached.cookies.compactMap(\.httpCookie) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        if let me = cached.confirmedMe { tdxMe = me }
        handleTdxSsoSuccess(token: cached.token, expiry: cached.expiry,
                            userId: cached.userId, userName: cached.userName, persist: false)
        if let me = cached.confirmedMe {
            ticketInbox.start(service: tdxService, me: me)
            InboxAgent.registerIfInstalled()
        }

        let probeEmail = cached.confirmedUpn
        Task { @MainActor [weak self] in
            guard let self else { return }
            let email = probeEmail
            if (try? await self.tdxService.findPerson(email: email)) == nil {
                dbg.warn("[SSO] Saved TDX session was refused; signing in again", category: "tdx-sso")
                TdxSessionCache.clear()
                self.tdxService.clearSsoToken()
                self.tdxSsoAuthenticated = false
                self.attemptSilentTdxSso(useCache: false)
            }
        }
        return true
    }

    /// Handle successful SSO authentication
    func handleTdxSsoSuccess(token: String, expiry: Date, userId: String?, userName: String?, persist: Bool = true) {
        // If token isn't a real JWT, use cookie-based auth instead
        if !token.hasPrefix("eyJ") {
            // Extract cookies from shared storage for the TDX domain
            if let baseUrl = config.tdxBaseUrl, let url = URL(string: baseUrl) {
                let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
                if !cookies.isEmpty {
                    tdxService.setSsoCookies(cookies, userName: userName)
                } else {
                    tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
                }
            } else {
                tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
            }
        } else {
            tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
        }
        tdxSsoAuthenticated = true
        tdxSignInStage = cachedTickets.isEmpty || !isTicketsCacheValid ? .tickets : nil
        tdxAuthenticatedUserName = userName
        showTdxSsoLogin = false
        authManager.update(.tdx, state: .valid(user: userName, expiry: expiry))
        if let upn = userId, upn.contains("@") { tdxService.sharedSessionUpn = upn.lowercased() }
        finishTdxSignIn(succeeded: true)

        // `userId` is the address the identity check just verified.
        if persist && Self.isTdxSessionCacheEnabled,
           let upn = userId, upn.contains("@"), let baseUrl = config.tdxBaseUrl {
            let cookies = URL(string: baseUrl).flatMap { HTTPCookieStorage.shared.cookies(for: $0) } ?? []
            let me = tdxMe?.primaryEmail?.lowercased() == upn.lowercased() ? tdxMe : nil
            TdxSessionCache(token: token, expiry: expiry, userId: userId, userName: userName,
                            cookies: cookies, me: me, confirmedUpn: upn, baseUrl: baseUrl).save()
        }

        // The background helper only needs the session for the inbox.
        guard !InboxAgent.isAgentProcess else { return }

        // Launch preloads tickets in parallel with this sign-in and usually
        // loses the race (notAuthenticated), leaving the Dashboard at zero
        // tickets. Load them now that the session exists.
        if !isTicketsCacheValid {
            Task { await preloadTickets() }
        }
        
        // Resolve the actual TDX UID from the email — SSO returns email, not TDX UID
        if let email = userId, !email.isEmpty {
            Task {
                do {
                    let people = try await tdxService.searchPeople(searchText: email, maxResults: 1)
                    if let person = people.first, let uid = person.uid {
                        tdxService.setSsoToken(token, expiry: expiry, userId: uid, userName: userName)
                    }
                } catch {
                    // Non-fatal — keep the email as fallback
                }
            }
        }
        
        // Invalidate tickets cache and reload data
        invalidateTicketsCache()
        Task {
            await preloadAllData()
        }
    }
    
    /// Refuse a TDX session that is not confirmed as the signed-in user's:
    /// another account's, one with no address, or one with no expected
    /// address to compare against. Its token is never stored, any earlier session is cleared, and
    /// the service account is shut off too, so nothing is attributed to the
    /// wrong person. There is no other route: no interactive window either.
    func rejectTdxSsoIdentity(_ result: TdxSsoResult) {
        TdxSessionCache.clear()
        let reason = result.error ?? "TDX sign-in refused: identity could not be confirmed"
        dbg.error("[SSO] \(reason) — sign-in refused", category: "tdx-sso")
        tdxService.refuseSso(reason: reason)
        tdxSsoAuthenticated = false
        tdxSignInStage = nil
        tdxAuthenticatedUserName = nil
        tdxMe = nil
        showTdxSsoLogin = false
        authManager.update(.tdx, state: .failed(message: reason))
        invalidateTicketsCache()
        finishTdxSignIn(succeeded: false)
        tdxNeedsSignIn = true
    }

    /// Handle SSO authentication failure or cancellation
    func handleTdxSsoFailure(_ error: String?) {
        showTdxSsoLogin = false
        tdxSignInStage = nil
        if let error = error {
            errorMessage = "TDX SSO login failed: \(error)"
            authManager.update(.tdx, state: .failed(message: error))
        }
    }
    
    // MARK: - TDX Identity ("me")

    /// The TDX person record for whoever is driving the app.
    ///
    /// TDX's Web API always authenticates as the service account, so the session
    /// itself can't say who you are. This is resolved separately from the
    /// signed-in Azure identity and is what "Assign to me" acts on.
    @Published var tdxMe: TdxPerson?
    /// Comments across all tickets that notified `tdxMe`.
    let ticketInbox = TicketInboxModel()
    /// Mirrors the inbox's unread count onto the Dock icon. Nil in the helper.
    private var dockBadge: DockBadgeController?

    /// Email addresses to try when resolving `tdxMe`, best first.
    private func tdxIdentityCandidates() async -> [String] {
        var candidates: [String] = []
        if let name = tdxAuthenticatedUserName, name.contains("@") { candidates.append(name) }
        return candidates
    }

    /// Make the signed-in address available to the TDX SSO flow.
    ///
    /// `app-sso platform -s` is not a reliable source: on an enrolled Mac it
    /// can expose no `upn` key at all and mask `loginUserName` as
    /// `a***e@example.edu`. The Azure identity has the real address; failing
    /// that, the device sources and the Office account (`SignedInAddress`).
    func primeTdxSsoUpn() async {
        guard TdxSsoLoginViewModel.fallbackUpn == nil else { return }

        // Last: the device, then the account Office and Company Portal were
        // activated with. The identity check refuses a sign-in with no address
        // to compare against, so an address from any of these beats none.
        let found = await Task.detached(priority: .userInitiated) { () -> (address: String, source: String)? in
            if let device = SignedInAddress.readDevice() { return device }
            if let office = SignedInAddress.readMicrosoftAccount() { return (office, "Microsoft Office account") }
            return nil
        }.value
        if let found {
            dbg.info("[PSSO] Signed-in address from \(found.source): \(found.address)", category: "tdx-sso")
            TdxSsoLoginViewModel.fallbackUpn = found.address
        } else {
            dbg.warn("[PSSO] No signed-in address from Azure DevOps, the Azure CLI, the device or Office", category: "tdx-sso")
        }
    }

    /// Resolve and cache the current user's TDX person record. Cheap to call
    /// repeatedly — it returns immediately once resolved.
    func resolveTdxMe() async {
        guard tdxMe == nil, config.isTdxConfigured else { return }

        for email in await tdxIdentityCandidates() {
            do {
                if let person = try await tdxService.findPerson(email: email) {
                    dbg.info("TDX identity resolved: \(person.fullName ?? "?") via \(email)", category: "tdx")
                    tdxMe = person
                    if Self.isTdxSessionCacheEnabled, var cached = TdxSessionCache.load(),
                       person.primaryEmail?.lowercased() == cached.confirmedUpn {
                        cached.me = person
                        cached.save()
                    }
                    // Build the inbox quietly from launch, so it is ready
                    // before anyone opens it.
                    ticketInbox.start(service: tdxService, me: person)
                    InboxAgent.registerIfInstalled()
                    return
                }
            } catch {
                dbg.warn("TDX identity lookup failed for \(email): \(error.localizedDescription)", category: "tdx")
            }
        }
        dbg.warn("TDX identity unresolved — no signed-in email matched a TDX person", category: "tdx")
    }
    
}

/// The steps of the automatic TDX sign-in, in order. Nothing here waits on
/// the person: each step runs by itself and the window only reports it.
enum TdxSignInStage: Int, CaseIterable {
    case account, microsoft, teamDynamix, browser, tickets

    var label: String {
        switch self {
        case .account: "Finding your account"
        case .microsoft: "Connecting to Microsoft"
        case .teamDynamix: "Signing in to TeamDynamix"
        case .browser: "Finishing sign-in"
        case .tickets: "Loading tickets"
        }
    }

    /// Share of the way through, for a determinate bar.
    var fraction: Double { Double(rawValue + 1) / Double(Self.allCases.count + 1) }
}
