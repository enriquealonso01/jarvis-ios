import SwiftUI
import UIKit
import JarvisKit
import Persistence
import DesignSystem
import FeaturesChat
import FeaturesSidebar

/// v2 chat auth: every v2 request (POST /v1/conversations/…/messages and
/// the SSE /events tail) carries the same dashboard bearer the v1 screens
/// use, refreshed when it is about to expire. Without it the gateway
/// answers 302 → /login and v2 chat silently never reaches JARVIS.
enum V2Auth {
    static let bearer: JarvisKit.BearerProvider = { @MainActor in
        try? await AuthStore.shared.validAccessToken()
    }
}

// MARK: - ChatGPT-grammar shell (Item 3 + UI expansion package)
//
// UI expansion 03_SCREEN_SPECS / prototype, binding (Enrique's package wins
// over the earlier UI Law where they differ):
//   • Header: sidebar toggle, chat title + subtitle (project or "General
//     chat"), export + new-chat actions on the right.
//   • Mobile drawer ~85% of the width (≤320pt) over a dimmed chat; opens via
//     ≡ or a leading-edge swipe, closes via scrim tap, ✕, or swipe-left.
//   • Drawer: brand row → New chat → Search chats (inline, live) → Pinned →
//     Projects (collapsible) → Recents → profile row (v1 settings/calls).
//   • Obsidian canvas, deep-surface surfaces, surface-border hairlines, one
//     cyan accent. Dark only.

/// The v2 chat surface + slide-over sidebar shell.
struct V2SidebarShell: View {
    /// View model over the shared store; nil store (open failure) degrades
    /// to an empty sidebar — never a launch crash (same contract as Item 1).
    /// (Qualified: FeaturesSidebar ships its own legacy SidebarViewModel;
    /// the store-contract implementation this shell hosts is FeaturesChat's.)
    @StateObject private var vm: FeaturesChat.SidebarViewModel
    @State private var selection: SidebarSelection?
    /// Header export button → the conversation's PDF export sheet.
    @State private var exportPresented = false
    /// Voice overlay presenter (composer voice button / in-chat pill).
    @ObservedObject private var voice = V2VoiceOverlay.shared
    private let store: PersistenceStore?

    init(store: PersistenceStore?) {
        _vm = StateObject(wrappedValue: FeaturesChat.SidebarViewModel(store: store ?? PersistenceStore()))
        self.store = store
    }

    var body: some View {
        SlideOverSidebar(isPresented: Binding(
            get: { vm.isOpen },
            set: { open in Task { await vm.setOpen(open) } }
        )) {
            SidebarPanelView(
                vm: vm,
                onSelect: { selection in handle(selection) },
                store: store,
                onOpenProjectChat: { chatID in handle(.chat(id: chatID)) })
        } underlying: {
            chatSurface
        }
        .background(Tokens.Palette.canvas.ignoresSafeArea())
        .fullScreenCover(isPresented: $voice.isPresented) {
            V2VoiceScreen()
        }
        .task {
            await vm.restoreState()
            await vm.reload()
        }
    }

    // MARK: Routing (Item 3 §3)

    private func handle(_ selection: SidebarSelection) {
        switch selection {
        // Picking a destination closes the slide-over (ChatGPT grammar).
        case .chat(let id):
            Task {
                await vm.select(conversationID: id)
                self.selection = .chat(id: id)
                await vm.setOpen(false)
            }
        case .newChat:
            Task {
                let conversation = await vm.newChat()
                self.selection = .chat(id: conversation.id)
                await vm.setOpen(false)
            }
        case .projectHome(let id):
            // Item 10: Project Home renders in the chat surface; chats opened
            // from it route back through `.chat` (same header + composer).
            // `self.` — the parameter shadows the @State property here.
            self.selection = .projectHome(id: id)
            Task { await vm.setOpen(false) }
        case .search, .addOn:
            // Search is inline in the drawer (live filter + message search);
            // add-on destinations are not part of the v2 drawer.
            self.selection = selection
        }
    }

    // MARK: Header model

