import SwiftUI

struct AttentionRow: View {
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind == .pullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                .foregroundStyle(iconColor)
                .frame(width: 18)
                .accessibilityLabel(iconAccessibilityLabel)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(item.repositoryName)
                    Text("#\(item.number)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                HStack(spacing: 5) {
                    if item.isDraft {
                        ReasonBadge(title: "Draft", color: .gray)
                    }
                    if item.kind == .pullRequest && item.isApproved {
                        ReasonBadge(title: "Approved", color: .green)
                    }
                    ForEach(AttentionReason.displayOrder, id: \.title) { entry in
                        if item.reasons.contains(entry.reason) {
                            ReasonBadge(title: entry.title, color: color(for: entry.reason))
                        }
                    }
                    Spacer(minLength: 4)
                    Text(item.lastActivityAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityLabel(
                            "Last activity \(item.lastActivityAt.formatted(.relative(presentation: .named)))"
                        )
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        if item.kind == .pullRequest {
            return item.isDraft ? .gray : .green
        }
        return .green
    }

    private var iconAccessibilityLabel: String {
        if item.kind == .pullRequest {
            return item.isDraft ? "Draft pull request" : "Pull request"
        }
        return "Issue"
    }

    private func color(for reason: AttentionReason) -> Color {
        switch reason {
        case .reviewRequested:
            return .orange
        case .assigned:
            return .blue
        case .mentioned:
            return .pink
        default:
            return .secondary
        }
    }
}

private struct ReasonBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
