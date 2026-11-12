import Foundation
import Observation
import UIKit
import UserNotifications

/// The one list of approvals the home's row, the Approvals page and the app icon badge share. It
/// reads again when the app comes forward, when the page opens, on pull, when an approval push
/// arrives, and every 30 seconds while the home or the page is on screen (`watch`); signs and sends
/// the owner's answers; and keeps the host holding this phone's push token and public signing key.
@MainActor
@Observable
final class JarvisApprovalsStore {
    static let shared = JarvisApprovalsStore()

    enum Phase: Equatable {
        case loading, ready, failed(String)
    }

    /// Why a card's last answer did not go through; `field` puts it by the input box.
    struct CardError: Equatable {
        let message: String
        let field: Bool
    }

    static let pollInterval: Duration = .seconds(30)
    /// A poll tick within this long of a read does nothing; a pull, a push or opening the page always reads.
    static let minimumGap: TimeInterval = 10

    private(set) var pending: [JarvisApproval] = []
    private(set) var recent: [JarvisApproval] = []
    private(set) var phase = Phase.loading
    /// The fingerprint the host holds for this phone's key; nil when it holds none.
    private(set) var serverFingerprint: String?
    private(set) var sending: Set<String> = []
    private(set) var cardErrors: [String: CardError] = [:]
    /// A sentence for the top of the page: an answer the host says was already settled.
    var notice: String?
    /// A tapped approval notification asks for the page; the home opens it and clears this.
    var wantsOpen = false

    @ObservationIgnored private let api: any JarvisApprovalsAPI
    @ObservationIgnored private let makeSigner: () throws -> JarvisApprovalSigner
    @ObservationIgnored private let setBadge: (Int) -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var signer: JarvisApprovalSigner?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var alertRegistered = false
    @ObservationIgnored private var apnsToken: String?
    @ObservationIgnored private var isRegistering = false
    /// Host time minus phone time at the last read, so a card's countdown and a signature's
    /// expiry follow the host's clock.
    @ObservationIgnored private var clockSkew: TimeInterval = 0
    @ObservationIgnored private var didPreparePush = false

    private static let tokenKey = "jarvis.approvals.alertToken"

    init(api: (any JarvisApprovalsAPI)? = nil,
         signer: @escaping () throws -> JarvisApprovalSigner = { try JarvisApprovalSigner.onThisPhone() },
         setBadge: @escaping (Int) -> Void = JarvisApprovalsStore.setIconBadge,
         defaults: UserDefaults = .standard) {
        self.api = api ?? JarvisApprovalsBridge()
        makeSigner = signer
        self.setBadge = setBadge
        self.defaults = defaults
    }

    var pendingCount: Int { pending.count }
    var groups: [JarvisApprovals.Group] { JarvisApprovals.groups(pending) }
    /// Host time, for a card's countdown.
    var now: Date { Date().addingTimeInterval(clockSkew) }
    /// This phone's key fingerprint, or nil when the Keychain can't give the key.
    var localFingerprint: String? { try? currentSigner().fingerprint }

    // MARK: - Reading

