# NurseTimer — Build Specification

A local-only, privacy-first task and medication reminder app for nurses. iPhone + Apple Watch. Think "smart alarm clock organized by patient," not a clinical system.

> **Change log (Core-only, Milestone 1).** Sections amended after v1.0 are marked with the change tag that introduced them, e.g. **[interval-validation]**, **[fail-loud-decode]**, **[hard-cap-grouping]**.

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

### 3.3 TaskEvent (shift log) **[skip-redesign]**
Fields: id, taskID, action (`.given`/`.done`/`.skipped`/`.snoozed`/`.missedAcknowledged`/`.paused`), timestamp, note (String?).

`note` records **no clinical reasons** — the chart is the system of record for why. For `.skipped` and `.paused` the note is the **source only**: `"in app"`, `"via notification"`, or `"via watch"`. (`.paused` was added for the in-app Pause action.)

### 3.4 AppSettings (single row)
defaultLeadTimeMinutes = 15, defaultSnoozeMinutes = 3, privacyModeNotifications = true, appLockEnabled = true, appLockTimeoutMinutes = 5, shiftStartHour (Int?).

---

## 4. Scheduling Logic (Shared, unit-tested)

### 4.1 Next-due computation **[interval-validation]**
- `.interval(IntervalMinutes)`: when marked Given at time T → `nextDueAt = T + interval`. Anchored to **actual administration time**, not the previous scheduled time. The interval is validated on construction and on decode: values `< 5 min` or `> 24 h`, and non-positive values, are rejected (unrepresentable). Sub-hour intervals (e.g. q30min) are legitimate for generic care tasks.
- `.fixedTimes`: next occurrence of any listed time after now, correctly crossing midnight. **On completion the schedule advances past the occurrence being completed** — the next listed time strictly after `max(completedAt, occurrenceDue)` — so an **early** Given (given before the scheduled time) moves to the NEXT listed time rather than re-resolving to the same one and re-firing its due alert (feedback item 5).
- **Multi-time fixed doses — which occurrence did Given complete? (feedback pass 4, item 2).** A fixed-times task keeps a single `nextDueAt` pointer, so by default Given completes the current next-due occurrence (item 2a — unchanged). **Ambiguity (item 2b):** when the current occurrence is **overdue** AND the completion time has reached the **lead window of the next listed time** (`completedAt ≥ nextTime − lead`), the app cannot tell whether the nurse is giving the overdue dose late or the next dose early — so it **asks** with a chooser ("Which dose was given? 9:00 AM (overdue) / 5:00 PM"), never guessing (`SchedulingEngine.fixedGivenCandidates`, tested). Choosing the overdue occurrence resolves it and leaves the later one scheduled; choosing the later occurrence records the leapt-over overdue dose as **`.missedAcknowledged` (logged)** — an unresolved dose must **never disappear without a record** — then completes the later one and advances past it. **Display (item 2c):** everywhere a task's day of times renders (By-Patient row, task sheet, patient detail), each occurrence shows its state — resolved doses struck + checked, the pending one highlighted (red when overdue) — derived live from the listed times + pointer, nothing per-occurrence persisted.
- **Given/Done is valid at ANY time (feedback item 5):** early, on-time, or late. It always records the actual completion time, completes the current upcoming occurrence, advances the schedule per the anchoring rules above (interval → `completedAt + interval`; fixed → next time after the occurrence), and the follow-on replan cancels that occurrence's pending pre/due/taper notifications (cancel-all-then-reschedule from the new `nextDueAt`). Within 5 minutes before due a row reads "Due now" with added prominence — **presentation emphasis only, never a validity gate**.
- `.once`: fires once; after completion, task auto-pauses.
- `.prn`: no automatic scheduling.
- **Muted tasks (design pass, feedback item 2): `notificationsEnabled == false` excludes a task from planning exactly like `isPaused` does** — same guard in `NotificationPlanner.plan`. A muted task keeps its schedule and stays visible in the app (Board / Schedule / Grid, with a muted indicator); it simply fires no reminders. This is the only Core change for the mute feature (guard + one test); it is not a scheduling-math change. Note: mirroring paused semantics exactly, a muted task that is *also* `.needsRepair` still surfaces its repair warning (the repair check precedes both the paused and muted guards), because a schedule that can't load is a data-integrity problem to fix regardless of muting.
- **`.needsRepair` [fail-loud-decode]: produces no next-due and no reminders.** It is rejected **before** `nextDueAt` is examined; any pre-existing `nextDueAt` is untrusted and must not produce notifications or projections. **Schedule decoding never silently falls back to a valid-looking schedule** — an undecodable payload (corrupt JSON, unknown case, or an out-of-range interval that fails validation) becomes `.needsRepair` carrying the raw bytes, quarantined per-task so one bad task never blocks loading the rest of the store, and reported to the app via `tasksNeedingRepair: [TaskID]` (§4.3).

