import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppController.self) private var controller
    @Query(sort: [
        SortDescriptor(\AttentionItem.updatedAt, order: .reverse),
        SortDescriptor(\AttentionItem.repositoryName),
        SortDescriptor(\AttentionItem.number),
    ]) private var items: [AttentionItem]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let message = statusMessage {
                statusBanner(message)
                Divider()
            }

            content

            Divider()
            footer
        }
        .frame(width: 430, height: 560)
        .task {
            await controller.start()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attention")
                    .font(.headline)
                if let date = controller.lastSuccessfulRefreshAt {
                    Text("Updated \(date, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not refreshed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await controller.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canRefresh)
            .help("Refresh")
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !items.isEmpty {
            List(items) { item in
                Button {
                    if let url = item.url {
                        controller.open(url)
                    }
                } label: {
                    AttentionRow(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens on GitHub")
            }
            .listStyle(.inset)
        } else if controller.isRefreshing {
            centeredState(icon: nil, title: "Checking GitHub…", detail: nil, showsProgress: true)
        } else {
            switch controller.authenticationState {
            case .notConfigured:
                centeredState(
                    icon: "gear.badge.xmark",
                    title: "OAuth client ID required",
                    detail: "Set GITHUB_OAUTH_CLIENT_ID in the app target before connecting GitHub."
                )
            case .signedOut, .failed:
                signedOutState
            case .authorizing(let authorization):
                centeredState(
                    icon: "person.badge.clock",
                    title: "Finish connecting GitHub",
                    detail: "Enter \(authorization.userCode) on GitHub."
                )
            case .signedIn:
                centeredState(
                    icon: "checkmark.circle",
                    title: "Nothing needs your attention",
                    detail: "Open issues and pull requests matching your attention rules will appear here."
                )
            }
        }
    }

    private var signedOutState: some View {
        VStack(spacing: 14) {
            centeredState(
                icon: "person.crop.circle.badge.plus",
                title: "Connect GitHub",
                detail: controller.cachedAccountLogin == nil
                    ? "Sign in to load issues and pull requests that need your attention."
                    : "Reconnect to update the cached feed for @\(controller.cachedAccountLogin ?? "your account")."
            )
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gear")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit AttentionSeaker") {
                controller.quit()
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private var statusMessage: String? {
        var messages: [String] = []
        if case .failed(let message) = controller.refreshState {
            messages.append(message)
        }
        if !controller.truncatedReasons.isEmpty {
            messages.append("Some searches exceeded GitHub's 1,000-item result limit; the newest results are shown.")
        }
        if case .failed(let message) = controller.authenticationState,
           !messages.contains(message) {
            messages.append(message)
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private func centeredState(
        icon: String?,
        title: String,
        detail: String?,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
