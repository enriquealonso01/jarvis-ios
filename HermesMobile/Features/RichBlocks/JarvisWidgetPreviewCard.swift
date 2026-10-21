import SwiftUI

/// A widget JARVIS designed in a chat (requirement 8): a preview at the home screen's small and
/// medium sizes, and Add to Home Screen, which saves it for the JARVIS widget. A spec whose id is
/// already saved offers Update and Remove instead.
struct JarvisWidgetPreviewCard: View {
    let spec: JarvisWidgetSpec
    @State private var saved: JarvisWidgetSpec?
    @State private var showsHowTo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Home Screen Widget", systemImage: "square.grid.2x2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    preview(.small, width: 158)
                    preview(.medium, width: 338)
                }
            }
            if let data = spec.data, !data.isEmpty {
                Text("Live data from \(data), refreshed when you open JARVIS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    // Keep live values already fetched for a widget being redesigned.
                    var next = spec
                    if displayed != spec {
                        next.value = saved?.value; next.rows = saved?.rows; next.points = saved?.points
                        next.trend = saved?.trend; next.updated = saved?.updated
                    }
                    if JarvisWidgetStore.save(next) {
                        saved = next
                        showsHowTo = true
                    }
                } label: {
                    Label(saved == nil ? "Add to Home Screen" : "Update Widget", systemImage: "plus.square.on.square")
                }
                .buttonStyle(JarvisButtonStyle(.primary))
                .accessibilityIdentifier("widget.add")
                if saved != nil {
                    Button("Remove", role: .destructive) {
                        JarvisWidgetStore.remove(id: spec.id)
                        saved = nil
                        showsHowTo = false
                    }
                    .buttonStyle(JarvisButtonStyle(.ghost))
                    .accessibilityIdentifier("widget.remove")
                }
            }
            if showsHowTo {
                Text("Saved. To place it: touch and hold your Home Screen, tap Edit, then Add Widget, and choose JARVIS. To pick this one, touch and hold the widget and choose Edit Widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("widget.howTo")
            }
        }
        .jarvisCard()
        .onAppear { saved = JarvisWidgetStore.spec(id: spec.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("widget.preview")
    }

    /// The saved copy when it carries live values for this spec's data file, else the spec.
    private var displayed: JarvisWidgetSpec {
        if let saved, spec.data != nil, saved.data == spec.data { return saved }
        return spec
    }

    private func preview(_ size: JarvisWidgetContentView.Size, width: CGFloat) -> some View {
        JarvisWidgetContentView(spec: displayed, size: size)
            .padding(14)
            .frame(width: width, height: 158)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.tertiarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
    }
}

/// Lays each saved widget's live data file over its spec and redraws the widgets. Runs when the
/// app comes forward. A data file must sit in ~/JARVIS-Files, the folder Files from JARVIS reads.
enum JarvisWidgetRefresher {
    @MainActor static func refresh(server: URL, connection: BotConnection) async {
        let specs = JarvisWidgetStore.all()
        guard specs.contains(where: { $0.data != nil }) else { return }
        let http = HermesConnections.shared.connection(for: connection, server: server)
        var changed = false
        var next: [JarvisWidgetSpec] = []
        for spec in specs {
            guard let path = spec.data, isAllowed(path),
                  let body = try? await http.data(.fsReadText(path: path)),
                  let reply = try? JSONDecoder().decode(BotJSON.self, from: body),
                  reply["binary"].flag != true, let text = reply["text"].text,
                  let json = text.data(using: .utf8) else {
                next.append(spec)
                continue
            }
            let updated = spec.applying(dataFile: json)
            if updated != spec { changed = true }
            next.append(updated)
        }
        if changed { JarvisWidgetStore.write(next) }
    }

    static func isAllowed(_ path: String) -> Bool {
        path.hasPrefix(JarvisFiles.folder + "/") && !path.split(separator: "/").contains("..") && !path.contains("\0")
    }
}