### 4.2 Reminder timeline per due time **[taper]**
For a task due at `D` with lead `L` and snooze interval `S`, the **post-due tapered chain**
is a pure function of `(anchor, S, now, horizon)` with no stored phase state:
1. Pre-alert at `D − L`.
2. Due alert at `D`.
3. **Tapered re-pings (item 3):**
   - **Phase 1** — `fastCount` (5) pings at `S`: `D+S … D+5S`.
   - **Phase 2** — `midCount` (5) pings at `midIntervalMinutes` (15).
   - **Phase 3** — `slowIntervalMinutes` (30) spacing to the horizon (the "indefinite" slow phase).
   Indices are 1-based from the anchor (stable across re-plans). Acting on the task cancels the whole chain (re-plan drops it).
4. **Explicit Snooze** re-anchors the **entire taper at Phase 1 from the tap time** (`tap+S, tap+2S, …`).
5. **Pre-scheduling (item 3):** every upcoming occurrence in the 12h horizon is planned *now* WITH its post-due taper, so the app never needs to foreground after the due alert for re-pings to begin. Budget reduction may subsequently shorten (tail-first) or digest-replace that chain.

### 4.3 Notification budget management **[hard-cap-grouping] [representation] [taper] [repair-warnings]**
The OS caps pending local notifications at 64. NurseTimer enforces a **hard invariant: the emitted plan NEVER exceeds `maxPlanNotifications` (60)**, and — as a **tested planner postcondition** — while any task is due or overdue the plan is **non-empty** and represents **every** such task by at least one notification (individually or as a digest member). The reduce-to-zero backstop was **removed**. Invalid settings are clamped to safe defaults at plan entry and reported via `settingsAdjusted` (never crash, never empty).

Only the next 12 hours are scheduled; the planner recomputes the whole set on every change / foreground (cancel-all then reschedule). Identifiers: individual `"{taskID}|{dueISO}|{slot}"`; due digests `group|{room}|{windowISO}` / `group|*|{windowISO}` / `group|*|global`; overdue digests `overdue|{room|*}|{windowISO}` / `overdue|*|global`; repair warning `repair|{taskID}`; repair digest `repairs|{count}`. Member task IDs are carried at every tier.

**Repair warnings are OWNED by the planner (item 2):** planned **FIRST** against the cap; task notifications fit the remainder. Exempt from trimming but coalesced into ONE repair digest (`"N tasks need schedule repair — tap to fix"`) above `repairDigestThreshold` (5) or when they'd starve the tasks. Immediate trigger. Routing: an individual warning tap → that task's repair form; a repair digest tap → the Board's repair section. The scheduler removes obsolete delivered repair notifications when membership changes (repaired / newly broken) and doesn't re-buzz stable ones.

