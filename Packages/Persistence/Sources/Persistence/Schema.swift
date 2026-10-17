import Foundation
import GRDB

/// GRDB schema v1 (plan §5.2, feature #4): task-spec tables + FTS5 + the
/// App-Group widget snapshot. Migration identifiers/order are pinned by
/// BuildSmokeTests — append, never rewrite.
enum AppSchema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1: core tables --------------------------------------------------
        migrator.registerMigration(Schema.Migrations.v1.identifier) { db in
            try db.create(table: "conversations") { t in
                t.column("id", .blob).primaryKey()
                t.column("project_id", .blob).indexed()
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull().indexed()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("last_message_preview", .text)
            }
            try db.create(table: "messages") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversation_id", .blob).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("status", .text).notNull()
                    .defaults(to: MessageStatus.sending.rawValue)
                t.column("attachments", .text).notNull().defaults(to: "[]")
                t.column("branch_id", .text)
                t.column("branch_index", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "messages.byConversationCreated",
                          on: "messages", columns: ["conversation_id", "created_at"])
            try db.create(index: "messages.byStatus", on: "messages", columns: ["status"])

            try db.create(table: "branches") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversation_id", .blob).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("parent_message_id", .blob)
                    .references("messages", onDelete: .setNull)
                t.column("branch_index", .integer).notNull().defaults(to: 0)
                t.column("active", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "branches.byConversation",
                          on: "branches", columns: ["conversation_id", "branch_index"])

            try db.create(table: "outbox") { t in
                t.column("id", .blob).primaryKey()
                t.column("payload", .text).notNull() // OutboxPayload JSON
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("next_retry_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "outbox.byNextRetry", on: "outbox", columns: ["next_retry_at"])

            try db.create(table: "run_cards") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversation_id", .blob).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("run_id", .text).notNull().indexed()
                t.column("status", .text).notNull()
                    .defaults(to: RunCardStatus.queued.rawValue)
                t.column("steps", .text).notNull().defaults(to: "[]") // [RunStep] JSON
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "run_cards.byConversation",
                          on: "run_cards", columns: ["conversation_id", "created_at"])
        }

        // v1: FTS5 index over message content -------------------------------
        migrator.registerMigration(Schema.Migrations.v1FTS.identifier) { db in
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.column("content")
            }
        }

        // v1: App-Group widget snapshot (feature #40 prep, schema only) -----
        // Read-only for the widgets extension later: it opens the same file in
        // the App Group container and SELECTs; only the app process writes.
        migrator.registerMigration(Schema.Migrations.v1WidgetSnapshot.identifier) { db in
            try db.create(table: "widget_snapshot") { t in
                t.column("key", .text).primaryKey()
                t.column("value_json", .text).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }

        // v2: §5.2 completeness — projects / runs / run_steps / recordings /
        // transcript_segments (additive; v1 history is never rewritten).
        migrator.registerMigration(Schema.Migrations.v2ProjectsRuns.identifier) { db in
            try db.create(table: "projects") { t in
                t.column("id", .blob).primaryKey()
                t.column("name", .text).notNull()
                t.column("instructions", .text).notNull().defaults(to: "")
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "projects.byUpdated", on: "projects", columns: ["updated_at"])

            try db.create(table: "runs") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversation_id", .blob)
                    .references("conversations", onDelete: .cascade)
                t.column("project_id", .blob)
                    .references("projects", onDelete: .setNull)
                t.column("status", .text).notNull()
                    .defaults(to: RunStatus.queued.rawValue)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "runs.byConversation",
                          on: "runs", columns: ["conversation_id", "created_at"])
            try db.create(index: "runs.byProject", on: "runs", columns: ["project_id"])

            try db.create(table: "run_steps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("run_id", .blob).notNull()
                    .references("runs", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("state", .text).notNull()
                    .defaults(to: RunStepState.pending.rawValue)
                t.column("step_order", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "run_steps.byRun",
                          on: "run_steps", columns: ["run_id", "step_order"])

            try db.create(table: "recordings") { t in
                t.column("id", .blob).primaryKey()
                t.column("file_path", .text).notNull()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "transcript_segments") { t in
                t.column("id", .blob).primaryKey()
                t.column("recording_id", .blob).notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("speaker", .text).notNull().defaults(to: "")
                t.column("text", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "transcript_segments.byRecording",
                          on: "transcript_segments", columns: ["recording_id", "created_at"])
        }

        // v2: messages sync columns — persisted `server_id` (nullable, unique)
        // + `pendingSync` (default true). Existing rows keep pendingSync=true.
        migrator.registerMigration(Schema.Migrations.v2MessageSyncColumns.identifier) { db in
            try db.alter(table: "messages") { t in
                t.add(column: "server_id", .text)
                t.add(column: "pending_sync", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "messages.byServerID",
                          on: "messages", columns: ["server_id"], unique: true)
        }

        // v2FTS: FTS5 index over transcript segments (§5.2 unified search).
        migrator.registerMigration(Schema.Migrations.v2FTSTranscripts.identifier) { db in
            try db.create(virtualTable: "transcript_segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "transcript_segments")
                t.column("text")
            }
        }

        // Item 2 (#1): per-message stream resume pointer. The SSE
        // Last-Event-ID resume reads this; 0 = no events applied yet.
        // (Index already exists from v1 — columns only.)
        migrator.registerMigration(Schema.Migrations.v2LastEventID.identifier) { db in
            try db.alter(table: "messages") { t in
                t.add(column: "last_event_id", .integer).notNull().defaults(to: 0)
            }
        }

        // Item 3 (#2): project pin flag — sidebar Pinned mixes pinned chats
        // and pinned projects. Existing projects default to unpinned.
        migrator.registerMigration(Schema.Migrations.v2ProjectPinned.identifier) { db in
            try db.alter(table: "projects") { t in
                t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
