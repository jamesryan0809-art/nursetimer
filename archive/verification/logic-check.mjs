// Logic cross-check for NurseTimerCore.
//
// This is NOT the Swift test suite. It is a faithful JavaScript port of the pure
// scheduling algorithms in Sources/NurseTimerCore (SchedulingEngine +
// NotificationPlanner), run against the SAME scenarios as
// Tests/NurseTimerCoreTests. Its job: verify the *logic* is correct on a machine
// where no Swift toolchain can be installed (Windows, no admin for WSL/MSVC).
//
// Any divergence here is a real algorithm bug that would also fail in Swift.
// It cannot catch Swift-specific compile errors — run `swift test` on macOS/Linux
// for that.
//
// Run: node verification/logic-check.mjs

// ----------------------------------------------------------------------------
// Time helpers (a "calendar" = a time zone, mirroring Swift's Calendar+TimeZone)
// ----------------------------------------------------------------------------

const MIN = 60 * 1000, HOUR = 3600 * 1000, DAY = 86400 * 1000;

const utcCal = {
  make: (y, mo, d, h = 0, mi = 0) => Date.UTC(y, mo - 1, d, h, mi, 0),
  parts: (ms) => {
    const dt = new Date(ms);
    return { y: dt.getUTCFullYear(), mo: dt.getUTCMonth() + 1, d: dt.getUTCDate(),
             h: dt.getUTCHours(), mi: dt.getUTCMinutes() };
  },
};

function zoneParts(ms, tz) {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const m = {};
  for (const p of dtf.formatToParts(new Date(ms))) m[p.type] = p.value;
  return { y: +m.year, mo: +m.month, d: +m.day, h: +m.hour, mi: +m.minute, s: +m.second };
}
function zoneOffsetMs(ms, tz) {
  const p = zoneParts(ms, tz);
  const asUTC = Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s);
  return asUTC - ms; // offset east of UTC (negative for America/New_York)
}
function zonedCal(tz) {
  const make = (y, mo, d, h = 0, mi = 0) => {
    const guess = Date.UTC(y, mo - 1, d, h, mi, 0);
    let utc = guess - zoneOffsetMs(guess, tz);
    utc = guess - zoneOffsetMs(utc, tz); // refine once for DST edges
    return utc;
  };
  return { make, parts: (ms) => { const p = zoneParts(ms, tz); return { y: p.y, mo: p.mo, d: p.d, h: p.h, mi: p.mi }; } };
}
const nyCal = zonedCal('America/New_York');

function isoUTC(ms) {
  const p = utcCal.parts(ms);
  const z = (n, w = 2) => String(n).padStart(w, '0');
  const dt = new Date(ms);
  return `${z(p.y, 4)}-${z(p.mo)}-${z(p.d)}T${z(p.h)}:${z(p.mi)}:${z(dt.getUTCSeconds())}Z`;
}

// ----------------------------------------------------------------------------
// SchedulingEngine (port of Sources/NurseTimerCore/SchedulingEngine.swift)
// ----------------------------------------------------------------------------

function nextDueAfterCompletion(schedule, completedAt, cal) {
  switch (schedule.kind) {
    case 'interval': return completedAt + schedule.hours * HOUR;
    case 'fixedTimes': return nextFixedTime(completedAt, schedule.times, cal);
    case 'once': return null;
    case 'prn': return null;
  }
}
function shouldAutoPauseAfterCompletion(schedule) { return schedule.kind === 'once'; }

function nextFixedTime(reference, times, cal) {
  if (!times.length) return null;
  const cands = [];
  const base = cal.parts(reference);
  for (const off of [0, 1]) {
    for (const t of times) {
      const cand = cal.make(base.y, base.mo, base.d + off, t.h, t.mi); // Date.UTC normalizes day overflow
      if (cand > reference) cands.push(cand);
    }
  }
  return cands.length ? Math.min(...cands) : null;
}

function preAlertDate(due, leadMinutes) { return due - leadMinutes * MIN; }

