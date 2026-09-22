import SwiftUI

public final class SyncProgressViewModel: ObservableObject {
    @Published public var showQueueDetails: Bool = false
    public init() {}
}

public struct SyncProgressDetailedView: View {
    public let progress: SyncProgress
    @StateObject private var vm = SyncProgressViewModel()
    
    public init(progress: SyncProgress) {
        self.progress = progress
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Status + Percentage
            HStack {
                Text(progress.isSyncing ? "Syncing" : "Idle")
                    .font(.system(size: 13, weight: .bold))
                
                Spacer()
                
                let pct = progress.percentComplete
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.accentColor)
            }
            
            // Progress Bar
            ProgressView(value: progress.percentComplete)
                .progressViewStyle(.linear)
            
            // File Count & Active File
            VStack(alignment: .leading, spacing: 4) {
                if progress.filesTotal > 0 {
                    Text("\(progress.filesCompleted) of \(progress.filesTotal) files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                }
                
                if !progress.currentFileName.isEmpty {
                    HStack(spacing: 4) {
                        Text("Current:")
                            .foregroundColor(.secondary)
                        Text(progress.currentFileName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                }
            }
            
            // Data Transferred & Estimated Remaining
            HStack {
                let transferredStr = ByteCountFormatter.string(fromByteCount: progress.bytesTransferred, countStyle: .file)
                let totalStr = ByteCountFormatter.string(fromByteCount: progress.totalBytesToTransfer, countStyle: .file)
                
                if progress.totalBytesToTransfer > 0 {
                    Text("\(transferredStr) / \(totalStr)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if progress.isSyncing && progress.estimatedSecondsRemaining > 0 {
                    Text("Remaining: ~\(Int(progress.estimatedSecondsRemaining))s")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Queue Breakdown Toggle
            Button(action: { withAnimation { vm.showQueueDetails.toggle() } }) {
                HStack {
                    Text("Queue Details")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: vm.showQueueDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            if vm.showQueueDetails {
                VStack(spacing: 6) {
                    QueueRow(label: "Completed", count: progress.filesCompleted, color: .green)
                    QueueRow(label: "Syncing", count: progress.isSyncing ? 1 : 0, color: .blue)
                    QueueRow(label: "Waiting", count: max(0, progress.filesPending - (progress.isSyncing ? 1 : 0)), color: .orange)
                    QueueRow(label: "Failed", count: progress.failedOperationsCount, color: .red)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct QueueRow: View {
    let label: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }
}
