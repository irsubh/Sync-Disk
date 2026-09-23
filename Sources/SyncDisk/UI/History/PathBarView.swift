import SwiftUI
import AppKit

public struct PathComponentItem: Identifiable, Hashable {
    public var id: String { url.path }
    public let title: String
    public let url: URL
    public let isDirectory: Bool
    public let isVolume: Bool
    public let backupRelativePath: String?
}

public struct PathBarView: View {
    public let selectedFilePath: String?
    public let selectedVersion: FileHistoryEntry?
    public let currentFolderPath: String?
    @ObservedObject public var syncEngine: SyncEngine
    public let onSelectFolder: (String?) -> Void
    
    public init(
        selectedFilePath: String?,
        selectedVersion: FileHistoryEntry? = nil,
        currentFolderPath: String? = nil,
        syncEngine: SyncEngine,
        onSelectFolder: @escaping (String?) -> Void = { _ in }
    ) {
        self.selectedFilePath = selectedFilePath
        self.selectedVersion = selectedVersion
        self.currentFolderPath = currentFolderPath
        self.syncEngine = syncEngine
        self.onSelectFolder = onSelectFolder
    }
    
    /// Resolves the destination-side URL on the external drive (e.g. SanDisk) for the current context.
    /// Priority: selected file path -> navigated folder -> destination root.
    /// Shows the true backup mirror location on the external disk.
    private var targetURL: URL? {
        guard let destBase = syncEngine.config.syncDestination else {
            return nil
        }
        
        // 1. A specific file is selected
        if let sel = selectedFilePath, !sel.isEmpty {
            return destBase.appendingPathComponent(sel)
        }
        
        // 2. A folder is being browsed
        if let folder = currentFolderPath, !folder.isEmpty {
            return destBase.appendingPathComponent(folder)
        }
        
        // 3. Fallback: root destination
        return destBase
    }
    
    /// Dynamically walks up the filesystem hierarchy from the destination URL to the volume root.
    private var pathComponents: [PathComponentItem] {
        guard let destBase = syncEngine.config.syncDestination?.standardizedFileURL,
              let url = targetURL?.standardizedFileURL else { return [] }
        
        var destStd = destBase.path
        if destStd.hasSuffix("/") && destStd.count > 1 {
            destStd.removeLast()
        }
        let volumeName = (try? destBase.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? destBase.lastPathComponent
        
        var chain: [PathComponentItem] = []
        var curr = url
        
        while true {
            let isDestRoot = (curr.path == destStd)
            let isVolume = isDestRoot || curr.path == "/"
            let name: String
            if isDestRoot {
                name = volumeName
            } else if !curr.lastPathComponent.isEmpty {
                name = curr.lastPathComponent
            } else {
                name = curr.path
            }
            let isDir = curr.pathExtension.isEmpty || curr.hasDirectoryPath
            
            // In-app logical path relative to destination root
            let relPath: String?
            if isDestRoot {
                relPath = nil
            } else if curr.path.hasPrefix(destStd + "/") {
                let sub = String(curr.path.dropFirst(destStd.count + 1))
                relPath = sub
            } else {
                relPath = nil
            }
            
            chain.append(PathComponentItem(
                title: name,
                url: curr,
                isDirectory: isDir,
                isVolume: isVolume,
                backupRelativePath: relPath
            ))
            
            if isDestRoot || curr.path == "/" || curr.path.count <= destStd.count {
                break
            }
            let parent = curr.deletingLastPathComponent()
            if parent.path == curr.path || parent.path == "/Volumes" {
                break
            }
            curr = parent
        }
        
        return chain.reversed()
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pathComponents.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 4) {
                            PathIconView(item: item)
                            
                            Text(item.title)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.001))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if item.isDirectory {
                                onSelectFolder(item.backupRelativePath)
                            }
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url.path, forType: .string)
                            }
                        }
                        
                        if index < pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.45))
                                .padding(.horizontal, 1)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color(nsColor: .separatorColor).opacity(0.5)),
            alignment: .top
        )
    }
}

private struct PathIconView: View {
    let item: PathComponentItem
    
    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 10))
            .foregroundColor(item.isVolume ? Color.blue : (item.isDirectory ? Color.accentColor : Color.secondary))
            .frame(width: 13, height: 13)
    }
    
    private var iconName: String {
        if item.isVolume {
            return "externaldrive.fill"
        }
        if item.isDirectory {
            if item.title.lowercased() == "snapshots" || item.title.contains("202") {
                return "clock.arrow.circlepath"
            }
            return "folder.fill"
        }
        let ext = item.url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "svg":
            return "photo"
        case "mp3", "m4a", "wav", "aac", "flac":
            return "music.note"
        case "mp4", "mov", "m4v", "mkv":
            return "film"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz":
            return "archivebox"
        default:
            return "doc"
        }
    }
}
