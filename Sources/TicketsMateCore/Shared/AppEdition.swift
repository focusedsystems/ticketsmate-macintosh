import Foundation

/// Which app this build is. TicketsMate is TicketsMate limited to the Tickets
/// tab. TicketsMate bundles it from its own binary, under its own name, bundle
/// id and icon, with `TicketsMateEdition` set to `TicketsMate` in its
/// Info.plist; scripts/export-ticketsmate also writes it out as a standalone
/// app, compiled with only the TicketsMate edition. Each edition keeps its own
/// settings, so the two install and run side by side.
public enum AppEdition: String, Sendable {
    case ticketsMate = "TicketsMate"

    public static let current = AppEdition.ticketsMate

    /// The bundle id a process without a bundle (`swift run`) stands in for.
    public static let defaultBundleIdentifier = "systems.focused.ticketsmate"

    /// The name shown in the window, About box and onboarding.
    public var displayName: String { rawValue }

    /// True when the app shows only the Tickets tab.
    public var isTicketsOnly: Bool { true }

    /// The URL scheme links to the app use.
    public var linkScheme: String { "ticketsmate" }

    /// Per-user folder for config.yaml and credentials.json.
    public var supportDirectory: String { "~/.ticketsmate" }

    /// Preference domain a configuration profile configures the app through,
    /// and the Keychain service its secrets are stored under: the bundle id.
    public func preferencesDomain(bundleIdentifier: String?) -> String {
        bundleIdentifier ?? Self.defaultBundleIdentifier
    }

    /// Folder debug.log is written to, the standard per-user Logs folder.
    public var logDirectory: String { "~/Library/Logs/TicketsMate" }

    public var preferencesDomain: String {
        preferencesDomain(bundleIdentifier: AppIdentity.mainBundleIdentifier)
    }

    /// Expands `name` inside this edition's support folder.
    public func supportPath(_ name: String) -> String {
        NSString(string: "\(supportDirectory)/\(name)").expandingTildeInPath
    }
}

/// The app a process belongs to. The background inbox helper is a separate
/// bundle nested inside the app, with its own bundle id so macOS never treats
/// it as the app, yet it reads the app's settings, keychain items and launch
/// agent. Its Info.plist names the app under `mainBundleIdentifierKey`.
public enum AppIdentity {
    public static let mainBundleIdentifierKey = "TicketsMateMainBundleIdentifier"

    /// Suffix the helper's bundle id and launch agent label add to the app's.
    public static let inboxHelperSuffix = ".inbox-agent"

    /// The app's bundle id: the one the helper's Info.plist names, otherwise
    /// the running bundle's own.
    public static func mainBundleIdentifier(info: [String: Any]?, bundleIdentifier: String?) -> String? {
        if let named = info?[mainBundleIdentifierKey] as? String {
            let trimmed = named.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return bundleIdentifier
    }

    public static let mainBundleIdentifier: String? = mainBundleIdentifier(
        info: Bundle.main.infoDictionary, bundleIdentifier: Bundle.main.bundleIdentifier)

    /// True inside the nested helper bundle.
    public static let isInboxHelperBundle: Bool =
        Bundle.main.object(forInfoDictionaryKey: mainBundleIdentifierKey) != nil

    /// The launch agent label, and the helper's bundle id, for an app.
    public static func inboxHelperIdentifier(main: String) -> String {
        main + inboxHelperSuffix
    }
}

/// The version string the About pane shows.
public enum AppVersionDisplay {
    /// Release builds stamp CFBundleShortVersionString with the date
    /// (YYYY.MM.DD) and CFBundleVersion with the time (HHMM); joined they are
    /// the same YYYY.MM.DD.HHMM the command-line tool reports. An unstamped
    /// build reads "dev", with the commit it was built from when known.
    public static func string(short: String?, build: String?, commit: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        let isDate = short.split(separator: ".").count == 3 && short.count == 10 && short.allSatisfy { $0.isNumber || $0 == "." }
        if isDate {
            return build.count == 4 && build.allSatisfy(\.isNumber) ? "\(short).\(build)" : short
        }
        if short.split(separator: ".").count == 4 && short.hasPrefix("20") { return short }
        if let commit, !commit.isEmpty { return "dev (\(commit))" }
        return "dev"
    }
}