    /// The open conversation's row from the sidebar lists (title source).
    private var currentConversation: StoredConversation? {
        guard let id = vm.selectedConversationID else { return nil }
        if let hit = vm.pinned.first(where: { $0.id == id }) { return hit }
        if let hit = vm.recents.first(where: { $0.id == id }) { return hit }
        for node in vm.projects {
            if let hit = node.conversations.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    private var headerTitle: String {
        guard vm.selectedConversationID != nil else { return "JARVIS" }
        return currentConversation?.title ?? "New chat"
    }

    private var headerSubtitle: String {
        guard vm.selectedConversationID != nil else { return "Personal Intelligence" }
        if let projectID = currentConversation?.projectID,
           let node = vm.projects.first(where: { $0.project.id == projectID }) {
            return node.project.name
        }
        return "General chat"
    }

    // MARK: Chat surface

    @ViewBuilder
    private var chatSurface: some View {
        NavigationStack {
            Group {
                if case .projectHome(let projectID)? = selection {
                    V2ProjectHomeView(
                        projectID: projectID,
                        store: store ?? PersistenceStore(),
                        onOpenChat: { chatID in handle(.chat(id: chatID)) })
                        .id(projectID)
                        .scrollContentBackground(.hidden)
                        .background(Tokens.Palette.canvas.ignoresSafeArea())
                        .toolbarBackground(Tokens.Palette.canvas, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    Task { await vm.setOpen(true) }
                                } label: {
                                    Image(systemName: "line.3.horizontal")
                                }
                                .accessibilityLabel("Open sidebar")
                                .accessibilityIdentifier("chat.menuButton")
                            }
                        }
                } else {
                    chatContent
                        .safeAreaInset(edge: .top, spacing: 0) {
                            V2ChatHeader(
                                title: headerTitle,
                                subtitle: headerSubtitle,
                                onMenu: { Task { await vm.setOpen(true) } },
                                onExport: vm.selectedConversationID == nil
                                    ? nil
                                    : { exportPresented = true },
                                onNewChat: { handle(.newChat) })
                        }
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .background(Tokens.Palette.canvas.ignoresSafeArea())
            .background(
                // Edge-swipe from the leading edge opens the sidebar
                // (UI Law §1). Narrow leading strip so it never fights the
                // system back-swipe.
                GeometryReader { geo in
                    Color.clear
                        .frame(width: Tokens.Spacing.l)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { value in
                                    if value.startLocation.x < Tokens.Spacing.l,
                                       value.translation.width > 40 {
                                        Task { await vm.setOpen(true) }
                                    }
                                }
                        )
                        .frame(width: geo.size.width, height: geo.size.height,
                               alignment: .topLeading)
                }
            )
        }
    }

    @ViewBuilder
    private var chatContent: some View {
        if let id = vm.selectedConversationID {
            // Item 8: the v2 chat surface = REAL transcript (full-width
            // assistant blocks, user bubbles, anchored streaming) + the
            // composer docked below it.
            V2ChatHost(store: store, conversationID: id, sidebarVM: vm,
                       exportPresented: $exportPresented)
                .id(id)
        } else {
            V2EmptyStateView(onNewChat: { handle(.newChat) })
        }
    }
}

// MARK: - Chat header (prototype `.topbar`)

/// ≡ · title / subtitle · export · new chat. Custom (not the system nav
/// bar) so the layout matches the reference exactly: left-aligned title
/// block, 44pt icon targets, near-invisible hairline underneath.
struct V2ChatHeader: View {
    let title: String
    let subtitle: String
    let onMenu: () -> Void
    var onExport: (() -> Void)? = nil
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onMenu) {
                Image(systemName: "line.3.horizontal")
            }
            .buttonStyle(JarvisIconButtonStyle())
            .accessibilityLabel("Open sidebar")
            .accessibilityIdentifier("chat.menuButton")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.Typography.headerTitle)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Tokens.Typography.headerSubtitle)
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("chat.headerTitle")

            if let onExport {
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(JarvisIconButtonStyle())
                .accessibilityLabel("Export chat as PDF")
                .accessibilityIdentifier("chat.exportButton")
            }

            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(JarvisIconButtonStyle())
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("chat.newChatButton")
        }
        .padding(.horizontal, 6)
        .frame(height: Tokens.Layout.headerHeight)
        .background(Tokens.Palette.canvas.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Tokens.Palette.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - The sidebar panel (prototype `.sidebar`)

/// One message-search hit (a conversation whose CONTENT matched).
struct V2SearchHit: Identifiable, Equatable {
    let id: UUID
    let title: String
    let snippet: String
}

/// Pure helpers for the drawer search (FTS pattern + readable snippet).
enum V2Search {
    /// FTS5 prefix query from free text: each token stripped to bareword
    /// characters and quoted (`"breck"* "day"*`) so user input can never be
    /// FTS syntax (no injection of MATCH operators, no syntax errors).
    static func ftsPattern(_ query: String) -> String? {
        let tokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token in token.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// A one-line excerpt around the first match; rich envelopes are read
    /// through their plain summaries, never shown as raw JSON.
    static func snippet(_ content: String, query: String) -> String {
        var text = content
        if let blocks = RichContentPayload.parse(content) {
            text = blocks.map { $0.content.plainSummary }.joined(separator: " · ")
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        let needle = query.components(separatedBy: .whitespaces).first(where: { !$0.isEmpty }) ?? query
        guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(90))
        }
        let start = text.index(range.lowerBound, offsetBy: -32, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + String(text[start..<end]).trimmingCharacters(in: .whitespaces) + suffix
    }
}

struct SidebarPanelView: View {
    @ObservedObject var vm: FeaturesChat.SidebarViewModel
    let onSelect: (SidebarSelection) -> Void
    /// Item 10: the shell's shared store (search + Project Home read it).
    var store: PersistenceStore? = nil
    /// Item 10: shell router for chats opened from Project Home.
    var onOpenProjectChat: ((UUID) -> Void)? = nil
    @State private var settingsPresented = false
    /// Conversations whose message CONTENT matched the query (FTS).
    @State private var messageHits: [V2SearchHit] = []
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
            VStack(spacing: 10) {
                newChatRow
                searchRow
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if isSearching {
                        searchResults
                    } else {
                        pinnedSection
                        projectsSection
                        recentsSection
                        if vm.canLoadMoreRecents {
                            loadMoreButton
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .padding(.bottom, Tokens.Spacing.l)
            }
            .scrollDismissesKeyboard(.immediately)

            profileRow
        }
        .background(Tokens.Palette.elevated)
        .task(id: vm.searchQuery) {
            await runContentSearch()
        }
        // Until v2 has its own Settings, the profile row opens the full v1
        // app (Sessions · Projects · Calls · More → Secrets, Settings with
        // sign-out + Face ID) so nothing v1 could do is lost in v2.
        .sheet(isPresented: $settingsPresented) {
            RootTabView()
        }
    }

    // MARK: Brand row

    private var brandRow: some View {
        HStack(spacing: 11) {
            OrbitalCoreView(state: .idle, isStatic: true)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text("JARVIS")
                .font(.footnote.weight(.heavy))
                .tracking(2.6)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Spacer()
            Button {
                searchFocused = false
                Task { await vm.setOpen(false) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(JarvisIconButtonStyle())
            .accessibilityLabel("Close sidebar")
            .accessibilityIdentifier("sidebar.closeButton")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    // MARK: New chat + Search

    private var newChatRow: some View {
        Button {
            searchFocused = false
            onSelect(.newChat)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                Text("New chat")
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.Palette.accentLabel)
            .padding(.horizontal, 14)
            .frame(minHeight: Tokens.Layout.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(Tokens.Palette.accentSurface))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .strokeBorder(Tokens.Palette.accentBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.newChat")
    }

    /// Inline live search (03 Sidebar: debounced, titles AND content).
    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Palette.textMuted)
            TextField(text: $vm.searchQuery,
                      prompt: Text("Search chats").foregroundColor(Tokens.Palette.textMuted)) {
                Text("Search chats")
            }
            .font(.subheadline)
            .foregroundStyle(Tokens.Palette.textPrimary)
            .tint(Tokens.Palette.accent)
            .focused($searchFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityIdentifier("sidebar.search")
            if !vm.searchQuery.isEmpty {
                Button {
                    vm.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Tokens.Palette.textMuted)
                        .frame(width: 32, height: Tokens.Layout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("sidebar.searchClear")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, vm.searchQuery.isEmpty ? 12 : 2)
        .frame(minHeight: Tokens.Layout.hitTarget)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokens.Palette.sunken))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(searchFocused ? Tokens.Palette.accent.opacity(0.45) : Tokens.Palette.border,
                              lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .accessibilityElement(children: .contain)
    }

    // MARK: Search results

    /// Title / preview matches across every section (deduplicated).
    private var titleMatches: [StoredConversation] {
        var seen = Set<UUID>()
        var out: [StoredConversation] = []
        let q = trimmedQuery
        let pinned = vm.pinned.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.lastMessagePreview?.localizedCaseInsensitiveContains(q) ?? false)
        }
        let projectChats = vm.filteredProjects.flatMap { $0.conversations }
        for conversation in pinned + vm.filteredRecents + projectChats where !seen.contains(conversation.id) {
            seen.insert(conversation.id)
            out.append(conversation)
        }
        return out
    }

    @ViewBuilder
    private var searchResults: some View {
        let chats = titleMatches
        let chatIDs = Set(chats.map(\.id))
        let hits = messageHits.filter { !chatIDs.contains($0.id) }
        if chats.isEmpty && hits.isEmpty {
            Text("No conversations found")
                .font(.footnote)
                .foregroundStyle(Tokens.Palette.textMuted)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("sidebar.searchEmpty")
        }
        if !chats.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel("Chats")
                ForEach(chats) { conversation in
                    searchResultRow(id: conversation.id, title: conversation.title,
                              snippet: conversation.lastMessagePreview)
                }
            }
        }
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel("In messages")
                ForEach(hits) { hit in
                    searchResultRow(id: hit.id, title: hit.title, snippet: hit.snippet)
                }
            }
        }
    }

    private func searchResultRow(id: UUID, title: String, snippet: String?) -> some View {
        Button {
            vm.searchQuery = ""
            searchFocused = false
            onSelect(.chat(id: id))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.textMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.hitTarget, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(V2RowButtonStyle(isSelected: false))
        .accessibilityIdentifier("sidebar.searchResult.\(id.uuidString)")
    }

    /// Debounced FTS search over message content (250 ms; `.task(id:)`
    /// cancels the previous query as the user types).
    private func runContentSearch() async {
        let q = trimmedQuery
        guard q.count >= 2, let store, let pattern = V2Search.ftsPattern(q) else {
            messageHits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let messages = (try? await store.searchMessages(matching: pattern, limit: 40)) ?? []
        var seen = Set<UUID>()
        var hits: [V2SearchHit] = []
        for message in messages where !seen.contains(message.conversationID) {
            seen.insert(message.conversationID)
            guard let conversation = await store.get(id: message.conversationID) else { continue }
            hits.append(V2SearchHit(
                id: conversation.id,
                title: conversation.title,
                snippet: V2Search.snippet(message.content, query: q)))
            if hits.count >= 12 { break }
        }
        guard !Task.isCancelled else { return }
        messageHits = hits
    }

    // MARK: Section label (prototype `.section-head`)

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Tokens.Typography.sectionLabel)
            .tracking(1.5)
            .foregroundStyle(Tokens.Palette.sectionLabel)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Pinned

    @ViewBuilder
    private var pinnedSection: some View {
        if !vm.pinned.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel("Pinned")
                ForEach(vm.pinned) { conversation in
                    conversationRow(conversation)
                }
            }
        }
    }

    // MARK: Projects (collapsible section; schema from Item 1)

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Task(priority: .userInitiated) { await vm.setProjectsExpanded(!vm.projectsExpanded) }
            } label: {
                HStack(spacing: 6) {
                    Text("PROJECTS")
                        .font(Tokens.Typography.sectionLabel)
                        .tracking(1.5)
                        .foregroundStyle(Tokens.Palette.sectionLabel)
                    Image(systemName: vm.projectsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Tokens.Palette.sectionLabel)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(vm.projectsExpanded ? "Projects, expanded" : "Projects, collapsed")
            .accessibilityIdentifier("sidebar.projectsToggle")

            if vm.projectsExpanded {
                if vm.projects.isEmpty {
                    Text("No projects yet")
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                // Item 10: each row opens its Project Home (title,
                // instructions, sources, project-scoped chats, new chat).
                ForEach(vm.projects) { node in
                    Button {
                        searchFocused = false
                        onSelect(.projectHome(id: node.project.id))
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Tokens.Palette.accent)
                                .frame(width: 8, height: 8)
                            Text(node.project.name)
                                .font(Tokens.Typography.row)
                                .lineLimit(1)
                            Spacer()
                            Text("\(node.conversations.count)")
                                .font(.caption)
                                .foregroundStyle(Tokens.Palette.textMuted)
                        }
                        .foregroundStyle(Tokens.Palette.textBody)
                        .padding(.horizontal, 12)
                        .frame(minHeight: Tokens.Layout.hitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(V2RowButtonStyle(isSelected: false))
                    .accessibilityIdentifier("sidebar.project.\(node.project.id.uuidString)")

                    ForEach(node.conversations) { conversation in
                        conversationRow(conversation, indented: true)
                    }
                }
            }
        }
    }

    // MARK: Recents (paginated from the store)

    /// Recents = chats outside any project (ChatGPT grammar: project chats
    /// live under their project, not twice in the drawer).
    private var looseRecents: [StoredConversation] {
        vm.filteredRecents.filter { $0.projectID == nil }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Recents")
            if looseRecents.isEmpty && vm.loaded {
                Text("No conversations yet")
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, Tokens.Spacing.s)
            }
            ForEach(looseRecents) { conversation in
                conversationRow(conversation)
            }
        }
    }

    private func conversationRow(_ conversation: StoredConversation, indented: Bool = false) -> some View {
        V2ConversationRow(
            conversation: conversation,
            isSelected: vm.selectedConversationID == conversation.id,
            contextMenu: .pinAndArchive,
            indented: indented
        ) {
            searchFocused = false
            onSelect(.chat(id: conversation.id))
        } onPin: {
            Task { await vm.setPinned(!conversation.pinned, conversationID: conversation.id) }
        } onArchive: {
            Task { await vm.setArchived(true, conversationID: conversation.id) }
        } onRename: { newTitle in
            Task { await vm.rename(conversationID: conversation.id, to: newTitle) }
        } onDelete: {
            Task { await vm.delete(conversationID: conversation.id) }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await vm.loadMoreRecents() }
        } label: {
            Text("Load more")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tokens.Palette.accent)
                .frame(maxWidth: .infinity, minHeight: Tokens.Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.loadMore")
    }

    // MARK: Profile row (→ v1 app: settings, calls, secrets)

    private var profileRow: some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                OrbitalCoreView(state: .idle, isStatic: true)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text("Settings · Calls · Projects · Secrets")
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textMuted)
            }
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.vertical, Tokens.Spacing.m)
            .frame(minHeight: Tokens.Layout.hitTarget + 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Palette.border).frame(height: 1)
        }
        .accessibilityIdentifier("sidebar.profileRow")
    }
}

