// Reference implementation of the 2026 DeepSeek peak/off-peak price clock.
// Ported 1:1 from https://deepakness.com/deepseek/ (inline JS) so that every
// surface of this project can be checked against it. Do not "fix" semantics
// here — SPEC.md §2 is the contract.
//
// Units: all instants are JS Date objects, all math in UTC.

export const SWITCH_MINUTES = [60, 240, 360, 600];

// 2026-08-22T16:00Z == 2026-08-23T00:00 Beijing (Sunday).
export const WEEKEND_RULE_START = Date.UTC(2026, 7, 22, 16);

// Inclusive Beijing-date ranges billed off-peak all day.
export const CN_HOLIDAYS = [
  ['2026-09-25', '2026-09-27'], // Mid-Autumn
  ['2026-10-01', '2026-10-07'], // National Day
];

const BEIJING_MS = 8 * 3600000;

export function beijingDateKey(date) {
  return new Date(date.getTime() + BEIJING_MS).toISOString().slice(0, 10);
}

export function isBeijingWeekend(date) {
  const day = new Date(date.getTime() + BEIJING_MS).getUTCDay();
  return day === 0 || day === 6;
}

export function isBeijingHoliday(date) {
  const key = beijingDateKey(date);
  return CN_HOLIDAYS.some(([from, to]) => key >= from && key <= to);
}

export function offPeakAllDay(date) {
  return (
    date.getTime() >= WEEKEND_RULE_START &&
    (isBeijingWeekend(date) || isBeijingHoliday(date))
  );
}

export function minuteOfDayUTC(date) {
  return date.getUTCHours() * 60 + date.getUTCMinutes();
}

export function kindAtInstant(date) {
  if (offPeakAllDay(date)) return 'off';
  const m = minuteOfDayUTC(date);
  return (m >= 60 && m < 240) || (m >= 360 && m < 600) ? 'peak' : 'off';
}

export function isSwitchInstant(date) {
  const m = minuteOfDayUTC(date);
  if (!SWITCH_MINUTES.includes(m)) return false;
  return !offPeakAllDay(date);
}

/** First `count` real switch instants strictly after `now`. */
export function nextSwitches(now, count) {
  const dayStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const out = [];
  let day = 0;
  let index = 0;
  while (out.length < count) {
    const instant = dayStart + day * 86400000 + SWITCH_MINUTES[index] * 60000;
    const candidate = new Date(instant);
    if (instant > now.getTime() && isSwitchInstant(candidate)) {
      out.push({ date: candidate, kind: kindAtInstant(candidate) });
    }
    index += 1;
    if (index >= SWITCH_MINUTES.length) {
      index = 0;
      day += 1;
    }
  }
  return out;
}

/** Most recent real switch instant at or before `now` (21-day scan). */
export function currentWindowStart(now) {
  const dayStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  let best = null;
  for (let day = -21; day <= 0; day += 1) {
    for (let i = 0; i < SWITCH_MINUTES.length; i += 1) {
      const instant = dayStart + day * 86400000 + SWITCH_MINUTES[i] * 60000;
      const candidate = new Date(instant);
      if (
        instant <= now.getTime() &&
        isSwitchInstant(candidate) &&
        (best === null || instant > best.getTime())
      ) {
        best = candidate;
      }
    }
  }
  return best || new Date(now.getTime() - 86400000);
}

export function utcWindow(now) {
  const next = nextSwitches(now, 1)[0];
  return {
    kind: kindAtInstant(now),
    nextKind: next.kind,
    start: currentWindowStart(now),
    end: next.date,
    minuteOfDay: minuteOfDayUTC(now),
  };
}

/** n windows, first is the current one. */
export function windowList(now, count) {
  const upcoming = nextSwitches(now, count);
  let start = currentWindowStart(now);
  let kind = kindAtInstant(now);
  const out = [];
  for (let i = 0; i < count; i += 1) {
    out.push({ start, end: upcoming[i].date, kind, current: i === 0 });
    start = upcoming[i].date;
    kind = upcoming[i].kind;
  }
  return out;
}

/**
 * 24h bar segments in display time.
 * @param now reference instant
 * @param offsetMinutes minutes east of UTC for the display zone (+630)
 */
export function displaySegments(now, offsetMinutes = 0) {
  const offset = offsetMinutes;
  // Anchor on the *display zone's* calendar day: east of UTC the local date can be
  // a day ahead of the UTC date (e.g. 20:52Z Friday is 07:22 Saturday at +10:30).
  const local = new Date(now.getTime() + offset * 60000);
  const dayStart = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - offset * 60000;

  const boundaries = [0, 1440];
  for (const m of SWITCH_MINUTES) boundaries.push(((m + offset) % 1440 + 1440) % 1440);
  boundaries.push(((960 + offset) % 1440 + 1440) % 1440); // Beijing midnight
  boundaries.sort((a, b) => a - b);

  const raw = [];
  for (let i = 0; i < boundaries.length - 1; i += 1) {
    const start = boundaries[i];
    const end = boundaries[i + 1];
    if (end <= start) continue;
    const sample = new Date(dayStart + (start + 0.5) * 60000);
    raw.push({ start, end, kind: kindAtInstant(sample) });
  }

  const merged = [];
  for (const segment of raw) {
    const last = merged[merged.length - 1];
    if (last && last.kind === segment.kind) last.end = segment.end;
    else merged.push({ ...segment });
  }
  return merged;
}

/* ---------- formatting helpers ---------- */

export function clockText(totalSeconds) {
  const sec = Math.max(0, Math.floor(totalSeconds));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

export function awayLabel(ms) {
  const mins = Math.max(0, Math.floor(ms / 60000));
  const h = Math.floor(mins / 60);
  return h ? `${h}h ${mins % 60}m` : `${mins}m`;
}

export function durationLabel(ms) {
  const mins = Math.max(0, Math.round(ms / 60000));
  const h = Math.floor(mins / 60);
  const rest = mins % 60;
  if (!h) return `${rest}m`;
  return rest ? `${h}h ${rest}m` : `${h}h`;
}
