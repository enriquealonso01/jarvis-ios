import Foundation

/// FeaturesCapture stub (features #34–#38 land here from M4). Pure chunking
/// policy for the meeting recorder — AVAudioEngine I/O itself lives behind the
/// recorder in M4; no audio imports in tested code (Linux-runnable).
public enum RecorderPolicy {
    /// Recorder chunks files at ~5-min boundaries — I/O stalls past ~40min on
    /// single files (plan feature #34). Returns the chunk index a timestamp
    /// belongs to.
    public static func chunkIndex(at timeInterval: TimeInterval, chunkSeconds: TimeInterval = 300) -> Int {
        Int(max(0, timeInterval) / chunkSeconds)
    }

    public static let defaultChunkSeconds: TimeInterval = 300
}

public struct Recording: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var transcriptSegmentCount: Int

    public init(id: UUID = UUID(), title: String, startedAt: Date = Date(),
                durationSeconds: Double = 0, transcriptSegmentCount: Int = 0) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.transcriptSegmentCount = transcriptSegmentCount
    }
}
