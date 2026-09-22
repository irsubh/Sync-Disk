import Foundation

public struct FolderSnapshotItem: Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String               // e.g. "subfolder/document.txt"
    public let isDirectory: Bool
    public let fileEntry: FileHistoryEntry?
    public var children: [FolderSnapshotItem]
    
    public init(name: String, path: String, isDirectory: Bool, fileEntry: FileHistoryEntry? = nil, children: [FolderSnapshotItem] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.fileEntry = fileEntry
        self.children = children
    }
}

public struct FolderSnapshot: Sendable {
    public let folderLogicalPath: String
    public let snapshotDate: Date
    public let items: [FolderSnapshotItem]
    
    public init(folderLogicalPath: String, snapshotDate: Date, items: [FolderSnapshotItem]) {
        self.folderLogicalPath = folderLogicalPath
        self.snapshotDate = snapshotDate
        self.items = items
    }
    
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy — HH:mm:ss"
        return formatter.string(from: snapshotDate)
    }
    
    /// Total count of files in this snapshot
    public var totalFileCount: Int {
        func countFiles(in list: [FolderSnapshotItem]) -> Int {
            var sum = 0
            for item in list {
                if item.isDirectory {
                    sum += countFiles(in: item.children)
                } else {
                    sum += 1
                }
            }
            return sum
        }
        return countFiles(in: items)
    }
}
