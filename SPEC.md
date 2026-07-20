# NurseTimer — Build Specification

A local-only, privacy-first task and medication reminder app for nurses. iPhone + Apple Watch. Think "smart alarm clock organized by patient," not a clinical system.

> **Change log (Core-only, Milestone 1).** Sections amended after v1.0 are marked with the change tag that introduced them, e.g. **[interval-validation]**, **[fail-loud-decode]**.

---

## 1. Product Definition

### 1.1 What it is
An organizational reminder tool a nurse programs manually at the start of each shift. It tracks patients by room number (optional first name), holds medication and generic care tasks per patient, and fires escalating reminders to the Apple Watch and iPhone ahead of each due time.

### 1.2 What it is NOT (hard non-goals — do not build)
- No drug database, autocomplete of drug names, or dose validation
- No drug interaction, allergy, or contraindication checking
- No dosage calculation of any kind
- No EHR/eMAR integration
- No cloud sync, accounts, or server backend in v1
- No analytics/telemetry that leaves the device
- The app never suggests, warns about, or validates clinical content. All content is free-text entered by the nurse. Reminders fire purely on nurse-entered schedules.

First-launch disclaimer (must be acknowledged once): "This app is a personal organizational tool. It is not a medical device and does not replace your facility's medication administration record or clinical judgment."

### 1.3 Target platforms
- iOS 17+ (iPhone), SwiftUI, SwiftData
- watchOS 10+ companion app (paired, not standalone-installable; requires iPhone app)

---

## 2. Architecture

### 2.1 Stack
- **UI:** SwiftUI on both platforms
- **Persistence:** SwiftData, local device only. No CloudKit. `FileProtectionType.complete`.
- **Phone↔Watch sync:** WatchConnectivity (`WCSession`). Phone is source of truth.
- **Notifications:** `UNUserNotificationCenter` local notifications, scheduled on both phone and watch.

### 2.2 Project structure
Scheduling logic (next-due, snooze chains, notification identifiers, budget) lives in **Shared** (the `NurseTimerCore` Swift package) and is unit-tested. Both app targets consume it.

---

## 3. Data Model (SwiftData)

### 3.1 Patient
Fields: id (UUID), roomNumber (String, required), firstName (String?), notes (String?), isActive (Bool), createdAt/updatedAt (Date), tasks ([CareTask], cascade delete). Display name = `"Rm " + roomNumber + (firstName != nil ? " · " + firstName : "")`.

### 3.2 CareTask (single model, two kinds) **[interval-validation]**
Fields: id, kind (`.medication`/`.generic`), title, dosage (String?, med only), route (String?, med only), scheduleType (enum, see below), lastCompletedAt (Date?), nextDueAt (Date?), leadTimeMinutes (Int?), snoozeMinutes (Int?), isPaused (Bool), history ([TaskEvent]).

`scheduleType` cases:
- **`.interval(IntervalMinutes)` [interval-validation]** — every N **minutes** (stored as minutes; supports both hourly q4h and sub-hour q30min). Anchored to actual administration time. `IntervalMinutes` is only constructible for values in **[5 minutes, 24 hours]** — invalid intervals are unrepresentable in the type (§4.1).
- `.fixedTimes([DateComponents])` — set wall-clock times (0900/2100).
- `.once(Date)` — one-shot; auto-pauses after completion.
- `.prn` — as-needed; never auto-schedules.
- **`.needsRepair(rawPayload: Data)` [fail-loud-decode]** — a schedule that could not be decoded from the store, carrying the raw undecodable bytes for diagnostics. A task in this state schedules **no** reminders and is surfaced for manual repair (§4.1, §6.2/§6.3). This case exists so decode failure is *explicit*, never a silent coercion to PRN.

Built-in generic task quick-picks (prefill title only): Turn/reposition, Vitals, I&O, Blood glucose, Ambulate, Custom.

### 3.3 TaskEvent (shift log)
Fields: id, taskID, action (`.given`/`.done`/`.skipped`/`.snoozed`/`.missedAcknowledged`), timestamp, note (String?).

### 3.4 AppSettings (single row)
defaultLeadTimeMinutes = 15, defaultSnoozeMinutes = 3, privacyModeNotifications = true, appLockEnabled = true, appLockTimeoutMinutes = 5, shiftStartHour (Int?).

---

## 4. Scheduling Logic (Shared, unit-tested)

