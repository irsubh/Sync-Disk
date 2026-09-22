import Foundation

public enum HistoryViewMode: String, CaseIterable, Sendable {
    case files = "Files"
    case folders = "Folders"
    case storage = "Storage"
}

public struct DayGrowthItem: Identifiable, Sendable, Equatable {
    public var id: String { dateLabel }
    public let date: Date
    public let dateLabel: String
    public let addedBytes: Int64
    public let versionCount: Int
    
    public init(date: Date, dateLabel: String, addedBytes: Int64, versionCount: Int) {
        self.date = date
        self.dateLabel = dateLabel
        self.addedBytes = addedBytes
        self.versionCount = versionCount
    }
    
    public var formattedAddedSize: String {
        "+ " + ByteCountFormatter.string(fromByteCount: addedBytes, countStyle: .file)
    }
}

public struct DiskStatus: Equatable, Sendable {
    public var isConnected: Bool
    public var volumeName: String
    public var destinationPath: String
    public var totalSpaceBytes: Int64
    public var freeSpaceBytes: Int64
    public var syncedSizeBytes: Int64
    public var historySizeBytes: Int64
    public var otherUsedBytes: Int64
    public var growthTodayBytes: Int64
    public var growthThisWeekBytes: Int64
    public var growthThisMonthBytes: Int64
    public var totalVersionsCount: Int
    public var totalFilesCount: Int
    public var lastVerifiedDate: Date?
    public var dailyGrowth: [DayGrowthItem]
    
    public init(
        isConnected: Bool = false,
        volumeName: String = "External Disk",
        destinationPath: String = "",
        totalSpaceBytes: Int64 = 0,
        freeSpaceBytes: Int64 = 0,
        syncedSizeBytes: Int64 = 0,
        historySizeBytes: Int64 = 0,
        otherUsedBytes: Int64 = 0,
        growthTodayBytes: Int64 = 0,
        growthThisWeekBytes: Int64 = 0,
        growthThisMonthBytes: Int64 = 0,
        totalVersionsCount: Int = 0,
        totalFilesCount: Int = 0,
        lastVerifiedDate: Date? = nil,
        dailyGrowth: [DayGrowthItem] = []
    ) {
        self.isConnected = isConnected
        self.volumeName = volumeName
        self.destinationPath = destinationPath
        self.totalSpaceBytes = totalSpaceBytes
        self.freeSpaceBytes = freeSpaceBytes
        self.syncedSizeBytes = syncedSizeBytes
        self.historySizeBytes = historySizeBytes
        self.otherUsedBytes = otherUsedBytes
        self.growthTodayBytes = growthTodayBytes
        self.growthThisWeekBytes = growthThisWeekBytes
        self.growthThisMonthBytes = growthThisMonthBytes
        self.totalVersionsCount = totalVersionsCount
        self.totalFilesCount = totalFilesCount
        self.lastVerifiedDate = lastVerifiedDate
        self.dailyGrowth = dailyGrowth
    }
    
    public var syncDiskTotalBytes: Int64 {
        syncedSizeBytes + historySizeBytes
    }
    
    public var totalAppFootprintBytes: Int64 {
        syncDiskTotalBytes
    }
    
    public var totalUsedOnDriveBytes: Int64 {
        max(0, totalSpaceBytes - freeSpaceBytes)
    }
    
    public var formattedFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: freeSpaceBytes, countStyle: .file)
    }
    
    public var formattedTotalSpace: String {
        ByteCountFormatter.string(fromByteCount: totalSpaceBytes, countStyle: .file)
    }
    
    public var formattedSyncedSize: String {
        ByteCountFormatter.string(fromByteCount: syncedSizeBytes, countStyle: .file)
    }
    
    public var formattedHistorySize: String {
        ByteCountFormatter.string(fromByteCount: historySizeBytes, countStyle: .file)
    }
    
    public var formattedTotalAppFootprint: String {
        ByteCountFormatter.string(fromByteCount: totalAppFootprintBytes, countStyle: .file)
    }
    
    public var formattedOtherUsed: String {
        ByteCountFormatter.string(fromByteCount: otherUsedBytes, countStyle: .file)
    }
    
    public var formattedTotalUsedOnDrive: String {
        ByteCountFormatter.string(fromByteCount: totalUsedOnDriveBytes, countStyle: .file)
    }
    
    public var formattedGrowthToday: String {
        "+ " + ByteCountFormatter.string(fromByteCount: growthTodayBytes, countStyle: .file)
    }
    
    public var formattedGrowthThisWeek: String {
        "+ " + ByteCountFormatter.string(fromByteCount: growthThisWeekBytes, countStyle: .file)
    }
    
    public var formattedGrowthThisMonth: String {
        "+ " + ByteCountFormatter.string(fromByteCount: growthThisMonthBytes, countStyle: .file)
    }
}

public struct SyncProgress: Equatable, Sendable {
    public var isSyncing: Bool
    public var currentFileName: String
    public var filesPending: Int
    public var filesCompleted: Int
    public var totalBytesToTransfer: Int64
    public var bytesTransferred: Int64
    public var lastSyncDate: Date?
    public var statusDescription: String
    
    public init(
        isSyncing: Bool = false,
        currentFileName: String = "",
        filesPending: Int = 0,
        filesCompleted: Int = 0,
        totalBytesToTransfer: Int64 = 0,
        bytesTransferred: Int64 = 0,
        lastSyncDate: Date? = nil,
        statusDescription: String = "Idle"
    ) {
        self.isSyncing = isSyncing
        self.currentFileName = currentFileName
        self.filesPending = filesPending
        self.filesCompleted = filesCompleted
        self.totalBytesToTransfer = totalBytesToTransfer
        self.bytesTransferred = bytesTransferred
        self.lastSyncDate = lastSyncDate
        self.statusDescription = statusDescription
    }
    
    public var fractionCompleted: Double {
        let total = filesCompleted + filesPending
        guard total > 0 else { return 0 }
        return Double(filesCompleted) / Double(total)
    }
    
    public var percentComplete: Double {
        fractionCompleted
    }
    
    public var filesTotal: Int {
        filesCompleted + filesPending
    }
    
    public var estimatedSecondsRemaining: Double {
        guard isSyncing && bytesTransferred > 0 else { return 0 }
        let remainingBytes = max(0, totalBytesToTransfer - bytesTransferred)
        return Double(remainingBytes) / max(Double(bytesTransferred) / 10.0, 1024 * 1024)
    }
    
    public var failedOperationsCount: Int {
        0
    }
}
