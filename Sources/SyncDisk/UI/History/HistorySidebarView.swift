import SwiftUI
import AppKit

public enum HistoryLibraryFilter: String, CaseIterable, Hashable, Sendable {
    case all = "All Files"
    case active = "Active"
    case history = "History"
}

public enum HistorySidebarSelection: Hashable {
    case allFiles
    case activeOnly
    case deletedOnly
    case source(UUID)
}

public struct HistorySidebarView: View {
    @ObservedObject public var syncEngine: SyncEngine
    @Binding public var libraryFilter: HistoryLibraryFilter
    @Binding public var selectedSourceId: UUID?
    public let totalFileCount: Int
    public let activeCount: Int
    public let deletedCount: Int
    public let onAddSource: () -> Void
    public let onSelectStorage: () -> Void
    public let onFilterChange: ((HistoryLibraryFilter, UUID?) -> Void)?
    
    public init(
        syncEngine: SyncEngine,
        libraryFilter: Binding<HistoryLibraryFilter>,
        selectedSourceId: Binding<UUID?>,
        totalFileCount: Int,
        activeCount: Int,
        deletedCount: Int,
        onAddSource: @escaping () -> Void = {},
        onSelectStorage: @escaping () -> Void = {},
        onFilterChange: ((HistoryLibraryFilter, UUID?) -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self._libraryFilter = libraryFilter
        self._selectedSourceId = selectedSourceId
        self.totalFileCount = totalFileCount
        self.activeCount = activeCount
        self.deletedCount = deletedCount
        self.onAddSource = onAddSource
        self.onSelectStorage = onSelectStorage
        self.onFilterChange = onFilterChange
    }
    
    // Backwards-compatible convenience initializer
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
        self.totalFileCount = totalFileCount
        self.activeCount = activeCount
        self.deletedCount = deletedCount
        self.onAddSource = onAddSource
        self.onSelectStorage = onSelectStorage
        
        self._libraryFilter = Binding<HistoryLibraryFilter>(
            get: {
                switch selection.wrappedValue {
                case .allFiles: return .all
                case .activeOnly: return .active
                case .deletedOnly: return .history
                case .source: return .all
                }
            },
            set: { newFilter in
                switch newFilter {
                case .all: selection.wrappedValue = .allFiles
                case .active: selection.wrappedValue = .activeOnly
                case .history: selection.wrappedValue = .deletedOnly
                }
            }
        )
        
        self._selectedSourceId = Binding<UUID?>(
            get: {
                if case .source(let id) = selection.wrappedValue {
                    return id
                }
                return nil
            },
            set: { newSourceId in
                if let id = newSourceId {
                    selection.wrappedValue = .source(id)
                }
            }
        )
        
        self.onFilterChange = { filter, sourceId in
            if let sid = sourceId {
                onSelectSection?(.source(sid))
            } else {
                switch filter {
                case .all: onSelectSection?(.allFiles)
                case .active: onSelectSection?(.activeOnly)
                case .history: onSelectSection?(.deletedOnly)
                }
            }
        }
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
                
                libraryRow(
                    filter: .all,
                    icon: "tray.full",
                    count: totalFileCount
                )
                
                libraryRow(
                    filter: .active,
                    icon: "checkmark",
                    count: activeCount
                )
                
                libraryRow(
                    filter: .history,
                    icon: "clock",
                    count: deletedCount
                )
            }
            
