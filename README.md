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
- ✅ Swift XCTest suite: **99 passed, 0 failures** (Swift 6.1.2, WSL) — re-run on Mac to confirm.
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
- ⬜ **Schedule mode control (design pass):** segmented By Time / By Patient / Grid; last-used
  mode persists across relaunch (`AppSettings.scheduleModeRaw`, saved without a replan).
- ⬜ **Grid mode (design pass):** columns = active patients (room headers, abbreviated,
  horizontal scroll past ~4–6); rows = 1-hour blocks; each occurrence a compact chip at its
  time×room cell; status coloring matches Board (imminent occurrence tinted, later projections
  lighter/neutral); "now" row highlighted and auto-scrolled into view on open; tap a chip →
  task detail sheet. Confirm header truncation, horizontal + vertical scroll, and now-row anchor
  on a real device with 6+ rooms.
- ⬜ **Undo from the Log (feedback pass 4, item 4):** the most-recent undoable event per task
  shows Undo (swipe + inline button); Given/Done, Skip, Pause, Resume undoable — Snooze,
  Missed-ack, Undone are not. Confirm undo restores the task's prior state exactly (snapshot,
  not recomputed), fires the "Undone · next due …" haptic+toast, keeps the original event
  (struck through) and adds an `.undone` entry, and that Undo disappears once a newer event
  exists or the task is deleted. Events created before this update (nil snapshot) offer no Undo.
  `TaskEvent` snapshot fields + `.resumed`/`.undone` are migration-safe; Core-covered by
  `TaskActionTests`.
- ⬜ **Reminder task kind (feedback pass 4, item 3):** Add/Edit picker has Medication / Care
  task / Reminder; Reminder hides dosage/route/PRN-frequency and schedules like a care task.
  Patient detail groups Medications → Care tasks → Reminders (reminders last). Notifications
  read "Reminder · [name] · Rm X" (privacy ON: "Reminder due · Rm X"). Migration-safe raw value.
  Core-covered by `TaskKindTests`.
- ⬜ **Fixed-times dose disambiguation (feedback pass 4, item 2):** with a 0900/1700/2100 med
  where 0900 is overdue, tap Given near 1700 → a chooser appears ("9:00 AM (overdue) / 5:00 PM").
  Confirm: picking the overdue completes it and leaves 1700 scheduled; picking 1700 logs the
  0900 as `.missedAcknowledged` (a record exists — it never vanishes) and advances to 2100.
  Unambiguous Given (not overdue, or well before the next lead window) does NOT prompt. Verify
  the per-occurrence display (done struck+checked / pending highlighted / upcoming) on the
  By-Patient row, task sheet, and patient detail. Core-covered by `SchedulingEngineTests`.
- ⬜ **Delete task (feedback pass 4, item 1):** task sheet + Edit screen both offer a
  confirmed, destructive Delete; the confirm names task + room and states log history is
  removed (TaskEvent cascade). Confirm pending notifications are canceled (replan) and that
  deleting from the nested Edit screen also closes the task sheet (it checks the task still
  exists). Patient delete unchanged.
- ⬜ **Action acknowledgment (feedback micro-pass):** every successful Given/Skip/Snooze/
  Pause/Resume fires a haptic + a brief bottom toast ("Given · next due 5:07 PM", etc.) read
  from post-commit state; toast auto-dismisses ~2s, never covers the nav bar or action buttons,
  and is static under Reduce Motion. Confirm NO toast on a save failure (error banner shows
  instead), and that the string matches the recomputed next-due. **Haptics are device-only — the
  simulator won't vibrate, so absence of vibration in the simulator is expected, not a bug;
  verify haptics on a physical device.**
- ⬜ **Tap-to-act task detail (design pass, feedback item 1):** tapping any task row (Board,
  patient detail, Schedule By-Time/By-Patient rows, Grid chip) opens a sheet with large
  Given/Done · Snooze · Skip Once · Pause (confirmed) · Edit buttons; paused → Resume;
  needsRepair → Fix schedule. Confirm the swipe actions still work as shortcuts, that Edit
  presents cleanly over the detail sheet, and that each action dismisses and refreshes the row.
- ⬜ **Reminders promoted + per-task mute (design pass, feedback item 2):** Add/Edit form shows
  a "Reminders" section at the TOP (lead time, re-ping interval prefilled from Settings
  defaults, Notifications on/off); Advanced section is gone. `CareTask.notificationsEnabled` is
  **migration-safe (property-level default ON)** on an existing store. A muted task shows the
  `bell.slash` "Reminders off" indicator on Board / patient detail / Schedule / Grid and fires
  NO notifications (Core exclusion, mirrors paused — covered by `NotificationPlannerTests`);
  the task sheet shows the muted banner with one-tap re-enable. Confirm a muted task still
  appears everywhere (silence stays visible) and that unmuting replans and restores reminders.
