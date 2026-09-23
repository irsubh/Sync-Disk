import SwiftUI
import AppKit

public struct MenuBarPopupView: View {
    @ObservedObject public var syncEngine: SyncEngine
    public let onOpenHistory: () -> Void
    public let onOpenStorage: () -> Void
    public let onOpenSettings: () -> Void
    
    public init(
        syncEngine: SyncEngine,
        onOpenHistory: @escaping () -> Void,
        onOpenStorage: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void
    ) {
        self.syncEngine = syncEngine
        self.onOpenHistory = onOpenHistory
        self.onOpenStorage = onOpenStorage
        self.onOpenSettings = onOpenSettings
    }
    
    private var disk: DiskStatus {
        syncEngine.diskStatus
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            // Header: App Title, Logo & Live Status Capsule Badge
            HStack(spacing: 10) {
                LogoIconView(size: 26)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Disk")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Status Badge Capsule
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    
                    Text(statusBadgeTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(statusColor.opacity(0.12))
                )
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            
            // Elevated Storage Card
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(disk.isConnected ? .accentColor : .secondary)
                    
                    Text(disk.volumeName.isEmpty ? "External Disk" : disk.volumeName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if disk.isConnected {
                        Text("\(disk.formattedFreeSpace) free")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
                
                if disk.isConnected {
                    // Segmented Storage Bar
                    StorageBarView(diskStatus: disk, style: .barOnly, barHeight: 7)
                    
                    // Quick Metrics Breakdown
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.primary.opacity(0.85))
                                .frame(width: 5, height: 5)
                            Text("Sync")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(disk.formattedSyncedSize)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                            Text("History")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(disk.formattedHistorySize)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.top, 1)
                    
                    // Last Sync Timestamp
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text(lastSyncText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.top, 1)
                } else {
                    Text("Connect your backup disk to resume syncing")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 0.5)
                    )
            )
            
            // Action Menu Rows
            VStack(spacing: 2) {
                MenuActionRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncEngine.isRestoring ? "Restoring in progress…" : (syncEngine.syncProgress.isSyncing ? "Syncing in background…" : "Sync Now"),
                    isEnabled: disk.isConnected && !syncEngine.syncProgress.isSyncing && !syncEngine.isRestoring,
                    action: {
                        syncEngine.triggerReconcile()
                    }
                )
                
                MenuActionRow(
                    icon: "clock.arrow.circlepath",
                    title: "Open History",
                    shortcut: "⌘H",
                    action: onOpenHistory
                )
                
                MenuActionRow(
                    icon: "chart.pie",
                    title: "View Storage",
                    action: onOpenStorage
                )
                
                MenuActionRow(
                    icon: "gearshape",
                    title: "Settings…",
                    shortcut: "⌘,",
                    action: onOpenSettings
                )
            }
            
            // Divider
            Divider()
                .padding(.horizontal, 2)
            
            // Quit Row
            MenuActionRow(
                icon: "power",
                title: "Quit Sync Disk",
                shortcut: "⌘Q",
                isDestructive: false,
                action: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .padding(.bottom, 2)
        }
        .padding(12)
        .frame(width: 280)
    }
    
    // Status color mapping
    private var statusColor: Color {
        if syncEngine.isRestoring {
            return .accentColor
        } else if !disk.isConnected {
            return .orange
        } else if syncEngine.isLiveSyncPaused {
            return .orange
        } else if syncEngine.syncProgress.isSyncing {
            return .accentColor
        } else if syncEngine.lastErrorMessage != nil {
            return .red
        } else {
            return .green
        }
    }
    
    private var statusBadgeTitle: String {
        if syncEngine.isRestoring {
            return "Restoring"
        } else if !disk.isConnected {
            return "Offline"
        } else if syncEngine.isLiveSyncPaused {
            return "Paused"
        } else if syncEngine.syncProgress.isSyncing {
            return "Syncing"
        } else if syncEngine.lastErrorMessage != nil {
            return "Alert"
        } else {
            return "Synced"
        }
    }
    
    private var statusText: String {
        if syncEngine.isRestoring {
            let done = syncEngine.restoreCurrentFile
            let total = syncEngine.restoreTotalFiles
            return total > 0 ? "Restoring (\(done)/\(total) files)" : "Restoring files…"
        } else if !disk.isConnected {
            return "Disk disconnected"
        } else if syncEngine.isLiveSyncPaused {
            return "Live syncing paused"
        } else if syncEngine.syncProgress.isSyncing {
            return "Syncing (\(syncEngine.syncProgress.filesPending) files left)"
        } else if let err = syncEngine.lastErrorMessage {
            return err
        } else {
            return "Everything is up to date"
        }
    }
    
    private var lastSyncText: String {
        guard let date = syncEngine.syncProgress.lastSyncDate else {
            return "Not synced yet"
        }
        let elapsed = Int(-date.timeIntervalSinceNow)
        if elapsed < 60 {
            return "Last synced just now"
        } else if elapsed < 3600 {
            let mins = max(1, elapsed / 60)
            return "Last synced \(mins) min ago"
        } else {
            let df = DateFormatter()
            df.dateStyle = .none
            df.timeStyle = .short
            return "Last synced at \(df.string(from: date))"
        }
    }
}

// MARK: - Premium Action Row with Hover & SF Symbols
private final class MenuRowHoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

private struct MenuActionRow: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void
    
    @StateObject private var hover = MenuRowHoverState()
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(isDestructive ? .red.opacity(0.85) : (isEnabled ? .primary.opacity(0.85) : .secondary.opacity(0.45)))
                    .frame(width: 16, alignment: .center)
                
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isDestructive ? .red : (isEnabled ? .primary : .secondary.opacity(0.6)))
                
                Spacer()
                
                if let sc = shortcut {
                    Text(sc)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.55))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hover.isHovered && isEnabled ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.14) : Color.clear)
        )
        .onHover { isHovering in
            hover.isHovered = isHovering
        }
    }
}
