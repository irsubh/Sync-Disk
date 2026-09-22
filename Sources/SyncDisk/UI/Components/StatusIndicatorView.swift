import SwiftUI

public enum EngineDisplayState {
    case synced
    case syncing(filesRemaining: Int)
    case disconnected
    case attentionRequired(message: String)
}

public struct StatusIndicatorView: View {
    public let isConnected: Bool
    public let isSyncing: Bool
    public let filesRemaining: Int
    public let errorMessage: String?
    public var compact: Bool = false
    
    public init(
        isConnected: Bool,
        isSyncing: Bool,
        filesRemaining: Int = 0,
        errorMessage: String? = nil,
        compact: Bool = false
    ) {
        self.isConnected = isConnected
        self.isSyncing = isSyncing
        self.filesRemaining = filesRemaining
        self.errorMessage = errorMessage
        self.compact = compact
    }
    
    public var displayState: EngineDisplayState {
        if let err = errorMessage, !err.isEmpty {
            return .attentionRequired(message: err)
        } else if !isConnected {
            return .disconnected
        } else if isSyncing {
            return .syncing(filesRemaining: filesRemaining)
        } else {
            return .synced
        }
    }
    
    public var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            indicatorIcon
            
            if !compact {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
            }
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.12))
        .clipShape(Capsule())
    }
    
    @ViewBuilder
    private var indicatorIcon: some View {
        switch displayState {
        case .synced:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.blue)
                .rotationEffect(.degrees(isSyncing ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isSyncing)
        case .disconnected:
            Circle()
                .stroke(Color.orange, lineWidth: 2)
                .frame(width: 7, height: 7)
        case .attentionRequired:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.red)
        }
    }
    
    private var statusColor: Color {
        switch displayState {
        case .synced:
            return .green
        case .syncing:
            return .blue
        case .disconnected:
            return .orange
        case .attentionRequired:
            return .red
        }
    }
    
    private var statusText: String {
        switch displayState {
        case .synced:
            return "Synced"
        case .syncing(let remaining):
            return remaining > 0 ? "Syncing (\(remaining))" : "Syncing..."
        case .disconnected:
            return "Disk disconnected"
        case .attentionRequired:
            return "Attention required"
        }
    }
}
