import Foundation

/// Result of a speech-to-text transcription.
public struct TranscriptionResult: Identifiable, Codable, Sendable {
    public let id: UUID
    public let text: String
    public let language: String
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let timestamp: Date
    public let gainDB: Double?

    public init(
        id: UUID = UUID(),
        text: String,
        language: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        timestamp: Date = Date(),
        gainDB: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.duration = duration
        self.processingTime = processingTime
        self.timestamp = timestamp
        self.gainDB = gainDB
    }

    /// Formatted gain string like "+13.5dB" or "-2.1dB". Nil if not normalized or trivial gain.
    public var formattedGain: String? {
        guard let db = gainDB, abs(db) >= 1.0 else { return nil }
        return String(format: "%+.1fdB", db)
    }

    /// Duration formatted as "Xs" or "M:SS".
    public var formattedDuration: String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Processing time formatted as "X.Xs".
    public var formattedProcessingTime: String {
        String(format: "%.1fs", processingTime)
    }

    /// Relative timestamp like "2m ago", "1h ago".
    public var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}
