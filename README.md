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

**App icon** ("stethoscope clock") is authored as vector at [Icon/AppIcon.svg](Icon/AppIcon.svg)
and rasterized into all three targets' `Assets.xcassets/AppIcon.appiconset` by
[Icon/generate-icons.sh](Icon/generate-icons.sh) (needs `rsvg-convert`, e.g.
`brew install librsvg`). Both the SVG and the generated PNGs are checked in; re-run the
script after editing the SVG.

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
- ⬜ App icon renders on iOS, Watch, and Widget (generated from `Icon/AppIcon.svg`).
- ⬜ **Watch embedding (post-build-day):** iOS install previously failed with "Could not get
  contents of Watch directory" (embed temporarily disabled). Re-enabled with `embed: true` +
  `codeSign: true` on iOS→Watch and Watch→Widget. Confirm on Mac that `make project` builds
  and installs the iOS app WITH the watch app in `.app/Watch/` and the widget in the watch
  app's `PlugIns/`; if XcodeGen's auto "Embed Watch Content" phase still misfires, inspect its
  destination (`$(CONTENTS_FOLDER_PATH)/Watch`).
- ⬜ **Info.plist keys (post-build-day):** `CFBundleExecutable = $(EXECUTABLE_NAME)` now present
  in App/Watch/Widget plists (installer required it). Confirm all three targets install.

### Core (already verified where noted)
- ✅ Swift XCTest suite: **58 passed, 0 failures** (Swift 6.1.2, WSL) — re-run on Mac to confirm.
- ⬜ SwiftData model-container initialization (`PersistenceController.makeContainer`).
- ⬜ Store file is `FileProtectionType.complete` at rest.
- ⬜ CRUD persistence (patients, tasks, events, settings) survives relaunch.

### iPhone app — Milestone 2 (authored, uncompiled)
- ⬜ Tabs Board / Schedule / Log render; system colors/typography; status-only color.
- ⬜ Patient list: add / edit / deactivate / reactivate / delete (with confirm).
- ⬜ Add/Edit Task form: type, title (+ generic quick-picks), dosage/route (med only),
  schedule modes (interval / fixed / once / PRN), last-given, lead/snooze overrides, pause.
- ⬜ Interval picker cannot submit 0 / negative / <5m / >24h.
- ⬜ Add/Edit form shows a live preview beneath the schedule controls: "First reminder"
  (interval, no last-given) / "Next due" (interval, last-given set) / "Next" (fixed times).
- ⬜ Given/Done writes an event, sets `lastCompletedAt`, recomputes `nextDueAt`
  (interval re-anchors to actual time; fixed advances; once auto-pauses; PRN stays nil),
  clears `explicitSnoozeAt`.
- ⬜ Snooze / Skip / Pause / Resume / Missed-ack behave per spec.
- ⬜ Board: overdue red, due-soon orange, Up Next strip, ordering, empty state, refresh
  after every action; repair tasks pinned on top and open the repair flow.
- ⬜ Schedule: projected interval + fixed occurrences; projections visually distinct from
  events; PRN/paused/completed-once/needsRepair excluded; nothing persisted as an event.
- ⬜ Log: reverse-chron events, per-patient filter, empty state (no export).
- ⬜ Notifications: authorization request; pre/due/snooze delivery; deterministic ids;
  full replan on change + foreground; obsolete requests removed/replaced; budget respected.
- ⬜ Notification actions Given / Snooze / Skip (Snooze primary) update persistence when
  used foregrounded, backgrounded, and terminated.
- ⬜ Repair-warning notification uses the deterministic per-task id (no duplicates) and is
  removed after repair.
- ⬜ Safety-relevant failures (scheduling / persistence / registration) surface as banners
  + os_log, never silently dropped.

### Lock / privacy / settings / disclaimer — Milestone 3 (authored, uncompiled)
- ⬜ App lock via LocalAuthentication: locks on launch (when enabled) and after the
  configured background timeout; Unlock prompts Face ID / Touch ID / passcode.
- ⬜ App-lock success, cancellation, failure, timeout all handled; failure keeps it locked
  and shows the reason; no custom auth, no biometric data stored.
- ⬜ Privacy mode (default ON) redacts lock-screen notifications to `Task due · Rm X` —
  no patient name, med name, dosage, route, or notes; full detail only in-app.
- ⬜ Turning privacy mode off restores descriptive notification content.
- ⬜ Settings: default lead (5–60) / snooze (1–15); privacy toggle; app-lock toggle +
  timeout; Clear shift log (confirm); Delete all data (confirm); Disclaimer & About.
- ⬜ Reminder-affecting settings changes trigger a replan; app-lock changes reconfigure the lock.
- ⬜ First-launch disclaimer (§1.2 exact wording) shown once and re-viewable in Settings.

### Watch app + widget — Milestone 4 (authored, uncompiled, sync stubbed)
- ⬜ Watch app builds and runs against `SyncTransport` (stub); **no** `WCSession`,
  no networking, no `WCSessionDelegate` / message / app-context / file transfer.
- ⬜ Now view: tasks sorted OVERDUE → DUE≤15m → upcoming; room/title/dosage/due; Crown
  scroll; accessibility labels; empty state; permanent "not synced · sample data" banner.
- ⬜ Task detail: Snooze (dominant/first), Given/Done, Skip (2nd-tap confirm + quick reason).
- ⬜ Custom notification interface renders content; actions come from the shared category.
- ⬜ Widget/complication: accessory families; **honest not-synced state** (no fabricated
  data); sample-data previews. Live complication data can't be validated until
  WatchConnectivity + shared state exist (a later milestone).
