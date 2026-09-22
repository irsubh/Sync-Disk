import Foundation

public struct SnapshotManifestItem: Codable, Sendable, Identifiable {
    public var id: String { logicalPath }
    public let logicalPath: String
    public let originalFilename: String
    public let fileSize: Int64
    public let sha256: String
    public let changeType: String
    public let timestamp: Date
    public let versionNumber: Int
    public let relativePathInSnapshot: String
    
    public init(
        logicalPath: String,
        originalFilename: String,
        fileSize: Int64,
        sha256: String,
        changeType: String,
        timestamp: Date,
        versionNumber: Int,
        relativePathInSnapshot: String
    ) {
        self.logicalPath = logicalPath
        self.originalFilename = originalFilename
        self.fileSize = fileSize
        self.sha256 = sha256
        self.changeType = changeType
        self.timestamp = timestamp
        self.versionNumber = versionNumber
        self.relativePathInSnapshot = relativePathInSnapshot
    }
}

public struct SnapshotManifest: Codable, Sendable {
    public let snapshotId: UUID
    public let timestamp: Date
    public let dateFormatted: String
    public var files: [SnapshotManifestItem]
    
    public init(snapshotId: UUID = UUID(), timestamp: Date, files: [SnapshotManifestItem] = []) {
        self.snapshotId = snapshotId
        self.timestamp = timestamp
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.dateFormatted = df.string(from: timestamp)
        self.files = files
    }
    
    public static func load(from directoryURL: URL) -> SnapshotManifest? {
        let manifestURL = directoryURL.appendingPathComponent(".manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SnapshotManifest.self, from: data)
    }
    
    public func save(to directoryURL: URL) throws {
        let manifestURL = directoryURL.appendingPathComponent(".manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: manifestURL, options: .atomic)
    }
}
