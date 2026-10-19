import SwiftUI
import UIKit
import JarvisKit
import Persistence
import DesignSystem
import FeaturesChat
import FeaturesSidebar

// MARK: - Item 3: ChatGPT-grammar slide-over sidebar (feature #2, P0)
//
// UI Law §1 + research/11 §1, verbatim:
//   • Slide-over ~85% width sliding in ABOVE the conversation (chat edge
//     stays visible) — never push navigation, never docked on phone.
//   • Opens via the ≡ menu button or a leading-edge swipe; closes via
//     scrim tap or swipe-left.
//   • Contents top-to-bottom: New chat + Search rows → horizontal add-ons
//     bar (Agent Runs · Recordings · Memory · Schedules) → Library
//     placeholder → Pinned → Projects (collapsible) → Recents (paginated)
//     → profile row → Settings placeholder sheet.
// Dark mode + Dynamic Type: every color/font is a system or token value —
// no hardcoded palette, no fixed font sizes.

/// The v2 chat surface + slide-over sidebar shell. The chat body is a v1
/// placeholder screen — Item 3 ships the navigation shell, not the new
/// transcript (Item 4 lands the composer + transcript).
struct V2SidebarShell: View {
    /// View model over the shared store; nil store (open failure) degrades
    /// to an empty sidebar — never a launch crash (same contract as Item 1).
    /// (Qualified: FeaturesSidebar ships its own legacy SidebarViewModel;
    /// the store-contract implementation this shell hosts is FeaturesChat's.)
    @StateObject private var vm: FeaturesChat.SidebarViewModel
    @State private var selection: SidebarSelection?
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
                onOpenProjectChat: { chatID in projectHomeChatTarget = chatID })
        } underlying: {
            chatSurface
        }
        .task {
            await vm.restoreState()
            await vm.reload()
        }
    }
    // MARK: Routing (Item 3 §3)

    /// Item 9/10: set on Project Home chat opens — Project Home and the
    /// chat surface share ONE NavigationStack, so the chat cannot appear
    /// beneath its own Project Home (§P-5 composition contract).
    @State private var projectHomeChatTarget: UUID?

    private func handle(_ selection: SidebarSelection) {
        switch selection {
        case .chat(let id):
            Task {
                await vm.select(conversationID: id)
                self.selection = .chat(id: id)
            }
        case .newChat:
            Task {
                let conversation = await vm.newChat()
                self.selection = .chat(id: conversation.id)
            }
        case .projectHome(let id):
            // Item 10: Project Home is the real destination (was a
            // placeholder). Chats open INSIDE its stack (composition law).
            projectHomeChatTarget = nil
            // `self.` — the parameter shadows the @State property here.
            self.selection = .projectHome(id: id)
        case .search, .addOn:
            // Placeholders (Item 6 search, add-on screens).
            self.selection = selection
        }
    }

    // MARK: Chat surface (v2 composer + open affordances)

    @ViewBuilder
    private var chatSurface: some View {
        NavigationStack {
            Group {
                if let homeID = projectHomeChatTarget {
                    // Item 10: a chat opened from Project Home keeps the
                    // project's stack — Project Home stays underneath (the
                    // back button returns to it; no orphaned chat surface).
                    V2ChatHost(store: store, conversationID: homeID, sidebarVM: vm)
                        .id(homeID)
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                } else if let id = vm.selectedConversationID {
                    // Item 8: the v2 chat surface = REAL transcript (UI Law
                    // §2/§3/§5 — full-width assistant blocks, tinted user
                    // bubbles, anchored streaming) + the Item-4 composer
                    // docked below it. V2ChatHost owns the store-backed
                    // transcript VM and replays composer sends into it.
                    VStack(spacing: 0) {
                        V2ChatHost(store: store, conversationID: id,
                                   sidebarVM: vm)
                    }
                    .id(id)
                } else {
                    V2EmptyStateView()
                }
            }
            .navigationTitle("JARVIS")
            .navigationBarTitleDisplayMode(.inline)
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
}

// MARK: - The sidebar panel (contents per UI Law §1)

struct SidebarPanelView: View {
    @ObservedObject var vm: FeaturesChat.SidebarViewModel
    let onSelect: (SidebarSelection) -> Void
    /// Item 10: the shell's shared store (Project Home reads the same DB).
    var store: PersistenceStore? = nil
    /// Item 10: shell router for chats opened from Project Home (the
    /// panel struct itself has no access to shell state).
    var onOpenProjectChat: ((UUID) -> Void)? = nil
    @State private var settingsPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    newChatRow
                    searchRow
                    addOnsBar
                    libraryRow
                    pinnedSection
                    projectsSection
                    recentsSection
                    if vm.canLoadMoreRecents {
                        loadMoreButton
                    }
                }
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.top, Tokens.Spacing.l)
                .padding(.bottom, Tokens.Spacing.l)
            }

            Divider()
            profileRow
        }
        .sheet(isPresented: $settingsPresented) {
            V2SettingsPlaceholderSheet()
        }
    }

    // MARK: New chat + Search rows

    private var newChatRow: some View {
        Button {
            onSelect(.newChat)
        } label: {
            Label("New chat", systemImage: "square.and.pencil")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Tokens.Sidebar.rowHeight,
                       alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("sidebar.newChat")
    }

    /// Search row — placeholder routing to Item 6 (client-side filter in
    /// the VM already narrows the lists once a field lands here).
    private var searchRow: some View {
        Button {
            onSelect(.search)
        } label: {
            Label("Search chats", systemImage: "magnifyingglass")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Tokens.Sidebar.rowHeight,
                       alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("sidebar.search")
    }

    // MARK: Horizontal add-ons bar (chips; destinations are stubs)

    private var addOnsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(V2AddOnChip.standard) { chip in
                    Button {
                        if let sel = chip.sidebarSelection {
                            onSelect(sel)
                        }
                    } label: {
                        Label(chip.title, systemImage: chip.systemImage)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, Tokens.Spacing.m)
                            .frame(minHeight: Tokens.Sidebar.addOnChipHeight)
                            .background(
                                Capsule().fill(Color(uiColor: .secondarySystemBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.addOn.\(chip.id)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Library row placeholder (ChatGPT-grammar slot; images/files land in
    /// a later milestone item). No navigation yet — the row is the contract.
    private var libraryRow: some View {
        Button {
            // Placeholder destination (no selection case yet).
        } label: {
            Label("Library", systemImage: "books.vertical")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: Tokens.Sidebar.rowHeight,
                       alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.library")
    }

    // MARK: Pinned (chats, newest first)

    @ViewBuilder
    private var pinnedSection: some View {
        if !vm.pinned.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("Pinned")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(vm.pinned) { conversation in
                    V2ConversationRow(
                        conversation: conversation,
                        isSelected: vm.selectedConversationID == conversation.id,
                        contextMenu: .pinAndArchive
                    ) {
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
            }
        }
    }

    // MARK: Projects (collapsible section; schema from Item 1)

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Button {
                Task(priority: .userInitiated) { await vm.setProjectsExpanded(!vm.projectsExpanded) }
            } label: {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text("Projects")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Image(systemName: vm.projectsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.projectsToggle")

            if vm.projectsExpanded {
                // Item 10: each row navigates to its Project Home (title,
                // instructions, sources, project-scoped chats, new chat).
                ForEach(vm.projects) { node in
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        NavigationLink {
                            V2ProjectHomeView(
                                projectID: node.project.id,
                                store: store ?? PersistenceStore(),
                                onOpenChat: onOpenProjectChat)
                        } label: {
                            HStack(spacing: Tokens.Spacing.s) {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(node.project.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(node.conversations.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: Tokens.Sidebar.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar.project.\(node.project.id.uuidString)")

                        ForEach(node.conversations) { conversation in
                            V2ConversationRow(
                                conversation: conversation,
                                isSelected: vm.selectedConversationID == conversation.id,
                                contextMenu: .pinAndArchive,
                                indented: true
                            ) {
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
                    }
                }
            }
        }
    }

    // MARK: Recents (paginated from the store)

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Recents")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if vm.recents.isEmpty && vm.loaded {
                Text(vm.searchQuery.isEmpty ? "No conversations yet" : "No matches")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Spacing.s)
            }
            ForEach(vm.filteredRecents) { conversation in
                V2ConversationRow(
                    conversation: conversation,
                    isSelected: vm.selectedConversationID == conversation.id,
                    contextMenu: .pinAndArchive
                ) {
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
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await vm.loadMoreRecents() }
        } label: {
            Text("Load more")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: Tokens.Sidebar.rowHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("sidebar.loadMore")
    }

    // MARK: Profile row (→ Settings placeholder sheet)

    private var profileRow: some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS")
                        .font(.headline)
                    Text("Settings")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.vertical, Tokens.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.profileRow")
    }
}

// MARK: - Add-on chips (non-functional stubs are fine, visible is not)

struct V2AddOnChip: Identifiable {
    enum ChipID: String {
        case runs, recordings, widgets, library
    }

    let id: String
    let title: String
    let systemImage: String
    let addOnID: ChipID

    /// Maps to the FeaturesSidebar selection enum (which pins exactly 4
    /// cases: runs / recordings / memory / schedules — a library case is
    /// intentionally absent there; Library is a sidebar row, not a chip).
    var sidebarSelection: SidebarSelection? {
        switch addOnID {
        case .runs: return .addOn(.runs)
        case .recordings: return .addOn(.recordings)
        case .widgets, .library: return nil // placeholder destinations
        }
    }

    static let standard: [V2AddOnChip] = [
        V2AddOnChip(id: "runs", title: "Agent Runs", systemImage: "arrow.triangle.branch", addOnID: .runs),
        V2AddOnChip(id: "recordings", title: "Recordings", systemImage: "waveform", addOnID: .recordings),
        V2AddOnChip(id: "widgets", title: "Widgets", systemImage: "square.grid.2x2", addOnID: .widgets),
    ]
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if let preview = conversation.lastMessagePreview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if conversation.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(minHeight: Tokens.Sidebar.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Item 5 FIX: .swipeActions never fired here — the three sidebar
        // sections render in a ScrollView+VStack, and .swipeActions is a
        // List-only modifier. Replaced with a row drag that reveals the
        // same red, non-full-swipe Delete (§8): confirm dialog → VM
        // swipeDelete path unchanged. Child gestures beat the shell's
        // plain .gesture (SlideOverSidebar), so panel-close is untouched.
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
                        .foregroundStyle(.white)
                        .frame(width: 88, height: Tokens.Sidebar.rowHeight)
                        .background(Color.red, in: Rectangle())
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
///     losing committed text (engine stop, partial persists).
struct V2ChatHost: View {
    let store: PersistenceStore?
    let conversationID: UUID
    /// Item 5: auto-title writes back into the sidebar's VM (shared store,
    /// one writer at a time — the shell owns exactly one).
    var sidebarVM: FeaturesChat.SidebarViewModel? = nil
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
                    store: store)
            }
            vm = TranscriptViewModel(
                conversationID: conversationID,
                store: store,
                streamClient: client)
        }
    }

    init(store: PersistenceStore?, conversationID: UUID,
         sidebarVM: FeaturesChat.SidebarViewModel? = nil) {
        self.store = store
        self.conversationID = conversationID
        self.sidebarVM = sidebarVM
        // Item 9: the real regenerate path — POST via the coordinator with
        // outbox replay on failure (offline sends are never lost). When the
        // server isn't configured there is NO send path, and the regenerate
        // control is omitted entirely (no fake buttons).
        if ServerConfig.shared.configured,
           let baseURL = URL(string: ServerConfig.shared.config.baseURL) {
            self.sendCoordinator = MessageSendCoordinator(
                api: JarvisKit.APIClient(config: JarvisKit.ServerConfig(baseURL: baseURL)),
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
            isStreaming: holder.vm.isStreaming)
    }

    var body: some View {
        V2TranscriptView(
            vm: holder.vm,
            actionViewModel: actionVM,
            regenerateSend: sendCoordinator == nil ? nil : regenerateSendPath)
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
                Task { await CallManager.shared.placeDirectCall() }
            })
        }
    }

    init(store: PersistenceStore?, conversationID: UUID, sidebarVM: FeaturesChat.SidebarViewModel? = nil,
         onDidSend: (() -> Void)? = nil, onStreamStop: (() async -> Void)? = nil,
         isStreaming: Bool = false) {
        self.store = store
        self.conversationID = conversationID
        self.sidebarVM = sidebarVM
        self.onDidSend = onDidSend
        self.onStreamStop = onStreamStop
        self.isStreaming = isStreaming
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

/// Empty state before any selection.
struct V2EmptyStateView: View {
    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("New chat")
                .font(.title3.weight(.medium))
            Text("Open the sidebar to pick a conversation or start a new one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
