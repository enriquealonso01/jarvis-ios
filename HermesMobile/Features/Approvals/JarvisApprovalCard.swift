import SwiftUI

/// One request waiting for the owner: what is being asked, the evidence, the signed fields
/// (`type · subject`), the countdown, links, the box an action needs, and the buttons. Approve and
/// Deny answer a decision; Submit and Dismiss (a denial) answer an action.
struct JarvisApprovalCard: View {
    let item: JarvisApproval
    let store: JarvisApprovalsStore
    let server: URL

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var input = ""
    @State private var note = ""
    @State private var addsNote = false
    @FocusState private var focus: Field?

    private enum Field { case input, note }

    private var isSending: Bool { store.sending.contains(item.id) }
    private var error: JarvisApprovalsStore.CardError? { store.cardErrors[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let evidence = item.evidence { evidenceLine(evidence) }
            Text(verbatim: JarvisApprovalCard.signedLine(type: item.type, subject: item.subject))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let deadline = item.deadline { deadlineChip(deadline) }
            ForEach(item.links, id: \.self) { link in
                Button { openURL(link.url) } label: {
                    Label { Text(verbatim: link.label) } icon: { Image(systemName: "arrow.up.right.square") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if item.kind == .action, let box = item.input { inputField(box) }
            if addsNote {
                TextField("Note (optional)", text: $note)
                    .focused($focus, equals: .note)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
            }
            if let error, !error.field {
                Text(verbatim: error.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jarvisApprovals.card")
    }

    // MARK: - Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: item.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if item.adhoc {
                Text("ad hoc")
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemFill), in: Capsule())
            }
        }
    }

    private func evidenceLine(_ evidence: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if item.evidenceFromAgent {
                Text("agent says")
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(Color("AttentionApproval"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color("AttentionApproval").opacity(0.14), in: Capsule())
            }
            Text(verbatim: evidence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deadlineChip(_ deadline: Date) -> some View {
        Label {
            Text(verbatim: JarvisApprovals.deadlineText(deadline: deadline, now: store.now))
        } icon: {
            Image(systemName: "clock")
        }
        .font(AppFont.caption(weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(.secondarySystemFill), in: Capsule())
    }

    private func inputField(_ box: JarvisApproval.Input) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !box.label.isEmpty {
                Text(verbatim: box.label).font(.footnote.weight(.medium))
            }
            HStack(spacing: 8) {
                TextField(text: $input, axis: .vertical) { Text(verbatim: box.placeholder) }
                    .focused($focus, equals: .input)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("jarvisApprovals.input")
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Paste")
                    .accessibilityIdentifier("jarvisApprovals.paste")
            }
            if let error, error.field {
                Text(verbatim: error.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        // Large accessibility text stacks the buttons instead of squeezing them.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 10))
                                                         : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if isSending {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            if !addsNote {
                Button("Add note") { addsNote = true; focus = .note }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            if item.kind == .action {
                Button("Dismiss", role: .destructive) { answer(.deny) }
                    .accessibilityIdentifier("jarvisApprovals.deny")
                Button("Submit") { answer(.approve) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("jarvisApprovals.submit")
            } else {
                Button("Deny", role: .destructive) { answer(.deny) }
                    .accessibilityIdentifier("jarvisApprovals.deny")
                Button("Approve") { answer(.approve) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("jarvisApprovals.approve")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isSending)
    }

    @ViewBuilder private var footer: some View {
        if let session = item.session {
            Button {
                openChat(session)
            } label: {
                Label("Open chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("jarvisApprovals.openChat")
        }
    }

    // MARK: - Actions

    private func answer(_ decision: JarvisApprovals.Decision) {
        focus = nil
        Task { await store.decide(item, decision, input: input, note: note) }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string else { return }
        input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.clearError(for: item.id)
    }

    /// The agent's chat, through the same session link a notification or a Live Activity uses.
    private func openChat(_ session: JarvisApproval.Session) {
        let destination = HermesSessionDestination(server: server, profile: session.profile, key: session.id)
        AppIntentRouter.shared.requestDeepLink(HermesDeepLink.sessionURL(for: destination))
    }

    /// `type · subject`, the two fields the owner's signature covers.
    static func signedLine(type: String, subject: String) -> String {
        subject.isEmpty ? type : "\(type) · \(subject)"
    }
}
