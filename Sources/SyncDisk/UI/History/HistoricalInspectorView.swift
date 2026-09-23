import SwiftUI
import AppKit
import QuickLookUI

public final class HistoricalInspectorViewModel: ObservableObject {
    @Published public var previewFileURL: URL?
    @Published public var textPreviewContent: String?
    @Published public var isExtracting: Bool = false
    @Published public var isMediaPlaying: Bool = false
    @Published public var showRestoreConfirmation: Bool = false
    @Published public var showDetailsDisclosure: Bool = false
    @Published public var restoreSuccessMessage: String?
    @Published public var restoreErrorMessage: String?
    @Published public var copiedHashFeedback: Bool = false
    
    public init() {}
}

public struct HistoricalInspectorView: View {
    @ObservedObject public var syncEngine: SyncEngine
    public let entry: FileHistoryEntry?
    public let folder: FolderDisplayItem?
    public let allVersions: [FileHistoryEntry]
    public let onSelectVersion: (FileHistoryEntry) -> Void
    public let onOpenFolder: (String) -> Void
    
    @StateObject private var vm = HistoricalInspectorViewModel()
    
    public init(
        syncEngine: SyncEngine,
        entry: FileHistoryEntry?,
        folder: FolderDisplayItem? = nil,
        allVersions: [FileHistoryEntry] = [],
        onSelectVersion: @escaping (FileHistoryEntry) -> Void = { _ in },
        onOpenFolder: @escaping (String) -> Void = { _ in }
    ) {
        self.syncEngine = syncEngine
        self.entry = entry
        self.folder = folder
        self.allVersions = allVersions
        self.onSelectVersion = onSelectVersion
        self.onOpenFolder = onOpenFolder
    }
    
    private var isFileDeleted: Bool {
        if let current = entry, current.changeType == .deleted { return true }
        if let first = allVersions.first, first.changeType == .deleted { return true }
        return false
    }
    
    private var fileExtension: String {
        guard let name = entry?.originalFilename else { return "" }
        return (name as NSString).pathExtension.lowercased()
    }
    
