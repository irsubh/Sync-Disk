import SwiftUI

public final class FolderSnapshotTreeViewModel: ObservableObject {
    @Published public var availableTimestamps: [Date] = []
    @Published public var selectedTimestamp: Date?
    @Published public var snapshotRootNodes: [SnapshotTreeNode] = []
    @Published public var snapshotFileCount: Int = 0
    @Published public var snapshotFolderCount: Int = 0
    @Published public var snapshotTotalBytes: Int64 = 0
    @Published public var showRestoreEntireSnapshotConfirmation: Bool = false
    @Published public var isRestoring: Bool = false
    @Published public var restoreStatusMessage: String?
    
    public init() {}
}

public struct FolderSnapshotTreeView: View {
    @ObservedObject public var syncEngine: SyncEngine
    @Binding public var selectedVersion: FileHistoryEntry?
    
    @StateObject private var vm = FolderSnapshotTreeViewModel()
    
    public init(syncEngine: SyncEngine, selectedVersion: Binding<FileHistoryEntry?>) {
        self.syncEngine = syncEngine
        self._selectedVersion = selectedVersion
    }
    
    public var body: some View {
        HSplitView {
            // Snapshot Selector (Grouped by Day)
            VStack(alignment: .leading, spacing: 8) {
                Text("SNAPSHOT POINTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                
                if vm.availableTimestamps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No snapshots recorded yet")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            let groups = groupDatesByDay(vm.availableTimestamps)
                            ForEach(groups, id: \.dateLabel) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.dateLabel.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .padding(.horizontal, 10)
                                    
                                    ForEach(group.timestamps, id: \.self) { date in
                                        let isSelected = vm.selectedTimestamp == date
                                        Button(action: {
                                            vm.selectedTimestamp = date
                                            loadSnapshot(for: date)
                                        }) {
                                            HStack(spacing: 8) {
                                                Circle()
                                                    .fill(isSelected ? Color.primary : Color.secondary.opacity(0.4))
                                                    .frame(width: 6, height: 6)
                                                
                                                Text(timeString(date))
                                                    .font(.system(size: 12, weight: isSelected ? .medium : .regular, design: .monospaced))
                                                    .foregroundColor(isSelected ? .primary : .secondary)
                                                
                                                Spacer()
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : Color.clear)
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 200)
            
            // Reconstructed Snapshot Directory Hierarchy
            VStack(alignment: .leading, spacing: 0) {
                if let date = vm.selectedTimestamp {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Snapshot")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text(fullDateTimeString(date))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("\(vm.snapshotFileCount) files · \(vm.snapshotFolderCount) folders · \(ByteCountFormatter.string(fromByteCount: vm.snapshotTotalBytes, countStyle: .file))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        if let msg = vm.restoreStatusMessage {
                            Text(msg)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                        
                        Button(action: { vm.showRestoreEntireSnapshotConfirmation = true }) {
                            Text("Restore Snapshot")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(vm.isRestoring)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
                    
                    Divider()
                    
                    // Tree List
                    List {
                        ForEach(vm.snapshotRootNodes) { node in
                            TreeNodeRow(node: node, onSelectFile: { entry in
                                self.selectedVersion = entry
                            })
                        }
                    }
                    .listStyle(.inset)
                } else {
                    EmptyStateView(
                        iconName: "clock",
                        title: "Folder Snapshots",
                        message: "Select a snapshot point to reconstruct the directory state."
                    )
                }
            }
            .frame(minWidth: 260)
        }
        .onAppear {
            loadAllTimestamps()
        }
        .sheet(isPresented: $vm.showRestoreEntireSnapshotConfirmation) {
            if let date = vm.selectedTimestamp {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                    
                    Text("Restore Entire Folder Snapshot?")
                        .font(.system(size: 15, weight: .bold))
                    
                    VStack(spacing: 4) {
                        Text("This will restore all files and folders to their exact state at:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Text(fullDateTimeString(date))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    
                    Text("The current version of your files will first be saved to History.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            vm.showRestoreEntireSnapshotConfirmation = false
                        }
                        .keyboardShortcut(.cancelAction)
                        
                        Button("Restore Entire Snapshot") {
                            vm.showRestoreEntireSnapshotConfirmation = false
                            performSnapshotRestore(date)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .frame(width: 380)
            }
        }
    }
    
    private func performSnapshotRestore(_ date: Date) {
        vm.isRestoring = true
        Task {
            do {
                try await syncEngine.restoreFullFolderSnapshot(at: date)
                await MainActor.run {
                    self.vm.isRestoring = false
                    self.vm.restoreStatusMessage = "Restored snapshot"
                }
            } catch {
                await MainActor.run {
                    self.vm.isRestoring = false
                    self.vm.restoreStatusMessage = "Restore failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Logic
    
    private func loadAllTimestamps() {
        do {
            let dates = try syncEngine.database.distinctDatesWithActivity(for: "")
            vm.availableTimestamps = dates
            if vm.selectedTimestamp == nil, let first = dates.first {
                vm.selectedTimestamp = first
                loadSnapshot(for: first)
            }
        } catch {
            print("FolderSnapshotTreeView: Error loading timestamps: \(error)")
        }
    }
    
    private func loadSnapshot(for date: Date) {
        do {
            let snapshot = try syncEngine.database.folderSnapshot(path: "", at: date)
            vm.snapshotFileCount = snapshot.totalFileCount
            
            // Build hierarchy from items
            let (roots, folderCount, totalBytes) = buildTreeFromSnapshotItems(snapshot.items)
            vm.snapshotRootNodes = roots
            vm.snapshotFolderCount = folderCount
            vm.snapshotTotalBytes = totalBytes
        } catch {
            print("FolderSnapshotTreeView: Error loading snapshot: \(error)")
        }
    }
    
    private func buildTreeFromSnapshotItems(_ items: [FolderSnapshotItem]) -> ([SnapshotTreeNode], Int, Int64) {
        var folderCount = 0
        var totalBytes: Int64 = 0
        
        func convert(_ item: FolderSnapshotItem) -> SnapshotTreeNode {
            if item.isDirectory {
                folderCount += 1
                let convertedChildren = item.children.map { convert($0) }
                return SnapshotTreeNode(name: item.name, isDirectory: true, children: convertedChildren)
            } else {
                if let entry = item.fileEntry {
                    totalBytes += entry.fileSize
                }
                return SnapshotTreeNode(name: item.name, isDirectory: false, entry: item.fileEntry)
            }
        }
        
        let nodes = items.map { convert($0) }
        return (nodes, folderCount, totalBytes)
    }
    
    private func groupDatesByDay(_ dates: [Date]) -> [DayTimestampGroup] {
        let calendar = Calendar.current
        var dict: [String: (order: Date, dates: [Date])] = [:]
        
        for date in dates {
            let label: String
            if calendar.isDateInToday(date) {
                label = "Today"
            } else if calendar.isDateInYesterday(date) {
                label = "Yesterday"
            } else {
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .none
                label = df.string(from: date)
            }
            
            if dict[label] != nil {
                dict[label]!.dates.append(date)
            } else {
                dict[label] = (order: date, dates: [date])
            }
        }
        
        return dict.map { DayTimestampGroup(dateLabel: $0.key, orderDate: $0.value.order, timestamps: $0.value.dates) }
            .sorted(by: { $0.orderDate > $1.orderDate })
    }
    
    private func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
    
    private func fullDateTimeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}

private struct DayTimestampGroup {
    let dateLabel: String
    let orderDate: Date
    let timestamps: [Date]
}

public final class SnapshotTreeNode: Identifiable, ObservableObject {
    public let id = UUID()
    public let name: String
    public let isDirectory: Bool
    public var children: [SnapshotTreeNode]?
    public let entry: FileHistoryEntry?
    @Published public var isExpanded: Bool = true
    
    public init(name: String, isDirectory: Bool, children: [SnapshotTreeNode]? = nil, entry: FileHistoryEntry? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.entry = entry
    }
}

private struct TreeNodeRow: View {
    @ObservedObject var node: SnapshotTreeNode
    let onSelectFile: (FileHistoryEntry) -> Void
    
    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if let kids = node.children {
                    ForEach(kids) { child in
                        TreeNodeRow(node: child, onSelectFile: onSelectFile)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let count = node.children?.count {
                        Text("\(count)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .foregroundColor(.secondary.opacity(0.6))
                    .font(.system(size: 12))
                Text(node.name)
                    .font(.system(size: 12))
                Spacer()
                if let entry = node.entry {
                    Text(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if let entry = node.entry {
                    onSelectFile(entry)
                }
            }
        }
    }
}