/// Sidebar row chrome: 11pt continuous corners, tonal press + selected
/// state (02 "selected: tonal background + semibold text, not just color").
struct V2RowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? Tokens.Palette.selected
                          : (configuration.isPressed ? Tokens.Palette.raised : Color.clear)))
    }
}

// MARK: - Conversation row (shared by Pinned / Projects / Recents)

/// One conversation row with Item 5 list mechanics (feature #5, UI Law §8):
///   • Long-press: Rename, Pin/Unpin, Archive, Delete (red, confirmed) —
///     in exactly that order, from the shared ListMechanicsEngine model.
///   • Swipe left: Delete (red), confirmed by the same dialog.
///   • Archive runs immediately — §8 gives it NO confirmation and keeps
///     the row (searchable later via Item 6).
struct V2ConversationRow: View {
    enum ContextMenu { case pinAndArchive }

    let conversation: StoredConversation
    let isSelected: Bool
    let contextMenu: ContextMenu
    var indented = false
    let action: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    /// Item 5: rename (long-press menu). Blank names are gated VM-side.
    var onRename: ((String) -> Void)? = nil
    /// Item 5: confirmed delete (menu item AFTER the confirmation, or the
    /// swipe action once the user confirms).
    var onDelete: (() -> Void)? = nil

    @State private var isRenameSheetPresented = false
    @State private var pendingConfirmation: RowMenuAction.Kind?
    /// Item 5 FIX: reveal offset of the row-drag delete (≤ 0).
    @State private var swipeOffset: CGFloat = 0