- ⬜ **PRN last-given + frequency (design pass, feedback item 3):** a PRN task's Board row and
  task sheet show "Last given <time> · <N ago>" (live, re-renders each minute) plus the optional
  free-text Frequency note; the Add/Edit form shows the Frequency field only in PRN mode.
  `CareTask.prnFrequencyText` is **migration-safe (default empty)**. CONFIRM the frequency is
  purely display — nothing parses it, computes a next-allowed dose, validates, or alerts
  (§1.2 non-goal) — and that the elapsed time updates without reopening the view.
- ⬜ **Task form reorder (design pass, feedback item 4):** section order is Reminders → type →
  title → schedule (with consequence preview) → PRN frequency (PRN only) → last given → Details
  (dosage, route — med only, at the bottom) → color tag. Confirm the flow reads top-to-bottom
  and that Details/color-tag still save correctly from their new positions.
- ⬜ **Non-blocking reduction (feedback pass 3, item 2):** the "many tasks scheduled" reduction
  no longer sits in the top banner. Confirm it shows as a one-time-per-change dismissible alert
  (on app open / when it first becomes true) and a persistent tappable nav-bar indicator
  (`bell.badge`) on the Board that re-shows details; it must NOT obstruct controls. Verify a
  persistence-error banner still appears at top with full priority (not demoted).
- ⬜ **Overdue persists in Schedule (feedback pass 3, item 4):** an overdue (uncompleted,
  unskipped) occurrence stays visible in all three modes — a pinned red "Overdue" section at
  top of By-Time, red (non-dimmed) rows in By-Patient, red cells in Grid (above the now row,
  lookback clamped to 24h in Grid) — until given/skipped. Confirm it does NOT age out or render
  struck/past, and that marking it given/skipped removes it. Completed rendering unchanged.
- ⬜ **Graduated redaction (feedback pass 3, item 3):** with privacy mode ON, notifications
  read "[Medication|Care] due · Rm X" and digests "3 medications overdue · Rm 422" — kind
  included, name/dosage/detail still excluded. Confirm pre/snooze/due/digests all follow the
  format, mixed-kind digests say "tasks", privacy OFF is unchanged, and (Verify-on-Mac)
  **watch-side tap-through detail remains sample-data until the sync milestone** — the watch
  inherits the redacted phone notification automatically but its in-app detail is still stubbed.
- ⬜ **Adjustable first reminder (feedback pass 3, item 1):** interval schedule + last-given
  blank → the "First reminder" preview is an editable DatePicker defaulting to now+interval and
  live-updating with the interval until touched. Saving sets `nextDueAt` directly (synthetic
  first-due) with `lastCompletedAt` still nil — confirm NO administration event is created and
  that later Given events anchor the interval from the actual given time.
- ⬜ **Early Given fix (feedback pass 3, item 5):** mark a FIXED-time task Given before its
  scheduled time — confirm `nextDueAt` advances to the NEXT listed time (not the same one) and
  the old due's pre/due/taper notifications are canceled by the replan; the pending due alert
  must NOT fire. Interval early-Given re-anchors to actual time (unchanged). Within 5 min before
  due, rows read "Due now" with heavier weight (emphasis only). Covered by
  `SchedulingEngineTests` (early/late fixed completion + planner-reflects-new-due).
- ⬜ **Per-med color tag (design pass):** Add/Edit form swatch picker (8-color palette + None)
  persists on `CareTask.colorTagRaw`; migration-safe default "none" on an existing store.
  Renders as a leading channel — left-edge bar on Board / patient-detail / Schedule rows, dot on
  Grid chips — SEPARATE from status color; confirm a tag never alters the red/orange/green
  urgency reading and that untagged rows stay aligned with tagged ones.
- ⬜ **12-hour / device-locale time (design pass):** all times (Board due labels, Schedule
  rows, Grid row labels + chips, Log timestamps, form previews) follow the device clock setting
  via one `AppTime` formatter; verify switching iOS to 24h flips every surface and that sort
  order stays chronological.
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
- ⬜ **Watch & Reminders setup screen (nurse-support):** Settings → Apple Watch → "Watch &
  reminders setup". Confirm the live checks read correctly on real paired devices —
  notification permission + Time-Sensitive (from `UNUserNotificationCenter`), and **watch paired
  / NurseTimer-installed-on-watch** (from a read-only `WCSession` probe on the **iOS** side).
  Note: this iOS-side `WCSession.activate()` is the app's FIRST use of WatchConnectivity and is
  unverified; it is a read-only diagnostic (sends nothing) and is independent of the still-stubbed
  data-sync milestone — do not confuse the two. Verify the "Fix"/"Open Notification Settings"
  buttons deep-link to NurseTimer's notification settings; the watch-side steps (install app,
  Mirror my iPhone, Wrist Detection) are instruction-only because iOS exposes no URL to those
  screens and no API to toggle them.

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

### First-user design pass (grid / tags / time format)
- ⬜ **Item 3 (locale time format):** all app-facing times go through `AppTime` (device
  12h/24h). Confirm on a 12h-locale device: Schedule (By Time/By Patient/Grid), Log
  timestamps, Board due labels, and the Add/Edit first-reminder preview all show AM/PM;
  sort order stays chronological. (Core notification digest titles still use 24h `HH:mm` —
  left per the no-Core-change constraint; revisit if inconsistency matters.)

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
