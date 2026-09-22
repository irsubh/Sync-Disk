import SwiftUI

public struct EmptyStateView: View {
    public let iconName: String
    public let title: String
    public let message: String
    public var buttonTitle: String? = nil
    public var action: (() -> Void)? = nil
    
    public init(
        iconName: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.iconName = iconName
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.action = action
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary.opacity(0.6))
            
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            
            if let bTitle = buttonTitle, let act = action {
                Button(action: act) {
                    Text(bTitle)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
