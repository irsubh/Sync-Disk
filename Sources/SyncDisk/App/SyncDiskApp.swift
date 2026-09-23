import SwiftUI
import AppKit

public struct SyncDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var syncEngine = SyncEngine.shared
    
    public init() {}
    
    public var body: some Scene {
        MenuBarExtra {
            MenuBarPopupView(
                syncEngine: syncEngine,
                onOpenHistory: {
                    WindowManager.shared.openHistoryWindow(syncEngine: syncEngine, initialMode: .files)
                },
                onOpenStorage: {
                    WindowManager.shared.openStorageWindow(syncEngine: syncEngine)
                },
                onOpenSettings: {
                    WindowManager.shared.openSettingsWindow(syncEngine: syncEngine)
                }
            )
            .onAppear {
                checkFirstLaunchOnboarding()
            }
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: MenuBarIconProvider.shared.icon())
                if syncEngine.isRestoring {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                } else if syncEngine.syncProgress.isSyncing {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                } else if !syncEngine.diskStatus.isConnected {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 4, height: 4)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
    
    private func checkFirstLaunchOnboarding() {
        if syncEngine.config.sources.isEmpty || syncEngine.config.syncDestination == nil {
            WindowManager.shared.openOnboardingWindow(syncEngine: syncEngine)
        }
    }
}
