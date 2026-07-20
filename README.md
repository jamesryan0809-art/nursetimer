# NurseTimer

A local-only, privacy-first task and medication **reminder organizer** for nurses —
iPhone + Apple Watch. "A smart alarm clock organized by patient," not a clinical
system. It has **no networking, no accounts, no cloud, and no clinical
decision-support** (see [BUILD_SPEC.md](BUILD_SPEC.md) §1.2 hard non-goals).

The authoritative specification is [BUILD_SPEC.md](BUILD_SPEC.md).

## Repository layout

```
NurseTimer/
  Package.swift            # Swift package: the tested scheduling core
  Sources/
    NurseTimerCore/        # Foundation-only scheduling engine + NotificationPlanner
    NurseTimerModels/      # SwiftData @Model layer (guarded; inert off Apple platforms)
  Tests/NurseTimerCoreTests/
  project.yml              # (Milestone 1+) declarative Xcode project (XcodeGen)
  App/                     # (Milestone 2+) iOS app sources
  Watch/                   # (Milestone 4)  watchOS app sources
  Widget/                  # (Milestone 4)  WidgetKit extension
  archive/                 # historical material, not part of the build or verification
```

The scheduling logic lives in the **`NurseTimerCore`** Swift package and is unit-tested;
both app targets consume it. `NurseTimerModels` holds the SwiftData `@Model` classes,
wrapped in `#if canImport(SwiftData)` so the package still builds/tests on Linux.

## Verification — authoritative source

**The Swift XCTest suite is the single source of truth for scheduling correctness.**

```
swift test        # Swift 6.1.2 → Executed 58 tests, with 0 failures (0 unexpected)
```