    /// The §8 menu model, order pinned by Item 5 tests: Rename,
    /// Pin/Unpin, Archive, Delete(red).
    private var menuActions: [RowMenuAction] {
        ListMechanicsEngine.menuActions(for: conversation)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s) {
                if indented {
                    Spacer().frame(width: Tokens.Spacing.l)
                }
                Text(conversation.title)
                    .font(Tokens.Typography.row)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Tokens.Palette.textPrimary : Tokens.Palette.textBody)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if conversation.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.Palette.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Tokens.Layout.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(V2RowButtonStyle(isSelected: isSelected))
        // Long titles truncate visually but stay whole for VoiceOver (03).
        .accessibilityLabel(conversation.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Item 5 FIX: .swipeActions never fired here — the sidebar sections
        // render in a ScrollView+VStack, and .swipeActions is a List-only
        // modifier. Replaced with a row drag that reveals the same red,
        // non-full-swipe Delete (§8): confirm dialog → VM swipeDelete path
        // unchanged. Child gestures beat the shell's plain .gesture
        // (SlideOverSidebar), so panel-close is untouched.
        .offset(x: swipeOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    swipeOffset = max(-96, min(0, value.translation.width))
                }
                .onEnded { value in
                    let horizontalDominant = abs(value.translation.width) > abs(value.translation.height)
                    if horizontalDominant, value.translation.width < -44 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            swipeOffset = -96
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            swipeOffset = 0
                        }
                    }
                }
        )
        .background(alignment: .trailing) {
            // The revealed action: red, trash-labeled, tap = confirm-first
            // (never a silent full swipe). Same identifier as before so QA
            // probes are unaffected.
            if swipeOffset < 0 {
                Button(role: .destructive) {
                    pendingConfirmation = .delete
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .frame(width: 88, height: Tokens.Layout.hitTarget)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                                .fill(Tokens.Palette.dangerFill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("sidebar.swipeDelete")
                .transition(.opacity)
            }
        }
        .contextMenu {
            ForEach(menuActions) { menuAction in
                Button(role: menuAction.isDestructive ? .destructive : nil) {
                    handle(menuAction)
                } label: {
                    switch menuAction.kind {
                    case .rename:
                        Label("Rename", systemImage: "pencil")
                    case .pin:
                        Label("Pin", systemImage: "pin")
                    case .unpin:
                        Label("Unpin", systemImage: "pin.slash")
                    case .archive:
                        Label("Archive", systemImage: "archivebox")
                    case .delete:
                        Label("Delete", systemImage: "trash")
                    }
                }
                .accessibilityIdentifier("sidebar.menu.\(menuAction.kind)")
            }
        }
        .accessibilityIdentifier("sidebar.conversation.\(conversation.id.uuidString)")
        // Delete is the only confirmed mechanic (§8). Archive above runs
        // immediately; rename opens the field instead.
        .confirmationDialog(
            "Delete “\(conversation.title)”?",
            isPresented: confirmationBinding(for: .delete),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation and its messages will be removed from this device.")
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            V2RenameSheet(
                currentTitle: conversation.title,
                onCancel: { isRenameSheetPresented = false },
                onSubmit: { newTitle in
                    isRenameSheetPresented = false
                    onRename?(newTitle)
                }
            )
        }
    }

    /// One confirmation binding per mechanic (only delete exists today).
    private func confirmationBinding(for kind: RowMenuAction.Kind) -> Binding<Bool> {
        Binding(
            get: { pendingConfirmation == kind },
            set: { presented in
                if !presented {
                    pendingConfirmation = nil
                    // Item 5 FIX: after the delete dialog resolves (confirm
                    // or cancel) the row-drag reveal snaps closed again.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        swipeOffset = 0
                    }
                }
            }
        )
    }

    private func handle(_ menuAction: RowMenuAction) {
        switch menuAction.kind {
        case .rename:
            isRenameSheetPresented = true
        case .pin, .unpin:
            onPin()
        case .archive:
            // §8: archive immediately — no confirmation, row stays.
            onArchive()
        case .delete:
            pendingConfirmation = .delete
        }
    }
}

