import Foundation

public final class StorageMetrics: @unchecked Sendable {
    private let fileManager = FileManager.default
    
    public init() {}
    
    /// Computes full disk status including external volume space, folder sizes, and history growth metrics.
    public func calculateStatus(
        syncDestination: URL?,
        historyDestination: URL?,
        sources: [SyncSource] = [],
        database: HistoryDatabase? = nil
    ) async -> DiskStatus {
        guard let dest = syncDestination else {
            return DiskStatus(
                isConnected: false,
                volumeName: "Not Configured",
                destinationPath: "",
                totalSpaceBytes: 0,
                freeSpaceBytes: 0,
                syncedSizeBytes: 0,
                historySizeBytes: 0
            )
        }
        
        let isConnected = fileManager.fileExists(atPath: dest.path) && fileManager.isWritableFile(atPath: dest.path)
        guard isConnected else {
            return DiskStatus(
                isConnected: false,
                volumeName: dest.lastPathComponent,
                destinationPath: dest.path,
                totalSpaceBytes: 0,
                freeSpaceBytes: 0,
                syncedSizeBytes: 0,
                historySizeBytes: 0
            )
        }
        
        var totalSpace: Int64 = 0
        var freeSpace: Int64 = 0
        var volumeName = dest.lastPathComponent
        
        if let values = try? dest.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]) {
            totalSpace = Int64(values.volumeTotalCapacity ?? 0)
            if let avail = values.volumeAvailableCapacity {
                freeSpace = Int64(avail)
            } else if let availImp = values.volumeAvailableCapacityForImportantUsage {
                freeSpace = availImp
            }
            if let name = values.volumeName, !name.isEmpty {
                volumeName = name
            }
        }
        
        let historyURL = historyDestination ?? dest.appendingPathComponent(".backup", isDirectory: true)
        
        var syncedSize: Int64 = 0
        if !sources.isEmpty {
            for source in sources where source.isEnabled {
                let sourceDest = dest.appendingPathComponent(source.name, isDirectory: true)
                syncedSize += await calculateDirectorySize(at: sourceDest, excludingSubdirectory: nil)
            }
        } else {
            syncedSize = await calculateDirectorySize(at: dest, excludingSubdirectory: historyURL)
        }
        
        let historySize = await calculateDirectorySize(at: historyURL, excludingSubdirectory: nil)
        
        let totalUsed = max(0, totalSpace - freeSpace)
        let syncDiskTotal = syncedSize + historySize
        let otherUsed = max(0, totalUsed - syncDiskTotal)
        
        var totalVersions = 0
        var totalFiles = 0
        var growthToday: Int64 = 0
        var growthWeek: Int64 = 0
        var growthMonth: Int64 = 0
        var daily: [DayGrowthItem] = []
        
        if let db = database {
            if let counts = try? db.historyCounts() {
                totalVersions = counts.totalVersions
                totalFiles = counts.totalFiles
            }
            growthToday = (try? db.historyGrowthToday()) ?? 0
            growthWeek = (try? db.historyGrowthThisWeek()) ?? 0
            growthMonth = (try? db.historyGrowthThisMonth()) ?? 0
            daily = (try? db.dailyHistoryGrowth(days: 7)) ?? []
        }
        
        return DiskStatus(
            isConnected: true,
            volumeName: volumeName,
            destinationPath: dest.path,
            totalSpaceBytes: totalSpace,
            freeSpaceBytes: freeSpace,
            syncedSizeBytes: syncedSize,
            historySizeBytes: historySize,
            otherUsedBytes: otherUsed,
            growthTodayBytes: growthToday,
            growthThisWeekBytes: growthWeek,
            growthThisMonthBytes: growthMonth,
            totalVersionsCount: totalVersions,
            totalFilesCount: totalFiles,
            lastVerifiedDate: Date(),
            dailyGrowth: daily
        )
    }
    
    public static let ignoredFolderNames: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "vendor", "Pods", "__pycache__", ".next", ".nuxt", ".cache", ".turbo"
    ]
    
    /// Computes the recursive byte size of a directory.
    public func calculateDirectorySize(at url: URL, excludingSubdirectory: URL?) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard self.fileManager.fileExists(atPath: url.path) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                var total: Int64 = 0
                let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
                
                let enumerator = self.fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                )
                
                let excludePath = excludingSubdirectory?.standardizedFileURL.path
                
                while let fileURL = enumerator?.nextObject() as? URL {
                    let lastComp = fileURL.lastPathComponent
                    // Strictly ignore OS system folders (.Spotlight-V100, .Trashes, .fseventsd, .DS_Store) and build caches
                    if lastComp.hasPrefix(".Spotlight") || lastComp == ".Trashes" || lastComp == ".fseventsd" || lastComp == ".DS_Store" || lastComp.hasPrefix(".staging_") {
                        enumerator?.skipDescendants()
                        continue
                    }
                    
                    if Self.ignoredFolderNames.contains(lastComp) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    
                    if let ex = excludePath, fileURL.standardizedFileURL.path.hasPrefix(ex) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    
                    if let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                       values.isDirectory != true {
                        total += Int64(values.fileSize ?? 0)
                    }
                }
                
                continuation.resume(returning: total)
            }
        }
    }
}
