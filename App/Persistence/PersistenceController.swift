import Foundation
import SwiftData
import NurseTimerModels

/// Builds the SwiftData container. Local device only, no CloudKit (spec §2.1).
/// The store and ALL its SQLite sidecars (`-wal`/`-shm`) are protected at rest (item 8).
enum PersistenceController {

    static let schema = Schema([Patient.self, CareTask.self, TaskEvent.self, AppSettings.self])

    /// The single source of truth for the at-rest data-protection level (item 8). Default
    /// `.complete`; the final choice (`.complete` vs `.completeUnlessOpen`) is decided on
    /// Mac after locked-phone testing, since `.complete` can block background access while
    /// the device is locked.
    static let protectionLevel: FileProtectionType = .complete

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: config)
        }
        let dir = storeDirectory()
        // Protect the CONTAINING DIRECTORY before the store is created, so files SwiftData
        // creates inside it — including the -wal/-shm sidecars written later — inherit the
        // protection class rather than the app default.
        applyProtection(toDirectory: dir)

        let url = dir.appending(path: "NurseTimer.store")
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)

        applyProtection(toStoreAt: url)   // reapply to the store + any sidecars that now exist
        return container
    }

    /// Reapply protection to the store and every sidecar. Belt-and-suspenders for a sidecar
    /// recreated without the inherited class after a checkpoint (item 8).
    static func reapplyProtection() {
        applyProtection(toStoreAt: storeDirectory().appending(path: "NurseTimer.store"))
    }

    // MARK: Internals

    private static func storeDirectory() -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "NurseTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func applyProtection(toDirectory dir: URL) {
        do {
            try FileManager.default.setAttributes([.protectionKey: protectionLevel], ofItemAtPath: dir.path)
        } catch {
            AppLog.persistence.error("Could not set protection on store directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func applyProtection(toStoreAt url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.setAttributes([.protectionKey: protectionLevel], ofItemAtPath: path)
            } catch {
                AppLog.persistence.error("Could not protect \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
