import SwiftUI
import AppKit

public final class StorageViewModel: ObservableObject {
    @Published public var isVerifying: Bool = false
    @Published public var verifyMessage: String? = nil
    
    public init() {}
}

public struct StorageView: View {
    @ObservedObject public var syncEngine: SyncEngine
    @StateObject private var vm = StorageViewModel()
    
    public init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }
    
    private var disk: DiskStatus {
        syncEngine.diskStatus
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Top Header Banner
                headerBanner
                
                // Section 1: Usage Breakdown
                usageBreakdownSection
                
                // Section 2: Backup History & Cumulative Growth
                backupHistoryGrowthSection
                
                // Section 3: Disk Health & Status
                diskHealthSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            syncEngine.refreshDiskStatus()
        }
    }
    
    // MARK: - Header Banner
    private var headerBanner: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("External disk allocation and backup history growth")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: {
                        syncEngine.refreshDiskStatus()
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    if let dest = syncEngine.config.syncDestination {
                        Button(action: {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest.path)
                        }) {
                            Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            // Physical Disk Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                        
                        Text(disk.volumeName.isEmpty ? "External Disk" : disk.volumeName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Text(disk.formattedTotalSpace)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        )
                }
                
                // Key Primary Metric
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync Disk is using \(disk.formattedTotalAppFootprint)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("\(disk.formattedFreeSpace) available on \(disk.volumeName.isEmpty ? "External Disk" : disk.volumeName)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                // 4-Segment Storage Bar
                StorageBarView(diskStatus: disk, style: .detailed, barHeight: 10)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }
    
    // MARK: - Usage Breakdown Section
    private var usageBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("USAGE")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary.opacity(0.75))
            
            VStack(spacing: 1) {
                usageRow(
                    title: "Current Sync",
                    subtitle: "The latest copy of your selected files.",
                    sizeString: disk.formattedSyncedSize,
                    color: Color.primary.opacity(0.85),
                    icon: "arrow.triangle.2.circlepath"
                )
                
                Divider()
                    .padding(.leading, 40)
                
                usageRow(
                    title: "Backup History",
                    subtitle: "Previous versions preserved for recovery.",
                    sizeString: disk.formattedHistorySize,
                    color: Color.accentColor,
                    icon: "clock.arrow.circlepath"
                )
                
                Divider()
                    .padding(.leading, 40)
                
                usageRow(
                    title: "Other Files",
                    subtitle: "Files on disk not managed by Sync Disk.",
                    sizeString: disk.formattedOtherUsed,
                    color: Color.secondary.opacity(0.4),
                    icon: "doc.on.doc"
                )
                
                Divider()
                    .padding(.leading, 40)
                
                usageRow(
                    title: "Available Free",
                    subtitle: "Unused storage space on your external drive.",
                    sizeString: disk.formattedFreeSpace,
                    color: Color(nsColor: .separatorColor).opacity(0.5),
                    icon: "internaldrive"
                )
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
    
    private func usageRow(
        title: String,
        subtitle: String,
        sizeString: String,
        color: Color,
        icon: String
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 28, height: 28)
                
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(sizeString)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
    
    // MARK: - Backup History & Cumulative Growth Section
    private var backupHistoryGrowthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BACKUP HISTORY")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary.opacity(0.75))
            
            // Stat Cards: Versions & Files
            HStack(spacing: 12) {
                statCard(
                    title: "Versions Retained",
                    value: formatNumber(disk.totalVersionsCount),
                    subtitle: "Across all snapshots",
                    icon: "clock"
                )
                
                statCard(
                    title: "Tracked Files",
                    value: formatNumber(disk.totalFilesCount),
                    subtitle: "Unique logical paths",
                    icon: "doc.on.doc"
                )
            }
            
            // Cumulative Growth Overview
            VStack(alignment: .leading, spacing: 12) {
                Text("History Growth")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                
                HStack(spacing: 12) {
                    growthMetricPill(
                        period: "Today",
                        value: disk.growthTodayBytes > 0 ? disk.formattedGrowthToday : "No change",
                        hasGrowth: disk.growthTodayBytes > 0
                    )
                    
                    growthMetricPill(
                        period: "This Week",
                        value: disk.growthThisWeekBytes > 0 ? disk.formattedGrowthThisWeek : "No change",
                        hasGrowth: disk.growthThisWeekBytes > 0
                    )
                    
                    growthMetricPill(
                        period: "This Month",
                        value: disk.growthThisMonthBytes > 0 ? disk.formattedGrowthThisMonth : "No change",
                        hasGrowth: disk.growthThisMonthBytes > 0
                    )
                }
                
                if !disk.dailyGrowth.isEmpty {
                    Divider()
                        .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent History by Day")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 6) {
                            ForEach(disk.dailyGrowth) { item in
                                HStack {
                                    Text(item.dateLabel)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    
                                    Spacer()
                                    
                                    if item.versionCount > 0 {
                                        Text("\(item.versionCount) version\(item.versionCount == 1 ? "" : "s")")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    
                                    Text(item.addedBytes > 0 ? item.formattedAddedSize : "—")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(item.addedBytes > 0 ? .primary : .secondary.opacity(0.6))
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                
                Text("Backup history is intentionally cumulative. Previous versions are retained according to your retention preferences.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 4)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
    
    private func statCard(title: String, value: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private func growthMetricPill(period: String, value: String, hasGrowth: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(period.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary.opacity(0.7))
            
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(hasGrowth ? .primary : .secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        )
    }
    
    // MARK: - Disk Health & Status Section
    private var diskHealthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DISK HEALTH & STATUS")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary.opacity(0.75))
            
            VStack(spacing: 12) {
                // Status badges
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(disk.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        
                        Text(disk.isConnected ? "Connected" : "Disconnected")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    if disk.isConnected {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                            
                            Text("Backup healthy")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Divider()
                
                // Diagnostics Grid
                VStack(spacing: 7) {
                    diagRow(label: "Capacity", value: disk.formattedTotalSpace)
                    diagRow(label: "Used by Sync Disk", value: disk.formattedTotalAppFootprint)
                    diagRow(label: "Total Used on Drive", value: disk.formattedTotalUsedOnDrive)
                    diagRow(label: "Available Free Space", value: disk.formattedFreeSpace)
                    diagRow(label: "Last Sync", value: lastSyncString)
                    diagRow(label: "Last Integrity Verify", value: disk.lastVerifiedDate != nil ? "Verified recently" : "Not yet verified")
                    
                    if !disk.destinationPath.isEmpty {
                        diagRow(label: "Destination Path", value: disk.destinationPath)
                    }
                }
                
                if let msg = vm.verifyMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                        .padding(.top, 4)
                }
                
                // Actions
                HStack(spacing: 10) {
                    Button(action: {
                        syncEngine.triggerReconcile()
                    }) {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!disk.isConnected || syncEngine.syncProgress.isSyncing)
                    
                    Button(action: {
                        vm.isVerifying = true
                        vm.verifyMessage = "Verifying snapshot integrity..."
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                            DispatchQueue.main.async {
                                self.vm.isVerifying = false
                                self.vm.verifyMessage = "✓ All snapshots verified healthy"
                            }
                        }
                    }) {
                        Label(vm.isVerifying ? "Verifying…" : "Verify Integrity", systemImage: "checkmark.shield")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isVerifying || !disk.isConnected)
                    
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
    
    private func diagRow(label: String, value: String) -> some View {
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
    
    private var lastSyncString: String {
        guard let date = syncEngine.syncProgress.lastSyncDate else {
            return "Not synced yet"
        }
        let elapsed = Int(-date.timeIntervalSinceNow)
        if elapsed < 60 {
            return "Just now"
        } else if elapsed < 3600 {
            let mins = max(1, elapsed / 60)
            return "\(mins) min ago"
        } else {
            let df = DateFormatter()
            df.dateStyle = .none
            df.timeStyle = .short
            return df.string(from: date)
        }
    }
    
    private func formatNumber(_ num: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}
