// Generates spec/vectors.json from the reference clock implementation.
//   node spec/vectors.mjs           -> (re)write spec/vectors.json
//   node spec/vectors.mjs --check   -> verify spec/vectors.json matches reference
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import * as clock from './reference-clock.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, 'vectors.json');

// Instants chosen to pin down every branch of the model.
const INSTANTS = [
  // ⏱ plain weekday peak windows (Fri 2026-10-30)
  '2026-10-30T00:59:00Z', '2026-10-30T01:00:00Z', '2026-10-30T03:59:59Z', '2026-10-30T04:00:00Z',
  '2026-10-30T05:59:00Z', '2026-10-30T06:00:00Z', '2026-10-30T09:00:00Z', '2026-10-30T09:59:59Z',
  '2026-10-30T10:00:00Z', '2026-10-30T23:59:00Z',
  // 🌙 before the weekend rule existed: weekends still show peak windows
  '2026-08-15T02:00:00Z', '2026-08-16T02:00:00Z', '2026-08-22T15:59:00Z',
  // 🚦 the cut-over instant
  '2026-08-22T16:00:00Z', '2026-08-22T16:01:00Z',
  // 🏖 Beijing weekend gating (Sat 2026-09-19 / Sun 2026-09-20)
  '2026-09-19T02:00:00Z', '2026-09-19T05:00:00Z', '2026-09-20T07:00:00Z', '2026-09-21T02:00:00Z',
  // 🎑 Mid-Autumn (2026-09-25 .. 09-27)
  '2026-09-25T02:00:00Z', '2026-09-26T07:00:00Z', '2026-09-27T09:30:00Z', '2026-09-28T02:00:00Z',
  // 🇨🇳 National Day week (2026-10-01 .. 10-07) — one long off-peak run
  '2026-10-01T02:00:00Z', '2026-10-03T06:30:00Z', '2026-10-05T03:00:00Z', '2026-10-07T23:00:00Z',
  '2026-10-08T00:59:00Z', '2026-10-08T01:00:00Z',
  // 🗓 a year out (make sure the day walker doesn't rely on 2026 tables)
  '2027-01-04T06:30:00Z', '2027-02-14T05:00:00Z', '2027-06-30T09:00:00Z',
  // 🔁 switches that are gated (weekend) must not be reported
  '2026-09-18T17:00:00Z', '2026-09-18T15:00:00Z',
];

const SEGMENT_CASES = [
  { t: '2026-10-30T09:00:00Z', offset: 0 },      // UTC
  { t: '2026-10-30T09:00:00Z', offset: 630 },    // +10:30, wraps
  { t: '2026-10-30T09:00:00Z', offset: -420 },   // America/Los_Angeles (-7)
  { t: '2026-09-19T02:00:00Z', offset: 630 },    // Beijing weekend, east-of-UTC view
  { t: '2026-10-05T03:00:00Z', offset: 0 },      // mid holiday run
  { t: '2026-08-22T16:00:00Z', offset: 0 },      // cut-over day
  // The display date can be ahead of the UTC date: 20:52Z Fri is Sat 07:22 in
  // +10:30, which must show the *weekend* day (all off-peak), not Friday's peaks.
  { t: '2026-10-30T20:52:00Z', offset: 630 },
  // And behind it: 03:00Z Sat is Fri 20:00 in Los Angeles, which must show Friday.
  { t: '2026-10-31T03:00:00Z', offset: -420 },
];

const WINDOW_CASES = [
  { t: '2026-10-30T09:00:00Z', count: 4 },
  { t: '2026-09-18T15:30:00Z', count: 4 },       // Fri evening -> weekend run
  { t: '2026-10-05T03:00:00Z', count: 3 },       // holiday run
];

const iso = (d) => d.toISOString().replace('.000Z', 'Z');

function build() {
  return {
    schema: 1,
    generated_by: 'spec/vectors.mjs (port of deepakness.com/deepseek inline JS)',
    switch_minutes: clock.SWITCH_MINUTES,
    weekend_rule_start: '2026-08-22T16:00:00Z',
    cn_holidays: clock.CN_HOLIDAYS,
    instants: INSTANTS.map((t) => {
      const d = new Date(t);
      const w = clock.utcWindow(d);
      return {
        t: iso(d),
        kind: w.kind,
        minute_of_day: w.minuteOfDay,
        window_start: iso(w.start),
        window_end: iso(w.end),
        next_kind: w.nextKind,
      };
    }),
    segments: SEGMENT_CASES.map(({ t, offset }) => ({
      t,
      offset_minutes: offset,
      segments: clock.displaySegments(new Date(t), offset),
    })),
    windows: WINDOW_CASES.map(({ t, count }) => ({
      t,
      count,
      windows: clock.windowList(new Date(t), count).map((w) => ({
        start: iso(w.start),
        end: iso(w.end),
        kind: w.kind,
        current: w.current,
      })),
    })),
  };
}

const built = build();

if (process.argv.includes('--check')) {
  if (!existsSync(OUT)) {
    console.error('vectors.json missing — run: node spec/vectors.mjs');
    process.exit(1);
  }
  const have = JSON.parse(readFileSync(OUT, 'utf8'));
  const a = JSON.stringify(have, null, 2);
  const b = JSON.stringify(built, null, 2);
  if (a !== b) {
    console.error('vectors.json is out of date with the reference implementation');
    process.exit(1);
  }
  console.log(`vectors.json OK (${built.instants.length} instants, ${built.segments.length} segment cases)`);
  process.exit(0);
}

writeFileSync(OUT, JSON.stringify(built, null, 2) + '\n');
console.log(`wrote ${OUT} — ${built.instants.length} instants, ${built.segments.length} segment cases, ${built.windows.length} window cases`);
