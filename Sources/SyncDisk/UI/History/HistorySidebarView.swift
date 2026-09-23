import SwiftUI
import AppKit

public enum HistorySidebarSelection: Hashable {
    case allFiles
    case activeOnly
    case deletedOnly
    case source(UUID)
}

public struct HistorySidebarView: View {
    @ObservedObject public var syncEngine: SyncEngine
    @Binding public var selection: HistorySidebarSelection
    public let totalFileCount: Int
    public let activeCount: Int
    public let deletedCount: Int
    public let onAddSource: () -> Void
    public let onSelectStorage: () -> Void
    public let onSelectSection: ((HistorySidebarSelection) -> Void)?
    
    public init(
        syncEngine: SyncEngine,
        selection: Binding<HistorySidebarSelection>,
        totalFileCount: Int,
        activeCount: Int,
        deletedCount: Int,
        onAddSource: @escaping () -> Void = {},
        onSelectStorage: @escaping () -> Void = {},
        onSelectSection: ((HistorySidebarSelection) -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self._selection = selection
        self.totalFileCount = totalFileCount
        self.activeCount = activeCount
        self.deletedCount = deletedCount
        self.onAddSource = onAddSource
        self.onSelectStorage = onSelectStorage
        self.onSelectSection = onSelectSection
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // LIBRARY Section
            VStack(alignment: .leading, spacing: 4) {
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                
                sidebarRow(
                    title: "All Files",
                    icon: "tray.full",
                    count: totalFileCount,
                    isSelected: selection == .allFiles
                ) {
                    selection = .allFiles
                    onSelectSection?(.allFiles)
                }
                
                sidebarRow(
                    title: "Active",
                    icon: "checkmark",
                    count: activeCount,
                    isSelected: selection == .activeOnly
                ) {
                    selection = .activeOnly
                    onSelectSection?(.activeOnly)
                }
                
                sidebarRow(
                    title: "History",
                    icon: "clock",
                    count: deletedCount,
                    isSelected: selection == .deletedOnly
                ) {
                    selection = .deletedOnly
                    onSelectSection?(.deletedOnly)
                }
            }
            
            // SOURCES Section
            VStack(alignment: .leading, spacing: 4) {
                Text("SOURCES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                
                ForEach(syncEngine.config.sources) { source in
                    let isSel: Bool = {
                        if case .source(let id) = selection {
                            return id == source.id
                        }
                        return false
                    }()
                    
                    sidebarRow(
                        title: source.name,
                        icon: "folder",
                        count: nil,
                        isSelected: isSel
                    ) {
                        selection = .source(source.id)
                        onSelectSection?(.source(source.id))
                    }
                }
                
                Button(action: onAddSource) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Add Source")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            // Storage Detailed Footer Card
            storageDetailedCard
        }
        .padding(.top, 16)
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    @ViewBuilder
    private var storageDetailedCard: some View {
        Button(action: onSelectStorage) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: Disk icon + volume name + disclosure chevron
                HStack(spacing: 7) {
                    Image(systemName: syncEngine.diskStatus.isConnected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .font(.system(size: 13))
                        .foregroundColor(syncEngine.diskStatus.isConnected ? .accentColor : .secondary)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(syncEngine.diskStatus.volumeName.isEmpty ? "Backup Drive" : syncEngine.diskStatus.volumeName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text(syncEngine.diskStatus.isConnected
                             ? "\(syncEngine.diskStatus.formattedTotalAppFootprint) used · \(syncEngine.diskStatus.formattedFreeSpace) free"
                             : "Drive Disconnected")
                            .font(.system(size: 9.5))
                            .foregroundColor(syncEngine.diskStatus.isConnected ? .secondary : .orange)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                
                // Segmented Visual Storage Bar
                StorageBarView(diskStatus: syncEngine.diskStatus, style: .barOnly, barHeight: 5)
                
                // Detailed Breakdown Rows
                if syncEngine.diskStatus.isConnected {
                    VStack(spacing: 3.5) {
                        HStack {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.primary.opacity(0.8))
                                    .frame(width: 5, height: 5)
                                Text("Sync Copy")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(syncEngine.diskStatus.formattedSyncedSize)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                        }
                        
                        HStack {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                                Text("History")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(syncEngine.diskStatus.formattedHistorySize)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }
                        
                        HStack {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                                    .frame(width: 5, height: 5)
                                Text("Free Space")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(syncEngine.diskStatus.formattedFreeSpace)
                                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }
    
    private func sidebarRow(
        title: String,
        icon: String,
        count: Int?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(width: 16)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Spacer()
                
                if let c = count {
                    Text("\(c)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(nsColor: .separatorColor).opacity(0.3) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}
