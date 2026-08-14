import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        Form {
            accountSection
            refreshSection
            startupSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .task {
            await controller.start()
            controller.refreshLaunchAtLoginStatus()
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            switch controller.authenticationState {
            case .notConfigured:
                LabeledContent("GitHub") {
                    Text("OAuth client ID missing")
                        .foregroundStyle(.secondary)
                }
                Text("Set the GITHUB_OAUTH_CLIENT_ID build setting to the client ID of an OAuth App with Device Flow enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .signedOut:
                connectionDisclosure
                Button("Connect GitHub…") {
                    controller.connectGitHub()
                }
                .buttonStyle(.borderedProminent)
            case .authorizing(let authorization):
                authorizationView(authorization)
            case .signedIn(let login):
                LabeledContent("GitHub account", value: "@\(login)")
                connectionDisclosure
                HStack {
                    Button("Reconnect GitHub…") {
                        controller.connectGitHub()
                    }
                    if let url = controller.manageGitHubAccessURL {
                        Button("Manage GitHub Access") {
                            controller.open(url)
                        }
                    }
                    Spacer()
                    Button("Sign Out and Clear Cache", role: .destructive) {
                        controller.signOutAndClearCache()
                    }
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                connectionDisclosure
                HStack {
                    Button("Try Again") {
                        controller.connectGitHub()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") {
                        controller.cancelAuthorization()
                    }
                }
            }
        }
    }

    private var refreshSection: some View {
        Section("Refresh") {
            LabeledContent("Interval") {
                HStack(spacing: 8) {
                    TextField(
                        "Minutes",
                        value: Binding(
                            get: { controller.refreshIntervalMinutes },
                            set: { controller.updateRefreshInterval($0) }
                        ),
                        format: .number
                    )
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
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
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: versionDescription)
            Link("GitHub Repository", destination: AppConfiguration.githubHomepageURL)
            Link("Privacy Policy", destination: AppConfiguration.privacyPolicyURL)
        }
    }

    private var connectionDisclosure: some View {
        Text("AttentionSeaker requests GitHub's broad repo OAuth scope so it can read matching items from private repositories. The app performs read-only API requests and stores the token only in Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func authorizationView(_ authorization: DeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter this code on GitHub")
                .font(.headline)
            Text(authorization.userCode)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
            Text("Code expires \(authorization.expiresAt, style: .relative).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(authorization.userCode, forType: .string)
                }
                Button("Open GitHub") {
                    controller.open(authorization.verificationURL)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    controller.cancelAuthorization()
                }
            }
            ProgressView()
                .controlSize(.small)
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
