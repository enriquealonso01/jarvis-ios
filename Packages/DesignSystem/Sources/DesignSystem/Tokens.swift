import SwiftUI

/// Design tokens for v2 (plan §5.1 — bubbles, composer, markdown, cards live
/// here from M1 items onward). UI Law §2: user bubbles right-aligned tinted,
/// assistant messages full-width, never bubbled.
public enum Tokens {
    public enum Bubble {
        /// Max width fraction of the container for a user bubble (UI Law §2: ~85%).
        public static let maxWidthFraction: CGFloat = 0.85
        public static let cornerRadius: CGFloat = 18
        /// Assistant messages render full-width with no bubble chrome.
        public static let assistantInset: CGFloat = 0
    }

    public enum Composer {
        /// Composer grows to ~5–6 lines then scrolls internally (UI Law §6).
        public static let maxVisibleLines: Int = 6
        public static let cornerRadius: CGFloat = 22
        /// >5k chars pasted auto-converts to an attachment chip (UI Law §6).
        public static let largePasteThreshold: Int = 5_000
    }

    public enum Sidebar {
        /// iPhone slide-over ~85% width, above the conversation (UI Law §1).
        public static let widthFraction: CGFloat = 0.85
        /// Monotonic bottom buffer — added once, never removed (UI Law §5).
        public static let scrollBottomBuffer: CGFloat = 50
        /// Recents page size (Item 3 §2: lists with pagination).
        public static let recentsPageSize = 20
        /// Standard row height — within iOS list norms (≤48pt, tester QA).
        public static let rowHeight: CGFloat = 44
        /// Panel corner radius on the trailing edge.
        public static let panelCornerRadius: CGFloat = 16
        /// Add-on chip height in the horizontal bar (UI Law §1).
        public static let addOnChipHeight: CGFloat = 32
        /// KV keys — sidebar state restoration writes through the store.
        public enum Keys {
            public static let isOpen = "sidebar.is_open"
            public static let projectsExpanded = "sidebar.projects_expanded"
            public static let lastSelection = "sidebar.last_selection"
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
