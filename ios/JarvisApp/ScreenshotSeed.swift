import SwiftUI
import Persistence
import FeaturesChat
import DesignSystem

#if DEBUG
/// CI screenshot lane + feel-review prep: seeds deterministic demo content so
/// a simulator can land straight on the real v2 surfaces (Item 3 sidebar shell,
/// Item 8 transcript, Item 4 composer, Item 11 rich blocks).
///
/// Compiled in DEBUG only and INERT unless the process is launched with
/// `-SCREENSHOT_SEED` (simctl launch args). Normal installs never execute any
/// of this — the launch-argument gate is checked before anything is touched.
///
/// The app target compiles with default-MainActor isolation, so the whole
/// enum is explicitly @MainActor and every entry point respects that:
/// `bootstrapIfNeeded` runs inside MainActor.assumeIsolated from
/// JarvisAppMain.main (synchronously, BEFORE AuthStore/ServerConfig snapshot
/// Keychain/UserDefaults), and `seedStore` runs as the app's first main-actor
/// Task from JarvisApp.init — strictly before V2SidebarShell's own .task
/// restores state (FIFO on the main actor), so the seeded sidebar-open flag
/// and selected conversation win the restore.
@MainActor
enum ScreenshotSeed {

    private static let seedArg = "-SCREENSHOT_SEED"
    private static let sidebarOpenArg = "-SCREENSHOT_SIDEBAR_OPEN"
    /// Optional UUID string: which seeded conversation to select on restore.
    private static let selectArg = "-SCREENSHOT_SELECT"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(seedArg)
    }

    /// Deterministic conversation ids — the screenshot lane asserts on these.
    /// (Hex-valid UUIDs: a non-hex placeholder like "DEMO…" would make
    /// UUID(uuidString:) nil and the force-unwrap crash at first use.)
    private static let breckConversation = UUID(uuidString: "D3EA0000-0000-0000-0000-000000000001")!
    private static let krendoraConversation = UUID(uuidString: "D3EA0000-0000-0000-0000-000000000002")!
    private static let voiceConversation = UUID(uuidString: "D3EA0000-0000-0000-0000-000000000003")!

    /// Synchronous half of the seed (Keychain + UserDefaults server config).
    /// Runs before the App struct initializes — see JarvisAppMain.main().
    static func bootstrapIfNeeded() {
        guard isActive else { return }
        AuthStore.saveString("jarvis.auth.access", "screenshot-demo-token")
        AuthStore.saveString("jarvis.auth.refresh", "screenshot-demo-refresh")
        AuthStore.saveString("jarvis.auth.expires",
                             String(Int(Date().timeIntervalSince1970) + 7 * 24 * 3600))
        let cfg = ServerConfigValues(baseURL: "https://jarvis.enriquecodes.com")
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: "jarvis.server.config.v1")
        }
    }

    /// Async GRDB half of the seed: demo conversations/messages + sidebar KV.
    /// Fired as JarvisApp.init's first Task — the sidebar shell's restore
    /// task is created later, so this always lands first.
    static func seedStore() async {
        guard isActive else { return }

        // Sidebar restoration state — which surface greets the screenshot.
        // Content MUST be inserted before the selection write: the guard
        // verifies the row exists, and restoreState nils a selection whose
        // row is missing.
        let args = ProcessInfo.processInfo.arguments
        let sidebarOpen = args.contains(sidebarOpenArg)
        guard let store = LocalStoreBootstrap.shared.store else { return }

        // Demo content (idempotent: fixed ids upsert over themselves).
        await seedBreckenridge(store)
        await seedKrendora(store)
        await seedVoice(store)

        await store.setAppState(sidebarOpen, key: Tokens.Sidebar.Keys.sidebarOpen)
        // Default to the Breck transcript; -SCREENSHOT_SELECT <uuid> overrides.
        let selected = args.firstIndex(of: selectArg).flatMap({ args[args.index(after: $0)] })
            ?? breckConversation.uuidString
        if let id = UUID(uuidString: selected), await store.get(id: id) != nil {
            await store.setAppState(id.uuidString, key: Tokens.Sidebar.Keys.lastSelection)
        }
    }

    // MARK: - Conversations

    private static func seedBreckenridge(_ store: PersistenceStore) async {
        await store.upsert(StoredConversation(
            id: breckConversation,
            title: "Breck day 3 — trip planning",
            updatedAt: Date().addingTimeInterval(-3600),
            pinned: true,
            lastMessagePreview: "Checklist is set — lift tickets are in your wallet."))

        await store.upsert(StoredMessage(
            conversationID: breckConversation,
            role: .user,
            content: "Plan day 3 at Breck for us — breakfast near the gondola, then something mellow for the afternoon.",
            status: .sent))

        await store.upsert(StoredMessage(
            conversationID: breckConversation,
            role: .assistant,
            content: "Day three is the mellow one: breakfast at 8, gondola by 9:15, and I kept the whole afternoon on blues so your knees get a break before the drive home.",
            status: .sent))

        // Rich envelope (Item 11): heading + table + notice + buttons +
        // chart + checklist + citation in ONE assistant row.
        let rich = RichBlocksEnvelope(
            messageId: "demo-breck-rich-1",
            conversationId: breckConversation.uuidString,
            blocks: [
                RichBlock(content: .heading(text: "Day 3 — Breckenridge", level: 2),
                          fallbackText: "Day 3 — Breckenridge"),
                RichBlock(content: .table(
                    headers: ["Time", "Stop", "Notes"],
                    rows: [
                        ["8:00", "Clint's Bakery", "Coffee + kolaches, 2 blocks from the gondola"],
                        ["9:15", "Peak 8 gondola", "Buy lift tickets — line is shortest before 9:30"],
                        ["11:30", "Four O'Clock Run", "Cruisy blue all the way to town"],
                        ["13:00", "Giampietro Pasta", "Early lunch, no reservation needed"],
                    ]),
                          fallbackText: "Day 3 itinerary table"),
                RichBlock(content: .notice(
                    tone: .warning,
                    text: "Wind holds are possible on Peak 6 tomorrow — this plan stays on Peak 7/8 terrain."),
                          fallbackText: "Wind hold warning for Peak 6"),
                RichBlock(content: .buttonGroup(buttons: [
                    RichBlockAction(id: "breck-lift", label: "Buy lift tickets", kind: .openUrl),
                    RichBlockAction(id: "breck-map", label: "Open trail map", kind: .openUrl),
                ]),
                          fallbackText: "Buy lift tickets, Open trail map"),
                RichBlock(content: .chart(
                    kind: .bar,
                    title: "Snow depth by base area (in)",
                    points: [
                        RichChartPoint(label: "Peak 7", value: 24),
                        RichChartPoint(label: "Peak 8", value: 27),
                        RichChartPoint(label: "Peak 9", value: 31),
                        RichChartPoint(label: "Peak 6", value: 19),
                    ]),
                          fallbackText: "Snow depth chart: Peak 7 24, Peak 8 27, Peak 9 31, Peak 6 19"),
                RichBlock(content: .checklist(items: [
                    RichChecklistItem(text: "Lift tickets in wallet", isChecked: true),
                    RichChecklistItem(text: "Goggles packed", isChecked: true),
                    RichChecklistItem(text: "Hand warmers for Jessica", isChecked: false),
                    RichChecklistItem(text: "Book scooter parking", isChecked: false),
                ]),
                          fallbackText: "4-item day-3 checklist"),
                RichBlock(content: .citation(
                    title: "Breckenridge trail status",
                    url: RichBlocks.safeURL("https://www.breckenridge.com/the-trail/the-terrain/")!),
                          fallbackText: "Breckenridge trail status"),
            ])
        if let body = try? rich.encodedData(), let json = String(data: body, encoding: .utf8) {
            await store.upsert(StoredMessage(
                conversationID: breckConversation,
                role: .assistant,
                content: "```jarvis-rich\n" + json + "\n```",
                status: .sent))
        }

        await store.upsert(StoredMessage(
            conversationID: breckConversation,
            role: .user,
            content: "Perfect. And remind Jessica about the hand warmers the night before.",
            status: .sent))
        await store.upsert(StoredMessage(
            conversationID: breckConversation,
            role: .assistant,
            content: "Done — I'll ping her the evening of the 30th. Anything else for the trip board?",
            status: .sent))
    }

    private static func seedKrendora(_ store: PersistenceStore) async {
        await store.upsert(StoredConversation(
            id: krendoraConversation,
            title: "Pedal trainer — ads check",
            updatedAt: Date().addingTimeInterval(-86_400),
            lastMessagePreview: "Spend $41.20, 3 orders, ROAS 4.1"))

        await store.upsert(StoredMessage(
            conversationID: krendoraConversation,
            role: .user,
            content: "How did the pedal trainer ads do yesterday?",
            status: .sent))

        // Markdown + code in one row, poll/form in another: exercises the
        // native markdown path and the interactive renderers.
        let md = RichBlocksEnvelope(
            messageId: "demo-kr-md-1",
            conversationId: krendoraConversation.uuidString,
            blocks: [
                RichBlock(content: .markdown(
                    "### Yesterday — pedal trainer\n- **Spend:** $41.20\n- **Orders:** 3\n- **ROAS:** 4.1×  (target ≥ 2.5×)\n\nWinner is the *knee-saver angle* creative again — CTR 2.8% vs 1.1% on the unboxing cut."),
                          fallbackText: "Yesterday pedal trainer: spend $41.20, 3 orders, ROAS 4.1x"),
                RichBlock(content: .code(
                    code: """
                    SELECT order_id, revenue
                    FROM orders
                    WHERE created_at::date = CURRENT_DATE - 1
                      AND source = 'meta-ads';
                    """,
                    language: "sql"),
                          fallbackText: "SQL: yesterday's meta-ads orders"),
            ])
        if let body = try? md.encodedData(), let json = String(data: body, encoding: .utf8) {
            await store.upsert(StoredMessage(
                conversationID: krendoraConversation,
                role: .assistant,
                content: "```jarvis-rich\n" + json + "\n```",
                status: .sent))
        }

        let poll = RichBlocksEnvelope(
            messageId: "demo-kr-poll-1",
            conversationId: krendoraConversation.uuidString,
            blocks: [
                RichBlock(content: .poll(
                    question: "Which creative gets the remaining $150?",
                    options: ["Knee-saver v2", "Unboxing cut", "Both 50/50"]),
                          fallbackText: "Poll: which creative gets the remaining $150?"),
                RichBlock(content: .form(
                    fields: [
                        RichFormField(id: "kr-budget", kind: .number, label: "Daily budget cap ($)", required: true),
                        RichFormField(id: "kr-confirm", kind: .checkbox, label: "Pause the unboxing ad set"),
                    ],
                    submitLabel: "Apply changes"),
                          fallbackText: "Budget cap field + pause checkbox"),
            ])
        if let body = try? poll.encodedData(), let json = String(data: body, encoding: .utf8) {
            await store.upsert(StoredMessage(
                conversationID: krendoraConversation,
                role: .assistant,
                content: "```jarvis-rich\n" + json + "\n```",
                status: .sent))
        }

        // A live-streaming row (UI Law §3): partial text with .streaming status.
        await store.upsert(StoredMessage(
            conversationID: krendoraConversation,
            role: .assistant,
            content: "Building the week-to-date report now — spend so far is $41.20 and orders are pacing",
            status: .streaming))
    }

    private static func seedVoice(_ store: PersistenceStore) async {
        await store.upsert(StoredConversation(
            id: voiceConversation,
            title: "Call log — Jessica",
            updatedAt: Date().addingTimeInterval(-7_200),
            lastMessagePreview: "Call transcript synced"))

        await store.upsert(StoredMessage(
            conversationID: voiceConversation,
            role: .user,
            content: "Call Jessica",
            status: .sent))
        await store.upsert(StoredMessage(
            conversationID: voiceConversation,
            role: .assistant,
            content: "Rang Jessica — 4m 12s. She confirmed Saturday dinner at 7 and wants the avocado thing from Peruvian Palms.",
            status: .sent))
    }
}
#endif
