import SwiftUI

/// Approvals: what JARVIS's agents need the owner to decide, a card each under its project, and a
/// collapsed list of what was answered lately. Every answer is signed on this phone
/// (`JarvisApprovalSigner`). The page reads again when it opens, when the app comes forward, on
/// pull and every 30 seconds (`JarvisApprovalsStore.watch`).
struct JarvisApprovalsView: View {
    /// The configured JARVIS server, for the session link "Open chat" uses.
    let server: URL

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = JarvisApprovalsStore.shared
    @State private var showsRecent = false

    var body: some View {
        content
            .navigationTitle(String(localized: "Approvals"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await store.watch()
            }
            .task { await JarvisApprovalsPush.prepare(asking: true) }
    }

    @ViewBuilder private var content: some View {
        if store.pending.isEmpty && store.recent.isEmpty, store.phase != .ready {
            switch store.phase {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Approvals Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }
                }
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let notice = store.notice { noticeRow(notice) }
                if store.pending.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing needs you", systemImage: "checkmark.seal")
                    } description: {
                        Text("When a JARVIS agent needs your decision, it shows up here.")
                    }
                    .accessibilityIdentifier("jarvisApprovals.empty")
                } else {
                    Text("\(store.pendingCount) waiting for you")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("jarvisApprovals.summary")
                }
                ForEach(store.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: group.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            JarvisApprovalCard(item: item, store: store, server: server)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                }
                if !store.recent.isEmpty { recentSection }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(reduceMotion ? nil : .snappy, value: store.pending.map(\.id))
        }
        .refreshable { await store.refresh() }
    }

    private func noticeRow(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").accessibilityHidden(true)
            Text(verbatim: notice).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(.footnote)
        .padding(12)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) { showsRecent.toggle() }
            } label: {
                HStack {
                    Text("Recent").font(.footnote.weight(.semibold)).textCase(.uppercase)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(showsRecent ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsRecent ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityIdentifier("jarvisApprovals.recent")
            if showsRecent {
                ForEach(store.recent) { item in
                    JarvisApprovalRecentRow(item: item, store: store)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let fingerprint = store.localFingerprint {
            Text("Signing key \(fingerprint)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .textSelection(.enabled)
                .accessibilityIdentifier("jarvisApprovals.key")
        }
    }
}

/// An answered request: its title, how it ended, and Retry when the host says it can run again.
private struct JarvisApprovalRecentRow: View {
    let item: JarvisApproval
    let store: JarvisApprovalsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(verbatim: JarvisApprovals.stateText(item.state))
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(item.state == "failed" ? Color.red : Color.secondary)
            }
            if let summary = item.summary {
                Text(verbatim: summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.cardErrors[item.id] {
                Text(verbatim: error.message).font(.footnote).foregroundStyle(.red)
            }
            if item.canRetry {
                Button("Retry") { Task { await store.decide(item, .retry) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.sending.contains(item.id))
                    .accessibilityIdentifier("jarvisApprovals.retry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
