import Foundation
import SwiftData
import NurseTimerModels

/// Builds the SwiftData container. Local device only, no CloudKit (spec §2.1).
/// The on-disk store is marked `FileProtectionType.complete` so it is encrypted at
/// rest when the device is locked.
enum PersistenceController {

    static let schema = Schema([Patient.self, CareTask.self, TaskEvent.self, AppSettings.self])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: config)
        }
        let url = storeURL()
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        applyCompleteFileProtection(at: url)
        return container
    }

    private static func storeURL() -> URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "NurseTimer.store")
    }

    /// Encrypt the store (and its -wal/-shm sidecars) at rest when the device is locked.
    private static func applyCompleteFileProtection(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
            } catch {
                AppLog.persistence.error("Could not set complete file protection on \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
