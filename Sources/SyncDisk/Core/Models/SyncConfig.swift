import Foundation

public struct SyncSource: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var isEnabled: Bool
    public let dateAdded: Date
    
    public init(id: UUID = UUID(), name: String, url: URL, isEnabled: Bool = true, dateAdded: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.dateAdded = dateAdded
    }
}

public struct SyncConfig: Codable, Equatable, Sendable {
    public var sources: [SyncSource]
    public var syncDestination: URL?
    public var backupDestination: URL? // If nil, defaults to .backup inside syncDestination
    public var isSyncEnabled: Bool
    public var launchAtLogin: Bool
    public var evictICloudAfterSync: Bool
    public var debounceSeconds: Double
    
    public init(
        sources: [SyncSource] = [],
        syncDestination: URL? = nil,
        backupDestination: URL? = nil,
        isSyncEnabled: Bool = true,
        launchAtLogin: Bool = false,
        evictICloudAfterSync: Bool = false,
        debounceSeconds: Double = 1.0
    ) {
        self.sources = sources
        self.syncDestination = syncDestination
        self.backupDestination = backupDestination
        self.isSyncEnabled = isSyncEnabled
        self.launchAtLogin = launchAtLogin
        self.evictICloudAfterSync = evictICloudAfterSync
        self.debounceSeconds = debounceSeconds
    }
    
    /// Returns the effective directory used for history preservation.
    /// By default, it's `.backup` inside the sync destination.
    public var effectiveHistoryURL: URL? {
        if let custom = backupDestination {
            return custom
        }
        guard let dest = syncDestination else { return nil }
        return dest.appendingPathComponent(".backup", isDirectory: true)
    }
    
    public static var configDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SyncDisk", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    public static var configFileURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }
    
    public static func load() -> SyncConfig {
        let file = configFileURL
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(SyncConfig.self, from: data) else {
            return SyncConfig()
        }
        return config
    }
    
    public func save() throws {
        let file = Self.configFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: file, options: .atomic)
    }
}
