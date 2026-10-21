import Foundation
import Observation

/// What the Command Center tab shows (requirement 7, exactly these five): cron jobs with issues,
/// subscription usage, a restart button, the project map and core vitals. Reads the JARVIS
/// Control Center routes the dashboard at jarvis.enriquecodes.com already serves
/// (`/api/control/zai_usage`, `/vitals`, `/knowledge_graph`, verified on the host's
/// `hermes_cli/web_routers/control_center.py`), Hermes's own `/api/cron/jobs`, and
/// `POST /api/gateway/restart`, all over the server's shared signed-in connection.
@MainActor
@Observable
final class CommandCenterModel {
    struct CronIssue: Identifiable, Equatable {
        let id: String
        let name: String
        let profile: String
        let detail: String
        let schedule: String?
    }

    /// One subscription: today the Z.AI GLM Coding Plan pool, one bar per window split by plan.
    struct Subscription: Identifiable, Equatable {
        struct Window: Identifiable, Equatable {
            struct Segment: Equatable { let plan: String; let percent: Double; let locked: Bool; let active: Bool }
            let id: String
            let label: String
            let percent: Double
            let effectivePercent: Double
            let resetInSeconds: Int?
            let segments: [Segment]
        }
        let id: String
        let title: String
        let status: String
        let detail: String?
        let windows: [Window]
    }

    struct Vitals: Equatable {
        var cpuPercent: Double?
        var memoryUsedMB: Double?
        var memoryTotalMB: Double?
        var diskUsedGB: Double?
        var diskTotalGB: Double?
        var uptimeSeconds: Double?
        var load: [Double] = []
    }

    struct Project: Identifiable, Equatable {
        let id: String
        let name: String
        let domain: String
        let nodes: Int
        let edges: Int
        let concepts: [String]
    }

    enum RestartState: Equatable { case idle, restarting, done, failed(String) }

    private(set) var cronIssues: [CronIssue] = []
    private(set) var cronError: String?
    private(set) var subscriptions: [Subscription] = []
    private(set) var usageError: String?
    private(set) var vitals: Vitals?
    private(set) var vitalsError: String?
    private(set) var projects: [Project] = []
    private(set) var projectsError: String?
    private(set) var restartState = RestartState.idle
    private(set) var isLoading = false
    private(set) var loadedAt: Date?

    let server: URL
    let connection: BotConnection
    private var http: HermesConnection { HermesConnections.shared.connection(for: connection, server: server) }

    init(server: URL, connection: BotConnection) {
        self.server = server
        self.connection = connection
    }

    func load() async {
        isLoading = true
        defer { isLoading = false; loadedAt = Date() }
        async let cron: Void = loadCron()
        async let usage: Void = loadUsage()
        async let vitals: Void = loadVitals()
        async let map: Void = loadProjects()
        _ = await (cron, usage, vitals, map)
    }

    func restart() async {
        restartState = .restarting
        do {
            _ = try await http.data(.restartGateway, accepting: 200..<300)
            restartState = .done
        } catch {
            restartState = .failed(error.localizedDescription)
        }
    }

    /// The draft a fix session opens with: what failed, so JARVIS can start right away.
    static func fixPrompt(for issue: CronIssue) -> String {
        "The scheduled task \"\(issue.name)\" (cron job \(issue.id)) has a problem: \(issue.detail)\n\n"
            + "Investigate why it is failing, fix it, and confirm the next run works."
    }

    // MARK: Loading

    private func loadCron() async {
        do {
            let jobs = try await HermesCronClient(http: http).cronJobs().jobs
            cronIssues = jobs.compactMap(Self.issue(for:))
            cronError = nil
        } catch {
            cronError = error.localizedDescription
        }
    }

    /// A job with a problem: its last run errored, delivery failed, or Hermes flags it.
    static func issue(for job: CronJob) -> CronIssue? {
        let error = [job.lastError, job.lastDeliveryError].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let failed = job.lastStatus == "error" || job.state == "error" || job.status == .needsAttention
            || job.lastDeliveryError?.isEmpty == false
        guard failed, let id = job.jobId, !id.isEmpty else { return nil }
        let detail = error ?? (job.status == .needsAttention ? "it needs attention" : "its last run failed")
        return CronIssue(id: id, name: job.displayName, profile: job.profile ?? "default", detail: detail,
                         schedule: job.scheduleText)
    }

    private func control(_ endpoint: String) async throws -> BotJSON {
        try JSONDecoder().decode(BotJSON.self, from: try await http.data(.jarvisControl(endpoint: endpoint)))
    }

    private func loadUsage() async {
        do {
            let reply = try await control("zai_usage")
            subscriptions = [Self.zaiSubscription(reply)]
            usageError = nil
        } catch {
            usageError = error.localizedDescription
        }
    }

    static func zaiSubscription(_ reply: BotJSON) -> Subscription {
        let windows: [Subscription.Window] = (reply["windows"].list ?? []).compactMap { window in
            guard let key = window["key"].text else { return nil }
            let segments = (window["segments"].list ?? []).map { segment in
                Subscription.Window.Segment(plan: segment["id"].text ?? "?",
                                            percent: segment["percent"].number ?? 0,
                                            locked: segment["locked"].flag == true,
                                            active: segment["active"].flag == true)
            }
            return Subscription.Window(id: key, label: window["label"].text ?? key,
                                       percent: window["percent"].number ?? 0,
                                       effectivePercent: window["effective_percent"].number ?? window["percent"].number ?? 0,
                                       resetInSeconds: window["reset_in_seconds"].integer, segments: segments)
        }
        let plans = reply["plans"].integer ?? 0
        let usable = reply["usable"].integer ?? 0
        let status = reply["status"].text ?? "unknown"
        var detail = "\(usable) of \(plans) plans usable"
        if let level = reply["level"].text { detail += " · \(level)" }
        if let back = reply["back_in_seconds"].integer { detail += " · back in \(Self.duration(back))" }
        if let error = reply["error"].text, !error.isEmpty { detail = error }
        return Subscription(id: "zai", title: "Z.AI GLM Coding Plan", status: status, detail: detail, windows: windows)
    }

    private func loadVitals() async {
        do {
            let reply = try await control("vitals")
            vitals = Vitals(cpuPercent: reply["cpu_pct"].number, memoryUsedMB: reply["mem_used_mb"].number,
                            memoryTotalMB: reply["mem_total_mb"].number, diskUsedGB: reply["disk_used_gb"].number,
                            diskTotalGB: reply["disk_total_gb"].number, uptimeSeconds: reply["uptime_seconds"].number,
                            load: (reply["load"].list ?? []).compactMap(\.number))
            vitalsError = nil
        } catch {
            vitalsError = error.localizedDescription
        }
    }

    private func loadProjects() async {
        do {
            let reply = try await control("knowledge_graph")
            projects = (reply["repos"].list ?? []).compactMap { repo in
                guard let name = repo["name"].text else { return nil }
                return Project(id: name, name: name, domain: repo["domain"].text ?? "system",
                               nodes: repo["nodes"].integer ?? 0, edges: repo["edges"].integer ?? 0,
                               concepts: (repo["concepts"].list ?? []).compactMap(\.text))
            }
            projectsError = reply["available"].flag == false ? String(localized: "The project map has not been built yet.") : nil
        } catch {
            projectsError = error.localizedDescription
        }
    }

    static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}
