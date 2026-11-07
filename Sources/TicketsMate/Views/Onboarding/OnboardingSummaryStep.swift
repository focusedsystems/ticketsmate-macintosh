import SwiftUI
import TicketsMateCore

struct OnboardingSummaryStep: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: OnboardingWizardState
    @Environment(\.dismiss) private var dismiss
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review & Save")
                    .appFont(.title2, weight: .bold)
                Text("Review your configuration before saving.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if wizardState.enableTdx {
                        summaryCard(
                            icon: "ticket",
                            title: "TeamDynamix",
                            rows: tdxSummaryRows
                        )
                    }

                    // Test results
                    if !wizardState.testResults.isEmpty {
                        GroupBox("Connection Tests") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(wizardState.testResults) { result in
                                    HStack(spacing: 8) {
                                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(result.success ? .green : .orange)
                                        Text(result.service).appFont(.body, weight: .medium)
                                        Spacer()
                                        Text(result.message)
                                            .appFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            // Action buttons
            HStack {
                Button("Back") { wizardState.goBack() }

                Spacer()

                if wizardState.isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing...").appFont(.caption).foregroundStyle(.secondary)
                }

                Button("Save & Finish", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizardState.isTesting)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .task {
            await runTests()
        }
    }

    // MARK: - Summary Row Data


    private var tdxSummaryRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Base URL", wizardState.tdxBaseUrl),
            ("App ID", wizardState.tdxTicketingAppId),
            ("Auth", wizardState.tdxAuthMode.rawValue),
        ]
        if wizardState.tdxAuthMode == .serviceAccount {
            rows.append(("BEID", maskSecret(wizardState.tdxBeid)))
        }
        return rows
    }



    // MARK: - Summary Card

    private func summaryCard(icon: String, title: String, rows: [(String, String)]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(.tint)
                    Text(title).appFont(.body, weight: .semibold)
                    testResultBadge(for: title)
                    Spacer()
                }
                .padding(.bottom, 2)
                ForEach(rows, id: \.0) { label, value in
                    HStack {
                        Text(label)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(value)
                            .appFont(.caption, design: .monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func testResultBadge(for service: String) -> some View {
        if let result = wizardState.testResults.first(where: { $0.service == service }) {
            Spacer()
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .orange)
                .appFont(.caption)
        }
    }

    // MARK: - Connection Tests

    private func runTests() async {
        wizardState.isTesting = true
        wizardState.testResults = []

        let tempConfig = wizardState.buildConfig(base: appState.config)

        await withTaskGroup(of: ConnectionTestResult.self) { group in
            if wizardState.enableTdx {
                group.addTask { await testTdx(config: tempConfig) }
            }

            for await result in group {
                wizardState.testResults.append(result)
            }
        }

        wizardState.isTesting = false
    }


    private func testTdx(config: TicketsMateConfig) async -> ConnectionTestResult {
        if wizardState.tdxAuthMode == .sso {
            // SSO mode: run headless WKWebView SSO via the existing TDX SSO flow
            var ssoConfig = config
            ssoConfig.tdxAuthMethod = .browserSSO
            ssoConfig.tdxSsoEnabled = true
            let viewModel = TdxSsoLoginViewModel(config: ssoConfig)

            let hiddenWindow = NSWindow(
                contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                styleMask: [], backing: .buffered, defer: true
            )
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.orderOut(nil)

            let webView = viewModel.webView
            hiddenWindow.contentView = webView
            webView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)

            viewModel.startAuthentication()

            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                if let result = viewModel.authResult {
                    hiddenWindow.close()
                    if result.success {
                        return ConnectionTestResult(service: "TeamDynamix", success: true, message: "SSO authenticated as \(result.userName ?? "user")")
                    } else {
                        return ConnectionTestResult(service: "TeamDynamix", success: false, message: result.error ?? "SSO failed")
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            hiddenWindow.close()
            return ConnectionTestResult(service: "TeamDynamix", success: false, message: "SSO timed out")
        } else {
            do {
                let service = TdxService(config: config)
                _ = try await service.searchTickets(search: TicketSearchRequest(maxResults: 1), maxResults: 1)
                return ConnectionTestResult(service: "TeamDynamix", success: true, message: "Service account authenticated")
            } catch {
                return ConnectionTestResult(service: "TeamDynamix", success: false, message: error.localizedDescription)
            }
        }
    }


    // MARK: - Helpers

    private func maskSecret(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "*", count: value.count) }
        return String(value.prefix(4)) + "..." + String(value.suffix(4))
    }

    private func ensureHttps(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
        return "https://\(trimmed)"
    }

    private func abbreviateGuid(_ value: String) -> String {
        let parts = value.split(separator: "-")
        guard parts.count >= 2 else { return value }
        return parts[0] + "-" + parts[1] + "-..."
    }
}