/// Rename sheet (long-press → Rename): a single field with the current
/// title pre-filled; Cancel never writes, Save hands the draft to the VM
/// (whitespace-only drafts are rejected VM-side).
struct V2RenameSheet: View {
    let currentTitle: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Rename conversation") {
                    TextField("Title", text: $draft)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { onSubmit(draft) }
                        .accessibilityIdentifier("sidebar.rename.field")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.Palette.elevated)
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSubmit(draft) }
                        .accessibilityIdentifier("sidebar.rename.save")
                }
            }
        }
        .onAppear {
            draft = currentTitle
            fieldFocused = true
        }
        .presentationDetents([.medium])
        .presentationBackground(Tokens.Palette.elevated)
    }
}

// MARK: - Item 8: chat surface host (real transcript + composer)

/// Mounts the FeaturesChat `V2TranscriptView` over one conversation — the
/// REAL transcript replacing the Item-3 placeholder (UI Law §2/§3/§5):
///   • loads the newest page from the PersistenceStore (fetchMessages
///     page=50 paging; store restore path pinned from the view-model layer);
///   • live-tails the Item-2 ChatStreamEngine's coalesced snapshots for the
///     active conversation (cold-launch mid-stream restore included);
///   • replays composer sends into the transcript so the user row +
///     streaming assistant block appear without a manual refresh;
///   • §3 stop: the composer's square button cancels upstream without
///     losing committed text (engine stop, partial persists);
///   • rich-block interactions (button labels, poll votes, form answers)
///     ride the SAME user-row + delivery path as a typed message.
struct V2ChatHost: View {
    let store: PersistenceStore?
    let conversationID: UUID
    /// Item 5: auto-title writes back into the sidebar's VM (shared store,
    /// one writer at a time — the shell owns exactly one).
    var sidebarVM: FeaturesChat.SidebarViewModel? = nil
    /// Header export button (owned by the shell's header). nil = local.
    var exportPresented: Binding<Bool>? = nil
    /// Item 9: the action row needs the same send path the composer uses.
    private let sendCoordinator: MessageSendCoordinator?
    /// Item 9: the regenerate send path as a directly-typed closure (built
    /// once in init; `nil` coordinator → the view omits the control).
    private var regenerateSendPath: MessageActionViewModel.PerformSend {
        let coordinatorRef = sendCoordinator
        return { [weak coordinatorRef] text in
            guard let coordinatorRef else { return false }
            do {
                _ = try await coordinatorRef.send(
                    conversationID: conversationID, text: text, online: true)
                return true
            } catch {
                // send() already enqueued the outbox entry — the replay
                // path owns delivery; never double-send.
                return true
            }
        }
    }

