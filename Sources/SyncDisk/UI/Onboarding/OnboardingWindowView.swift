import SwiftUI
import AppKit

public final class OnboardingViewModel: ObservableObject {
    @Published public var currentStep: Int = 1
    @Published public var selectedSources: [SyncSource] = []
    @Published public var selectedDestination: URL?
    @Published public var customBackupURL: URL?
    @Published public var useCustomBackup: Bool = false
    @Published public var enableICloudOptimization: Bool = false
    
    public init(config: SyncConfig) {
        self.selectedSources = config.sources
        self.selectedDestination = config.syncDestination
        self.customBackupURL = config.backupDestination
        self.enableICloudOptimization = config.evictICloudAfterSync
    }
}

public struct OnboardingWindowView: View {
    @ObservedObject public var syncEngine: SyncEngine
    public let onComplete: () -> Void
    
    @StateObject private var vm: OnboardingViewModel
    
    public init(syncEngine: SyncEngine, onComplete: @escaping () -> Void) {
        self.syncEngine = syncEngine
        self.onComplete = onComplete
        self._vm = StateObject(wrappedValue: OnboardingViewModel(config: syncEngine.config))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if vm.currentStep == 1 {
                step1SetupView
            } else {
                step2ICloudView
            }
        }
        .frame(width: 520, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Step 1: Initial Setup
    private var step1SetupView: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                
                Text("Sync Disk")
                    .font(.system(size: 20, weight: .bold))
                
                Text("Keep your files synchronized and preserve every version.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 10)
            
            // Cards Container
            VStack(spacing: 12) {
                // 1. Sync Sources Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sync Sources")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                        Button(action: pickSourceFolder) {
                            Label("Add Folder", systemImage: "plus")
                                .font(.system(size: 11))
                        }
                    }
                    
                    if vm.selectedSources.isEmpty {
                        VStack(spacing: 4) {
                            Text("Choose folders you want Sync Disk to protect.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(vm.selectedSources) { source in
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.system(size: 11))
                                    Text(source.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Button(action: { vm.selectedSources.removeAll { $0.id == source.id } }) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // 2. Sync Destination Card
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync Destination")
                        .font(.system(size: 12, weight: .bold))
                    
                    HStack {
                        if let dest = vm.selectedDestination {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(dest.lastPathComponent)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(dest.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("No external disk or folder selected")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: pickDestinationFolder) {
                            Text(vm.selectedDestination == nil ? "Choose Destination..." : "Change...")
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // 3. Backup History Card
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backup History")
                        .font(.system(size: 12, weight: .bold))
                    
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.purple)
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automatically use .backup")
                                .font(.system(size: 12, weight: .medium))
                            Text(vm.selectedDestination != nil ? "\(vm.selectedDestination!.path)/.backup" : "Created inside destination")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button(action: { withAnimation { vm.currentStep = 2 } }) {
                    Text("Continue")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.selectedSources.isEmpty || vm.selectedDestination == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
    
    // MARK: - Step 2: iCloud Optimization Explanation
    private var step2ICloudView: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                
                Text("iCloud Storage Optimization")
                    .font(.system(size: 18, weight: .bold))
                
                Text("Free up Mac disk space while keeping permanent external backups.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 14)
            
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $vm.enableICloudOptimization) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically evict locally downloaded iCloud files after successful backup")
                            .font(.system(size: 12, weight: .semibold))
                        Text("When enabled, macOS frees local storage space after Sync Disk mirrors and verifies files on your external disk.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sync Disk Safety Guarantees:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    GuaranteeRow(text: "External copy completed successfully")
                    GuaranteeRow(text: "SHA-256 integrity verified against original")
                    GuaranteeRow(text: "External destination is mounted and writable")
                    GuaranteeRow(text: "Never evicts if external disk is disconnected")
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 28)
            
            Spacer()
            
            Divider()
            
            HStack {
                Button(action: { withAnimation { vm.currentStep = 1 } }) {
                    Text("Back")
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: finishOnboarding) {
                    Text("Start Synchronization")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
    
    // MARK: - Actions
    
    private func pickSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Select Folders to Sync"
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !vm.selectedSources.contains(where: { $0.url == url }) {
                    vm.selectedSources.append(SyncSource(name: url.lastPathComponent, url: url))
                }
            }
        }
    }
    
    private func pickDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Sync Destination"
        
        if panel.runModal() == .OK, let url = panel.url {
            vm.selectedDestination = url
        }
    }
    
    private func finishOnboarding() {
        var updated = syncEngine.config
        updated.sources = vm.selectedSources
        updated.syncDestination = vm.selectedDestination
        updated.backupDestination = vm.customBackupURL
        updated.evictICloudAfterSync = vm.enableICloudOptimization
        updated.isSyncEnabled = true
        
        syncEngine.updateConfig(updated)
        syncEngine.diskMonitor.checkStatus(forceNotify: true)
        syncEngine.triggerReconcile()
        
        onComplete()
    }
}

private struct GuaranteeRow: View {
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
        }
    }
}
