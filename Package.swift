// swift-tools-version: 5.9
import PackageDescription

// NurseTimer — Shared scheduling layer (Milestone 1).
//
// This package holds ONLY the Foundation-only scheduling engine + the SwiftData
// models. UI (iOS / watchOS) is NOT here — it will be an Xcode project that
// consumes these library targets.
//
// Target rules (enforced by the spec + build request):
//   - NurseTimerCore     : Foundation ONLY. No SwiftData/SwiftUI/UserNotifications.
//   - NurseTimerModels   : SwiftData @Model layer, guarded with #if canImport(SwiftData)
//                          so it is harmless on non-Apple toolchains. Depends on Core.
//   - NurseTimerCoreTests: XCTest. Depends on Core ONLY (never on Models).
let package = Package(
    name: "NurseTimer",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "NurseTimerCore", targets: ["NurseTimerCore"]),
        .library(name: "NurseTimerModels", targets: ["NurseTimerModels"]),
    ],
    targets: [
        .target(name: "NurseTimerCore"),
        .target(name: "NurseTimerModels", dependencies: ["NurseTimerCore"]),
        .testTarget(name: "NurseTimerCoreTests", dependencies: ["NurseTimerCore"]),
    ]
)