    @StateObject private var holder: TranscriptVMHolder
    /// Item 9: action-row VM (copy/share are store-free; regenerate rides
    /// the same transport+outbox path as composer sends).
    @StateObject private var actionVM: MessageActionViewModel
    /// Item 13: export-options sheet toggle (fallback when no header binding).
    @State private var showsExportSheet = false

    /// StateObject needs a concrete holder: the transcript VM's conversation
    /// target is fixed at shell-selection time, but its stream client needs
    /// the app's ServerConfig (singleton, available at init).
    @MainActor
    final class TranscriptVMHolder: ObservableObject {
        let vm: TranscriptViewModel
        init(store: PersistenceStore?, conversationID: UUID) {
            // Stream client only when the server is configured; the
            // transcript stays fully functional store-backed otherwise
            // (headless, no network touched).
            var client: ChatStreamClient? = nil
            if ServerConfig.shared.configured,
               let baseURL = URL(string: ServerConfig.shared.config.baseURL) {
                client = ChatStreamClient(
                    config: JarvisKit.ServerConfig(baseURL: baseURL),
                    conversationID: conversationID,
                    store: store,
                    bearerProvider: V2Auth.bearer)
            }
            vm = TranscriptViewModel(
                conversationID: conversationID,
                store: store,
                streamClient: client)
        }
    }

    init(store: PersistenceStore?, conversationID: UUID,
         sidebarVM: FeaturesChat.SidebarViewModel? = nil,
         exportPresented: Binding<Bool>? = nil) {
        self.store = store
        self.conversationID = conversationID
        self.sidebarVM = sidebarVM
        self.exportPresented = exportPresented
        // Item 9: the real regenerate path — POST via the coordinator with
        // outbox replay on failure (offline sends are never lost). When the
        // server isn't configured there is NO send path, and the regenerate
        // control is omitted entirely (no fake buttons).
        if ServerConfig.shared.configured,
           let baseURL = URL(string: ServerConfig.shared.config.baseURL) {
            self.sendCoordinator = MessageSendCoordinator(
                api: JarvisKit.APIClient(config: JarvisKit.ServerConfig(baseURL: baseURL),
                                         bearerProvider: V2Auth.bearer),
                store: store ?? PersistenceStore())
        } else {
            self.sendCoordinator = nil
        }
        _holder = StateObject(wrappedValue: TranscriptVMHolder(
            store: store, conversationID: conversationID))
        // Item 9: directly-typed send closure — Optional.map with a
        // multi-statement closure defeats Swift's type inference (CI
        // 39153190768), so the optionality is expressed in the closure body.
        let coordinatorRef = sendCoordinator
        let sendPath: MessageActionViewModel.PerformSend = { [weak coordinatorRef] text in
            guard let coordinatorRef else { return false }
            do {
                _ = try await coordinatorRef.send(
                    conversationID: conversationID,
                    text: text,
                    online: true)
                return true
            } catch {
                // send() already enqueued the outbox entry — the replay
                // path owns delivery; returning true avoids double-send.
                return true
            }
        }
        let actionViewModel = MessageActionViewModel(
            performSend: sendCoordinator == nil ? nil : sendPath)
        _actionVM = StateObject(wrappedValue: actionViewModel)
    }

