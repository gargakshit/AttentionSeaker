import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase
    @State private var gitHubCLIPathDraft = ""

    var body: some View {
        Form {
            accountSection
            refreshSection
            notificationSection
            startupSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .task {
            await controller.start()
            gitHubCLIPathDraft = controller.gitHubCLIPath ?? ""
            controller.refreshLaunchAtLoginStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                controller.refreshLaunchAtLoginStatus()
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            switch controller.authenticationState {
            case .checking:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking GitHub CLI…")
                }
            case .cliUnavailable:
                LabeledContent("GitHub CLI", value: "Not found")
                Text("Install gh in /opt/homebrew/bin, /usr/local/bin, /opt/local/bin, or a directory on PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Get GitHub CLI", destination: AppConfiguration.gitHubCLIHomepageURL)
                    Button("Check Again") {
                        Task { await controller.recheckGitHub() }
                    }
                }
            case .signedOut:
                LabeledContent("GitHub CLI", value: "Authentication required")
                authenticationInstructions
                HStack {
                    Button("Copy gh auth login") {
                        copyLoginCommand()
                    }
                    Button("Open Terminal") {
                        controller.openTerminal()
                    }
                    Button("Check Again") {
                        Task { await controller.recheckGitHub() }
                    }
                }
            case .signedIn(let login):
                LabeledContent("GitHub account", value: "@\(login)")
                Text("Authentication is managed by your local gh installation. AttentionSeaker does not read or store its access token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check Account Again") {
                        Task { await controller.recheckGitHub() }
                    }
                    Spacer()
                    Button("Clear Cached GitHub Data", role: .destructive) {
                        controller.clearCache()
                    }
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                authenticationInstructions
                HStack {
                    Button("Open Terminal") {
                        controller.openTerminal()
                    }
                    Button("Check Again") {
                        Task { await controller.recheckGitHub() }
                    }
                }
            }

            gitHubCLIExecutablePicker
        }
    }

    private var gitHubCLIExecutablePicker: some View {
        Group {
            LabeledContent("gh path") {
                TextField("GitHub CLI path", text: $gitHubCLIPathDraft)
                    .labelsHidden()
                    .accessibilityLabel("GitHub CLI path")
                    .onSubmit {
                        applyGitHubCLIPath()
                    }
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Spacer()
                Button("Apply") {
                    applyGitHubCLIPath()
                }
            }
        }
    }

    private var refreshSection: some View {
        Section("Refresh") {
            LabeledContent("Interval") {
                HStack(spacing: 8) {
                    TextField(
                        "",
                        value: Binding(
                            get: { controller.refreshIntervalMinutes },
                            set: { controller.updateRefreshInterval($0) }
                        ),
                        format: .number
                    )
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Refresh interval in minutes")
                    Stepper(
                        "",
                        value: Binding(
                            get: { controller.refreshIntervalMinutes },
                            set: { controller.updateRefreshInterval($0) }
                        ),
                        in: 5...1_440
                    )
                    .labelsHidden()
                    Text("minutes")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text("Refreshes at launch, on this interval while running, and when requested manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh Now") {
                Task { await controller.refresh() }
            }
            .disabled(!controller.canRefresh)
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle(
                "Launch AttentionSeaker at login",
                isOn: Binding(
                    get: { controller.isLaunchAtLoginEnabled },
                    set: { controller.setLaunchAtLogin($0) }
                )
            )
            .disabled(controller.launchAtLoginStatus == .unavailable)

            if let message = controller.launchAtLoginErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if controller.launchAtLoginStatus == .requiresApproval {
                HStack {
                    Text("macOS requires approval in Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") {
                        controller.openLoginItemsSettings()
                    }
                }
            } else if controller.launchAtLoginStatus == .unavailable {
                Text("macOS couldn't find this app as a login item. Move AttentionSeaker to Applications, reopen it, and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notificationSection: some View {
        Section("Notifications") {
            notificationPermissionStatus

            if let message = controller.notificationErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Issues")
                        .font(.headline)
                    notificationToggle("Authored by me", kind: .issue, reason: .authored)
                    notificationToggle("Mentions me", kind: .issue, reason: .mentioned)
                    notificationToggle("Assigned to me", kind: .issue, reason: .assigned)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pull Requests")
                        .font(.headline)
                    notificationToggle("Authored by me", kind: .pullRequest, reason: .authored)
                    notificationToggle("Mentions me", kind: .pullRequest, reason: .mentioned)
                    notificationToggle("Needs my review", kind: .pullRequest, reason: .reviewRequested)
                    notificationToggle("Assigned to me", kind: .pullRequest, reason: .assigned)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var notificationPermissionStatus: some View {
        switch controller.notificationAuthorizationState {
        case .authorized:
            Label("Notifications allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            HStack {
                Text("Allow macOS notifications to receive selected alerts.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Allow Notifications…") {
                    Task { await controller.requestNotificationAuthorization() }
                }
                .disabled(controller.isRequestingNotificationAuthorization)
            }
        case .denied:
            HStack {
                Text("Notifications are disabled in System Settings.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Notification Settings") {
                    controller.openNotificationSettings()
                }
            }
        }
    }

    private func notificationToggle(
        _ title: String,
        kind: AttentionKind,
        reason: AttentionReason
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { controller.isNotificationEnabled(kind: kind, reason: reason) },
                set: { enabled in
                    controller.setNotificationEnabled(enabled, kind: kind, reason: reason)
                    if enabled {
                        Task { await controller.requestNotificationAuthorization() }
                    }
                }
            )
        )
        .toggleStyle(.checkbox)
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: versionDescription)
            Link("GitHub Repository", destination: AppConfiguration.githubHomepageURL)
            Link("Privacy Policy", destination: AppConfiguration.privacyPolicyURL)
        }
    }

    private var authenticationInstructions: some View {
        Text("Run `gh auth login` in Terminal. The scopes granted to gh determine which public and private repositories AttentionSeaker can read.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("gh auth login", forType: .string)
    }

    private func applyGitHubCLIPath() {
        let path = gitHubCLIPathDraft
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath == controller.gitHubCLIPath {
            return
        }
        Task {
            await controller.setGitHubCLIOverridePath(trimmedPath)
            if controller.gitHubCLIPathErrorMessage == nil {
                gitHubCLIPathDraft = controller.gitHubCLIPath ?? ""
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