    /// Reads the list. A read already under way is joined, not repeated; `force: false` (a poll tick)
    /// skips a read that is not due.
    func refresh(force: Bool = true) async {
        if let inFlight { await inFlight.value; return }
        if !force, let lastRead, Date().timeIntervalSince(lastRead) < Self.minimumGap { return }
        let task = Task { await self.load() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Reads now, then every 30 seconds until cancelled: the home's and the page's `.task`.
    func watch() async {
        if !didPreparePush {
            didPreparePush = true
            await JarvisApprovalsPush.prepare(asking: false)
        }
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await refresh(force: false)
        }
    }

    private func load() async {
        do {
            apply(try await api.list())
            hasLoaded = true
            phase = .ready
            lastRead = Date()
            await syncRegistration()
        } catch {
            // A read that fails keeps what the list already shows; only a first read has nothing to show.
            if !hasLoaded { phase = .failed(error.localizedDescription) }
        }
    }

    private func apply(_ snapshot: JarvisApprovals.Snapshot) {
        pending = snapshot.pending
        recent = JarvisApprovals.recentOrder(snapshot.recent)
        serverFingerprint = snapshot.keyFingerprint
        alertRegistered = snapshot.alertRegistered
        if let host = snapshot.now { clockSkew = host.timeIntervalSinceNow }
        let open = Set(pending.map(\.id)).union(recent.map(\.id))
        cardErrors = cardErrors.filter { open.contains($0.key) }
        setBadge(pending.count)
    }

    // MARK: - Answering

    /// Signs and sends the owner's answer to `item`. On success the card leaves the pending list
    /// for the host's returned item; a refusal leaves a sentence by the card (`cardErrors`).
    func decide(_ item: JarvisApproval, _ decision: JarvisApprovals.Decision, input: String? = nil, note: String? = nil) async {
        guard !sending.contains(item.id) else { return }
        let typed = (item.kind == .action && decision != .deny) ? JarvisApprovals.firstText(input) : nil
        if item.kind == .action, decision != .deny, item.input?.required ?? true, typed == nil {
            cardErrors[item.id] = CardError(message: String(localized: "Fill in the box first."), field: true)
            return
        }
        sending.insert(item.id)
        cardErrors[item.id] = nil
        notice = nil
        defer { sending.remove(item.id) }
        do {
            let exp = Int(now.timeIntervalSince1970) + JarvisApprovals.signatureLifetime
            let signature = try currentSigner().sign(id: item.id, type: item.type, subject: item.subject,
                                                     decision: decision, input: typed, exp: exp)
            let body = JarvisApprovals.decisionBody(decision: decision, signature: signature, exp: exp, input: typed, note: note)
            let updated = try await api.decide(id: item.id, body: body)
            settle(item, as: updated)
            Task { await refresh() }
        } catch let refusal as JarvisApprovals.Refusal {
            await handle(refusal, for: item)
        } catch {
            cardErrors[item.id] = CardError(message: error.localizedDescription, field: false)
        }
    }

    /// The card leaves the list it was in; the host's returned item goes where its state says.
    func settle(_ item: JarvisApproval, as updated: JarvisApproval?) {
        pending.removeAll { $0.id == item.id }
        recent.removeAll { $0.id == item.id }
        if let updated {
            if updated.isPending { pending.append(updated) } else { recent = JarvisApprovals.recentOrder(recent + [updated]) }
        }
        setBadge(pending.count)
    }

    private func handle(_ refusal: JarvisApprovals.Refusal, for item: JarvisApproval) async {
        let detail = refusal.errorDescription ?? ""
        switch refusal.status {
        case 403:
            cardErrors[item.id] = CardError(message: String(localized: "This phone's key is not registered"), field: false)
            await syncRegistration(forceKey: true)
        case 409:
            cardErrors[item.id] = CardError(message: detail, field: false)
            notice = detail
            await refresh()
        case 422:
            cardErrors[item.id] = CardError(message: detail, field: true)
        default:
            cardErrors[item.id] = CardError(message: detail, field: false)
        }
    }

    func clearError(for id: String) {
        cardErrors[id] = nil
    }

    // MARK: - Registration

    /// The APNs token iOS gave this phone (lowercase hex); the host gets it now or on the next read.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        apnsToken = JarvisApprovalSigner.hex(deviceToken)
        Task { await syncRegistration() }
    }

    /// Tells the host this phone's push token and public key, whichever it lacks. Waits for a read,
    /// which says what the host holds.
    private func syncRegistration(forceKey: Bool = false) async {
        guard hasLoaded, !isRegistering else { return }
        isRegistering = true
        defer { isRegistering = false }
        let signer = try? currentSigner()
        let key = signer.flatMap { forceKey || serverFingerprint != $0.fingerprint ? $0.publicKeyBase64 : nil }
        let token = apnsToken.flatMap { $0 != defaults.string(forKey: Self.tokenKey) || !alertRegistered ? $0 : nil }
        guard key != nil || token != nil else { return }
        do {
            try await api.register(alertToken: token, signingKey: key)
            if let token { defaults.set(token, forKey: Self.tokenKey); alertRegistered = true }
            if key != nil { serverFingerprint = signer?.fingerprint }
        } catch {
            JarvisClientLog.record("approvals", "register failed (\(type(of: error)))", path: "/bridge/approvals/register")
        }
    }

    private func currentSigner() throws -> JarvisApprovalSigner {
        if let signer { return signer }
        let made = try makeSigner()
        signer = made
        return made
    }

    // MARK: - Icon badge

    nonisolated static func setIconBadge(_ count: Int) {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
}

/// Approval notifications: asking permission, registering for the push token, and reading a push.
@MainActor
enum JarvisApprovalsPush {
    /// `{"jarvis": {"kind": "approval", ...}}` is an approval push, whatever else it carries.
    static func isApproval(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["jarvis"] as? [String: Any])?["kind"] as? String == "approval"
    }

    /// Asks iOS for a push token once notifications are allowed. With `asking` and no answer yet it
    /// asks for permission first (alerts, sounds and the icon badge). A Debug build pointed at the
    /// stub bridge (`JarvisBridgeAddress`) never asks: the Maestro lane has no push.
    static func prepare(asking: Bool) async {
        guard JarvisCallEndpoints.qaBridgeOverride == nil else { return }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .denied:
            return
        case .notDetermined:
            guard asking, (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        default:
            break
        }
        UIApplication.shared.registerForRemoteNotifications()
    }
}