- ⬜ Watch UI is built on `NurseTimerCore` + `SyncTransport` only — no phone persistence coupling.

### Notification budget & taper (Core items 1–4 — verified in `swift test`; tune on Mac)
- ✅ Cap ≤ 60 and full task representation at any load (61+ overdue; mixed; global escape
  valve across rooms AND windows; combined saturation) — planner postcondition, tested.
- ✅ Tapered post-due chain (Phase 1 @S / Phase 2 @15m / Phase 3 @30m), pre-scheduled for
  future occurrences; 5-ping floor then whole-chain digest replacement; repair warnings
  planner-owned + digested; `planWasReduced` + counts.
- ⬜ **Tune on Mac:** pre-scheduled tapers raise baseline notification demand, so grouping
  can activate at realistic loads (~15–20 tasks per horizon). Evaluate the "reminders were
  reduced" banner on device so it stays informative rather than noisy — consider surfacing
  it only on coalescing (not every trim) if it fires too often.
- ⬜ Repair warning routing on device: individual tap → repair form; digest tap → Board
  repair section; obsolete delivered warnings removed on repair; no re-buzz on stable replans.

### App-layer audit fixes (items 6–12 — blind-authored, uncompiled)
- ⬜ **Item 6:** `CareTask.createdAt/updatedAt` added (was assigned but undeclared → compile
  error). Confirm the app compiles and the store migrates (new attributes have defaults).
- ⬜ **Item 7 (transactional commit):** save runs BEFORE replan; on success replan fires
  exactly once. Pending-Mac regression tests: (a) simulated `context.save()` failure →
  `context.rollback()` restores prior state and the scheduler is NOT invoked; (b) success →
  scheduler invoked once; (c) the "Couldn't save — action not recorded." error banner stays
  visible even when a reduction/coalescing condition also occurs (banner priority by rank);
  (d) fetch failures surface a banner + os_log rather than masquerading as valid-empty data.
- ⬜ **Item 8 (sidecar protection):** the store lives in a dedicated `NurseTimer/` directory
  whose protection class is set before the store is created, so `-wal`/`-shm` inherit it;
  reapplied after container init and via `reapplyProtection()`. Verify on Mac: inspect actual
  protection attributes of the store, `-wal`, and `-shm` after real writes, unlocked AND
  locked; decide `.complete` vs `.completeUnlessOpen` (one constant `protectionLevel`); confirm
  lock-screen notification actions record safely or fail visibly without corrupting state.
- ⬜ **Item 9 (last-given coherence):** submitting Last Given updates `lastCompletedAt` even
  when the schedule changed; clearing it nils `lastCompletedAt`; `nextDueAt` recomputes via
  `firstDue`; all commit atomically. Pending-Mac tests: change Last Given; clear it; change
  it together with the schedule; and rollback of schedule/anchor/lastCompletedAt/nextDueAt
  after a simulated save failure.
- ⬜ **Item 10 (banner on every reduction):** `replan()` shows the §4.3 banner on ANY
  reduction (`plan.planWasReduced`), not only coalescing; the message distinguishes trimming
  from grouping; never replaces an active error banner. Pending-Mac test: pre-alert trimming
  or chain shortening WITHOUT grouping still produces the banner.
- ⬜ **Item 11 (hour-bucket identity):** Schedule sections use the hour-bucket `Date` as
  `ForEach` identity (label is display-only); `ScheduleOccurrence.id` is task+time derived,
  not a fresh UUID. Pending-Mac test: equal clock-hour buckets on consecutive dates render
  as distinct sections.
- ⬜ **Item 12 (By Time / By Patient toggle):** Schedule tab has a segmented toggle. By Time
  keeps the hour-bucket view (item 11 identity); By Patient groups the day's projections per
  patient ("Rm 412 · Metoprolol: 0900 · 1700 · 0100") keyed by patientID/taskID. Both share the
  exclusions (PRN/paused/needs-repair/completed-once), keep projection styling, and never
  persist projections as events. Pending-Mac tests: grouping, ordering, exclusions,
  midnight-crossing occurrences, identity stability.

### Post-build-day navigation (items 2–4)
- ⬜ **Item 2:** Board patient cards tap → patient detail; task-row swipes still act on tasks;
  top-left Patients button retired; Add Patient visible in the toolbar + inline when the list
  is short; empty state "No patients yet · Add Patient"; inactive patients reachable via a
  footer link (no dead end).
- ⬜ **Item 3:** Patient detail hub — always-visible Add Medication / Add Task (preset kind,
  one tap to the form); the patient's day laid out chronologically with inline projected times
  (reuses `PatientScheduleBuilder` / By-Patient rendering — no duplicated projection logic);
  Given/Done, Snooze, Skip Once, Pause, Edit on each row; Edit/Deactivate/Delete patient.
- ⬜ **Item 4 (nav coherence):** notification tap → filtered Board; repair-warning tap →
  repair form; repair digest → Board (repair section); due/overdue digest → filtered Board;
  every sheet/push backs out to the Board with no dead ends. `PatientListView` repurposed to
  inactive-only so active-patient detail is reached only via the Board (no duplicate route).
  Nav map documented in BUILD_SPEC §6.1. Verify the graph end-to-end on device.

### Cross-cutting
- ⬜ Dynamic Type scales legibly (rows readable at arm's length).
- ⬜ Light and dark appearance both correct (status colors only).
- ⬜ iPhone simulator/device run; Watch simulator/device run.
- ⬜ Complication/widget timelines render across accessory families.
- ⬜ Signing, entitlements (Time Sensitive), bundle-id nesting, and companion-app config valid.
- ⬜ No network traffic generated anywhere (spec §10 / §1.2) — verify with a proxy/Network report.

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