### 4.1 Next-due computation **[interval-validation]**
- `.interval(IntervalMinutes)`: when marked Given at time T → `nextDueAt = T + interval`. Anchored to **actual administration time**, not the previous scheduled time. The interval is validated on construction and on decode: values `< 5 min` or `> 24 h`, and non-positive values, are rejected (unrepresentable). Sub-hour intervals (e.g. q30min) are legitimate for generic care tasks.
- `.fixedTimes`: next occurrence of any listed time after now, correctly crossing midnight.
- `.once`: fires once; after completion, task auto-pauses.
- `.prn`: no automatic scheduling.
- **`.needsRepair` [fail-loud-decode]: produces no next-due and no reminders.** It is rejected **before** `nextDueAt` is examined; any pre-existing `nextDueAt` is untrusted and must not produce notifications or projections. **Schedule decoding never silently falls back to a valid-looking schedule** — an undecodable payload (corrupt JSON, unknown case, or an out-of-range interval that fails validation) becomes `.needsRepair` carrying the raw bytes, quarantined per-task so one bad task never blocks loading the rest of the store, and reported to the app via `tasksNeedingRepair: [TaskID]` (§4.3).

### 4.2 Reminder timeline per due time
For a task due at D with lead L and snooze interval S:
1. Pre-alert at `D − L`.
2. Due alert at `D`.
3. If not acted on: re-ping every S minutes — a chain of 20 pre-computed snooze notifications (D+S … D+20S), the whole chain cancelled by acting on the task, extended on foreground/action when fewer than 5 remain.
4. Explicit Snooze: cancels current chain, schedules a new chain starting at `now + S`.

### 4.3 Notification budget management
The 64-pending-notification OS cap is the binding constraint. Only the next 12 hours of due times are scheduled. Deterministic identifiers: `"{taskID}|{dueISO8601}|{slot}"` where slot ∈ `pre`, `due`, `snooze-N`. Per task at most: 1 pre-alert + 1 due alert + the active snooze chain (overdue only). The planner recomputes the full pending set on every data change / foreground (cancel-all then reschedule). If the plan exceeds ~55 notifications, the furthest-out pre-alerts are dropped first and a subtle banner is surfaced. Due alerts are never dropped.

### 4.4 Interruption level
`.timeSensitive`. No Critical Alerts in v1 (v2 candidate).

---

## 5. Apple Watch App
(unchanged from v1.0 — watch target not started until Core is green)

---

## 6. iPhone App

### 6.1 Navigation
Bottom tab bar: **Board**, **Schedule**, **Log**. Settings via gear; Shift Review from the Board.

### 6.2 Screens (Add/Edit Task form) **[interval-validation] [fail-loud-decode]**
- **Board tab:** patients as cards sorted by soonest due; global "Up Next" strip; overdue pinned red at top. **Tasks needing repair (`.needsRepair`) are pinned above everything with an unmissable error treatment [fail-loud-decode]** (see §6.3).
- **Schedule tab:** day timeline of scheduled + projected occurrences, cluster highlighting, By-Time/By-Patient toggle. **`.needsRepair` tasks are excluded from projections [fail-loud-decode]** — they have no trustworthy schedule.
- **Patient detail / task list.**
- **Add/Edit Task form:**
  - kind toggle; title (free text); dosage/route (med only).
  - **Schedule picker [interval-validation]:** *Every N hours + minutes* is an **hours+minutes wheel/stepper bounded to [5 minutes, 24 hours]**, so out-of-range/nonsense intervals are **unenterable** — Core's `IntervalMinutes` validation is the backstop, not the primary gate. Other modes: At set times / Once / PRN.
  - last-given time (optional; if set for interval meds, computes `nextDueAt` immediately).
  - per-task lead & snooze overrides under "Advanced".
  - **Repair flow [fail-loud-decode]:** when opened for a `.needsRepair` task, the schedule field is **empty and required**; **all other task data is preserved**. Saving a repaired schedule clears the repair state and establishes a **new** valid `nextDueAt` from the selected schedule + anchor time — the old (untrusted) `nextDueAt` is **not** reused.
- **Shift Review**, **Log tab**, **Settings** — as v1.0.

### 6.3 Privacy & security + repair surfacing **[fail-loud-decode]**
App lock (Face ID / passcode), notification redaction in privacy mode, local-only data — as v1.0.

- **Schedule-repair surfacing [fail-loud-decode]:** on detecting a `.needsRepair` task, the app fires a local notification ("A task's schedule couldn't be loaded — tap to fix") using a **deterministic per-task identifier** (`NotificationPlanner.repairWarningIdentifier(taskID:)`) so re-detection **replaces** the existing warning rather than duplicating it. Once the task is repaired it drops out of `tasksNeedingRepair` and its pending warning is removed. Tapping the warning (or the pinned Board row) opens the Edit form per §6.2's repair flow.

### 6.4 Shift Review flow / 6.5 Overdue & missed handling — as v1.0.

---

## 7. Design Principles
Minimal, modern, fast. System-native SwiftUI, SF Symbols, system fonts. Color is information (red overdue / orange due-soon / green done). 44pt tap targets; two-tap common actions; no onboarding beyond the one-time disclaimer.

---

## 8–11
Edge cases, design, build order (§9), acceptance criteria (§10), and v2 parking lot (§11) as v1.0. Build-order gate stands: the watchOS target is not scaffolded until the Shared engine's unit tests are green.
