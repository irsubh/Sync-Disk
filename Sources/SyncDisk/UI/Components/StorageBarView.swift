import SwiftUI

public enum StorageBarStyle {
    case detailed
    case compact
    case barOnly
}

public struct StorageBarView: View {
    public let diskStatus: DiskStatus
    public var style: StorageBarStyle = .detailed
    public var barHeight: CGFloat = 8
    
    public init(
        diskStatus: DiskStatus,
        style: StorageBarStyle = .detailed,
        barHeight: CGFloat = 8
    ) {
        self.diskStatus = diskStatus
        self.style = style
        self.barHeight = barHeight
    }
    
    // Semantic Palette per user specification:
    // Sync -> dark neutral
    // History -> medium accent
    // Other -> light gray
    // Free -> subtle background track
    private var syncColor: Color {
        Color.primary.opacity(0.82)
    }
    
    private var historyColor: Color {
        Color.accentColor
    }
    
    private var otherColor: Color {
        Color.secondary.opacity(0.35)
    }
    
    private var freeTrackColor: Color {
        Color(nsColor: .separatorColor).opacity(0.18)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Segmented Bar
            GeometryReader { geo in
                let total = max(Double(diskStatus.totalSpaceBytes), 1.0)
                let syncBytes = Double(diskStatus.syncedSizeBytes)
                let historyBytes = Double(diskStatus.historySizeBytes)
                let otherBytes = Double(max(0, diskStatus.otherUsedBytes))
                
                let rawSync = (syncBytes / total) * geo.size.width
                let rawHistory = (historyBytes / total) * geo.size.width
                let rawOther = (otherBytes / total) * geo.size.width
                
                // Ensure small positive amounts have at least 3px visibility
                let minWidth: CGFloat = 3
                let wSync = syncBytes > 0 ? max(rawSync, minWidth) : 0
                let wHistory = historyBytes > 0 ? max(rawHistory, minWidth) : 0
                let wOther = otherBytes > 0 ? max(rawOther, minWidth) : 0
                
                let usedTotalWidth = wSync + wHistory + wOther
                let wFree = max(0, geo.size.width - usedTotalWidth)
                
                HStack(spacing: 1.5) {
                    if wSync > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(syncColor)
                            .frame(width: wSync)
                    }
                    if wHistory > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(historyColor)
                            .frame(width: wHistory)
                    }
                    if wOther > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(otherColor)
                            .frame(width: wOther)
                    }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(freeTrackColor)
                        .frame(width: wFree)
                }
            }
            .frame(height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: barHeight / 2))
            
            // Legends
            switch style {
            case .detailed:
                detailedLegend
            case .compact:
                compactLegend
            case .barOnly:
                EmptyView()
            }
        }
    }
    
    // MARK: - Detailed Legend (4 items + summary line)
    private var detailedLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                legendItem(
                    label: "Sync",
                    value: diskStatus.formattedSyncedSize,
                    color: syncColor
                )
                
                Spacer()
                
                legendItem(
                    label: "History",
                    value: diskStatus.formattedHistorySize,
                    color: historyColor
                )
                
                Spacer()
                
                legendItem(
                    label: "Other",
                    value: diskStatus.formattedOtherUsed,
                    color: otherColor
                )
                
                Spacer()
                
                legendItem(
                    label: "Free",
                    value: diskStatus.formattedFreeSpace,
                    color: freeTrackColor.opacity(0.8)
                )
            }
            
            // Subtitle summary line: "124.1 GB used of 1 TB · 875.9 GB available"
            let usedStr = diskStatus.formattedTotalUsedOnDrive
            let totalStr = diskStatus.formattedTotalSpace
            let freeStr = diskStatus.formattedFreeSpace
            
            Text("\(usedStr) used of \(totalStr) · \(freeStr) available")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.top, 2)
    }
    
    // MARK: - Compact Legend (for Sidebar / Popover)
    private var compactLegend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().fill(syncColor).frame(width: 6, height: 6)
                Text("Sync \(diskStatus.formattedSyncedSize)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 4) {
                Circle().fill(historyColor).frame(width: 6, height: 6)
                Text("History \(diskStatus.formattedHistorySize)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("\(diskStatus.formattedFreeSpace) free")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
    
    private func legendItem(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .padding(.leading, 12)
        }
    }
}
