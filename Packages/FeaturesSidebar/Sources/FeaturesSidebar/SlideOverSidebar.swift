import SwiftUI
import UIKit
import DesignSystem

/// iPhone slide-over sidebar geometry (UI Law §1, binding):
///   - ~85% width, sliding in ABOVE the conversation without fully
///     covering it (the remaining ~15% shows the conversation edge),
///   - scrim tap or swipe-left closes,
///   - NEVER docks on phone (docking is iPad-only, future item).
public struct SlideOverSidebar<Panel: View, Under: View>: View {
    @Binding private var isPresented: Bool
    private let panel: () -> Panel
    private let underlying: () -> Under

    @GestureState private var dragOffset: CGFloat = 0

    /// Panel width fraction of the container (Tokens.Sidebar.widthFraction).
    private let widthFraction: CGFloat
    /// iOS 18 has no horizontal-drag built-in dismissal for custom panels;
    /// this threshold mirrors the system sheet feel (~1/3 of the panel).
    private let dismissDragFraction: CGFloat = 0.3

    public init(
        isPresented: Binding<Bool>,
        widthFraction: CGFloat = Tokens.Sidebar.widthFraction,
        @ViewBuilder panel: @escaping () -> Panel,
        @ViewBuilder underlying: @escaping () -> Under
    ) {
        self._isPresented = isPresented
        self.widthFraction = widthFraction
        self.panel = panel
        self.underlying = underlying
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * widthFraction
            let dragThreshold = width * dismissDragFraction

            ZStack(alignment: .leading) {
                // The conversation stays visible underneath — never covered.
                underlying()
                    .disabled(isPresented) // scrim swallows taps; block under-scroll
                    .allowsHitTesting(!isPresented)

                // Scrim: tap to dismiss.
                if isPresented {
                    Color.black
                        .opacity(0.4)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .transition(.opacity)
                }

                // The panel itself.
                panel()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .updating($dragOffset) { value, state, _ in
                                // Only leftward drags move the panel (rubber-band rightward).
                                state = min(0, value.translation.width)
                            }
                            .onEnded { value in
                                if value.translation.width < -dragThreshold {
                                    close()
                                }
                            }
                    )
                    .offset(x: isPresented ? dragOffset : -width - 24)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isPresented)
            }
        }
    }

    private func close() {
        withAnimation { isPresented = false }
    }
}
