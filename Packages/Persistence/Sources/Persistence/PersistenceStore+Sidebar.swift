import Foundation
import GRDB

/// Item 3 sidebar read/write APIs (feature #2): a paginated, archived-
/// excluding conversations page query + the app-state KV surface the
/// view model's state-restoration writes through. Additive to Item 1/2.
extension PersistenceStore {

    // MARK: - Paginated conversations (sidebar Recents)

    /// Recents page: non-archived, unpinned, newest first, exactly `limit`
    /// rows (or fewer at the end), with a `limit+1` probe for `hasMore`.
    public struct ConversationPage: Sendable, Equatable {
        public let rows: [StoredConversation]
        public let hasMore: Bool
    }

    /// Pinned rows, newest first (sidebar Pinned section source).
    public func conversationsPinned(limit: Int = 100) async -> [StoredConversation] {
        (try? await dbWriter.read { db in
            try StoredConversation
                .filter(Column("archived") == false)
                .filter(Column("pinned") == true)
                .order(Column("updated_at").desc, Column("created_at").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// One page of the Recents list: archived excluded, pinned excluded
    /// (pinned live in their own section), newest first.
    public func conversationsPage(offset: Int, limit: Int) async -> ConversationPage {
        let rows = (try? await dbWriter.read { db in
            try StoredConversation
                .filter(Column("archived") == false)
                .filter(Column("pinned") == false)
                .order(Column("updated_at").desc, Column("created_at").desc, Column("id").desc)
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }) ?? []
        let hasMore = rows.count > limit
        return ConversationPage(rows: Array(rows.prefix(limit)), hasMore: hasMore)
    }

    // MARK: - App-state KV (state restoration, Item 3 §4)

    /// Persist one JSON-encodable app-state value under a stable key
    /// (widget_snapshot table = generic KV: key / value_json / updated_at).
    public func setAppState<T: Encodable>(_ value: T, key: String) async {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        await updateWidgetSnapshot(WidgetSnapshotEntry(key: key, valueJSON: json))
    }

    /// Read one app-state value back; nil when absent or undecodable
    /// (schema drift degrades to defaults, never crashes).
    public func appState<T: Decodable>(_ type: T.Type, key: String) async -> T? {
        guard let entry = await widgetSnapshotEntry(key: key),
              let data = entry.valueJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Convenience: remove one app-state key (e.g. selection deleted).
    public func removeAppState(key: String) async {
        _ = try? await dbWriter.write { db in
            _ = try WidgetSnapshotEntry.filter(Column("key") == key).deleteAll(db)
        }
    }
}
