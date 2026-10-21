import SceneKit
import SwiftUI

/// The Command Center tab (requirement 7): exactly cron jobs with issues (each opening a session
/// to fix it), subscription usage, Restart JARVIS, the 3D project map and core vitals.
struct CommandCenterView: View {
    let home: HermesHome
    @State private var model: CommandCenterModel
    @State private var fixChat: HermesSessionChat?
    @State private var confirmingRestart = false
    @State private var showsFullMap = false

    init(home: HermesHome, server: URL, connection: BotConnection) {
        self.home = home
        _model = State(initialValue: CommandCenterModel(server: server, connection: connection))
    }

    var body: some View {
        List {
            Section {
                SessionsHeader(logoColor: HeaderLogoColor.color(for: JarvisServer.headerColorHex), avatar: home.avatar,
                               isSearchDisabled: true, openSearch: {})
                    .sessionsTopChromeListRow()
            }
            cronSection
            usageSection
            restartSection
            mapSection
            vitalsSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load() }
        .task { await model.load() }
        .modifier(HermesHomeChrome(home: home, filter: { refreshButton }, newChat: { EmptyView() }))
        .navigationDestination(item: $fixChat) { chat in
            ChatView(hermesSession: chat)
        }
        .sheet(isPresented: $showsFullMap) {
            NavigationStack {
                ProjectMapView(projects: model.projects)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Project Map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsFullMap = false } } }
            }
        }
        .confirmationDialog("Restart JARVIS?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await model.restart() } }
        } message: {
            Text("Restarts the JARVIS gateway. Running turns stop, and WhatsApp, Signal and the other channels reconnect within a minute.")
        }
        .accessibilityIdentifier("commandCenter.list")
    }

    private var refreshButton: some View {
        Button {
            Task { await model.load() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isLoading)
    }

    // MARK: 1. Cron jobs with issues

    private var cronSection: some View {
        Section {
            if let error = model.cronError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
            } else if model.cronIssues.isEmpty {
                Label("Every scheduled task is healthy.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            ForEach(model.cronIssues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: issue.name).font(.headline)
                    Text(verbatim: issue.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    Button {
                        openFixSession(for: issue)
                    } label: {
                        Label("Fix with JARVIS", systemImage: "wrench.and.screwdriver")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(JarvisBrand.deepTeal)
                    .accessibilityIdentifier("commandCenter.fix.\(issue.id)")
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Scheduled tasks with issues")
        }
    }

    private func openFixSession(for issue: CommandCenterModel.CronIssue) {
        let target = ConversationTarget.new(profile: issue.profile)
        ChatDraftStore.shared.setDraft(CommandCenterModel.fixPrompt(for: issue),
                                       for: target.draftKey(server: model.server, connectionID: model.connection.id))
        fixChat = HermesSessionChat(server: model.server, connection: model.connection, target: target)
    }

    // MARK: 2. Subscription usage

    private var usageSection: some View {
        Section {
            if let error = model.usageError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.subscriptions) { subscription in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(verbatim: subscription.title).font(.headline)
                        Spacer()
                        Text(verbatim: subscription.status.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(subscription.status == "working" ? Color.green : Color.orange)
                    }
                    if let detail = subscription.detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(subscription.windows) { window in
                        UsageWindowRow(window: window)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Subscription usage")
        }
    }

    // MARK: 3. Restart

    private var restartSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingRestart = true
            } label: {
                HStack {
                    Label("Restart JARVIS", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    switch model.restartState {
                    case .restarting: ProgressView()
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .idle: EmptyView()
                    }
                }
            }
            .disabled(model.restartState == .restarting)
            .accessibilityIdentifier("commandCenter.restart")
            if case .failed(let why) = model.restartState {
                Text(verbatim: why).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 4. Project map

    private var mapSection: some View {
        Section {
            if let error = model.projectsError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
            }
            if !model.projects.isEmpty {
                ProjectMapView(projects: model.projects)
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("commandCenter.map")
                Button {
                    showsFullMap = true
                } label: {
                    Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        } header: {
            Text("Project map")
        } footer: {
            if !model.projects.isEmpty {
                Text(verbatim: "\(model.projects.count) projects · drag to orbit, pinch to zoom")
            }
        }
    }

    // MARK: 5. Core vitals

    private var vitalsSection: some View {
        Section {
            if let error = model.vitalsError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
            }
            if let vitals = model.vitals {
                VitalRow(title: "CPU", value: vitals.cpuPercent.map { "\(Int($0.rounded()))%" },
                         fraction: vitals.cpuPercent.map { $0 / 100 })
                VitalRow(title: "Memory",
                         value: pair(vitals.memoryUsedMB.map { $0 / 1024 }, vitals.memoryTotalMB.map { $0 / 1024 }, unit: "GB"),
                         fraction: ratio(vitals.memoryUsedMB, vitals.memoryTotalMB))
                VitalRow(title: "Disk", value: pair(vitals.diskUsedGB, vitals.diskTotalGB, unit: "GB"),
                         fraction: ratio(vitals.diskUsedGB, vitals.diskTotalGB))
                if !vitals.load.isEmpty {
                    LabeledContent("Load") {
                        Text(verbatim: vitals.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    }
                }
                if let uptime = vitals.uptimeSeconds {
                    LabeledContent("Uptime") { Text(verbatim: CommandCenterModel.duration(Int(uptime))) }
                }
            }
        } header: {
            Text("Core vitals")
        } footer: {
            if let loadedAt = model.loadedAt {
                Text(verbatim: "Updated \(loadedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    private func pair(_ used: Double?, _ total: Double?, unit: String) -> String? {
        guard let used else { return nil }
        guard let total else { return String(format: "%.1f %@", used, unit) }
        return String(format: "%.1f / %.0f %@", used, total, unit)
    }

    private func ratio(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return used / total
    }
}

private struct UsageWindowRow: View {
    let window: CommandCenterModel.Subscription.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: window.label.capitalized).font(.subheadline)
                Spacer()
                Text(verbatim: "\(Int(window.percent.rounded()))%").font(.subheadline.monospacedDigit())
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    let segments: [CommandCenterModel.Subscription.Window.Segment] = window.segments.isEmpty
                        ? [CommandCenterModel.Subscription.Window.Segment(plan: "", percent: window.percent, locked: false, active: true)]
                        : window.segments
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let width = (geometry.size.width - CGFloat(segments.count - 1) * 2) / CGFloat(segments.count)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule()
                                .fill(segment.locked ? Color.orange : (segment.percent >= 90 ? Color.red : JarvisBrand.jarvisCyan))
                                .frame(width: max(0, width * min(1, (segment.locked ? 100 : segment.percent) / 100)))
                        }
                        .frame(width: width)
                    }
                }
            }
            .frame(height: 8)
            if let reset = window.resetInSeconds {
                Text(verbatim: "Resets in \(CommandCenterModel.duration(reset))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VitalRow: View {
    let title: LocalizedStringKey
    let value: String?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) { Text(verbatim: value ?? "—") }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(fraction > 0.85 ? .red : JarvisBrand.jarvisCyan)
            }
        }
    }
}

/// The 3D project map, like the Control Center's knowledge map: one glowing sphere per project
/// (size by its graph's node count, colour by domain), grouped around its domain's hub, with its
/// key concepts as small satellites. SceneKit with the built-in orbit/zoom camera; it renders only
/// while touched (no continuous animation).
struct ProjectMapView: UIViewRepresentable {
    let projects: [CommandCenterModel.Project]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(JarvisBrand.obsidian)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.scene = Self.scene(for: projects)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene = Self.scene(for: projects)
    }

    static func color(for domain: String) -> UIColor {
        switch domain {
        case "krendora": return UIColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 1)
        case "ticketflipping": return UIColor(red: 0.55, green: 0.45, blue: 0.95, alpha: 1)
        case "personal": return UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1)
        default: return UIColor(JarvisBrand.jarvisCyan)
        }
    }

    static func scene(for projects: [CommandCenterModel.Project]) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode
        let core = SCNNode(geometry: SCNSphere(radius: 0.6))
        core.geometry?.firstMaterial?.emission.contents = UIColor(JarvisBrand.iceCore)
        root.addChildNode(core)

        let domains = Array(Set(projects.map(\.domain))).sorted()
        let maxNodes = Double(projects.map(\.nodes).max() ?? 1)
        for (domainIndex, domain) in domains.enumerated() {
            let angle = Double(domainIndex) / Double(max(domains.count, 1)) * 2 * .pi
            let hub = SCNVector3(Float(cos(angle) * 6), Float(sin(Double(domainIndex) * 1.7) * 2), Float(sin(angle) * 6))
            let color = color(for: domain)
            root.addChildNode(line(from: SCNVector3Zero, to: hub, color: color.withAlphaComponent(0.35)))
            let members = projects.filter { $0.domain == domain }
            for (index, project) in members.enumerated() {
                let a = Double(index) / Double(max(members.count, 1)) * 2 * .pi + Double(domainIndex)
                let ring = 1.6 + Double(index % 3) * 0.7
                let position = SCNVector3(hub.x + Float(cos(a) * ring), hub.y + Float(sin(a * 2) * 0.8),
                                          hub.z + Float(sin(a) * ring))
                let radius = 0.18 + 0.55 * sqrt(Double(project.nodes) / maxNodes)
                let sphere = SCNSphere(radius: radius)
                sphere.firstMaterial?.diffuse.contents = color
                sphere.firstMaterial?.emission.contents = color.withAlphaComponent(0.6)
                let node = SCNNode(geometry: sphere)
                node.position = position
                root.addChildNode(node)
                root.addChildNode(line(from: hub, to: position, color: color.withAlphaComponent(0.5)))

                let label = SCNText(string: project.name, extrusionDepth: 0.01)
                label.font = UIFont.systemFont(ofSize: 0.4, weight: .semibold)
                label.firstMaterial?.diffuse.contents = UIColor.white
                let labelNode = SCNNode(geometry: label)
                labelNode.position = SCNVector3(position.x, position.y + Float(radius) + 0.15, position.z)
                labelNode.constraints = [SCNBillboardConstraint()]
                labelNode.pivot = SCNMatrix4MakeTranslation(Float(project.name.count) * 0.1, 0, 0)
                root.addChildNode(labelNode)

                for (conceptIndex, _) in project.concepts.prefix(4).enumerated() {
                    let c = Double(conceptIndex) / 4 * 2 * .pi
                    let satellite = SCNNode(geometry: SCNSphere(radius: 0.06))
                    satellite.geometry?.firstMaterial?.emission.contents = UIColor(JarvisBrand.iceCore)
                    satellite.position = SCNVector3(position.x + Float(cos(c) * (radius + 0.35)), position.y,
                                                    position.z + Float(sin(c) * (radius + 0.35)))
                    root.addChildNode(satellite)
                }
            }
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 200
        camera.position = SCNVector3(0, 7, 18)
        camera.look(at: SCNVector3Zero)
        root.addChildNode(camera)
        return scene
    }

    private static func line(from start: SCNVector3, to end: SCNVector3, color: UIColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: [start, end])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.emission.contents = color
        geometry.firstMaterial?.diffuse.contents = color
        return SCNNode(geometry: geometry)
    }
}
