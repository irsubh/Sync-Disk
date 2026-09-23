import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct FolderDisplayItem: Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let itemCount: Int
    public let lastTimestamp: Date
    
    public init(name: String, path: String, itemCount: Int, lastTimestamp: Date) {
        self.name = name
        self.path = path
        self.itemCount = itemCount
        self.lastTimestamp = lastTimestamp
    }
}

public enum FileManagerGridItem: Identifiable, Hashable {
    case folder(FolderDisplayItem)
    case file(TrackedFileInfo)
    
    public var id: String {
        switch self {
        case .folder(let item): return "folder:\(item.path)"
        case .file(let item): return "file:\(item.logicalPath)"
        }
    }
    
    public var name: String {
        switch self {
        case .folder(let item): return item.name
        case .file(let item): return item.filename
        }
    }
    
    public var lastTimestamp: Date {
        switch self {
        case .folder(let item): return item.lastTimestamp
        case .file(let item): return item.lastTimestamp
        }
    }
}

public struct FileGridIconView: View {
    public let items: [FileManagerGridItem]
    @Binding public var selectedFilePath: String?
    @ObservedObject public var syncEngine: SyncEngine
    public let onSelectFile: (String) -> Void
    public let onSelectFolder: (FolderDisplayItem) -> Void
    public let onOpenFolder: (String) -> Void
    public let onOpenFile: (TrackedFileInfo) -> Void
    
