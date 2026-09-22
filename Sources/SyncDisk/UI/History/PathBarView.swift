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
    
    /// Resolves the source-side URL for the current context.
    /// Priority: selected file version → selected file live path → navigated folder → source root.
    /// Always shows where the content lives on disk, not in the backup store.
    private var targetURL: URL? {
        let sources = syncEngine.config.sources
        
        // 1. A specific file is selected
        if let sel = selectedFilePath, !sel.isEmpty {
            // Try to map logical path back to a live source URL
            for source in sources {
                if sel.hasPrefix(source.name + "/") {
                    let sub = String(sel.dropFirst(source.name.count + 1))
                    return source.url.appendingPathComponent(sub)
                } else if sel == source.name {
                    return source.url
                }
            }
            // Fallback: use backup path if no source match
            let backupBase = syncEngine.config.syncDestination
                ?? syncEngine.storageManager.historyBaseURL.deletingLastPathComponent()
            return backupBase.appendingPathComponent(sel)
        }
        
        // 2. A folder is being browsed
        if let folder = currentFolderPath, !folder.isEmpty {
            for source in sources {
                if folder.hasPrefix(source.name + "/") {
                    let sub = String(folder.dropFirst(source.name.count + 1))
                    return source.url.appendingPathComponent(sub)
                } else if folder == source.name {
                    return source.url
                }
            }
            let backupBase = syncEngine.config.syncDestination
                ?? syncEngine.storageManager.historyBaseURL.deletingLastPathComponent()
            return backupBase.appendingPathComponent(folder)
        }
        
        // 3. Nothing selected — show root of first available source
        return sources.first?.url
    }
    
    private static let rootVolumeName: String = {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Macintosh HD"
    }()
    
    /// Dynamically walks up the filesystem hierarchy from the source URL to the volume root.
    /// For each component, backupRelativePath holds the logical path relative to the source root
    /// so tapping a crumb navigates within the app correctly.
    private var pathComponents: [PathComponentItem] {
        guard let url = targetURL else { return [] }
        
        // Determine which source root this URL falls under (for logical path computation)
        let sources = syncEngine.config.sources
        var sourceRoot: URL? = nil
        var sourceName: String = ""
        for source in sources {
            let srcStd = source.url.standardizedFileURL.path
            let urlStd = url.standardizedFileURL.path
            if urlStd == srcStd || urlStd.hasPrefix(srcStd + "/") {
                sourceRoot = source.url.standardizedFileURL
                sourceName = source.name
                break
            }
        }
        
        var chain: [PathComponentItem] = []
        var curr = url.standardizedFileURL
        
        while true {
            let isVolume = (curr.path == "/" || curr.deletingLastPathComponent().path == "/Volumes")
            let name: String
            if curr.path == "/" {
                name = Self.rootVolumeName
            } else if !curr.lastPathComponent.isEmpty {
                name = curr.lastPathComponent
            } else {
                name = curr.path
            }
            let isDir = curr.pathExtension.isEmpty || curr.hasDirectoryPath
            
            // Compute in-app logical path for navigation (relative to source, prefixed with source name)
            let relPath: String?
            if let root = sourceRoot {
                if curr.path == root.path {
                    relPath = sourceName
                } else if curr.path.hasPrefix(root.path + "/") {
                    let sub = String(curr.path.dropFirst(root.path.count + 1))
                    relPath = sub.isEmpty ? sourceName : "\(sourceName)/\(sub)"
                } else {
                    relPath = nil  // above source root - no in-app navigation
                }
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
            
            if isVolume || curr.path == "/" {
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
