import AppKit
import SwiftData
import SwiftUI

enum AttentionFeedSection: String, CaseIterable, Identifiable {
    case stream
    case pullRequests
    case issues

    var id: Self { self }

    var title: String {
        switch self {
        case .stream:
            return "Stream"
        case .pullRequests:
            return "Pull Requests"
        case .issues:
            return "Issues"
        }
    }

    func includes(kind: AttentionKind, reasons: AttentionReason) -> Bool {
        switch self {
        case .stream:
            return true
        case .pullRequests:
            let includedReasons: AttentionReason = [.reviewRequested, .mentioned, .authored]
            return kind == .pullRequest && !reasons.intersection(includedReasons).isEmpty
        case .issues:
            let includedReasons: AttentionReason = [.assigned, .mentioned, .authored]
            return kind == .issue && !reasons.intersection(includedReasons).isEmpty
        }
    }
}

struct MenuBarView: View {
    @Environment(AppController.self) private var controller
    @Query(sort: [
        SortDescriptor(\AttentionItem.lastActivityAt, order: .reverse),
        SortDescriptor(\AttentionItem.repositoryName),
        SortDescriptor(\AttentionItem.number),
    ]) private var items: [AttentionItem]
    @State private var selectedSection = AttentionFeedSection.stream

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
                Text("I seek your Attention!")
                    .font(.headline)
                if let date = controller.lastSuccessfulRefreshAt {
                    Text("Updated \(date, style: .relative) ago")
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
            VStack(spacing: 0) {
                Picker("Feed", selection: $selectedSection) {
                    ForEach(AttentionFeedSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                if filteredItems.isEmpty {
                    emptySectionState
                } else {
                    List(filteredItems) { item in
                        Button {
                            if let url = item.url {
                                controller.open(url)
                            }
                        } label: {
                            AttentionRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens on GitHub")
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.square") {
                                if let url = item.url {
                                    controller.open(url)
                                }
                            }
                            Button("Copy Link", systemImage: "doc.on.doc") {
                                copyLink(item.urlString)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } else if controller.isRefreshing {
            centeredState(icon: nil, title: "Checking GitHub…", detail: nil, showsProgress: true)
        } else {
            switch controller.authenticationState {
            case .checking:
                centeredState(
                    icon: nil,
                    title: "Checking GitHub CLI…",
                    detail: nil,
                    showsProgress: true
                )
            case .cliUnavailable:
                centeredState(
                    icon: "gear.badge.xmark",
                    title: "GitHub CLI required",
                    detail: "Install gh locally, authenticate it, then check again in Settings."
                )
            case .signedOut, .failed:
                signedOutState
            case .signedIn:
                centeredState(
                    icon: "checkmark.circle",
                    title: "Nothing needs your attention",
                    detail: "Open issues and pull requests matching your attention rules will appear here."
                )
            }
        }
    }

    private var filteredItems: [AttentionItem] {
        items.filter { item in
            selectedSection.includes(kind: item.kind, reasons: item.reasons)
        }
    }

    @ViewBuilder
    private var emptySectionState: some View {
        switch selectedSection {
        case .stream:
            centeredState(
                icon: "checkmark.circle",
                title: "Nothing needs your attention",
                detail: nil
            )
        case .pullRequests:
            centeredState(
                icon: "arrow.triangle.pull",
                title: "No pull requests need your attention",
                detail: "Review requests, mentions, and pull requests authored by you appear here."
            )
        case .issues:
            centeredState(
                icon: "smallcircle.filled.circle",
                title: "No issues need your attention",
                detail: "Assigned, mentioned, and authored issues appear here."
            )
        }
    }

    private var signedOutState: some View {
        VStack(spacing: 14) {
            centeredState(
                icon: "person.crop.circle.badge.plus",
                title: "Authenticate GitHub CLI",
                detail: controller.cachedAccountLogin == nil
                    ? "Run gh auth login, then check again in Settings."
                    : "Authenticate gh to update the cached feed for @\(controller.cachedAccountLogin ?? "your account")."
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

    private func copyLink(_ urlString: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
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
