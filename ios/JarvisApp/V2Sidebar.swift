import SwiftUI
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
            SidebarPanelView(vm: vm) { selection in
                handle(selection)
            }
        } underlying: {
            chatSurface
        }
        .task {
            await vm.restoreState()
            await vm.reload()
        }
    }

    // MARK: Routing (Item 3 §3)

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
        case .search, .projectHome, .addOn:
            // Placeholders (Item 6 search, M3 project home, add-on screens).
            self.selection = selection
        }
    }

    // MARK: Chat surface (v2 composer + open affordances)

    private var chatSurface: some View {
        NavigationStack {
            Group {
                if let id = vm.selectedConversationID {
                    // Item 4: the v2 chat surface = composer docked above
                    // the keyboard (UI Law §6). The transcript body itself
                    // is the streaming engine's render (Item 5 wires the
                    // full thread view); for now a scroller placeholder
                    // sits above the live composer.
                    VStack(spacing: 0) {
                        V2ChatPlaceholderView(conversationID: id)
                        V2ComposerHost(store: store, conversationID: id, sidebarVM: vm)
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
                withAnimation { Task<Void, Never>(priority: .userInitiated) { @MainActor in await vm.setProjectsExpanded(!vm.projectsExpanded) } }
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
                // Sample data is acceptable per the item brief (schema
                // exists); projects create/manage in a later milestone.
                ForEach(vm.projects) { node in
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
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

// MARK: - Placeholder surfaces (this item = navigation shell)

/// Chat surface placeholder: real transcript streaming exists from Item 2
/// (ChatViewModel); the v2 chat screen lands with the composer item.
struct V2ChatPlaceholderView: View {
    let conversationID: UUID

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Conversation")
                .font(.title3.weight(.medium))
            Text(conversationID.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Chat surface continues here (Item 4: composer + transcript)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @StateObject private var holder: ComposerVMHolder
    @State private var isModelChooserPresented = false
    @State private var chooserSelection: String?

    /// StateObject needs a concrete holder: the composer VM's conversation
    /// target is set after init (conversation becomes known on selection).
    @MainActor
    final class ComposerVMHolder: ObservableObject {
        let vm: ComposerViewModel
        init(store: PersistenceStore?) {
            vm = ComposerViewModel(store: store)
        }
    }

    init(store: PersistenceStore?, conversationID: UUID, sidebarVM: FeaturesChat.SidebarViewModel? = nil) {
        self.store = store
        self.conversationID = conversationID
        self.sidebarVM = sidebarVM
        _holder = StateObject(wrappedValue: ComposerVMHolder(store: store))
    }

    var body: some View {
        V2ComposerView(vm: holder.vm, isModelChooserPresented: $isModelChooserPresented)
            .onAppear {
                holder.vm.conversationID = conversationID
                Task { await holder.vm.restoreState() }
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
