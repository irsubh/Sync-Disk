import SwiftUI
import AppKit

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var config: SyncConfig
    @Published public var customBackupURL: URL?
    @Published public var useCustomBackup: Bool
    @Published public var recursionWarning: String?
    @Published public var showSaveFeedback: Bool = false
    
    public init(config: SyncConfig) {
        self.config = config
        self.useCustomBackup = config.backupDestination != nil
        self.customBackupURL = config.backupDestination
        validateRecursion()
    }
    
    public func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Sync Source"
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !config.sources.contains(where: { $0.url == url }) {
                    config.sources.append(SyncSource(name: url.lastPathComponent, url: url))
                }
            }
            validateRecursion()
        }
    }
    
    public func removeSource(_ source: SyncSource) {
        config.sources.removeAll(where: { $0.id == source.id })
        validateRecursion()
    }
    
    public func chooseSyncDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select External Sync Destination"
        
        if panel.runModal() == .OK, let url = panel.url {
            if HistoryStorageManager.isForbiddenInternalStorage(url: url) {
                recursionWarning = "Sync destination must be located on an external drive (/Volumes/...), never on internal Mac storage."
                return
            }
            config.syncDestination = url
            validateRecursion()
        }
    }
    
    public func chooseBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose External Backup Folder"
        
        if panel.runModal() == .OK, let url = panel.url {
            if HistoryStorageManager.isForbiddenInternalStorage(url: url) {
                recursionWarning = "Backup history destination must be located on an external drive (/Volumes/...), never on internal Mac storage."
                return
            }
            customBackupURL = url
            useCustomBackup = true
            validateRecursion()
        }
    }
    
    public func resetBackupToDefault() {
        useCustomBackup = false
        customBackupURL = nil
        validateRecursion()
    }
    
    public func validateRecursion() {
        let historyPath = (useCustomBackup ? customBackupURL : config.effectiveHistoryURL)?.standardizedFileURL.path
        guard let hist = historyPath else {
            recursionWarning = nil
            return
        }
        
        for source in config.sources {
            let srcPath = source.url.standardizedFileURL.path
            if hist.hasPrefix(srcPath) {
                recursionWarning = "Warning: History location is inside sync source '\(source.name)'. This could create recursive backup behavior. Please choose a separate location."
                return
            }
        }
        recursionWarning = nil
    }
    
    public func saveAndApply(syncEngine: SyncEngine) {
        config.backupDestination = useCustomBackup ? customBackupURL : nil
        LaunchAtLoginManager.setEnabled(config.launchAtLogin)
        syncEngine.updateConfig(config)
        withAnimation {
            showSaveFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                self.showSaveFeedback = false
            }
        }
    }
}

public struct SettingsView: View {
    @ObservedObject public var syncEngine: SyncEngine
    public var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: SettingsViewModel
    
    public init(syncEngine: SyncEngine, onDismiss: (() -> Void)? = nil) {
        self.syncEngine = syncEngine
        self.onDismiss = onDismiss
        self._vm = StateObject(wrappedValue: SettingsViewModel(config: syncEngine.config))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                
                syncTab
                    .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                
                backupTab
                    .tabItem { Label("Backup", systemImage: "clock.arrow.circlepath") }
                
                iCloudTab
                    .tabItem { Label("iCloud", systemImage: "icloud") }
                
                advancedTab
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
            .padding(14)
            
            Divider()
            
            // Bottom Action Bar
            HStack {
                if vm.showSaveFeedback {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Settings saved")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button("Done") {
                    vm.saveAndApply(syncEngine: syncEngine)
                    if let cb = onDismiss {
                        cb()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 580, height: 440)
    }
    
    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch Sync Disk at login", isOn: $vm.config.launchAtLogin)
                Toggle("Show menu bar icon", isOn: .constant(true))
                    .disabled(true)
                Toggle("Start synchronization automatically", isOn: $vm.config.isSyncEnabled)
            }
            
            Section {
                Text("Sync Disk runs quietly in the macOS menu bar to continuously protect and mirror your selected folders.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Sync Tab
    private var syncTab: some View {
        Form {
            Section("Sync Sources") {
                VStack(alignment: .leading, spacing: 6) {
                    if vm.config.sources.isEmpty {
                        Text("No folders configured for synchronization.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach($vm.config.sources) { $source in
                            HStack {
                                Toggle("", isOn: $source.isEnabled)
                                    .labelsHidden()
                                
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)
                                
                                Text(source.name)
                                    .font(.system(size: 12, weight: .medium))
                                
                                Spacer()
                                
                                Text(source.url.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                
                                Button(action: { vm.removeSource(source) }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    
                    Button(action: vm.addFolder) {
                        Label("Add Folder...", systemImage: "plus")
                    }
                    .padding(.top, 4)
                }
            }
            
            Section("Sync Destination") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(syncEngine.diskStatus.isConnected ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(syncEngine.diskStatus.isConnected ? "External Disk Connected" : "External Disk Disconnected")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(syncEngine.diskStatus.isConnected ? .green : .orange)
                        }
                        
                        if let dest = vm.config.syncDestination {
                            Text(dest.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            Text("No destination selected")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button("Change...", action: vm.chooseSyncDestination)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Backup Tab
    private var backupTab: some View {
        Form {
            Section("Backup History") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("History Location")
                                .font(.system(size: 12, weight: .semibold))
                            
                            let effective = vm.useCustomBackup
                                ? (vm.customBackupURL?.path ?? "Custom location")
                                : (vm.config.syncDestination != nil ? "\(vm.config.syncDestination!.path)/.backup" : ".backup inside destination")
                            
                            Text(effective)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Change...", action: vm.chooseBackupDestination)
                    }
                    
                    if vm.useCustomBackup {
                        Button("Reset to Default (.backup inside destination)", action: vm.resetBackupToDefault)
                            .font(.system(size: 11))
                    }
                    
                    if let warning = vm.recursionWarning {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    
                    Divider()
                        .padding(.vertical, 2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• Previous versions are automatically preserved here.")
                        Text("• History is never removed by synchronization.")
                        Text("• Deduplicated via SHA-256 Content-Addressable Storage.")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - iCloud Tab
    private var iCloudTab: some View {
        Form {
            Section("iCloud Storage Optimization") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Automatically evict locally downloaded iCloud files after successful backup", isOn: $vm.config.evictICloudAfterSync)
                        .font(.system(size: 12, weight: .semibold))
                    
                    Text("Only evict after:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("External copy completed")
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("SHA-256 verified against source")
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Destination remains mounted and writable")
                        }
                    }
                    .font(.system(size: 11))
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    Text("This guarantees your files are completely preserved before local copies are freed.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Advanced Tab
    private var advancedTab: some View {
        Form {
            Section("Storage & Deduplication") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Content Deduplication (CAS)")
                            .font(.system(size: 12))
                        Spacer()
                        Text("Active (SHA-256)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.green)
                    }
                    
                    HStack {
                        Text("Database Engine")
                            .font(.system(size: 12))
                        Spacer()
                        Text("SQLite 3 (WAL Mode)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Debounce Delay")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(String(format: "%.1f", vm.config.debounceSeconds))s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $vm.config.debounceSeconds, in: 0.5...5.0, step: 0.5)
                }
            }
            
            Section("Database Maintenance") {
                HStack {
                    Text("Clean committed journal operations")
                    Spacer()
                    Button("Clean Journal") {
                        syncEngine.database.cleanCommittedJournalOperations()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