function snoozeChain(anchor, snoozeMinutes, now, count) {
  if (count <= 0 || snoozeMinutes <= 0) return [];
  const step = snoozeMinutes * MIN;
  let k = 1;
  if (anchor + step <= now) {
    k = Math.max(1, Math.floor((now - anchor) / step));
    while (anchor + k * step <= now) k += 1;
  }
  const res = [];
  for (let o = 0; o < count; o++) { const index = k + o; res.push({ index, date: anchor + index * step }); }
  return res;
}

// ----------------------------------------------------------------------------
// NotificationPlanner (port of Sources/NurseTimerCore/NotificationPlanner.swift)
// ----------------------------------------------------------------------------

const DEFAULT_SETTINGS = {
  defaultLeadTimeMinutes: 15, defaultSnoozeMinutes: 3,
  horizonHours: 12, snoozeChainLength: 20, softLimit: 55, hardCap: 64,
};

function identifier(taskID, due, token) { return `${taskID}|${isoUTC(due)}|${token}`; }

function plan(tasks, settings, now, cal) {
  const horizonEnd = now + settings.horizonHours * HOUR;
  let notifs = [];
  for (const t of tasks) {
    if (t.isPaused || t.nextDueAt == null) continue;
    const due = t.nextDueAt;
    const lead = t.leadTimeMinutes ?? settings.defaultLeadTimeMinutes;
    const snooze = t.snoozeMinutes ?? settings.defaultSnoozeMinutes;
    if (due >= now) {
      if (due > horizonEnd) continue;
      const preDate = preAlertDate(due, lead);
      if (preDate > now) notifs.push(mk(t.id, due, preDate, 'pre', 'pre'));
      notifs.push(mk(t.id, due, due, 'due', 'due'));
    } else {
      const anchor = t.explicitSnoozeAt ?? due;
      for (const p of snoozeChain(anchor, snooze, now, settings.snoozeChainLength)) {
        if (p.date <= horizonEnd) notifs.push(mk(t.id, due, p.date, 'snooze', `snooze-${p.index}`));
      }
    }
  }
  const { kept, trimmed } = applyBudget(notifs, settings);
  kept.sort((a, b) => a.fireDate - b.fireDate);
  return { notifications: kept, trimmed };
}
function mk(taskID, due, fireDate, kind, token) {
  return { identifier: identifier(taskID, due, token), taskID, dueDate: due, fireDate, slotKind: kind, token };
}
function applyBudget(notifs, settings) {
  let kept = notifs.slice();
  let trimmed = false;
  if (kept.length > settings.softLimit) {
    const overBy = kept.length - settings.softLimit;
    const dropIdx = kept.map((n, i) => ({ n, i })).filter((x) => x.n.slotKind === 'pre')
      .sort((a, b) => b.n.fireDate - a.n.fireDate).slice(0, overBy).map((x) => x.i);
    if (dropIdx.length) { const drop = new Set(dropIdx); kept = kept.filter((_, i) => !drop.has(i)); trimmed = true; }
  }
  if (kept.length > settings.hardCap) {
    const overBy = kept.length - settings.hardCap;
    const dropIdx = kept.map((n, i) => ({ n, i })).filter((x) => x.n.slotKind === 'snooze')
      .sort((a, b) => b.n.fireDate - a.n.fireDate).slice(0, overBy).map((x) => x.i);
    if (dropIdx.length) { const drop = new Set(dropIdx); kept = kept.filter((_, i) => !drop.has(i)); trimmed = true; }
  }
  return { kept, trimmed };
}

// ----------------------------------------------------------------------------
// Test harness
// ----------------------------------------------------------------------------

