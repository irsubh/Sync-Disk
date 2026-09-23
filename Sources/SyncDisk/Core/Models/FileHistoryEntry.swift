import Foundation

public enum ChangeType: String, Codable, Sendable, CaseIterable {
    case created = "created"
    case modified = "modified"
    case deleted = "deleted"
    case renamed = "renamed"
    
    public var displayName: String {
        switch self {
        case .created: return "Created"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }
    
    public var iconName: String {
        switch self {
        case .created: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "trash.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        }
    }
}

public struct FileHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceId: UUID
    public let logicalPath: String          // e.g. "Documents/Report.pdf"
    public let originalFilename: String     // e.g. "Report.pdf"
    public let timestamp: Date
    public let changeType: ChangeType
    public let previousPath: String?        // For renamed files
    public var fileSize: Int64
    public let sha256: String
    public var historyRelativePath: String  // Relative path inside backup history storage
    public var isCurrentVersion: Bool
    public var versionNumber: Int
    
    public init(
        id: UUID = UUID(),
        sourceId: UUID,
        logicalPath: String,
        originalFilename: String,
        timestamp: Date = Date(),
        changeType: ChangeType,
        previousPath: String? = nil,
        fileSize: Int64,
        sha256: String,
        historyRelativePath: String,
        isCurrentVersion: Bool = false,
        versionNumber: Int = 1
    ) {
        self.id = id
        self.sourceId = sourceId
        self.logicalPath = logicalPath
        self.originalFilename = originalFilename
        self.timestamp = timestamp
        self.changeType = changeType
        self.previousPath = previousPath
        self.fileSize = fileSize
        self.sha256 = sha256
        self.historyRelativePath = historyRelativePath
        self.isCurrentVersion = isCurrentVersion
        self.versionNumber = versionNumber
    }
    
    // MARK: - Formatting Helpers
    
    public var shortHash: String {
        if sha256.isEmpty { return "" }
        return String(sha256.prefix(7))
    }
    
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
    
    public var formattedDateOnly: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(timestamp) {
            return "Today"
        } else if calendar.isDateInYesterday(timestamp) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd MMM yyyy"
            return formatter.string(from: timestamp)
        }
    }
    
    public var formattedFullTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}
