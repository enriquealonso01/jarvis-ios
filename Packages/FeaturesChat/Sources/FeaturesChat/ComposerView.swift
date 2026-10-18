import SwiftUI
import DesignSystem

// Cross-platform system colors (CI runs swift tests for macOS too).
#if canImport(UIKit)
import UIKit
private func sysColor(_ name: String) -> Color {
    switch name {
    case "secondaryBg": return sysColor("secondaryBg")
    case "tertiaryBg": return sysColor("tertiaryBg")
    case "separator": return sysColor("separator")
    default: return Color.gray
    }
}
#else
import AppKit
private func sysColor(_ name: String) -> Color {
    switch name {
    case "secondaryBg": return Color(nsColor: .controlBackgroundColor)
    case "tertiaryBg": return Color(nsColor: .underPageBackgroundColor)
    case "separator": return Color(nsColor: .separatorColor)
    case "tertiaryFill": return Color(nsColor: .quaternarySystemFill)
    case "sysBg": return Color(nsColor: .windowBackgroundColor)
    case "secondaryLabel": return Color(nsColor: .secondaryLabelColor)
    default: return Color.gray
    }
}
#endif

// MARK: - Item 4: Composer view (feature #3, P0) — UI Law §6, verbatim:
//   Rounded capsule docked above keyboard. Three controls: ＋ (left), text
//   field, mic + waveform (right). ＋ opens bottom sheet: Photos, Camera,
//   Files (+ Hermes workspace files). Tool toggles = blue labeled chips
//   with × to clear. Composer grows to ~5–6 lines then scrolls internally;
//   send enables only with content; long-press send = one-off model
//   chooser; large pastes (>5k chars) auto-convert to attachment chips.
//   Model context picker at top of conversation, never in the composer.
// Dark mode: pure system-following — every color below is a system or
// DesignSystem token value; no hardcoded palette.

/// The v2 composer capsule. Zero composer behavior lives here — all state
/// and rules belong to `ComposerViewModel` (tester-pinned contract).
public struct V2ComposerView: View {
    @ObservedObject public var vm: ComposerViewModel
    /// Large-paste interception (UI Law §6): SwiftUI delivers typed text
    /// through the binding; this diff detects a paste jump (one edit that
    /// overshoots the threshold) and routes it through the chip path.
    @State private var lastObservedText = ""
    /// One-off model chooser presentation (fired via the .showModelChooser
    /// intent the app target forwards back into this binding).
    @Binding public var isModelChooserPresented: Bool

