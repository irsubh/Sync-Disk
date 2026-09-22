import Foundation
import AppKit

public final class PasteboardHelper: Sendable {
    public init() {}
    
    /// Copies a historical version file to NSPasteboard with its original logical filename.
    @MainActor
    public static func copyFileToClipboard(
        entry: FileHistoryEntry,
        storageManager: HistoryStorageManager
    ) throws {
        // Extract the file to a sandbox location using the original filename
        let cleanFileURL = try storageManager.extractHistoricalFile(entry: entry)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // Write the file URL as an NSURL object so Finder / Desktop can paste it directly
        pasteboard.writeObjects([cleanFileURL as NSURL])
        
        // Also provide string representation of the original file path
        pasteboard.setString(cleanFileURL.path, forType: .string)
    }
}
