import SwiftUI

/// Design tokens (UI Law §2): every color, font, and dimension the UI uses
/// comes from here — no hardcoded palette, no fixed sizes in feature code.
public enum Tokens {

    public enum Composer {
        public static let largePasteThreshold: Int = 5_000
    }

    public enum Sidebar {
        /// iPhone slide-over ~85% width, above the conversation (UI Law §1).
        public static let widthFraction: CGFloat = 0.85
        /// Monotonic bottom buffer — added once, never removed (UI Law §5).
        public static let scrollBottomBuffer: CGFloat = 50
        /// Recents page size (Item 3 §2: lists with pagination).
        public static let recentsPageSize: Int = 20
        /// Standard row height — within iOS list norms (≤48pt, tester QA).
        public static let rowHeight: CGFloat = 44
        /// Panel corner radius on the trailing edge.
        public static let panelCornerRadius: CGFloat = 16
        /// Add-on chip capsule height in the horizontal bar (UI Law §1) —
        /// icon-over-label chip.
        public static let addOnChipHeight: CGFloat = 64
        /// KV keys — sidebar state restoration writes through the store.
        public enum Keys {
            /// Store key: sidebar open/closed across launches (Item 3 §4).
            public static let sidebarOpen = "v2.sidebar.open"
            /// Store key: last selected sidebar destination (Item 3 §4).
            public static let lastSelection = "v2.sidebar.last-selection"
            /// Store key: Projects section expanded/collapsed (Item 3 §4).
            public static let projectsExpanded = "v2.sidebar.projects-expanded"
        }
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    /// Pure function: should a paste be converted to an attachment chip?
    public static func isLargePaste(_ characterCount: Int) -> Bool {
        characterCount > Composer.largePasteThreshold
    }
}
