import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct FileListView: View {
    public let items: [FileManagerGridItem]
    @Binding public var selectedFilePath: String?
    public let onSelectFile: (String) -> Void
    public let onSelectFolder: (FolderDisplayItem) -> Void
    public let onOpenFolder: (String) -> Void
    public let onOpenFile: (TrackedFileInfo) -> Void
    
    public init(
        items: [FileManagerGridItem],
        selectedFilePath: Binding<String?>,
        onSelectFile: @escaping (String) -> Void,
        onSelectFolder: @escaping (FolderDisplayItem) -> Void = { _ in },
        onOpenFolder: @escaping (String) -> Void = { _ in },
        onOpenFile: @escaping (TrackedFileInfo) -> Void = { _ in }
    ) {
        self.items = items
        self._selectedFilePath = selectedFilePath
        self.onSelectFile = onSelectFile
        self.onSelectFolder = onSelectFolder
        self.onOpenFolder = onOpenFolder
        self.onOpenFile = onOpenFile
    }
    
    // Convenience initializer for file-only arrays
    public init(
        files: [TrackedFileInfo],
        selectedFilePath: Binding<String?>,
        onSelectFile: @escaping (String) -> Void
    ) {
        self.items = files.map { FileManagerGridItem.file($0) }
        self._selectedFilePath = selectedFilePath
        self.onSelectFile = onSelectFile
        self.onSelectFolder = { _ in }
        self.onOpenFolder = { _ in }
        self.onOpenFile = { _ in }
    }
    
    public var body: some View {
        if items.isEmpty {
            EmptyStateView(
                iconName: "tray",
                title: "No Files Found",
                message: "Synchronized files will appear here automatically."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        switch item {
                        case .folder(let folder):
                            let isSelected = selectedFilePath == folder.path
                            FolderRowView(
                                folder: folder,
                                isSelected: isSelected,
                                onSelect: {
                                    selectedFilePath = folder.path
                                    onSelectFolder(folder)
                                },
                                onOpen: {
                                    onOpenFolder(folder.path)
                                }
                            )
                                
                        case .file(let file):
                            let isSelected = selectedFilePath == file.logicalPath
                            FileRowView(
                                file: file,
                                isSelected: isSelected,
                                onSelect: {
                                    selectedFilePath = file.logicalPath
                                    onSelectFile(file.logicalPath)
                                },
                                onOpen: {
                                    onOpenFile(file)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(minWidth: 220)
        }
    }
}

private final class RowClickState: ObservableObject {
    var lastClickTime: Date = Date.distantPast
}

private struct FolderRowView: View {
    let folder: FolderDisplayItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    @StateObject private var clickState = RowClickState()
    
    private static let retinaFolderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }()
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(nsImage: Self.retinaFolderIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text("\(folder.itemCount) item\(folder.itemCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            
            Spacer(minLength: 6)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(clickState.lastClickTime) < 0.35 {
                clickState.lastClickTime = Date.distantPast
                onOpen()
            } else {
                clickState.lastClickTime = now
                onSelect()
            }
        }
    }
}

private struct FileRowView: View {
    let file: TrackedFileInfo
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    @StateObject private var clickState = RowClickState()
    
    private var ext: String {
        (file.filename as NSString).pathExtension.lowercased()
    }
    
    private var isAppBundle: Bool {
        ext == "app"
    }
    
    private var displayName: String {
        if isAppBundle {
            return (file.filename as NSString).deletingPathExtension
        }
        return file.filename
    }
    
    private var cleanPath: String {
        file.logicalPath.split(separator: "/").joined(separator: " / ")
    }
    
    private var fileIconImage: NSImage {
        if let cached = ThumbnailCache.shared.cachedThumbnail(for: file.logicalPath) {
            return cached
        }
        let icon: NSImage
        if let uti = UTType(filenameExtension: ext) {
            icon = NSWorkspace.shared.icon(for: uti)
        } else {
            icon = NSWorkspace.shared.icon(for: .item)
        }
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Native macOS Icon
            ZStack {
                Image(nsImage: fileIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .opacity(file.isCurrentDeleted ? 0.5 : 1.0)
            }
            .frame(width: 32, height: 32)
            
            // Name & Path
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(file.isCurrentDeleted ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Text(cleanPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            
            Spacer(minLength: 6)
            
            // Status / Version Capsule
            if file.isCurrentDeleted {
                Text("Deleted")
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.12))
                    )
                    .layoutPriority(10)
            } else {
                Text("v\(file.versionCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(isSelected ? .primary : .secondary.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.primary.opacity(0.1) : Color(nsColor: .separatorColor).opacity(0.25))
                    )
                    .layoutPriority(10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(clickState.lastClickTime) < 0.35 {
                clickState.lastClickTime = Date.distantPast
                onOpen()
            } else {
                clickState.lastClickTime = now
                onSelect()
            }
        }
    }
}
