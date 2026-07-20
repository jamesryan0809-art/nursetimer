# NurseTimer — Shared Scheduling Layer (Milestone 1)

Foundation-only scheduling engine + notification planner for NurseTimer, plus the
SwiftData persistence layer. **No UI in this milestone** (per build order §9 step 1).

This is a **Swift Package** (not an Xcode project) so the scheduling logic can be
built and unit-tested with `swift test` on any Swift toolchain — the iOS/watchOS
apps will be an Xcode project that consumes these library targets later.

## Targets

| Target | Depends on | Frameworks | Purpose |
|---|---|---|---|
| `NurseTimerCore` | — | **Foundation only** | Scheduling engine, notification planner, value types, `SchedulableTask` protocol |
| `NurseTimerModels` | `NurseTimerCore` | SwiftData (guarded) | `@Model` classes (Patient/CareTask/TaskEvent/AppSettings). Wrapped in `#if canImport(SwiftData)` so it is inert off Apple platforms |
| `NurseTimerCoreTests` | `NurseTimerCore` **only** | XCTest | Unit tests — never touches SwiftData |

The tested code has **zero** SwiftData / SwiftUI / UserNotifications / WatchConnectivity
imports. The engine operates on the `SchedulableTask` protocol; the SwiftData
`CareTask` conforms to it so the same engine drives real persisted data on-device.

## Running the tests

```bash
cd NurseTimer
swift test          # builds NurseTimerCore + tests only (not the SwiftData target)
```

On a Mac you can also open `Package.swift` in Xcode and run the test target, then
add the iOS/watchOS app targets in a workspace alongside this package.

## Test status

**Swift `swift test`: PASSING ✅ — 32 XCTest cases, 0 failures (Swift 6.1.2).**
**Logic cross-check: PASSING ✅ — 55/55 (Node).**

The Swift suite was compiled and run for real on **Swift 6.1.2** under **WSL2 /
Ubuntu 24.04** on this Windows machine:

```
Build complete! (11.83s)
Test Suite 'All tests' passed
   Executed 32 tests, with 0 failures (0 unexpected)
```

This confirms not just the algorithms but Swift-specific compilation:
`Codable`/`Sendable` synthesis on `ScheduleType`, `CareTask`'s `SchedulableTask`
conformance, and the guarded SwiftData `NurseTimerModels` target (which builds to
an empty module on Linux via `#if canImport(SwiftData)`).

### Reproduce (WSL, Ubuntu 24.04, Swift 6.1.2 already installed)

```powershell
wsl -d Ubuntu-24.04 -u root -e bash -lc "cd /mnt/d/Dev/NurseTimer && swift test"
```

Setup gotchas that were resolved on this machine (documented in case the toolchain
is reprovisioned):
- Swift 6.1.2 tarball to `/opt/swift`; needs `libncurses6` at runtime.
- clang needs a GCC installation (`apt install gcc g++`) or it reports the
  misleading `Executable "ld" doesn't exist`.
- SwiftPM compiles `Package.swift` with a sanitized PATH, so the system linker is
  symlinked into clang's InstalledDir: `/opt/swift/usr/bin/{ld,ld.gold,ld.bfd}`.

### Portable logic cross-check (any machine, no Swift needed)

```bash
node verification/logic-check.mjs      # -> RESULT: 55 passed, 0 failed
```

A faithful JS port of the engine + planner running the same scenarios — see
[verification/logic-check.mjs](verification/logic-check.mjs). Useful on machines
without a Swift toolchain (e.g. plain Windows).

### On macOS

Open `Package.swift` in Xcode and run the test target, or `swift test` from the CLI.
Everything is Foundation-only, so no Apple-specific setup is required for the tests.

## Verify on Mac — required UI behavior (Core is built; UI is a later milestone)

Behavior Core enforces that the iOS/watchOS UI must honor (do not build now; noted so
the UI can't diverge from Core):

- **Interval schedule picker (Add/Edit form, spec §6.2):** the "Every N" schedule
  mode must be an **hours+minutes wheel/stepper bounded to [5 minutes, 24 hours]**, so
  invalid intervals are *unenterable*. Core's `IntervalMinutes` failable init is the
  backstop, not the primary gate — the picker should never be able to submit a value
  Core would reject.

- **Schedule-repair UI (spec §6.2/§6.3):** a task whose schedule failed to decode is
  reported in `NotificationPlan.tasksNeedingRepair`. The app must:
  1. Pin it to the top of the Board with an unmissable error treatment.
  2. On detection, fire a local notification ("A task's schedule couldn't be loaded —
     tap to fix") using `NotificationPlanner.repairWarningIdentifier(taskID:)` (a
     deterministic per-task id) so re-detection **replaces** rather than duplicates the
     warning; remove that pending warning once the task leaves `tasksNeedingRepair`.
  3. Exclude the task from the Schedule tab's projections.
  4. On tap, open the Edit form with the **schedule field empty and required**, all
     other task data preserved. Saving calls `CareTask.repair(with:anchor:)`, which sets
     a fresh `nextDueAt` (the old, untrusted one is never reused).

## Spec ambiguities resolved (see report / code comments)

1. **SwiftPM layout instead of the spec's `Shared/` Xcode folder** — chosen so tests
   can actually run without Xcode. The Xcode app will consume these library products.
2. **Explicit-snooze modeling** — added `explicitSnoozeAt: Date?` to `SchedulableTask`
   so the planner can re-anchor the ping chain to the tap time (spec §4.2 step 4).
3. **Snooze-chain "auto-extension"** — expressed as a pure recompute: the chain window
   always slides forward past `now`, so a long-overdue task always yields a full buffer.
4. **Multiple fixed-times in the horizon** — per §4.3 ("at most 1 pre + 1 due per task")
   only the single `nextDueAt` is scheduled; the day-timeline/projection view (§6.2) is
   a separate later milestone.