let passed = 0, failed = 0;
function ok(name, cond, detail = '') {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}  ${detail}`); }
}
function eq(name, a, b) { ok(name, a === b, `got ${a} want ${b}`); }
function group(t) { console.log(`\n${t}`); }
const T = (kind, extra = {}) => ({ kind, ...extra });          // schedule
const task = (o) => ({ leadTimeMinutes: null, snoozeMinutes: null, isPaused: false,
  explicitSnoozeAt: null, nextDueAt: null, ...o });

// ---- SchedulingEngine ----
group('SchedulingEngine — interval anchoring (§4.1, acceptance §10)');
eq('q4h given 13:07 -> due 17:07',
   nextDueAfterCompletion(T('interval', { hours: 4 }), utcCal.make(2026, 7, 19, 13, 7), utcCal),
   utcCal.make(2026, 7, 19, 17, 7));
eq('late dose given 17:45 -> 21:45 (not 21:00)',
   nextDueAfterCompletion(T('interval', { hours: 4 }), utcCal.make(2026, 7, 19, 17, 45), utcCal),
   utcCal.make(2026, 7, 19, 21, 45));
eq('q6h given 08:00 -> 14:00',
   nextDueAfterCompletion(T('interval', { hours: 6 }), utcCal.make(2026, 7, 19, 8, 0), utcCal),
   utcCal.make(2026, 7, 19, 14, 0));

group('SchedulingEngine — fixed times + midnight crossing (§4.1/§8)');
const fixed = [{ h: 9, mi: 0 }, { h: 21, mi: 0 }];
eq('08:00 -> next 09:00 today',
   nextFixedTime(utcCal.make(2026, 7, 19, 8, 0), fixed, utcCal), utcCal.make(2026, 7, 19, 9, 0));
eq('22:00 -> next 09:00 tomorrow (crosses midnight)',
   nextFixedTime(utcCal.make(2026, 7, 19, 22, 0), fixed, utcCal), utcCal.make(2026, 7, 20, 9, 0));
eq('exactly 21:00 rolls forward (strictly after)',
   nextFixedTime(utcCal.make(2026, 7, 19, 21, 0), fixed, utcCal), utcCal.make(2026, 7, 20, 9, 0));
ok('empty times -> null', nextFixedTime(0, [], utcCal) === null);

group('SchedulingEngine — once auto-pause / PRN (§4.1)');
ok('once -> nextDue null', nextDueAfterCompletion(T('once', { at: 0 }), 0, utcCal) === null);
ok('once auto-pauses', shouldAutoPauseAfterCompletion(T('once')) === true);
ok('interval does not auto-pause', shouldAutoPauseAfterCompletion(T('interval', { hours: 4 })) === false);
ok('prn does not auto-pause', shouldAutoPauseAfterCompletion(T('prn')) === false);
ok('prn never schedules', nextDueAfterCompletion(T('prn'), utcCal.make(2026, 7, 19, 12, 0), utcCal) === null);

group('SchedulingEngine — pre-alert (§4.2, acceptance §10)');
eq('due 17:07 lead 15 -> pre 16:52',
   preAlertDate(utcCal.make(2026, 7, 19, 17, 7), 15), utcCal.make(2026, 7, 19, 16, 52));

group('SchedulingEngine — snooze chains (§4.2)');
{
  const due = utcCal.make(2026, 7, 19, 17, 7);
  const c = snoozeChain(due, 3, due, 20);
  eq('fresh: length 20', c.length, 20);
  eq('fresh: first index 1', c[0].index, 1);
  eq('fresh: first date D+3m', c[0].date, due + 3 * MIN);
  eq('fresh: last index 20', c[19].index, 20);
  eq('fresh: last date D+60m', c[19].date, due + 20 * 3 * MIN);
  ok('fresh: contiguous indices', c.every((p, i) => p.index === i + 1));

  const c5 = snoozeChain(due, 5, due, 3);
  ok('default 3->5 widens spacing to 5m',
     c5[0].date === due + 5 * MIN && c5[1].date === due + 10 * MIN && c5[2].date === due + 15 * MIN);

  const tapped = utcCal.make(2026, 7, 19, 18, 0);
  eq('explicit snooze re-anchors to now+S', snoozeChain(tapped, 3, tapped, 20)[0].date, tapped + 3 * MIN);

  const dueO = utcCal.make(2026, 7, 19, 17, 0);
  const now = dueO + 100 * MIN;
  const cl = snoozeChain(dueO, 3, now, 20);
  eq('long-overdue: full buffer of 20', cl.length, 20);
  eq('long-overdue: first index 34 (3k>100)', cl[0].index, 34);
  eq('long-overdue: first date D+102m', cl[0].date, dueO + 34 * 3 * MIN);
  ok('long-overdue: all strictly future', cl.every((p) => p.date > now));

  ok('count 0 -> empty', snoozeChain(0, 3, 0, 0).length === 0);
  ok('snooze 0 -> empty', snoozeChain(0, 0, 0, 20).length === 0);
}

group('SchedulingEngine — DST spring-forward 2026-03-08 (§8)');
{
  const given = nyCal.make(2026, 3, 8, 1, 30);          // 01:30 EST
  const next = nextDueAfterCompletion(T('interval', { hours: 4 }), given, nyCal);
  eq('interval offset is absolute 4h', next - given, 4 * HOUR);
  const wc = nyCal.parts(next);
  ok('interval wall clock jumps to 06:30 EDT', wc.h === 6 && wc.mi === 30, `got ${wc.h}:${wc.mi}`);

  const ref = nyCal.make(2026, 3, 8, 0, 30);
  const ft = nextFixedTime(ref, [{ h: 9, mi: 0 }], nyCal);
  const fwc = nyCal.parts(ft);
  ok('fixed 09:00 stays wall-clock 09:00 on DST day', fwc.h === 9 && fwc.mi === 0, `got ${fwc.h}:${fwc.mi}`);
}

// ---- NotificationPlanner ----
const ID1 = '00000000-0000-0000-0000-000000000001';
const slots = (p) => p.notifications.map((n) => n.token);

group('NotificationPlanner — deterministic identifiers (§4.3/§5.4)');
{
  const due = utcCal.make(2024, 3, 9, 16, 0);
  eq('due id', identifier(ID1, due, 'due'), `${ID1}|2024-03-09T16:00:00Z|due`);
  eq('pre id', identifier(ID1, due, 'pre'), `${ID1}|2024-03-09T16:00:00Z|pre`);
  eq('snooze-3 id', identifier(ID1, due, 'snooze-3'), `${ID1}|2024-03-09T16:00:00Z|snooze-3`);
  const d2 = utcCal.make(2026, 7, 19, 17, 7);
  eq('same inputs -> same id', identifier(ID1, d2, 'snooze-7'), identifier(ID1, d2, 'snooze-7'));
}

group('NotificationPlanner — upcoming -> pre + due (§4.3)');
{
  const now = utcCal.make(2026, 7, 19, 16, 0);
  const due = utcCal.make(2026, 7, 19, 16, 30);
  const p = plan([task({ id: ID1, nextDueAt: due })], DEFAULT_SETTINGS, now, utcCal);
  ok('slots [pre,due]', JSON.stringify(slots(p)) === JSON.stringify(['pre', 'due']));
  ok('not trimmed', p.trimmed === false);
  eq('pre fires due-15', p.notifications[0].fireDate, utcCal.make(2026, 7, 19, 16, 15));
  eq('due fires at due', p.notifications[1].fireDate, due);

  const due2 = utcCal.make(2026, 7, 19, 16, 5); // pre already past
  const p2 = plan([task({ id: ID1, nextDueAt: due2 })], DEFAULT_SETTINGS, now, utcCal);
  ok('pre past -> due only', JSON.stringify(slots(p2)) === JSON.stringify(['due']));
}

group('NotificationPlanner — 12h horizon (§4.3/§8)');
{
  const now = utcCal.make(2026, 7, 19, 8, 0);
  ok('beyond 13h -> none',
     plan([task({ id: ID1, nextDueAt: now + 13 * HOUR })], DEFAULT_SETTINGS, now, utcCal).notifications.length === 0);
  ok('at 11h -> pre+due',
     plan([task({ id: ID1, nextDueAt: now + 11 * HOUR })], DEFAULT_SETTINGS, now, utcCal).notifications.length === 2);
}

group('NotificationPlanner — overdue chain + action cancels it (§4.2/§5.3)');
{
  const due = utcCal.make(2026, 7, 19, 16, 0);
  const now = due + 1 * MIN;
  const p = plan([task({ id: ID1, nextDueAt: due })], DEFAULT_SETTINGS, now, utcCal);
  eq('overdue -> full snooze chain (20)', p.notifications.length, 20);
  ok('all snooze slots', p.notifications.every((n) => n.slotKind === 'snooze'));
  ok('all share due date (cancel-by-due)', p.notifications.every((n) => n.dueDate === due));

  // simulate GIVEN: recompute nextDueAt to future; chain must vanish
  const newDue = nextDueAfterCompletion(T('interval', { hours: 4 }), now, utcCal);
  const p2 = plan([task({ id: ID1, nextDueAt: newDue, lastCompletedAt: now })], DEFAULT_SETTINGS, now, utcCal);
  ok('after given -> [pre,due], no snooze',
     JSON.stringify(slots(p2)) === JSON.stringify(['pre', 'due']) &&
     !p2.notifications.some((n) => n.slotKind === 'snooze'));

  const p3 = plan([task({ id: ID1, nextDueAt: due, explicitSnoozeAt: now })], DEFAULT_SETTINGS, now, utcCal);
  eq('explicit snooze re-anchors first ping to now+3', p3.notifications[0].fireDate, now + 3 * MIN);
}

group('NotificationPlanner — paused / PRN contribute nothing');
{
  const now = utcCal.make(2026, 7, 19, 16, 0);
  const p = plan([
    task({ id: ID1, nextDueAt: now + 30 * MIN, isPaused: true }),
    task({ id: 'prn', nextDueAt: null }),
  ], DEFAULT_SETTINGS, now, utcCal);
  ok('no notifications', p.notifications.length === 0);
}

group('NotificationPlanner — 64-cap trimming (§4.3)');
{
  const now = utcCal.make(2026, 7, 19, 8, 0);
  const tasks = [];
  for (let i = 0; i < 30; i++) {
    tasks.push(task({ id: `t${i}`, nextDueAt: now + (i + 1) * 10 * MIN, leadTimeMinutes: 5 }));
  }
  const p = plan(tasks, DEFAULT_SETTINGS, now, utcCal);
  ok('trimmed flag set', p.trimmed === true);
  eq('trimmed to soft limit 55', p.notifications.length, 55);
  eq('all 30 due kept', p.notifications.filter((n) => n.slotKind === 'due').length, 30);
  eq('25 pre kept', p.notifications.filter((n) => n.slotKind === 'pre').length, 25);
  const latest = tasks[29].id, earliest = tasks[0].id;
  ok('furthest task lost its pre', !p.notifications.some((n) => n.taskID === latest && n.slotKind === 'pre'));
  ok('nearest task kept its pre', p.notifications.some((n) => n.taskID === earliest && n.slotKind === 'pre'));

  const small = [];
  for (let i = 0; i < 10; i++) small.push(task({ id: `s${i}`, nextDueAt: now + (i + 1) * 10 * MIN, leadTimeMinutes: 5 }));
  const ps = plan(small, DEFAULT_SETTINGS, now, utcCal);
  ok('below soft limit -> not trimmed (20)', ps.trimmed === false && ps.notifications.length === 20);
}

group('NotificationPlanner — output sorted by fire date');
{
  const now = utcCal.make(2026, 7, 19, 8, 0);
  const tasks = [];
  for (let i = 0; i < 5; i++) tasks.push(task({ id: `o${i}`, nextDueAt: now + (5 - i) * 20 * MIN }));
  const fire = plan(tasks, DEFAULT_SETTINGS, now, utcCal).notifications.map((n) => n.fireDate);
  ok('ascending fire dates', JSON.stringify(fire) === JSON.stringify([...fire].sort((a, b) => a - b)));
}

console.log(`\n${'='.repeat(48)}`);
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
