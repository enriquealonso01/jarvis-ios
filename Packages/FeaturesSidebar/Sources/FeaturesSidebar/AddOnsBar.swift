import SwiftUI
import DesignSystem

/// Horizontal add-ons bar — the slot ChatGPT uses for Images / Codex /
/// Pulse (UI Law §1). Agent Runs · Recordings · Memory · Schedules.
public struct AddOnsBar: View {
    @Binding var selection: SidebarSelection
    private let addOns: [SidebarAddOn]

    public init(
        addOns: [SidebarAddOn] = SidebarAddOn.standard,
        selection: Binding<SidebarSelection>
    ) {
        self.addOns = addOns
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(addOns) { addOn in
                    Button {
                        selection = .addOn(SidebarAddOnID(rawValue: addOn.id) ?? .runs)
                    } label: {
                        VStack(spacing: Tokens.Spacing.xs) {
                            Image(systemName: addOn.systemImage)
                                .font(.system(size: 17, weight: .medium))
                                .frame(height: 22)
                            Text(addOn.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(width: 72)
                        .padding(.vertical, Tokens.Spacing.s)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("sidebar.addOn.\(addOn.id)")
                    .accessibilityLabel(addOn.title)
                }
            }
            .padding(.horizontal, Tokens.Spacing.l)
        }
        .padding(.top, Tokens.Spacing.m)
    }
}