    /// The Item-4 composer surface, wired to the transcript host's §3 stop
    /// and send-refresh hooks (its model-chooser sheet + CallManager wiring
    /// stay owned by the composer host). Item 8 QA fix: passes this host's
    /// live `isStreaming` down so the composer's stop swap actually fires.
    private var composerHost: some View {
        V2ComposerHost(
            store: store, conversationID: conversationID, sidebarVM: sidebarVM,
            onDidSend: { Task { await holder.vm.userDidSend() } },
            onStreamStop: { await holder.vm.stopTapped() },
            isStreaming: holder.vm.isStreaming,
            onDeliver: deliverPath)
    }

    /// Composer sends were store-only (the row never left the phone): the
    /// composer host hands each freshly written user row here and the
    /// coordinator POSTs it under its own id (outbox replay on failure).
    private var deliverPath: ((StoredMessage) async -> Void)? {
        guard let coordinator = sendCoordinator else { return nil }
        return { message in await coordinator.deliver(message) }
    }

    /// Rich-block interaction → a real user message (same path as typing):
    /// write the row, refresh the transcript (bubble appears, tail starts),
    /// then deliver it to the server (outbox replay on failure).
    private func sendFromRichBlock(_ text: String) {
        guard let store else { return }
        let row = StoredMessage(
            conversationID: conversationID,
            role: .user,
            content: text,
            status: .sending)
        let coordinator = sendCoordinator
        Task {
            await store.upsert(row)
            await holder.vm.userDidSend()
            if let coordinator {
                await coordinator.deliver(row)
                await holder.vm.userDidSend()
            }
        }
    }

    var body: some View {
        V2TranscriptView(
            vm: holder.vm,
            actionViewModel: actionVM,
            regenerateSend: sendCoordinator == nil ? nil : regenerateSendPath,
            onSendText: store == nil ? nil : { text in sendFromRichBlock(text) })
            // Item 13: export/share entry point for this conversation (the
            // trigger lives in the shell header).
            .modifier(ChatExportSheet(
                store: store,
                conversationID: conversationID,
                isPresented: exportPresented ?? $showsExportSheet))
            .onAppear {
                Task { await holder.vm.loadInitial() }
                // Item 12 (M2): call⇄chat binder rows land in THIS
                // conversation through the shell's shared store.
                M2CallTranscriptBinder.shared.visibleConversationID = conversationID
                M2CallTranscriptBinder.shared.store = store
            }
            .onDisappear {
                holder.vm.cancelTail()
                if M2CallTranscriptBinder.shared.visibleConversationID == conversationID {
                    M2CallTranscriptBinder.shared.visibleConversationID = nil
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The composer host below mirrors this host's live
                // `isStreaming` (Item 8 QA fix — see `composerHost`).
                composerHost
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Item 12 (M2): the in-chat voice pill while a call is
                // live — chat stays visible; user can type back mid-call.
                V2InChatVoiceBar()
            }
            .sheet(isPresented: Binding(
                get: { actionVM.shareText != nil },
                set: { presented in
                    if !presented { actionVM.shareDismissed() }
                })) {
                if let shareText = actionVM.shareText {
                    Item9ShareSheet(text: shareText)
                }
            }
    }
}

// MARK: - Item 4: composer host (app-target intent wiring)

/// Mounts the FeaturesChat `V2ComposerView` over one conversation and owns
/// the app-target side of the composer intents (UI Law §6):
///   • `.showModelChooser` (long-press send) → the one-off model sheet;
///   • `.startCall` (waveform) → CallManager placeDirectCall (M2 machine;
///     v1 CallManager exists and is reused until the §5.4 rewrite).
/// The composer itself stays pure — no call or chooser logic in the package.
struct V2ComposerHost: View {
    let store: PersistenceStore?
    let conversationID: UUID
    /// Item 5: auto-title writes back into the sidebar's VM (shared store,
    /// one writer at a time — the shell owns exactly one).
    var sidebarVM: FeaturesChat.SidebarViewModel? = nil
    /// Item 8: fired after a successful send so the transcript refreshes.
    var onDidSend: (() -> Void)? = nil
    /// Item 8 / UI Law §3: fired when the stop button is tapped mid-stream.
    var onStreamStop: (() async -> Void)? = nil
    /// Item 8 QA fix: the transcript host mirrors the transcript VM's live
    /// stream state in here (it owns the truth); without it the composer's
    /// §3 send⇄stop swap was dead code — `isStreaming` was never mutated.
    var isStreaming: Bool = false
    /// Delivers the user row a send just wrote to the server (nil = no
    /// server configured: the chat stays local-only, nothing faked).
    var onDeliver: ((StoredMessage) async -> Void)? = nil