**Reduction order (redesigned — feedback pass 5, item 2). Pre-alerts are workflow-critical (they are when a nurse pulls meds), so they are NOT the most expendable class — they give way LAST, after taper tails but before the grouping escape valves. Each step runs only as far as needed:**
- **a. Shorten chains uniformly from the tail** (phase-3 slow pings, then phase-2) down to the **five-ping floor** — **before touching any pre-alert**.
- **b. Trim default-lead pre-alerts**, furthest-due first.
- **c. Trim explicit-lead pre-alerts** (a per-task lead override is the nurse's stated intent) — only **after** default-lead ones, and only **before** the escape valves.
- **d. Coalesce upcoming tasks** — escalating *same room+window* → *cross-room per window* → **global** (`"N tasks due — open app"`).
- **e. Coalesce overdue tasks** — same ladder: `"3 overdue · Rm 422"` → `"6 overdue · 3 rooms"` → **global** `"N tasks overdue — open app"`. **Each ungrouped overdue task keeps ≥5 pings; when that can't fit, its whole chain is replaced by digest membership carrying its task ID.**

Due alerts and the five-ping chain floor are **never** touched. A realistic 8-task shift (with pre-scheduled tapers) now **retains all pre-alerts** — a permanent regression test. The global tier guarantees representation (worst case: one digest per category ≤ cap). Plan flags: `planWasReduced: Bool` + `ReductionSummary { preAlertsTrimmed, chainDepthReduced, digestsFormed, taperPingsTrimmed, preAlertsProtectedKept }`, plus `planWasCoalesced`/`coalescedGroupCount`, `wasTrimmed`, `settingsAdjusted`, and `tasksNeedingRepair: [TaskID]`.

**Reduction surfacing is non-blocking (design pass, feedback item 2).** Reminder reduction is informational, not an error, so it no longer occupies the top-of-screen banner (which obstructed controls). Instead it drives: (a) a **one-time-per-change**, dismissible alert on app open and whenever the reduction condition first becomes true or its details change; and (b) a small **persistent, tappable nav-bar indicator** on the Board while reduction is active, which re-shows the details on demand. Every task remains on the board — only ping timing is adjusted. **Persistence-error banners are unaffected and keep their existing priority** — they are never demoted by this change.

### 4.4 Interruption level
`.timeSensitive`. No Critical Alerts in v1 (v2 candidate).

---

## 5. Apple Watch App

### 5.1 Views **[skip-redesign]**
- **Now view:** tasks sorted by urgency (OVERDUE → DUE≤15m → upcoming).
- **Task detail:** actions are **Snooze**, **Given/Done**, **Skip Once**, and **Pause**.
  - **Skip Once** advances the schedule one occurrence and records a `.skipped` event; it executes immediately on tap. **No reason picker.**
  - **Pause** holds the task (no reminders until resumed), records a `.paused` event, and is **visually subordinate/destructive, physically separated from Skip Once, and always confirmed** (the confirmation names the task and room).

### 5.2 Notification presentation **[skip-redesign]**
Custom notification interface with actions **Snooze** (dominant / first), **Given/Done**, and **Skip Once**. **Pause is never offered from a notification.**

---

## 6. iPhone App

### 6.1 Navigation **[nav]**
Bottom tab bar: **Board**, **Schedule**, **Log**. Settings via the gear on the Board.
(Shift Review is deferred to a later milestone.)

**Navigation map (single entry point per screen; every push/sheet backs out to the Board):**
- **Board** — the primary patient entry point.
  - Tap a patient card → **Patient Detail** (push).
  - Task-row swipe → lifecycle (Given/Done · Snooze · Skip Once · Pause · Edit). Edit → **Task form** (sheet).
  - Tap a repair row → **Task form in repair mode** (sheet).
  - Toolbar: **Add Patient** (sheet) · **Settings** (sheet) · **Show all** (clears a room filter).
  - Footer / empty-state link: **Inactive Patients** (push) → reactivate / delete.
- **Patient Detail** (working hub).
  - **Add Medication** / **Add Task** → **Task form** (sheet), kind preset.
  - Task rows: same lifecycle + Edit as the Board.
  - Menu: **Edit Patient** (sheet) · **Deactivate** (pops to Board) · **Delete** (confirm, pops to Board).
- **Notification routing** (§5.2 / §6.3):
  - Task notification **tap** → Board filtered to the task's room.
  - Task **action** (Given / Snooze / Skip Once) → performed in place, no navigation.
  - **Repair warning** tap → that task's Task form (repair mode).
  - **Repair digest** tap → Board (the repair section is pinned at the top).
  - **Due / overdue digest** tap → Board filtered to the room (or the whole Board for cross-room / global digests).

No dead ends: every sheet dismisses to its presenter; every push pops to the Board. The
Task form is presented from exactly one place (a store-level request), so there are no
duplicate routes to it with divergent state; active-patient detail is reached only via the
Board (the Inactive list never routes to it).

### 6.2 Screens (Add/Edit Task form) **[interval-validation] [fail-loud-decode] [skip-redesign]**
- **Board tab:** patients as cards sorted by soonest due; global "Up Next" strip; overdue pinned red at top. **Tasks needing repair (`.needsRepair`) are pinned above everything with an unmissable error treatment [fail-loud-decode]** (see §6.3). **Board sort (design pass, feedback pass 4 item 6):** Settings → Board → Sort by **Next due** (default) / **Room ↑** / **Room ↓** (`AppSettings.boardSortRaw`, migration-safe). Room sort uses natural, numeric-aware comparison (`localizedStandardCompare`: 412A < 412B < 1201). **Overdue pinning is preserved** for every mode — attention (overdue / needs-repair) patients stay atop the active sort (under Next due they float up naturally; under Room sort they're explicitly pinned first).
- **Schedule tab:** day timeline of scheduled + projected occurrences, cluster highlighting, **By-Time / By-Patient / Grid** mode control (last-used mode persists in `AppSettings.scheduleModeRaw`, a UI preference saved without a replan). **Grid mode** is the paper-MAR view: columns are active patients (room-number headers, abbreviated, horizontal scroll past ~4–6 on iPhone), rows are 1-hour time blocks, each occurrence a compact chip at its time×room cell; status coloring matches the Board (the imminent occurrence carries the task's status color, later projections read lighter/neutral); the "now" row is highlighted and auto-scrolled into view; a chip taps through to patient detail. **`.needsRepair` tasks are excluded from projections [fail-loud-decode]** — they have no trustworthy schedule. Same exclusions across all three modes. **Overdue occurrences persist (design pass, feedback item 4):** an unresolved overdue occurrence (the task's `nextDueAt` is in the past, not yet given/skipped) stays visible in EVERY mode until resolved — pinned in a distinct red "Overdue" section at the top of By-Time, marked red (not dimmed/struck) in By-Patient rows and Grid cells. Overdue occurrences never age out of the view. Completed occurrences keep their existing rendering; the overdue marking is derived live from `nextDueAt`, nothing is persisted.
- **Patient detail / task list.** Row actions: Given/Done, Snooze, Edit, and **Skip Once** / **Pause [skip-redesign]**. Skip Once advances one occurrence (records `.skipped`) and executes immediately. Pause holds the task (records `.paused`), cancels its pending notifications, and is **always confirmed** (naming the task + room). Paused tasks stay on the Board in a paused state with a **Resume** action. No skip reason is collected anywhere.
- **Action acknowledgment (design pass, feedback micro-pass).** Every successful task action gets an immediate, unmissable confirmation: a standard `UIFeedbackGenerator` haptic (Given/Done → success, Skip → warning, Snooze → light, Pause/Resume → haptic) plus a brief, non-blocking bottom toast that auto-dismisses (~2s) and never obstructs the top nav bar or in-sheet action buttons. The message is built from **post-commit persisted state** — the actual recomputed `nextDueAt` ("Given · next due 5:07 PM", "Skipped · next due 9:00 PM", "Snoozed · re-ping 3:12 PM", "Paused — no reminders", "Resumed · next due …"; once/PRN show room, PRN adds "last given updated"). Success feedback fires **only on a persisted commit**; on save failure the existing error banner shows and no toast appears. Respects Reduce Motion (static toast, no slide/fade). Applies on every acting surface (Board tap-sheet + swipe, patient detail, Schedule/Grid via the task sheet). Watch actions keep their existing local behavior; watch notification actions still execute phone-side. Tapping ANY task row — Board, patient detail, Schedule list, or a Grid chip — opens a task-detail sheet with large explicit buttons: Given/Done, Snooze, Skip Once, Pause (confirmation preserved), Edit. This mirrors the watch task-detail layout and fixes discoverability: swipe actions remain as shortcuts but are no longer the only path to completing/skipping/pausing. A paused task offers Resume; a `.needsRepair` task offers Fix schedule. Patient-card taps still open the patient (nav pass); task rows within open the task sheet. **Delete (design pass, feedback pass 4 item 1):** the task sheet and the Edit screen both offer a destructive Delete beneath Pause, always confirmed (naming task + room) and stating that the task's **log history is removed too** (TaskEvent cascade) and its pending reminders canceled (via replan). Delete is **not** undoable (see item 4). Patient delete is unchanged.
- **Add/Edit Task form:**
  - **Section order (design pass, feedback item 4):** Reminders (item 2) → name (type + title) → schedule (with the existing consequence preview) → PRN frequency (when PRN) → last given → **Details** (dosage, route — med only, moved to the bottom) → color tag.
  - kind toggle; title (free text); dosage/route (med only), under "Details" at the bottom.
  - **Schedule picker [interval-validation]:** *Every N hours + minutes* is an **hours+minutes wheel/stepper bounded to [5 minutes, 24 hours]**, so out-of-range/nonsense intervals are **unenterable** — Core's `IntervalMinutes` validation is the backstop, not the primary gate. Other modes: At set times / Once / PRN.
  - **Adjustable first reminder (design pass, feedback item 1):** when the schedule is interval and last-given is blank, the "First reminder" preview becomes an **editable time control** defaulting to the computed `now + interval`, so the nurse can set when the first due should be. Under the hood this sets the initial `nextDueAt` directly (a synthetic first-due) — it does **NOT** fabricate a `lastCompletedAt`; no administration event is invented. Subsequent dosing follows normal interval math from actual given times. The default continues to live-update with the interval until the nurse manually adjusts it.
  - **Last Given time (optional) [last-given-coherence]:** the toggle's value is authoritative — a submitted value updates `lastCompletedAt` **regardless of whether the schedule changed**; clearing the toggle sets `lastCompletedAt = nil`. Whenever the schedule or the anchor changes, `nextDueAt` recomputes via the **same Core path used at creation** (`SchedulingEngine.firstDue`, anchored to `lastGiven ?? now`). Schedule, anchor, `lastCompletedAt`, and `nextDueAt` commit **atomically**.
  - **Color tag (design pass):** an optional swatch picker (8-color palette + None) that sets `CareTask.colorTagRaw`. Display-only label channel (spec §7) — not a scheduling input.
  - **PRN last-given + frequency (design pass, feedback item 3).** When the schedule is PRN, the task card/row and the task sheet display `lastCompletedAt` prominently with **live** elapsed time ("Last given 1:07 PM · 2h ago"), plus an optional free-text **Frequency** field (`CareTask.prnFrequencyText`, e.g. "every 4–6 hrs as needed"). **HARD CONSTRAINT [non-goal]:** the frequency is **display-only** — the app never parses it, computes next-allowed times, validates against it, or alerts from it. Doing any of those would be dose-timing calculation (§1.2, ABSOLUTE non-goal). The nurse reads last-given and the ordered frequency and decides. The live "N ago" text is plain elapsed-time rendering, not a dose calculation.
  - **Reminders — promoted to the TOP of the form (design pass, feedback item 2).** A "Reminders" section above the name field with: (a) **lead time** ("Notify me __ min before due") — the per-task `leadTimeMinutes` override, prefilled from the Settings default; (b) **re-ping interval** ("If I don't respond, re-ping every __ min") — the per-task `snoozeMinutes` override, prefilled from the default; (c) a per-task **Notifications** on/off toggle (`CareTask.notificationsEnabled`, migration-safe default ON). A value left at the default is stored as `nil` (keeps following the global default); a changed value is stored as the per-task override. The old collapsed "Advanced" section is removed — these controls are primary. **MUTED IS LOUD:** a muted task shows an unmissable, monochrome muted indicator (`bell.slash` + "Reminders off") on Board rows, patient detail, and Schedule/Grid, and the task sheet shows "Reminders off" with a one-tap re-enable. Silence must always be visible.
  - **Repair flow [fail-loud-decode]:** when opened for a `.needsRepair` task, the schedule field is **empty and required**; **all other task data is preserved**. Saving a repaired schedule clears the repair state and establishes a **new** valid `nextDueAt` from the selected schedule + anchor time — the old (untrusted) `nextDueAt` is **not** reused.
- **Shift Review**, **Log tab**, **Settings** — as v1.0.

### 6.3 Privacy & security + repair surfacing **[fail-loud-decode]**
App lock (Face ID / passcode), notification redaction in privacy mode, local-only data — as v1.0.

- **Completed-today section (design pass, feedback pass 4 item 5).** Patient detail, beneath Medications/Care/Reminders, has a **collapsed-by-default** "Completed today (N)" disclosure listing today's resolved occurrences (given/done/skipped, not reverted) with action + time — derived live from TaskEvents, **nothing persisted**. The expanded/collapsed choice is remembered for the app session (in-memory, per patient).
- **Reminder task kind (design pass, feedback pass 4 item 3).** A third `TaskKind.reminder` for non-clinical per-patient reminders (e.g. "call family", "chart check"). It schedules **identically to `.generic`** (interval / fixed / once / PRN) and only differs in presentation: the Add/Edit picker gains **Reminder** (no dosage / route / PRN-frequency fields); patient detail groups tasks into **Medications → Care tasks → Reminders** (reminders at the bottom); notifications read **"Reminder · [name] · Rm X"** (privacy ON: **"Reminder due · Rm X"**, and reminder-only digests "N reminders due · Rm X"). Raw value is additive/migration-safe (unknown stored kinds fall back to `.generic`).
- **Graduated redaction (design pass, feedback item 3).** With privacy mode **ON**, a redacted notification reads **"[Medication|Care] due · Rm X"** — task **kind is included**; patient name, medication name, dosage, route, and notes remain excluded. **Rationale:** kind (medication vs. care task) is **not clinically identifying** — it names no patient, drug, or dose — yet it lets the nurse make a **routing decision from the wrist** ("a med in 422 is due" vs. "a care task"). Digests follow the same rule: **"3 medications overdue · Rm 422"** (kind-aware count + room; mixed-kind groups fall back to "tasks"; repair digests are unchanged as they carry no clinical content). Applied consistently to pre-alerts, snooze pings, due alerts, and digests. Privacy mode **OFF** is unchanged (descriptive: "Rm X · <name>"). Redaction is enforced in the scheduler, not Core. Watch mirroring inherits this automatically (watchOS mirrors the phone's notification content).

- **Schedule-repair surfacing [fail-loud-decode]:** on detecting a `.needsRepair` task, the app fires a local notification ("A task's schedule couldn't be loaded — tap to fix") using a **deterministic per-task identifier** (`NotificationPlanner.repairWarningIdentifier(taskID:)`) so re-detection **replaces** the existing warning rather than duplicating it. Once the task is repaired it drops out of `tasksNeedingRepair` and its pending warning is removed. Tapping the warning (or the pinned Board row) opens the Edit form per §6.2's repair flow.

- **Undo from the Log (design pass, feedback pass 4 item 4).** Each `TaskEvent` captures a snapshot at action time (`previousNextDueAt`, `previousLastCompletedAt`, `previousIsPaused`, `previousExplicitSnoozeAt` — additive/migration-safe). The Log offers **Undo** (swipe + inline button) on a task's **most-recent** event, valid only while it's still the latest event, the task still exists, and a snapshot was captured. Undo **restores the snapshot exactly** (no recomputed guesses), replans, and does **not** delete the original — it marks it **reverted** (struck through in the Log) and records a `.undone` event referencing it, so the shift log stays a truthful history of mistakes and corrections. Undoable: Given/Done, Skip, Pause, **Resume** (Resume is now logged as `.resumed`). Undo of Delete is **not** supported (deletion is warned, item 1). A haptic + "Undone · next due …" toast confirms, sourced from post-commit state. Core adds `.resumed` + `.undone` TaskActions (tested).

### 6.4 Shift Review flow / 6.5 Overdue & missed handling — as v1.0.

---

## 7. Design Principles
Minimal, modern, fast. System-native SwiftUI, SF Symbols, system fonts. Color is information (red overdue / orange due-soon / green done). 44pt tap targets; two-tap common actions; no onboarding beyond the one-time disclaimer.

**Two independent color channels (design pass).** There are exactly two uses of color, kept strictly separate so neither can be misread as the other:
1. **Status** — red overdue / orange due-soon / green done, plus the repair-error treatment. Status OWNS these hues and is the ONLY thing that communicates urgency. It tints the status dot, due-time text, and (in Grid) the chip background.
2. **Per-med color tag** — an optional nurse-chosen label (`CareTask.colorTagRaw`, "none" default) drawn from a fixed 8-color palette (`TaskColorTag`) that DELIBERATELY EXCLUDES red/orange/green. It is display-only (never a scheduling input) and always renders as a distinct leading channel — a thin left-edge bar on Board/patient-detail/Schedule rows, a small dot on Grid chips — never by recoloring a status element. A tag must never make a row read as more or less urgent. Tags flow through the read models (`ScheduleOccurrence`, `PatientTaskLine`) so every surface renders from the same source.

**Time display (design pass).** All user-facing times render through one shared formatter (`AppTime`) that follows the device locale/clock setting (12h AM/PM or 24h); sort order is always chronological regardless of display format.

---

## 8–11
Edge cases, design, build order (§9), acceptance criteria (§10), and v2 parking lot (§11) as v1.0. Build-order gate stands: the watchOS target is not scaffolded until the Shared engine's unit tests are green.