    private var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "webp", "gif", "svg", "tiff", "bmp", "ico", "icns", "psd", "pdf"].contains(fileExtension)
    }
    
    private var isAudio: Bool {
        ["mp3", "m4a", "wav", "aac", "flac", "aiff", "alac", "ogg"].contains(fileExtension)
    }
    
    private var isVideo: Bool {
        ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(fileExtension)
    }
    
    private var isText: Bool {
        ["txt", "md", "swift", "py", "js", "ts", "json", "html", "css", "csv", "xml", "yml", "yaml", "sh", "sql", "log"].contains(fileExtension)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if let folder = folder {
                folderInspectorView(folder: folder)
            } else if let version = entry {
                fileInspectorView(version: version)
            } else {
                EmptyStateView(
                    iconName: "clock",
                    title: "No Item Selected",
                    message: "Select a file or folder from the list to view its version timeline and preview."
                )
            }
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: entry?.id) { _, _ in
            vm.isMediaPlaying = false
            loadPreview()
        }
        .onAppear {
            loadPreview()
        }
        .sheet(isPresented: $vm.showRestoreConfirmation) {
            if let ver = entry {
                restoreConfirmationSheet(ver)
            }
        }
    }
    
    // MARK: - Folder Inspector (Fixed Header, Mac 3D Folder Icon, Does Not Scroll)
    
    @ViewBuilder
    private func folderInspectorView(folder: FolderDisplayItem) -> some View {
        let isRootView = folder.path.isEmpty
        
        // FIXED TOP HEADER: macOS 3D Folder Icon & Folder metadata do NOT scroll
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                
                Image(nsImage: {
                    let icon = NSWorkspace.shared.icon(for: .folder)
                    icon.size = NSSize(width: 128, height: 128)
                    return icon
                }())
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 66)
                .opacity(folder.isDeleted ? 0.6 : 1.0)
                .shadow(color: Color.black.opacity(folder.isDeleted ? 0.08 : 0.18), radius: 4, x: 0, y: 2)
                .padding(20)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            
            VStack(alignment: .center, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(folder.isDeleted ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                // Path breadcrumb: show source names for root, or component path for sub-folders
                let pathLabel = isRootView
                    ? syncEngine.config.sources.map { $0.name }.joined(separator: "  ·  ")
                    : folder.path.split(separator: "/").joined(separator: " / ")
                
                if !pathLabel.isEmpty {
                    Text(pathLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                if folder.isDeleted {
                    Text("FOLDER · DELETED · v\(folder.versionCount)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                } else {
                    Text(isRootView
                        ? "\(syncEngine.config.sources.count) source\(syncEngine.config.sources.count == 1 ? "" : "s")"
                        : "FOLDER · \(folder.itemCount) item\(folder.itemCount == 1 ? "" : "s") · v\(folder.versionCount)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        
        Divider()
        
        // SCROLLABLE DETAILS
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if folder.isDeleted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                        
                        Text("This folder was removed from your source drive. Historical files remain protected.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.08))
                    )
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("INFORMATION")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                    
                    VStack(spacing: 7) {
                        detailRow(label: "Status", value: folder.isDeleted ? "Deleted from disk" : "Active")
                        detailRow(label: "Version", value: "v\(folder.versionCount)")
                        detailRow(label: "Items", value: "\(folder.itemCount)")
                        detailRow(label: "Last Modified", value: fullDateTimeString(folder.lastTimestamp))
                        if isRootView {
                            // Show each source folder path for the root/all-files view
                            ForEach(syncEngine.config.sources, id: \.id) { source in
                                detailRow(label: source.name, value: source.url.path)
                            }
                        } else {
                            detailRow(label: "Location", value: folder.path)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
                }
                
                if !isRootView {
                    folderTimelineSection(folder: folder)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        
        // FIXED BOTTOM ACTION BAR — only shown when a real folder is selected (not the root)
        if !isRootView {
            HStack(spacing: 8) {
                Button(action: {
                    revealFolderInFinder(folder.path)
                }) {
                    Text("Show in Finder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Spacer()
                
                if folder.isDeleted {
                    Button(action: {
                        Task {
                            try? await syncEngine.restoreFolder(path: folder.path)
                        }
                    }) {
                        Label("Restore Folder", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button(action: {
                        onOpenFolder(folder.path)
                    }) {
                        Text("Open Folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
    
    private struct FolderDayGroup {
        let dateLabel: String
        let entries: [FolderHistoryVersion]
    }
    
    private func groupFolderVersionsByDay(_ versions: [FolderHistoryVersion]) -> [FolderDayGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: versions) { ver in
            cal.startOfDay(for: ver.timestamp)
        }
        
        let sortedDays = groups.keys.sorted(by: >)
        return sortedDays.map { dayDate in
            let label: String
            if cal.isDateInToday(dayDate) {
                label = "Today"
            } else if cal.isDateInYesterday(dayDate) {
                label = "Yesterday"
            } else {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .none
                label = fmt.string(from: dayDate)
            }
            let sortedEntries = (groups[dayDate] ?? []).sorted(by: { $0.timestamp > $1.timestamp })
            return FolderDayGroup(dateLabel: label, entries: sortedEntries)
        }
    }
    
    @ViewBuilder
    private func folderTimelineSection(folder: FolderDisplayItem) -> some View {
        let versions = syncEngine.database.folderHistory(for: folder.path)
        if !versions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("FOLDER HISTORY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                
                let grouped = groupFolderVersionsByDay(versions)
                
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(grouped, id: \.dateLabel) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.dateLabel.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                            
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, ver in
                                    let isLast = index == group.entries.count - 1
                                    
                                    HStack(alignment: .top, spacing: 10) {
                                        // Dot & vertical line
                                        VStack(spacing: 0) {
                                            if ver.isCurrentVersion {
                                                Circle()
                                                    .fill(ver.changeType == .deleted ? Color.red : Color.green)
                                                    .frame(width: 7, height: 7)
                                                    .padding(.top, 4)
                                            } else if ver.changeType == .deleted {
                                                Circle()
                                                    .fill(Color.red)
                                                    .frame(width: 7, height: 7)
                                                    .padding(.top, 4)
                                            } else {
                                                Circle()
                                                    .strokeBorder(Color.secondary.opacity(0.65), lineWidth: 1.5)
                                                    .frame(width: 7, height: 7)
                                                    .padding(.top, 4)
                                            }
                                            
                                            if !isLast {
                                                Rectangle()
                                                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                                                    .frame(width: 1)
                                                    .frame(minHeight: 28)
                                            }
                                        }
                                        .frame(width: 12)
                                        
                                        // Content
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(timeString(ver.timestamp))
                                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                    .foregroundColor(.primary)
                                                
                                                Spacer()
                                                
                                                Text("v\(ver.versionNumber)")
                                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1.5)
                                                    .background(
                                                        Capsule()
                                                            .fill(Color(nsColor: .separatorColor).opacity(0.2))
                                                    )
                                            }
                                            
                                            HStack(spacing: 6) {
                                                Text(ver.changeType.rawValue.capitalized)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(ver.changeType == .deleted ? .red : (ver.isCurrentVersion ? .green : .secondary))
                                                
                                                Text("·")
                                                    .foregroundColor(.secondary.opacity(0.4))
                                                
                                                Text("\(ver.itemCount) item\(ver.itemCount == 1 ? "" : "s")")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - File Inspector (Fixed Preview Card & Filename Header, Does Not Scroll)
    
    @ViewBuilder
    private func fileInspectorView(version: FileHistoryEntry) -> some View {
        // FIXED TOP HEADER: Live Visual Preview and File Header do NOT scroll
        VStack(spacing: 12) {
            previewSection(version: version)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            
            VStack(alignment: .center, spacing: 3) {
                Text(version.originalFilename)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(isFileDeleted ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text(version.logicalPath.split(separator: "/").joined(separator: " / "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack(spacing: 5) {
                    if isFileDeleted {
                        Text("DELETED")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    Text("\(fileExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: effectiveFileSize(for: version), countStyle: .file))")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        
        Divider()
        
        // SCROLLABLE TIMELINE & DETAILS
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Human Version Timeline
                timelineSection(currentSelected: version)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                
                // Subtle Details (Collapsible technical metadata)
                detailsDisclosureSection(version: version)
                    .padding(.horizontal, 16)
                
                if let success = vm.restoreSuccessMessage {
                    Text(success)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 16)
                }
                
                if let err = vm.restoreErrorMessage {
                    Text(err)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        
        // Bottom Action Bar (Open, Copy, Save As..., Restore)
        bottomActionBar(version: version)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor))
    }
    
    // MARK: - Preview Section
    
    @ViewBuilder
    private func previewSection(version: FileHistoryEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            
            if vm.isExtracting {
                ProgressView()
                    .controlSize(.small)
            } else if let previewURL = vm.previewFileURL {
                if isImage {
                    InspectorImagePreview(url: previewURL, cacheKey: version.logicalPath)
                } else if isAudio && !vm.isMediaPlaying {
                    // Quiet Audio Card: Never autoplay
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Button(action: { vm.isMediaPlaying = true }) {
                            Label("Play Preview", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(20)
                } else if isVideo && !vm.isMediaPlaying {
                    // Quiet Video Card: Never autoplay
                    VStack(spacing: 8) {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Button(action: { vm.isMediaPlaying = true }) {
                            Label("Play Preview", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(20)
                } else if isText, let content = vm.textPreviewContent {
                    // Actual Text / Code Preview
                    ScrollView {
                        Text(content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                    )
                } else {
                    // Document or playing media via QuickLook (autostarts = false)
                    ZStack(alignment: .topTrailing) {
                        QuickLookPreview(previewURL: previewURL)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                            )
                        
                        if (isAudio || isVideo) && vm.isMediaPlaying {
                            Button(action: { vm.isMediaPlaying = false }) {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .padding(8)
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No Preview Available")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(height: 120)
            }
        }
        .frame(minHeight: 140, maxHeight: 200)
        .padding(.horizontal, 16)
    }
    
    // MARK: - Human History Section
    
    @ViewBuilder
    private func timelineSection(currentSelected: FileHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HISTORY")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary.opacity(0.7))
            
            let versionsList = allVersions.isEmpty ? [currentSelected] : allVersions
            let grouped = groupVersionsByDay(versionsList)
            
            VStack(alignment: .leading, spacing: 16) {
                ForEach(grouped, id: \.dateLabel) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.dateLabel.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                        
                        VStack(spacing: 0) {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, ver in
                                let isLast = index == group.entries.count - 1
                                let isSel = ver.id == currentSelected.id
                                
                                timelineRow(
                                    entry: ver,
                                    isSelected: isSel,
                                    isLast: isLast,
                                    onSelect: { onSelectVersion(ver) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func timelineRow(
        entry: FileHistoryEntry,
        isSelected: Bool,
        isLast: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                // Connection line & Dot (● current/deleted, ○ previous)
                VStack(spacing: 0) {
                    if entry.changeType == .deleted {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                    } else if entry.isCurrentVersion {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                    } else {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.65), lineWidth: 1.5)
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                    }
                    
                    if !isLast {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.4))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 12)
                
                // Content
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(timeString(entry.timestamp))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                        
                        Text(humanChangeText(entry.changeType))
                            .font(.system(size: 11, weight: entry.changeType == .deleted ? .semibold : .regular))
                            .foregroundColor(entry.changeType == .deleted ? .red : .secondary)
                        
                        Spacer()
                        
                        Text("v\(entry.versionNumber)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .separatorColor).opacity(0.2))
                            )
                            .layoutPriority(10)
                    }
                    
                    Text(ByteCountFormatter.string(fromByteCount: effectiveFileSize(for: entry), countStyle: .file))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.vertical, 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Details Disclosure
    
    @ViewBuilder
    private func detailsDisclosureSection(version: FileHistoryEntry) -> some View {
        DisclosureGroup(
            isExpanded: $vm.showDetailsDisclosure,
            content: {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow(label: "Path", value: version.logicalPath)
                    let effSize = effectiveFileSize(for: version)
                    detailRow(label: "Size", value: "\(effSize) bytes")
                    detailRow(label: "Version", value: "\(version.versionNumber)")
                    
                    HStack {
                        Text("SHA-256")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: copySHA256) {
                            HStack(spacing: 4) {
                                Text(vm.copiedHashFeedback ? "Copied" : String(version.sha256.prefix(12)) + "…")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(vm.copiedHashFeedback ? .green : .secondary)
                                Image(systemName: vm.copiedHashFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            },
            label: {
                Text("Details")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        )
    }
    
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    // MARK: - Bottom Action Bar
    
    private func bottomActionBar(version: FileHistoryEntry) -> some View {
        HStack(spacing: 8) {
            Button(action: openFile) {
                Text("Open")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Button(action: copyToClipboard) {
                Text("Copy")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Button(action: saveAsPrompt) {
                Text("Save As…")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Spacer()
            
            Button(action: { vm.showRestoreConfirmation = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                    Text(isFileDeleted ? "Restore File" : "Restore")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
    
    // MARK: - Restore Confirmation Sheet
    
    private func restoreConfirmationSheet(_ ver: FileHistoryEntry) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            
            Text("Restore this version?")
                .font(.system(size: 15, weight: .bold))
            
            VStack(spacing: 4) {
                Text(ver.originalFilename)
                    .font(.system(size: 13, weight: .medium))
                Text(fullDateTimeString(ver.timestamp))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Text("Your current version will first be saved to History.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    vm.showRestoreConfirmation = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Restore") {
                    vm.showRestoreConfirmation = false
                    performRestore(ver)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 360)
    }
    
    // MARK: - Helpers & Actions
    
    private func effectiveFileSize(for entry: FileHistoryEntry) -> Int64 {
        let isAppOrPackage = entry.originalFilename.lowercased().hasSuffix(".app") ||
                             entry.logicalPath.lowercased().hasSuffix(".app")
        
        if entry.fileSize > 0 && !isAppOrPackage {
            return entry.fileSize
        }
        
        var targetURL: URL? = syncEngine.resolveURL(for: entry.logicalPath)
        if targetURL == nil && !entry.historyRelativePath.isEmpty {
            let snapURL = syncEngine.storageManager.historyBaseURL.appendingPathComponent(entry.historyRelativePath)
            if FileManager.default.fileExists(atPath: snapURL.path) {
                targetURL = snapURL
            }
        }
        
        if let targetURL = targetURL {
            let sz = HistoryWindowViewModel.calculateItemSize(at: targetURL)
            if sz > 0 {
                return sz
            }
        }
        return entry.fileSize
    }
    
    private func dotColor(for entry: FileHistoryEntry) -> Color {
        if entry.isCurrentVersion {
            return .green
        } else if entry.changeType == .deleted {
            return .red
        } else {
            return .secondary.opacity(0.5)
        }
    }
    
    private func humanChangeText(_ type: ChangeType) -> String {
        switch type {
        case .created: return "Created"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }
    
    private func timeString(_ date: Date) -> String {
        HistoryFormatters.time.string(from: date)
    }
    
    private func fullDateTimeString(_ date: Date) -> String {
        HistoryFormatters.fullDateTime.string(from: date)
    }
    
    private func groupVersionsByDay(_ entries: [FileHistoryEntry]) -> [DayVersionGroup] {
        let cal = Calendar.current
        var dict: [String: (order: Date, items: [FileHistoryEntry])] = [:]
        
        for entry in entries {
            let label: String
            if cal.isDateInToday(entry.timestamp) {
                label = "Today"
            } else if cal.isDateInYesterday(entry.timestamp) {
                label = "Yesterday"
            } else {
                label = HistoryFormatters.mediumDate.string(from: entry.timestamp)
            }
            
            if dict[label] != nil {
                dict[label]!.items.append(entry)
            } else {
                dict[label] = (order: entry.timestamp, items: [entry])
            }
        }
        
        return dict.map { DayVersionGroup(dateLabel: $0.key, orderDate: $0.value.order, entries: $0.value.items) }
            .sorted(by: { $0.orderDate > $1.orderDate })
    }
    
    private func loadPreview() {
        guard let ver = entry else {
            vm.previewFileURL = nil
            vm.textPreviewContent = nil
            return
        }
        
        // Fast path: Direct file preview using centralized resolver
        var directURL: URL? = syncEngine.resolveURL(for: ver.logicalPath)
        
        // If file doesn't exist locally or is deleted, try the snapshot URL
        if (directURL == nil || !FileManager.default.fileExists(atPath: directURL!.path)) && !ver.historyRelativePath.isEmpty {
            let snapURL = syncEngine.storageManager.historyBaseURL.appendingPathComponent(ver.historyRelativePath)
            if FileManager.default.fileExists(atPath: snapURL.path) {
                directURL = snapURL
            }
        }
        
        // Fallback: look for any available snapshot from other versions of this file
        if directURL == nil || !FileManager.default.fileExists(atPath: directURL!.path) {
            if let nonDel = allVersions.first(where: { !$0.historyRelativePath.isEmpty }) {
                let snapURL = syncEngine.storageManager.historyBaseURL.appendingPathComponent(nonDel.historyRelativePath)
                if FileManager.default.fileExists(atPath: snapURL.path) {
                    directURL = snapURL
                }
            }
        }
        
        if let readyURL = directURL {
            var textSnippet: String? = nil
            let ext = (ver.originalFilename as NSString).pathExtension.lowercased()
            if ["txt", "md", "swift", "py", "js", "ts", "json", "html", "css", "csv", "xml", "yml", "yaml", "sh", "sql", "log"].contains(ext) {
                if let handle = try? FileHandle(forReadingFrom: readyURL) {
                    let data = handle.readData(ofLength: 2048)
                    try? handle.close()
                    textSnippet = String(data: data, encoding: .utf8)
                }
            }
            self.vm.previewFileURL = readyURL
            self.vm.textPreviewContent = textSnippet
            self.vm.isExtracting = false
            return
        }
        
        // Fallback: extract if not found directly
        vm.isExtracting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try syncEngine.storageManager.extractHistoricalFile(entry: ver)
                var textSnippet: String? = nil
                let ext = (ver.originalFilename as NSString).pathExtension.lowercased()
                if ["txt", "md", "swift", "py", "js", "ts", "json", "html", "css", "csv", "xml", "yml", "yaml", "sh", "sql", "log"].contains(ext) {
                    if let data = try? Data(contentsOf: url),
                       let str = String(data: data.prefix(2048), encoding: .utf8) {
                        textSnippet = str
                    }
                }
                DispatchQueue.main.async {
                    self.vm.previewFileURL = url
                    self.vm.textPreviewContent = textSnippet
                    self.vm.isExtracting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.vm.previewFileURL = nil
                    self.vm.textPreviewContent = nil
                    self.vm.isExtracting = false
                }
            }
        }
    }
    
    private func copySHA256() {
        guard let ver = entry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ver.sha256, forType: .string)
        withAnimation {
            vm.copiedHashFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            vm.copiedHashFeedback = false
        }
    }
    
    private func openFile() {
        guard let url = vm.previewFileURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    private func copyToClipboard() {
        guard let url = vm.previewFileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
    
    private func saveAsPrompt() {
        guard let url = vm.previewFileURL, let ver = entry else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ver.originalFilename
        panel.canCreateDirectories = true
        
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                try? FileManager.default.copyItem(at: url, to: dest)
            }
        }
    }
    
    private func performRestore(_ ver: FileHistoryEntry) {
        Task {
            do {
                try await syncEngine.restoreVersion(entry: ver)
                await MainActor.run {
                    self.vm.restoreSuccessMessage = "Restored \(ver.originalFilename)"
                    self.vm.restoreErrorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.vm.restoreErrorMessage = "Restore failed: \(error.localizedDescription)"
                    self.vm.restoreSuccessMessage = nil
                }
            }
        }
    }
    
    private func revealFolderInFinder(_ folderPath: String) {
        if let dest = syncEngine.config.syncDestination {
            let destFolder = dest.appendingPathComponent(folderPath)
            if FileManager.default.fileExists(atPath: destFolder.path) {
                NSWorkspace.shared.activateFileViewerSelecting([destFolder])
                return
            }
        }
        for source in syncEngine.config.sources {
            if folderPath.hasPrefix(source.name + "/") {
                let sub = String(folderPath.dropFirst(source.name.count + 1))
                let u = source.url.appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: u.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                    return
                }
            } else if folderPath == source.name {
                if FileManager.default.fileExists(atPath: source.url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                    return
                }
            }
        }
        let backupBase = syncEngine.config.effectiveHistoryURL ?? syncEngine.storageManager.historyBaseURL
        let snapshotsDir = backupBase.appendingPathComponent("snapshots")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path) {
            for snap in entries {
                let candidate = snapshotsDir.appendingPathComponent("\(snap)/\(folderPath)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([candidate])
                    return
                }
            }
        }
    }
}

private struct DayVersionGroup {
    let dateLabel: String
    let orderDate: Date
    let entries: [FileHistoryEntry]
}

private enum HistoryFormatters {
    static let time: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()
    static let fullDateTime: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
    static let mediumDate: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()
}

private final class InspectorImageState: ObservableObject {
    @Published var image: NSImage?
    @Published var isLoading: Bool = true
}

private struct InspectorImagePreview: View {
    let url: URL
    let cacheKey: String
    @StateObject private var state = InspectorImageState()
    
    var body: some View {
        Group {
            if let img = state.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.14), radius: 5, x: 0, y: 2)
                    .padding(12)
            } else if state.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 120)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No Preview Available")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(height: 120)
            }
        }
        .task(id: url.path) {
            state.isLoading = true
            defer { state.isLoading = false }
            
            if let direct = NSImage(contentsOf: url) {
                state.image = direct
                return
            }
            if let cached = ThumbnailCache.shared.cachedThumbnail(for: cacheKey) {
                state.image = cached
                return
            }
            let (thumb, _) = await ThumbnailCache.shared.loadThumbnail(for: url, cacheKey: cacheKey, maxPixelSize: 512)
            guard !Task.isCancelled else { return }
            state.image = thumb
        }
    }
}