    @StateObject private var holder: ComposerVMHolder
    @State private var isModelChooserPresented = false
    @State private var chooserSelection: String?

    /// StateObject needs a concrete holder: the composer VM's conversation
    /// target is set after init (conversation becomes known on selection).
    /// Item 12 (M2): the waveform intent rides the VM's `events` channel —
    /// wired here at VM creation (deterministic; no view-body observation)
    /// → the REAL CallKit/WebRTC call engine (UI Law §7).
    @MainActor
    final class ComposerVMHolder: ObservableObject {
        let vm: ComposerViewModel
        init(store: PersistenceStore?) {
            vm = ComposerViewModel(store: store, events: { event in
                guard event == .startCall else { return }
                // The voice button opens the voice screen in its honest
                // READY state; the session starts from its Start control.
                Task { @MainActor in V2VoiceOverlay.shared.present() }
            })
        }
    }

    init(store: PersistenceStore?, conversationID: UUID, sidebarVM: FeaturesChat.SidebarViewModel? = nil,
         onDidSend: (() -> Void)? = nil, onStreamStop: (() async -> Void)? = nil,
         isStreaming: Bool = false, onDeliver: ((StoredMessage) async -> Void)? = nil) {
        self.store = store
        self.conversationID = conversationID
        self.sidebarVM = sidebarVM
        self.onDidSend = onDidSend
        self.onStreamStop = onStreamStop
        self.isStreaming = isStreaming
        self.onDeliver = onDeliver
        _holder = StateObject(wrappedValue: ComposerVMHolder(store: store))
    }

    var body: some View {
        V2ComposerView(
            vm: holder.vm,
            isModelChooserPresented: $isModelChooserPresented,
            onDidSend: onDidSend,
            onStreamStop: onStreamStop)
            .onAppear {
                holder.vm.conversationID = conversationID
                Task { await holder.vm.restoreState() }
            }
            // Item 8 QA fix: mirror the host-supplied stream state (the
            // transcript VM owns the truth — see V2ChatHost.composerHost).
            // onChange (not onAppear) so the §3 send⇄stop swap tracks the
            // stream live, including starting mid-visit.
            .onChange(of: isStreaming) { _, newValue in
                holder.vm.setStreaming(newValue)
            }
            .onChange(of: holder.vm.isStreaming) { _, newValue in
                if newValue != isStreaming { holder.vm.setStreaming(isStreaming) }
            }
            .sheet(isPresented: $isModelChooserPresented) {
                V2ModelChooserSheet(vm: holder.vm, selection: $chooserSelection)
            }
            .onChange(of: holder.vm.sentMessageCount) { _, newCount in
                // Item 5 (UI Law §8): conversations auto-title after the
                // first exchange. The composer exposes a monotonic send
                // counter; each tick retitles via the pure rule (fires only
                // while the row still carries its default title).
                guard newCount > 0 else { return }
                // Deliver the row this send wrote (same id → no duplicate).
                if let onDeliver, let sent = holder.vm.lastSentMessage {
                    Task { await onDeliver(sent) }
                }
                Task {
                    let role = holder.vm.lastSentRole ?? .user
                    let text = holder.vm.lastSentText ?? ""
                    guard let sidebarVM else { return }
                    _ = await sidebarVM.applyAutoTitleIfFirstExchange(
                        conversationID: conversationID,
                        messageRole: role,
                        messageText: text)
                }
            }
    }
}

/// Empty state before any selection: the static mark + one real action.
struct V2EmptyStateView: View {
    var onNewChat: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            OrbitalCoreView(state: .idle, isStatic: true)
                .frame(width: 72, height: 72)
            Text("What can I help you with?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text("Open the sidebar to pick a conversation, or start a new one.")
                .font(.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.xl)
            if let onNewChat {
                Button("New chat", action: onNewChat)
                    .buttonStyle(JarvisButtonStyle(.primary))
                    .padding(.top, 6)
                    .accessibilityIdentifier("chat.emptyNewChat")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.canvas)
    }
}

/// Item 9: the UIActivityViewController share sheet (message actions).
/// Presenting the controller directly inside a sheet works but fights
/// SwiftUI's presentation machinery on iOS 26 — this wrapper hosts it via
/// the classic representable bridge.
struct Item9ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Settings placeholder sheet (profile row destination — real Settings
/// lands in a later item: backend URL, voice, models per research/11 §6).
struct V2SettingsPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Tokens.Spacing.l) {
                Image(systemName: "gearshape")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.title3.weight(.medium))
                Text("Backend URL, voice, and models land here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.l)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, Tokens.Spacing.xl)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