    public init(vm: ComposerViewModel, isModelChooserPresented: Binding<Bool>) {
        self.vm = vm
        self.isModelChooserPresented = isModelChooserPresented
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            toolChips
            attachmentChips
            capsule
        }
        .sheet(isPresented: Binding(
            get: { vm.isSheetPresented },
            set: { present in
                if present { vm.plusTapped() } else { vm.dismissSheet() }
            }
        )) {
            V2ComposerPlusSheet(vm: vm)
        }
    }

    // MARK: Tool chips (blue labeled chips with ×, never silent)

    @ViewBuilder
    private var toolChips: some View {
        if vm.isChipAreaVisible {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(vm.selectedModels) { tool in
                        HStack(spacing: Tokens.Spacing.xs) {
                            Text(tool.label)
                                .font(.footnote.weight(.medium))
                            Button {
                                vm.toggle(modelID: tool.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.footnote)
                            }
                            .accessibilityLabel("Clear \(tool.label)")
                            .accessibilityIdentifier("composer.toolChip.clear.\(tool.id)")
                        }
                        .padding(.horizontal, Tokens.Spacing.m)
                        .frame(minHeight: 28)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("composer.toolChip.\(tool.id)")
                    }
                }
            }
            .accessibilityIdentifier("composer.toolChipRow")
        }
    }

    // MARK: Attachment chips (＋ sheet picks + large-paste chips)

    @ViewBuilder
    private var attachmentChips: some View {
        if !vm.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(vm.attachments) { attachment in
                        HStack(spacing: Tokens.Spacing.xs) {
                            Image(systemName: iconName(for: attachment.source))
                                .font(.footnote)
                            Text(attachment.displayName)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                            Button {
                                vm.removeAttachment(id: attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.footnote)
                            }
                            .accessibilityLabel("Remove \(attachment.displayName)")
                            .accessibilityIdentifier("composer.attachmentChip.remove.\(attachment.id.uuidString)")
                        }
                        .padding(.horizontal, Tokens.Spacing.m)
                        .frame(minHeight: 28)
                        .background(Capsule().fill(sysColor("secondaryBg")))
                        .accessibilityIdentifier("composer.attachmentChip")
                    }
                }
            }
            .accessibilityIdentifier("composer.attachmentChipRow")
        }
    }

    // MARK: The capsule (＋ left · text field · mic/waveform + send right)

    private var capsule: some View {
        HStack(alignment: .bottom, spacing: Tokens.Spacing.s) {
            plusButton
            textField
            waveformButton
            sendButton
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
        .background(
            Capsule().fill(sysColor("secondaryBg"))
        )
        .overlay(
            Capsule().strokeBorder(sysColor("separator"), lineWidth: 0.5)
        )
        .accessibilityIdentifier("composer.capsule")
    }

    private var plusButton: some View {
        Button {
            vm.plusTapped()
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .frame(width: 32, height: 32)
                .background(Circle().fill(sysColor("tertiaryBg")))
        }
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("composer.plusButton")
    }

    /// Text field. Grows line by line up to `ComposerViewModel.maxLines`
    /// (inside the §6 5–6-line window), then `axis: .vertical` takes over
    /// scrolling internally — the frame height comes from the VM's pure
    /// `fieldHeight` so layout and logic can never disagree.
    private var textField: some View {
        TextField("Message", text: Binding(
            get: { vm.text },
            set: { newValue in
                // Paste detection: a single edit jumping past the threshold
                // is a paste — convert to a chip, never grow the field.
                let jump = newValue.count - lastObservedText.count
                if jump > Tokens.Composer.largePasteThreshold {
                    vm.onPaste(text: newValue)
                    vm.text = lastObservedText
                } else {
                    vm.text = newValue
                    lastObservedText = newValue
                }
            }
        ), axis: .vertical)
        .font(.body)
        .lineLimit(1...ComposerViewModel.maxLines)
        .frame(minHeight: ComposerViewModel.lineHeight,
               maxHeight: vm.fieldHeight, alignment: .leading)
        .accessibilityIdentifier("composer.textField")
    }

    /// Waveform button — STARTS A CALL (UI Law §7), never a dictation mode.
    /// The VM emits `.startCall`; the app target wires CallManager there.
    private var waveformButton: some View {
        Button {
            vm.waveformTapped()
        } label: {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .accessibilityLabel("Start voice call")
        .accessibilityIdentifier("composer.waveformButton")
    }

    /// Send enables ONLY with non-whitespace content (UI Law §6); mid-stream
    /// it presents the stop affordance (UI Law §3). Long-press = one-off
    /// model chooser — the persistent model context picker lives at the top
    /// of the conversation, never in the composer.
    private var sendButton: some View {
        Button {
            Task { try? await vm.send() }
        } label: {
            Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(vm.canSend
                        ? Color.accentColor
                        : sysColor("tertiaryFill"))
                )
                .foregroundStyle(vm.canSend
                    ? sysColor("sysBg")
                    : sysColor("secondaryLabel"))
        }
        .disabled(!vm.canSend)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                vm.sendLongPressed()
                isModelChooserPresented = true
            }
        )
        .accessibilityLabel("Send")
        .accessibilityIdentifier("composer.sendButton")
    }

    private func iconName(for source: ComposerAttachment.Source) -> String {
        switch source {
        case .paste: return "doc.on.clipboard"
        case .picker: return "paperclip"
        }
    }
}

// MARK: - ＋ bottom sheet (Photos, Camera, Files, Hermes files)

/// Row set per UI Law §6: exactly Photos/Camera/Files/HermesFiles, in that
/// order, straight from the VM's `sheetOptions`. Real pickers are Item 6 —
/// this item ships the rows; a picked row stages a chip so it's never silent.
struct V2ComposerPlusSheet: View {
    @ObservedObject var vm: ComposerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Add to message")
                .font(.headline)
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.top, Tokens.Spacing.l)

            ForEach(vm.sheetOptions) { row in
                Button {
                    vm.selectSheetOption(row)
                } label: {
                    Label(row.label, systemImage: row.systemImage)
                        .font(.body)
                        .frame(minHeight: Tokens.Sidebar.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Tokens.Spacing.l)
                .accessibilityIdentifier("composer.sheet.row.\(row.id.rawValue)")
            }

            Spacer(minLength: Tokens.Spacing.l)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - One-off model chooser (long-press send, UI Law §6)

/// Presented over the composer after a long-press on send. The persistent
/// model context picker is a TOP-of-conversation control (never in the
/// composer); this sheet only selects the model for the next message. The
/// app target owns this sheet + the `.showModelChooser` intent routing; the
/// payload is `vm.chooserOptions` (the catalog, never the selection).
public struct V2ModelChooserSheet: View {
    @ObservedObject public var vm: ComposerViewModel
    @Binding public var selection: String?
    @Environment(\.dismiss) private var dismiss

    public init(vm: ComposerViewModel, selection: Binding<String?>) {
        self.vm = vm
        self.selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Use model for this message")
                .font(.headline)
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.top, Tokens.Spacing.l)
            ForEach(vm.chooserOptions) { model in
                Button {
                    selection = model.label
                    dismiss()
                } label: {
                    HStack {
                        Text(model.label).font(.body)
                        Spacer()
                        if selection == model.label {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .frame(minHeight: Tokens.Sidebar.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Tokens.Spacing.l)
                .accessibilityIdentifier("composer.modelChooser.\(model.id)")
            }
            Spacer(minLength: Tokens.Spacing.l)
        }
        .presentationDetents([.medium])
    }
}