            // SOURCES Section
            VStack(alignment: .leading, spacing: 4) {
                Text("SOURCES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                
                ForEach(syncEngine.config.sources) { source in
                    let isSel = (selectedSourceId == source.id)
                    
                    sidebarRow(
                        title: source.name,
                        icon: "folder",
                        count: nil,
                        isSelected: isSel
                    ) {
                        selectedSourceId = source.id
                        onFilterChange?(libraryFilter, source.id)
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
            
            // Active Activity Card (shown above storage widget for Restoring, Syncing, or Paused)
            activityStatusCard
            
            // Storage Detailed Footer Card
            storageDetailedCard
        }
        .padding(.top, 16)
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func libraryRow(
        filter: HistoryLibraryFilter,
        icon: String,
        count: Int?
    ) -> some View {
        let isCurrentFilter = (libraryFilter == filter)
        let isPrimarySelected = isCurrentFilter && (selectedSourceId == nil)
        let isFilterActiveOnSource = isCurrentFilter && (selectedSourceId != nil)
        
        return Button(action: {
            if isFilterActiveOnSource {
                // If this filter is already active on a source, clicking it resets back to root
                selectedSourceId = nil
                onFilterChange?(filter, nil)
            } else {
                libraryFilter = filter
                // If a source is selected, keep the source and apply this filter to it
                onFilterChange?(filter, selectedSourceId)
            }
        }) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isCurrentFilter ? .semibold : .medium))
                    .foregroundColor(isPrimarySelected ? .primary : (isFilterActiveOnSource ? .accentColor : .secondary))
                    .frame(width: 16)
                
                Text(filter.rawValue)
                    .font(.system(size: 13, weight: isPrimarySelected ? .semibold : (isFilterActiveOnSource ? .medium : .regular)))
                    .foregroundColor(isPrimarySelected ? .primary : (isFilterActiveOnSource ? .accentColor : .secondary))
                
                Spacer()
                
                if let c = count {
                    Text("\(c)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(isFilterActiveOnSource ? .accentColor.opacity(0.8) : .secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isPrimarySelected
                            ? Color(nsColor: .separatorColor).opacity(0.3)
                            : (isFilterActiveOnSource ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
    
    // MARK: - Activity Status Cards (Restoring, Syncing, or Paused)
    
    @ViewBuilder
    private var activityStatusCard: some View {
        if syncEngine.isRestoring {
            restoreProgressCard
        } else if syncEngine.syncProgress.isSyncing {
            syncingProgressCard
        } else if syncEngine.isLiveSyncPaused {
            pausedStatusCard
        }
    }

    @ViewBuilder
    private var restoreProgressCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
                
                Text(syncEngine.restoreTitle.isEmpty ? "Restoring" : syncEngine.restoreTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                let pct = Int(round(syncEngine.restoreProgress * 100))
                Text("\(pct)%")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
            }
            
            // Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        .frame(height: 5)
                    
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1.0, max(0.0, syncEngine.restoreProgress)))), height: 5)
                        .animation(.linear(duration: 0.15), value: syncEngine.restoreProgress)
                }
            }
            .frame(height: 5)
            
            HStack {
                Text("Restoring files…")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(syncEngine.restoreCurrentFile) / \(syncEngine.restoreTotalFiles)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.8)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    @ViewBuilder
    private var syncingProgressCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
                
                Text(syncEngine.syncProgress.currentFileName.isEmpty ? "Live Syncing" : syncEngine.syncProgress.currentFileName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                let pct = Int(round(syncEngine.syncProgress.fractionCompleted * 100))
                if syncEngine.syncProgress.filesTotal > 0 {
                    Text("\(pct)%")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                }
            }
            
            // Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        .frame(height: 5)
                    
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: syncEngine.syncProgress.filesTotal > 0
                                ? max(4, geo.size.width * CGFloat(min(1.0, max(0.0, syncEngine.syncProgress.fractionCompleted))))
                                : 24,
                            height: 5
                        )
                        .animation(.linear(duration: 0.15), value: syncEngine.syncProgress.fractionCompleted)
                }
            }
            .frame(height: 5)
            
            HStack {
                Text(syncEngine.syncProgress.statusDescription.isEmpty ? "Syncing files…" : syncEngine.syncProgress.statusDescription)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                if syncEngine.syncProgress.filesTotal > 0 {
                    Text("\(syncEngine.syncProgress.filesCompleted) / \(syncEngine.syncProgress.filesTotal)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.8)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    @ViewBuilder
    private var pausedStatusCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 1) {
                Text("Live Sync Paused")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Monitoring suspended")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                syncEngine.toggleLiveSyncing()
            }) {
                Text("Resume")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