Last run: **58 XCTest cases, 0 failures**, compiled and executed for real on
**Swift 6.1.2** under **WSL2 / Ubuntu 24.04**. The suite covers the baseline engine
plus the three sanctioned Core changes — interval validation, fail-loud schedule
decode (`.needsRepair`), and the hard 60-notification cap with room/window digest
grouping — and exercises Swift-specific compilation (`Codable`/`Sendable` synthesis,
`CareTask`'s `SchedulableTask` conformance, the guarded SwiftData target).

> A historical JavaScript port of the engine lives at
> [`archive/verification/logic-check.mjs`](archive/verification/logic-check.mjs).
> It is **retained only as a historical scratch artifact and is NOT an authoritative
> or independent verification of the Swift implementation** — do not treat its output
> as validating the Swift code. Run `swift test` for that.

### Reproduce the Swift tests (WSL, Ubuntu 24.04, Swift 6.1.2)

```powershell
wsl -d Ubuntu-24.04 -u root -e bash -lc "cd /mnt/d/Dev/NurseTimer && swift test"
```

Toolchain setup notes for a reprovisioned machine: Swift 6.1.2 tarball to `/opt/swift`
(needs `libncurses6`); clang needs `gcc`/`g++` present (else the misleading
`Executable "ld" doesn't exist`); SwiftPM sanitizes PATH when compiling `Package.swift`,
so symlink the linker into clang's InstalledDir (`/opt/swift/usr/bin/{ld,ld.gold,ld.bfd}`).

On macOS, just `swift test`, or open `Package.swift` in Xcode. Everything tested is
Foundation-only, so no Apple-specific setup is needed for the tests.

---

## Building the app (Mac workflow)

The Xcode project is **not** checked in — it is generated from the declarative
[`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen),
so there is no hand-edited `.xcodeproj` to drift or conflict. Generated targets:

| Target | Platform | Bundle id |
|---|---|---|
| `NurseTimer` | iOS 17+ | `com.nursetimer.app` |
| `NurseTimerWatch` | watchOS 10+ | `com.nursetimer.app.watch` |
| `NurseTimerWidget` | watchOS (WidgetKit ext.) | `com.nursetimer.app.watch.widget` |
| `NurseTimerAppTests` | iOS unit tests | `com.nursetimer.app.tests` |

Signing is Automatic with **no development team hardcoded** — each developer picks
their team locally. Info.plist and `.entitlements` templates are checked in under
`App/`, `Watch/`, `Widget/`.

**On a Mac:**
1. `git clone https://github.com/jamesryan0809-art/nursetimer.git && cd nursetimer`
2. Install XcodeGen: `brew install xcodegen` (pinned/tested: **2.43.0**; `mint install yonaskolb/XcodeGen@2.43.0` also works).
3. `make project` — generates `NurseTimer.xcodeproj` (checks for XcodeGen, prints an install hint if missing).
4. `open NurseTimer.xcodeproj`.
5. Select signing teams for each target (Signing & Capabilities).
6. Build/run `NurseTimer` (iPhone) and `NurseTimerWatch` (Watch) schemes.

No machine-specific signing data or Xcode user state is committed (`.gitignore`).

---

## Verify on Mac

**Status of this repository:** the `NurseTimerCore` package is compiled and tested
(above). Everything Apple-platform (the Xcode project, the iOS app, the watchOS app,
the widget) was **authored without a Mac and has NOT been compiled, launched, run in a
simulator, or run on a device.** Nothing below marked ⬜ has been verified. A Mac with
Xcode 16+ must complete each item.

### Project generation & build
- ⬜ Install XcodeGen (`brew install xcodegen`) — see [Makefile](Makefile) / `make project`.
- ⬜ `make project` generates `NurseTimer.xcodeproj` without errors.
- ⬜ Swift package dependencies (`NurseTimerCore`, `NurseTimerModels`) resolve.
- ⬜ iOS app target compiles.
- ⬜ watchOS app target compiles.
- ⬜ Widget extension compiles.
- ⬜ Signing teams selected locally; bundle IDs / entitlements / companion config valid.

### Core (already verified where noted)
- ✅ Swift XCTest suite: **58 passed, 0 failures** (Swift 6.1.2, WSL) — re-run on Mac to confirm.
- ⬜ SwiftData model-container initialization.
- ⬜ CRUD persistence survives relaunch.

### Behavior Core enforces that the UI must honor
- **Interval schedule picker (BUILD_SPEC §6.2):** the "Every N" mode must be an
  hours+minutes picker bounded to **[5 minutes, 24 hours]** so invalid intervals are
  *unenterable*; `IntervalMinutes` is the backstop, not the primary gate.
- **Schedule-repair (BUILD_SPEC §6.2/§6.3):** tasks in `NotificationPlan.tasksNeedingRepair`
  are pinned atop the Board with an unmissable treatment; the app fires a warning
  notification via `NotificationPlanner.repairWarningIdentifier(taskID:)` (deterministic,
  so re-detection replaces rather than duplicates; removed after repair); they are
  excluded from Schedule projections; tapping opens Edit with the schedule field empty
  and required, all other data preserved; saving calls `CareTask.repair(with:anchor:)`
  which establishes a fresh `nextDueAt` (the old, untrusted one is never reused).
- **"Many tasks scheduled" banner (BUILD_SPEC §4.3):** shown when
  `NotificationPlan.planWasCoalesced` or `.wasTrimmed` is true. A digest
  (`PlannedNotification.group`) routes on tap to the room-filtered Board
  (`group.room`) or the whole Board (cross-room, `room == nil`).

---

## Core design decisions (resolved ambiguities)

1. **SwiftPM layout** for the tested core (not the spec's `Shared/` Xcode folder), so
   tests run without Xcode. The Xcode app consumes the library products.
2. **Explicit-snooze modeling** — `explicitSnoozeAt: Date?` on `SchedulableTask` re-anchors
   the ping chain to the tap time (BUILD_SPEC §4.2 step 4).
3. **Snooze-chain auto-extension** — a pure recompute: the chain window slides past `now`,
   so a long-overdue task always yields a full buffer.
4. **Interval unit is minutes** with validated `[5m, 24h]` bounds; sub-hour cadences (q30min)
   are first-class.
5. **Fail-loud decode** — an undecodable schedule becomes `.needsRepair` (never silent PRN),
   quarantined per task.
6. **Hard 60-notification cap** with same-room→cross-room digest grouping guarantees the OS
   64-pending budget is never exceeded and no due time is unrepresented.