    public init(
        items: [FileManagerGridItem],
        selectedFilePath: Binding<String?>,
        syncEngine: SyncEngine,
        onSelectFile: @escaping (String) -> Void,
        onSelectFolder: @escaping (FolderDisplayItem) -> Void = { _ in },
        onOpenFolder: @escaping (String) -> Void,
        onOpenFile: @escaping (TrackedFileInfo) -> Void = { _ in }
    ) {
        self.items = items
        self._selectedFilePath = selectedFilePath
        self.syncEngine = syncEngine
        self.onSelectFile = onSelectFile
        self.onSelectFolder = onSelectFolder
        self.onOpenFolder = onOpenFolder
        self.onOpenFile = onOpenFile
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 105, maximum: 125), spacing: 14, alignment: .top)
    ]
    
    public var body: some View {
        if items.isEmpty {
            EmptyStateView(
                iconName: "square.grid.2x2",
                title: "Folder is Empty",
                message: "No files or subfolders found here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        switch item {
                        case .folder(let folder):
                            let isSelected = selectedFilePath == folder.path
                            FolderGridCard(
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
                            .id(item.id)
                            
                        case .file(let file):
                            let isSelected = selectedFilePath == file.logicalPath
                            FileGridCard(
                                file: file,
                                isSelected: isSelected,
                                syncEngine: syncEngine,
                                onSelect: {
                                    selectedFilePath = file.logicalPath
                                    onSelectFile(file.logicalPath)
                                },
                                onOpen: {
                                    onOpenFile(file)
                                }
                            )
                            .id(item.id)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Folder Grid Card

private final class FolderCardState: ObservableObject {
    @Published var isHovered: Bool = false
    var lastClickTime: Date = Date.distantPast
}

private struct FolderGridCard: View {
    let folder: FolderDisplayItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    @StateObject private var state = FolderCardState()
    
    // High-resolution Retina macOS Finder 3D Aqua Folder Icon (cached static)
    private static let retinaFolderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }()
    
    var body: some View {
        VStack(spacing: 5) {
            // Folder Icon - Genuine macOS 3D Folder Icon
            ZStack {
                Image(nsImage: Self.retinaFolderIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 50)
                    .shadow(color: Color.black.opacity(0.14), radius: 2.5, x: 0, y: 1.5)
            }
            .frame(width: 64, height: 60)
            
            // Name
            Text(folder.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            
            // Subtitle
            Text("\(folder.itemCount) item\(folder.itemCount == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(width: 110)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : (state.isHovered ? Color(nsColor: .separatorColor).opacity(0.12) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover in
            state.isHovered = hover
        }
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(state.lastClickTime) < 0.35 {
                state.lastClickTime = Date.distantPast
                onOpen()
            } else {
                state.lastClickTime = now
                onSelect()
            }
        }
    }
}

// MARK: - File Grid Card

private final class FileCardState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var thumbnailImage: NSImage?
    @Published var dimensionSubtitle: String?
    var lastClickTime: Date = Date.distantPast
}

private struct FileGridCard: View {
    let file: TrackedFileInfo
    let isSelected: Bool
    let syncEngine: SyncEngine
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    @StateObject private var state = FileCardState()
    
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
    
    private var isRasterImage: Bool {
        let raster: Set<String> = [
            "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp", "icns", "ico"
        ]
        return raster.contains(ext)
    }
    
    var body: some View {
        VStack(spacing: 5) {
            // Thumbnail / Icon (Genuine Mac App Icon, Raster Squircle, or macOS System Icon)
            ZStack {
                if let thumb = state.thumbnailImage {
                    if isAppBundle {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 58, height: 58)
                            .shadow(color: Color.black.opacity(0.14), radius: 2.5, x: 0, y: 1.5)
                    } else if isRasterImage {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
                    } else {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 54, height: 54)
                            .shadow(color: Color.black.opacity(0.10), radius: 1.5, x: 0, y: 1)
                    }
                } else {
                    fileTypeIcon
                        .frame(width: 58, height: 58)
                }
            }
            .frame(width: 64, height: 60)
            
            // Filename (Mac style: hide .app extension for applications just like Finder)
            Text(displayName)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            
            // Subtitle (Dimensions, "Application", Duration, or File Size)
            Text(subtitleText)
                .font(.system(size: 10))
                .foregroundColor(subtitleColor)
                .lineLimit(1)
        }
        .frame(width: 110)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : (state.isHovered ? Color(nsColor: .separatorColor).opacity(0.12) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover in
            state.isHovered = hover
        }
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(state.lastClickTime) < 0.35 {
                state.lastClickTime = Date.distantPast
                onOpen()
            } else {
                state.lastClickTime = now
                onSelect()
            }
        }
        .task(id: file.logicalPath) {
            await loadThumbnail()
        }
    }
    
    private var fileTypeIcon: some View {
        let icon: NSImage
        if let uti = UTType(filenameExtension: ext) {
            icon = NSWorkspace.shared.icon(for: uti)
        } else {
            icon = NSWorkspace.shared.icon(for: .item)
        }
        icon.size = NSSize(width: 64, height: 64)
        return Image(nsImage: icon)
            .resizable()
            .scaledToFit()
            .frame(width: 52, height: 52)
            .shadow(color: Color.black.opacity(0.10), radius: 1.5, x: 0, y: 1)
    }
    
    private var subtitleText: String {
        if file.isCurrentDeleted {
            return "Deleted"
        }
        if isAppBundle {
            return "Application"
        }
        if let dims = state.dimensionSubtitle {
            return dims
        }
        return ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
    }
    
    private var subtitleColor: Color {
        if file.isCurrentDeleted {
            return .red.opacity(0.8)
        }
        if isAppBundle {
            return .secondary.opacity(0.85)
        }
        if state.dimensionSubtitle != nil {
            return Color.accentColor.opacity(0.85)
        }
        return .secondary.opacity(0.85)
    }
    
    @MainActor
    private func loadThumbnail() async {
        // Instant synchronous cache check: 0ms render
        if let cachedImg = ThumbnailCache.shared.cachedThumbnail(for: file.logicalPath) {
            state.thumbnailImage = cachedImg
            state.dimensionSubtitle = ThumbnailCache.shared.cachedDimensions(for: file.logicalPath)
            return
        }
        
        // Fast centralized resolve without directory enumeration
        guard let targetURL = syncEngine.resolveURL(for: file.logicalPath) else { return }
        
        let (img, dims) = await ThumbnailCache.shared.loadThumbnail(for: targetURL, cacheKey: file.logicalPath)
        guard !Task.isCancelled else { return }
        state.thumbnailImage = img
        state.dimensionSubtitle = dims
    }
}
