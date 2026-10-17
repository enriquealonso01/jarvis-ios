import Foundation

/// FeaturesRuns stub (features #26–#33 land here from M3). Pure run-state
/// model: status cards, plan checklist, approval gates.
public enum RunPhase: String, Sendable, Equatable, Codable {
    case running
    case needsApproval
    case done
    case failed
}

public struct RunStep: Sendable, Equatable, Identifiable, Codable {
    public var id: Int
    public var title: String
    public var completed: Bool

    public init(id: Int, title: String, completed: Bool = false) {
        self.id = id
        self.title = title
        self.completed = completed
    }
}

public struct AgentRun: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var title: String
    public var phase: RunPhase
    public var steps: [RunStep]

    public init(id: UUID = UUID(), title: String, phase: RunPhase = .running, steps: [RunStep] = []) {
        self.id = id
        self.title = title
        self.phase = phase
        self.steps = steps
    }

    /// "Krendora orders — step 3/5" style label for Live Activity (feature #30).
    public var progressLabel: String {
        let done = steps.filter(\.completed).count
        return "\(title) — step \(done)/\(steps.count)"
    }

    public mutating func completeStep(_ id: Int) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].completed = true }
        if steps.allSatisfy(\.completed), phase == .running { phase = .done }
    }
}
