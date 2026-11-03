#!/usr/bin/env node
/**
 * DeepSeek Tracker — metrics collector.
 *
 * Produces `metrics/metrics.json` exactly per SPEC.md §4 (schema v1) using only
 * the Node.js standard library (Node >= 20, no npm dependencies).
 *
 * Sources
 *   1. https://status.deepseek.com/  — Flashcat status page. There is no public
 *      JSON API (only /api/health), so we parse the server-rendered HTML's
 *      Next.js flight payload: `self.__next_f.push([1,"…"])`. It embeds
 *      `initialPageConfig` (components + sections), an `initialData` blob with
 *      `section_uptimes` / `component_uptimes` / `*_impacts`, and
 *      `initialCalendarData.changes` (incidents with open/close timestamps).
 *   2. https://api.deepseek.com/models — reachability/latency probe (401 is
 *      fine, it proves reachability and arrives fast, no key needed).
 *   3. https://api.deepseek.com/user/balance — optional; only when
 *      DEEPSEEK_API_KEY is set in the environment.
 *
 * CLI
 *   node collector/status-collector.mjs [--once] [--interval <seconds>]
 *        [--out <path>] [--serve [port]] [--help]
 *
 *   --once              collect a single cycle and exit (default)
 *   --interval <sec>    collect forever, sleeping <sec> between cycles
 *   --out <path>        output file (default metrics/metrics.json)
 *   --serve [port]      serve the JSON on 127.0.0.1:<port> (default 8787).
 *                       With --interval it also collects; together with an
 *                       explicit --once it collects once first. On its own it
 *                       just serves whatever is on disk.
 *
 * Design rules baked in here
 *   - Every source is independently failure-tolerant and has a hard timeout.
 *   - A source that fails keeps its last-good value (loaded from the previous
 *     metrics.json or from an earlier cycle in this process); the JSON gets an
 *     additive `warnings` array entry beginning `stale_source:<source>`.
 *   - Writes are atomic (tmp file + rename) so readers never see partial JSON.
 *   - `overall: "unknown"` + `error` is emitted rather than fabricated data
 *     whenever the status page cannot be parsed with confidence.
 *   - The API key never leaves the environment except as a masked key hint.
 */

import { createServer } from 'node:http';
import {
  mkdir,
  readFile,
  rename,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------
// Constants (exported so the tests and docs can stay honest)
// ---------------------------------------------------------------------------

export const SCHEMA_VERSION = 1;

export const STATUS_URL = 'https://status.deepseek.com/';
export const LATENCY_URL = 'https://api.deepseek.com/models';
export const BALANCE_URL = 'https://api.deepseek.com/user/balance';
export const LATENCY_ENDPOINT = 'api.deepseek.com';
export const STATUS_SOURCE = 'status.deepseek.com';

export const DEFAULT_OUT = 'metrics/metrics.json';
export const DEFAULT_SERVE_PORT = 8787;
export const DEFAULT_SERVE_HOST = '127.0.0.1';

/** Hard wall-clock budget for a single source fetch. */
export const SOURCE_TIMEOUT_MS = 10_000;
/** Per-probe timeout for the latency source. */
export const LATENCY_PROBE_TIMEOUT_MS = 3_000;
/** Overall budget for all latency probes in one cycle. */
export const LATENCY_SOURCE_BUDGET_MS = 10_000;
export const LATENCY_PROBES = 5;

export const MAX_COMPONENTS = 6;

/** SPEC §4 age policy. */
export const AGE_LIVE_MS = 2 * 60 * 1000;
export const AGE_STALE_MS = 15 * 60 * 1000;

export const OVERALL_STATUSES = Object.freeze([
  'operational',
  'degraded',
  'partial_outage',
  'full_outage',
  'maintenance',
  'unknown',
]);

export const COMPONENT_STATUSES = Object.freeze([
  'operational',
  'degraded',
  'partial_outage',
  'full_outage',
  'maintenance',
]);

/** Incident severity, low → high. `maintenance` is handled separately. */
const SEVERITY = Object.freeze({
  operational: 0,
  degraded: 1,
  partial_outage: 2,
  full_outage: 3,
});

const STATUS_LABELS = Object.freeze({
  operational: 'All systems operational',
  degraded: 'Degraded performance',
  partial_outage: 'Partial outage',
  full_outage: 'Full outage',
  maintenance: 'Scheduled maintenance in progress',
  unknown: 'Status unknown',
});

const TERMINAL_CHANGE_STATUSES = new Set([
  'resolved',
  'cancelled',
  'canceled',
  'completed',
  'closed',
]);

const USER_AGENT = 'deepseek-tracker-collector/1.0 (metrics; +https://status.deepseek.com/)';

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------

/** ISO-8601 UTC with second precision (matches the SPEC sample). */
export function nowIso(ms = Date.now()) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function errorText(err) {
  if (err == null) return 'unknown error';
  if (err instanceof Error) return err.message || err.name || 'error';
  return String(err);
}

/** One structured JSON log line to stderr. */
export function logEvent(event, fields = {}) {
  process.stderr.write(JSON.stringify({ event, ...fields }) + '\n');
}

function toMs(seconds) {
  if (seconds == null || seconds === '') return null;
  const n = Number(seconds);
  if (!Number.isFinite(n)) return null;
  // Values arrive as epoch seconds; accept ms defensively.
  return n > 1e12 ? n : n * 1000;
}

function finiteNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function round1(n) {
  return Math.round(n * 10) / 10;
}

function round2(n) {
  return Math.round(n * 100) / 100;
}

function clampUptime(value) {
  const n = finiteNumber(value);
  if (n == null || n < 0 || n > 100) return null;
  return round2(n);
}

/** Mask an API key for the metrics JSON: `sk-…abcd`. */
export function maskKey(key) {
  const s = typeof key === 'string' ? key.trim() : '';
  if (!s) return 'sk-…';
  return `sk-…${s.slice(-4)}`;
}

export function sleep(ms) {
  return new Promise((res) => setTimeout(res, ms));
}

/** fetch() with an AbortController hard timeout. */
export async function fetchWithTimeout(url, options = {}) {
  const {
    fetchImpl = globalThis.fetch,
    timeoutMs = SOURCE_TIMEOUT_MS,
    ...init
  } = options;
  const controller = new AbortController();
  const timer = setTimeout(() => {
    controller.abort(new Error(`timeout after ${timeoutMs}ms`));
  }, Math.max(1, timeoutMs));
  try {
    return await fetchImpl(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Next.js flight-payload parsing
// ---------------------------------------------------------------------------

/**
 * Scan a JSON value (object/array/string) starting at `start` and return the
 * index just past its end, respecting strings and escapes. Returns -1 when the
 * value is unterminated.
 */
function scanJsonEnd(text, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') {
      inString = true;
    } else if (ch === '[' || ch === '{') {
      depth += 1;
    } else if (ch === ']' || ch === '}') {
      depth -= 1;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

/**
 * Extract and concatenate every `self.__next_f.push([1,"…"])` flight chunk from
 * a server-rendered Next.js document.
 */
export function extractFlightPayload(html) {
  if (typeof html !== 'string' || html.length === 0) {
    throw new Error('flight payload: empty HTML document');
  }
  const marker = 'self.__next_f.push(';
  let payload = '';
  let chunks = 0;
  let cursor = 0;
  while (true) {
    const at = html.indexOf(marker, cursor);
    if (at === -1) break;
    const start = html.indexOf('[', at + marker.length);
    if (start === -1) break;
    const end = scanJsonEnd(html, start);
    if (end === -1) break;
    try {
      const arr = JSON.parse(html.slice(start, end));
      if (Array.isArray(arr) && typeof arr[1] === 'string') {
        payload += arr[1];
        chunks += 1;
      }
    } catch {
      // Ignore an unparseable chunk; other chunks may still be usable.
    }
    cursor = end;
  }
  if (!payload) {
    throw new Error('flight payload: no self.__next_f.push data found');
  }
  return { payload, chunks };
}

/** Find `"<key>":{…}` in a flight payload and JSON.parse the object. */
function jsonObjectAfter(payload, key, fromIndex = 0) {
  const at = payload.indexOf(key, fromIndex);
  if (at === -1) return null;
  const start = payload.indexOf('{', at + key.length);
  if (start === -1) return null;
  const end = scanJsonEnd(payload, start);
  if (end === -1) return null;
  try {
    return JSON.parse(payload.slice(start, end));
  } catch {
    return null;
  }
}

/** Find every `"<key>":{…}` occurrence. */
function allJsonObjectsAfter(payload, key) {
  const out = [];
  let cursor = 0;
  while (true) {
    const at = payload.indexOf(key, cursor);
    if (at === -1) break;
    const start = payload.indexOf('{', at + key.length);
    if (start === -1) break;
    const end = scanJsonEnd(payload, start);
    if (end === -1) break;
    try {
      out.push(JSON.parse(payload.slice(start, end)));
    } catch {
      // skip
    }
    cursor = Math.max(end, at + key.length);
  }
  return out;
}

function findUpdatedAt(payload) {
  const m = payload.match(/"initialDataUpdatedAt"\s*:\s*(\d{10,})/);
  if (!m) return null;
  const n = Number(m[1]);
  if (!Number.isFinite(n)) return null;
  return n > 1e12 ? n : n * 1000;
}

/**
 * Turn the Chinese/English component label from the status page into a short
 * English-ish display name:
 *
 *   "DeepSeek V4.1 Flash API服务(API Service)" → "DeepSeek V4.1 Flash API"
 *   "搜索API服务(Search API Service)"          → "Search API Service"
 *   "对话服务(Chatservice)"                    → "Chat Service"
 *   "上传文件服务(File Upload Service)"        → "File Upload Service"
 */
export function cleanComponentName(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') return 'Unknown component';
  const name = raw.trim();
  const paren = name.match(/^(.*?)\s*[（(]([^()（）]*)[)）]\s*$/);
  const base = paren ? paren[1].trim() : name;
  const parenText = paren ? paren[2].trim() : '';
  const cjk = /[\u3400-\u9fff\uf900-\ufaff]/;

  // Prefer the latin part of the base (drops trailing Chinese "服务").
  const latinBase = base
    .replace(/[\u3400-\u9fff\uf900-\ufaff]/g, '')
    .replace(/\s+/g, ' ')
    .trim();

  let out;
  if (latinBase && !cjk.test(base[0] || '')) {
    out = latinBase;
  } else if (parenText) {
    out = parenText;
  } else {
    out = latinBase || base;
  }
  out = out.replace(/\s+/g, ' ').trim();
  // The page's own English fallback spells this without a space.
  if (/^chatservice$/i.test(out)) out = 'Chat Service';
  return out || name;
}

/**
 * Parse a status.deepseek.com HTML document into its raw embedded structures.
 * Throws (rather than guessing) when the expected blocks are absent, so the
 * caller can emit `overall: "unknown"` + `error`.
 */
export function parseStatusPage(html, options = {}) {
  const { nowMs = Date.now() } = options;
  const { payload, chunks } = extractFlightPayload(html);

  // Page metadata: `initialPageConfig` is the canonical copy on the live page.
  // Older/newer builds may only ship it inside an `initialData` blob.
  const initialDataBlobs = allJsonObjectsAfter(payload, '"initialData":');
  const pageBlob = initialDataBlobs.find((b) => b && b.page) || null;
  let page = jsonObjectAfter(payload, '"initialPageConfig":');
  if (!page && pageBlob) page = pageBlob.page;
  if (!page) throw new Error('status page: page configuration not found');

  const statusData =
    initialDataBlobs.find(
      (b) =>
        b &&
        (Array.isArray(b.section_uptimes) ||
          Array.isArray(b.component_uptimes) ||
          Array.isArray(b.section_impacts) ||
          Array.isArray(b.component_impacts)),
    ) || null;
  if (!statusData) throw new Error('status page: uptime/impact data not found');

  const calendarData = jsonObjectAfter(payload, '"initialCalendarData":');
  const activeChanges =
    (pageBlob && Array.isArray(pageBlob.active_changes) && pageBlob.active_changes) ||
    (Array.isArray(page.active_changes) && page.active_changes) ||
    [];
  const updatedAtMs = findUpdatedAt(payload);

  const components = Array.isArray(page.components) ? page.components : [];
  if (components.length === 0) {
    throw new Error('status page: component list is empty');
  }
  for (const component of components) {
    if (!component || typeof component.component_id !== 'string' || !component.component_id) {
      throw new Error('status page: component is missing component_id');
    }
    if (typeof component.name !== 'string' || !component.name) {
      throw new Error('status page: component is missing name');
    }
  }

  return {
    page,
    statusData,
    calendarData: calendarData && Array.isArray(calendarData.changes) ? calendarData : null,
    activeChanges,
    updatedAtMs,
    flightChunks: chunks,
    flightPayloadLength: payload.length,
    parsedAtMs: nowMs,
  };
}

function isActiveInterval(startMs, endMs, nowMs) {
  if (startMs == null || startMs > nowMs) return false;
  return endMs == null || endMs > nowMs;
}

function isActiveImpact(impact, nowMs) {
  if (!impact) return false;
  return isActiveInterval(
    toMs(impact.start_at_seconds),
    toMs(impact.end_at_seconds),
    nowMs,
  );
}

function isActiveChange(change, nowMs) {
  if (!change) return false;
  const start = toMs(change.start_at_seconds);
  const end = toMs(change.close_at_seconds ?? change.end_at_seconds);
  if (!isActiveInterval(start, end, nowMs)) return false;
  const status = String(change.status || '').toLowerCase();
  // Interval is authoritative; a terminal status with no close timestamp is
  // the one case where we trust the label instead of the window.
  if (end == null && TERMINAL_CHANGE_STATUSES.has(status)) return false;
  return true;
}

function isMaintenanceChange(change) {
  const type = String((change && change.type) || '').toLowerCase();
  return type === 'maintenance' || type === 'scheduled_maintenance';
}

function incidentType(change) {
  const type = String((change && change.type) || 'incident').toLowerCase();
  return !isMaintenanceChange(change) && type === 'incident';
}

function maxStatus(current, candidate) {
  const rank = (status) => (status in SEVERITY ? SEVERITY[status] : -1);
  return rank(candidate) > rank(current) ? candidate : current;
}

/**
 * Derive the SPEC §4 `status` object from the parsed page payload.
 *
 * Severity ordering: full_outage > partial_outage > degraded > operational.
 * `maintenance` is used when a scheduled-maintenance window is active and no
 * worse incident state is present. Per-component or per-section impacts are
 * matched to components; section impacts apply to every component in that
 * section. The overall value is derived before the list is capped at six so a
 * low-priority outage still surfaces.
 */
export function deriveStatus({
  page,
  statusData,
  calendarData = null,
  activeChanges = [],
  nowMs = Date.now(),
} = {}) {
  if (!page || !Array.isArray(page.components) || page.components.length === 0) {
    throw new Error('deriveStatus: page.components is required');
  }
  if (!statusData) throw new Error('deriveStatus: statusData is required');

  const sections = Array.isArray(page.sections) ? page.sections : [];
  const sectionOrder = new Map();
  for (const section of sections) {
    if (section && section.section_id != null) {
      sectionOrder.set(section.section_id, finiteNumber(section.order_id) ?? 0);
    }
  }

  const componentUptime = new Map();
  for (const row of statusData.component_uptimes || []) {
    if (row && row.component_id) componentUptime.set(row.component_id, row.uptime);
  }
  const sectionUptime = new Map();
  for (const row of statusData.section_uptimes || []) {
    if (row && row.section_id) sectionUptime.set(row.section_id, row.uptime);
  }

  const componentImpacts = (statusData.component_impacts || []).filter(
    (row) => row && row.component_id,
  );
  const sectionImpacts = (statusData.section_impacts || []).filter(
    (row) => row && row.section_id,
  );

  const activeComponentStatus = new Map();
  const activeSectionStatus = new Map();
  const maintenanceComponents = new Set();
  const maintenanceSections = new Set();
  const impactIncidentIds = new Set();

  for (const impact of componentImpacts) {
    if (!isActiveImpact(impact, nowMs)) continue;
    const status = String(impact.status || '').toLowerCase();
    if (status === 'maintenance') {
      maintenanceComponents.add(impact.component_id);
      continue;
    }
    if (!(status in SEVERITY)) continue;
    if (status !== 'operational') {
      activeComponentStatus.set(
        impact.component_id,
        maxStatus(activeComponentStatus.get(impact.component_id) || 'operational', status),
      );
      if (impact.change_id != null) impactIncidentIds.add(String(impact.change_id));
    }
  }

  for (const impact of sectionImpacts) {
    if (!isActiveImpact(impact, nowMs)) continue;
    const status = String(impact.status || '').toLowerCase();
    if (status === 'maintenance') {
      maintenanceSections.add(impact.section_id);
      continue;
    }
    if (!(status in SEVERITY)) continue;
    if (status !== 'operational') {
      activeSectionStatus.set(
        impact.section_id,
        maxStatus(activeSectionStatus.get(impact.section_id) || 'operational', status),
      );
      if (impact.change_id != null) impactIncidentIds.add(String(impact.change_id));
    }
  }

  // Maintenance windows from the calendar / active-change list.
  let maintenanceActive = maintenanceComponents.size > 0 || maintenanceSections.size > 0;
  const calendarChanges =
    calendarData && Array.isArray(calendarData.changes) ? calendarData.changes : [];
  for (const change of calendarChanges) {
    if (isMaintenanceChange(change) && isActiveChange(change, nowMs)) {
      maintenanceActive = true;
    }
  }
  const activeIncidentIds = new Set();
  for (const change of activeChanges) {
    if (!change) continue;
    if (isMaintenanceChange(change)) {
      maintenanceActive = true;
    } else if (incidentType(change) && change.id != null) {
      activeIncidentIds.add(String(change.id));
    }
  }
  for (const change of calendarChanges) {
    if (isActiveChange(change, nowMs) && incidentType(change) && change.change_id != null) {
      activeIncidentIds.add(String(change.change_id));
    }
  }
  for (const id of impactIncidentIds) activeIncidentIds.add(id);

  // Component statuses for every component (before the six-item cap).
  const derived = page.components.map((raw, index) => {
    const id = raw.component_id;
    const sectionId = raw.section_id || '';
    let status = activeComponentStatus.get(id) || 'operational';
    if (sectionId) {
      status = maxStatus(status, activeSectionStatus.get(sectionId) || 'operational');
    }
    if (status === 'operational') {
      if (
        maintenanceComponents.has(id) ||
        (sectionId && maintenanceSections.has(sectionId))
      ) {
        status = 'maintenance';
      }
    }
    const uptime = clampUptime(
      componentUptime.has(id)
        ? componentUptime.get(id)
        : sectionId && sectionUptime.has(sectionId)
          ? sectionUptime.get(sectionId)
          : null,
    );
    return {
      id,
      name: cleanComponentName(raw.name),
      status,
      uptime,
      _index: index,
      _order: finiteNumber(raw.order_id) ?? 0,
      _sectionId: sectionId,
      _sectionOrder: sectionId ? sectionOrder.get(sectionId) ?? 0 : -1,
    };
  });

  let overallRank = 0;
  for (const component of derived) {
    if (component.status in SEVERITY) {
      overallRank = Math.max(overallRank, SEVERITY[component.status]);
    }
  }
  let overall = 'operational';
  if (overallRank > 0) {
    overall = Object.keys(SEVERITY).find((key) => SEVERITY[key] === overallRank) || 'degraded';
  } else if (maintenanceActive) {
    overall = 'maintenance';
  }

  // "At most 6, ordered by importance": standalone API components first, then
  // components grouped under sections, each by the page's own ordering.
  const ordered = [...derived].sort((a, b) => {
    const aStandalone = a._sectionId === '';
    const bStandalone = b._sectionId === '';
    if (aStandalone !== bStandalone) return aStandalone ? -1 : 1;
    if (!aStandalone) {
      if (a._sectionOrder !== b._sectionOrder) return a._sectionOrder - b._sectionOrder;
    }
    if (a._order !== b._order) return a._order - b._order;
    return a._index - b._index;
  });

  const components = ordered.slice(0, MAX_COMPONENTS).map((component) => ({
    id: component.id,
    name: component.name,
    status: component.status,
    uptime: component.uptime,
  }));

  return {
    overall,
    label: STATUS_LABELS[overall] || STATUS_LABELS.unknown,
    components,
    active_incidents: activeIncidentIds.size,
  };
}

/** Convenience wrapper: HTML → derived status (throws on any parse problem). */
export function statusFromHtml(html, options = {}) {
  const parsed = parseStatusPage(html, options);
  return {
    ...parsed,
    status: deriveStatus({ ...parsed, nowMs: options.nowMs ?? Date.now() }),
  };
}

// ---------------------------------------------------------------------------
// Status source
// ---------------------------------------------------------------------------

function statusSanityCheck(status, updatedAtMs, nowMs) {
  if (!status || !Array.isArray(status.components)) {
    throw new Error('status page: derived status has no components');
  }
  if (!OVERALL_STATUSES.includes(status.overall)) {
    throw new Error(`status page: invalid overall status "${status.overall}"`);
  }
  if (status.components.length === 0) {
    throw new Error('status page: no components after derivation');
  }
  for (const component of status.components) {
    if (!COMPONENT_STATUSES.includes(component.status)) {
      throw new Error(`status page: invalid component status "${component.status}"`);
    }
    if (typeof component.name !== 'string' || component.name.trim() === '') {
      throw new Error('status page: component name is empty');
    }
  }
  if (updatedAtMs != null) {
    const age = nowMs - updatedAtMs;
    if (age > 7 * 24 * 3600 * 1000) {
      throw new Error('status page: embedded data is more than 7 days old');
    }
    if (age < -10 * 60 * 1000) {
      throw new Error('status page: embedded data timestamp is in the future');
    }
  }
}

/**
 * Fetch + parse the status page. Returns `{ status, updatedAtMs }`.
 * Throws with a human-readable message on any failure (caller degrades).
 */
export async function collectStatus(options = {}) {
  const {
    fetchImpl = globalThis.fetch,
    url = STATUS_URL,
    timeoutMs = SOURCE_TIMEOUT_MS,
    nowMs = Date.now(),
  } = options;
  const res = await fetchWithTimeout(url, {
    fetchImpl,
    timeoutMs,
    headers: {
      accept: 'text/html,application/xhtml+xml',
      'accept-language': 'en',
      'user-agent': USER_AGENT,
    },
  });
  if (!res.ok) throw new Error(`status page: HTTP ${res.status}`);
  const html = typeof res.text === 'function' ? await res.text() : '';
  const parsed = parseStatusPage(html, { nowMs });
  const status = deriveStatus({ ...parsed, nowMs });
  statusSanityCheck(status, parsed.updatedAtMs, nowMs);
  return { status, updatedAtMs: parsed.updatedAtMs };
}

// ---------------------------------------------------------------------------
// Latency source
// ---------------------------------------------------------------------------

/** p50 (median) of a numeric sample list; rounds even-length medians. */
export function computeP50(samples) {
  const values = (samples || [])
    .map(Number)
    .filter((n) => Number.isFinite(n) && n >= 0)
    .sort((a, b) => a - b);
  if (values.length === 0) return null;
  const mid = Math.floor(values.length / 2);
  if (values.length % 2 === 1) return Math.round(values[mid]);
  return Math.round((values[mid - 1] + values[mid]) / 2);
}

/** Build the SPEC §4 latency object from successful probe samples. */
export function summarizeLatency(samples, { endpoint = LATENCY_ENDPOINT, checkedAt = nowIso() } = {}) {
  const ok = samples.length > 0;
  return {
    ok,
    ms: ok ? samples[samples.length - 1] : null,
    p50_ms: ok ? computeP50(samples) : null,
    samples: samples.length,
    endpoint,
    checked_at: checkedAt,
  };
}

/**
 * Five sequential GET probes. A 401/403 (no key) counts as reachable; 5xx,
 * timeouts and network errors count as failed probes. Never throws.
 * Returns `{ latency, errors }`.
 */
export async function collectLatency(options = {}) {
  const {
    fetchImpl = globalThis.fetch,
    url = LATENCY_URL,
    endpoint = LATENCY_ENDPOINT,
    probes = LATENCY_PROBES,
    perProbeTimeoutMs = LATENCY_PROBE_TIMEOUT_MS,
    budgetMs = LATENCY_SOURCE_BUDGET_MS,
    nowMsFn = Date.now,
  } = options;

  const samples = [];
  const errors = [];
  const startedAt = nowMsFn();

  for (let i = 0; i < probes; i += 1) {
    const remaining = budgetMs - (nowMsFn() - startedAt);
    if (remaining <= 50) {
      errors.push('latency: source budget exhausted');
      break;
    }
    const probeStart = nowMsFn();
    try {
      const res = await fetchWithTimeout(url, {
        fetchImpl,
        timeoutMs: Math.min(perProbeTimeoutMs, remaining),
        method: 'GET',
        headers: { accept: 'application/json', 'user-agent': USER_AGENT },
      });
      const status = Number(res && res.status);
      // Drain the body so the keep-alive socket is reusable for the next probe.
      if (res && typeof res.text === 'function') {
        try {
          await res.text();
        } catch {
          // body drain failure does not invalidate an observed response
        }
      }
      const elapsed = Math.max(1, Math.round(nowMsFn() - probeStart));
      if (!Number.isFinite(status) || status >= 500) {
        errors.push(`latency: HTTP ${status}`);
        continue;
      }
      samples.push(elapsed);
    } catch (err) {
      errors.push(`latency: ${errorText(err)}`);
    }
  }

  return {
    latency: summarizeLatency(samples, {
      endpoint,
      checkedAt: nowIso(nowMsFn()),
    }),
    errors,
  };
}

// ---------------------------------------------------------------------------
// Balance source
// ---------------------------------------------------------------------------

/**
 * Validate the balance JSON returned by api.deepseek.com. A fresh key belongs
 * in `env` only; the returned object contains the masked hint, never the key.
 * `balance_infos` may hold several currencies — prefer USD (the pricing table's
 * currency), otherwise the first entry.
 */
export function mapBalance(json, { key = '', httpStatus = 200 } = {}) {
  if (httpStatus === 401 || httpStatus === 403) {
    return { available: false, reason: 'unauthorized' };
  }
  if (json == null || typeof json !== 'object' || Array.isArray(json)) {
    // The task's contract: a null/absent balance payload means unauthorized.
    return { available: false, reason: 'unauthorized' };
  }
  if (json.is_available !== true) {
    return { available: false, reason: 'not_available' };
  }
  const infos = Array.isArray(json.balance_infos) ? json.balance_infos : [];
  if (infos.length === 0) {
    return { available: false, reason: 'bad_payload' };
  }
  const info =
    infos.find(
      (entry) => entry && String(entry.currency || '').toUpperCase() === 'USD',
    ) || infos[0];
  const total = finiteNumber(info.total_balance);
  const topUp = finiteNumber(info.topped_up_balance);
  const granted = finiteNumber(info.granted_balance);
  const currency =
    typeof info.currency === 'string' && info.currency.trim()
      ? info.currency.trim().toUpperCase()
      : null;
  if (total == null || topUp == null || granted == null || currency == null) {
    return { available: false, reason: 'bad_payload' };
  }
  return {
    available: true,
    currency,
    total: round2(total),
    top_up: round2(topUp),
    granted: round2(granted),
    key_hint: maskKey(key),
  };
}

/**
 * Optional balance collection. Never throws. Without DEEPSEEK_API_KEY the HTTP
 * request is NOT attempted (task contract).
 */
export async function collectBalance(options = {}) {
  const {
    fetchImpl = globalThis.fetch,
    env = process.env,
    url = BALANCE_URL,
    timeoutMs = SOURCE_TIMEOUT_MS,
  } = options;
  const key = typeof env.DEEPSEEK_API_KEY === 'string' ? env.DEEPSEEK_API_KEY.trim() : '';
  if (!key) {
    return { balance: { available: false, reason: 'no_api_key' }, errors: [] };
  }
  let res;
  try {
    res = await fetchWithTimeout(url, {
      fetchImpl,
      timeoutMs,
      headers: {
        authorization: `Bearer ${key}`,
        accept: 'application/json',
        'user-agent': USER_AGENT,
      },
    });
  } catch (err) {
    return {
      balance: { available: false, reason: 'network_error' },
      errors: [`balance: ${errorText(err)}`],
    };
  }
  const httpStatus = Number(res && res.status);
  if (httpStatus === 401 || httpStatus === 403) {
    return { balance: { available: false, reason: 'unauthorized' }, errors: [] };
  }
  if (!res || !res.ok) {
    return {
      balance: { available: false, reason: `http_${httpStatus}` },
      errors: [`balance: HTTP ${httpStatus}`],
    };
  }
  let json = null;
  try {
    json = typeof res.json === 'function' ? await res.json() : null;
  } catch {
    json = null;
  }
  const balance = mapBalance(json, { key, httpStatus });
  const errors =
    balance.reason === 'bad_payload'
      ? ['balance: unexpected payload from /user/balance']
      : [];
  return { balance, errors };
}

// ---------------------------------------------------------------------------
// Age / staleness helpers (SPEC §4 age policy)
// ---------------------------------------------------------------------------

/**
 * Classify a `generated_at` timestamp.
 *   < 2 min  → state "live"
 *   2–15 min → state "aged"   (dimmed, show "updated 4m ago")
 *   > 15 min → state "stale"  (offer retry)
 *   missing  → state "unavailable"
 */
export function ageState(generatedAt, nowMs = Date.now()) {
  const parsed = typeof generatedAt === 'string' ? Date.parse(generatedAt) : NaN;
  if (!Number.isFinite(parsed)) {
    return { state: 'unavailable', age_ms: null, label: 'no data' };
  }
  const age = Math.max(0, nowMs - parsed);
  if (age < AGE_LIVE_MS) {
    return { state: 'live', age_ms: age, label: null };
  }
  const label = `updated ${formatAge(age)} ago`;
  if (age <= AGE_STALE_MS) {
    return { state: 'aged', age_ms: age, label };
  }
  return { state: 'stale', age_ms: age, label };
}

export function formatAge(ageMs) {
  if (!Number.isFinite(ageMs) || ageMs < 0) return '0m';
  const totalMinutes = Math.floor(ageMs / 60000);
  if (totalMinutes < 1) return 'just now';
  if (totalMinutes < 60) return `${totalMinutes}m`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours < 24) return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const restHours = hours % 24;
  return restHours ? `${days}d ${restHours}h` : `${days}d`;
}

// ---------------------------------------------------------------------------
// Schema validation (SPEC §4, schema v1)
// ---------------------------------------------------------------------------

const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

function isIsoUtc(value) {
  return typeof value === 'string' && ISO_RE.test(value) && !Number.isNaN(Date.parse(value));
}

function isPlainObject(value) {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Structural validator for schema v1. Returns `{ ok, errors }`.
 *
 * The one tolerated deviation: the “nothing was ever collected” state may be
 * represented by `generated_at: null` together with `status`/`latency`/`balance`
 * all `null` and an `error` string (see docs/metrics.md). Every value the
 * collector itself writes has a real `generated_at`.
 */
export function validateMetrics(metrics) {
  const errors = [];
  const bad = (message) => errors.push(message);

  if (!isPlainObject(metrics)) {
    return { ok: false, errors: ['metrics.json must be a JSON object'] };
  }
  if (metrics.schema !== SCHEMA_VERSION) {
    bad(`schema must be ${SCHEMA_VERSION}`);
  }
  if (typeof metrics.source !== 'string' || metrics.source.length === 0) {
    bad('source must be a non-empty string');
  }

  const allSourcesNull =
    metrics.status == null && metrics.latency == null && metrics.balance == null;
  if (metrics.generated_at == null) {
    if (!allSourcesNull) bad('generated_at is required unless all sources are null');
  } else if (!isIsoUtc(metrics.generated_at)) {
    bad('generated_at must be an ISO-8601 UTC string (e.g. 2026-10-30T09:12:00Z)');
  }

  if (metrics.status != null) {
    const status = metrics.status;
    if (!isPlainObject(status)) {
      bad('status must be an object or null');
    } else {
      if (!OVERALL_STATUSES.includes(status.overall)) {
        bad(`status.overall must be one of ${OVERALL_STATUSES.join('|')}`);
      }
      if (typeof status.label !== 'string') bad('status.label must be a string');
      if (!Array.isArray(status.components)) {
        bad('status.components must be an array');
      } else {
        if (status.components.length > MAX_COMPONENTS) {
          bad(`status.components must contain at most ${MAX_COMPONENTS} items`);
        }
        status.components.forEach((component, index) => {
          const where = `status.components[${index}]`;
          if (!isPlainObject(component)) {
            bad(`${where} must be an object`);
            return;
          }
          if (typeof component.id !== 'string' || !component.id) {
            bad(`${where}.id must be a non-empty string`);
          }
          if (typeof component.name !== 'string' || !component.name) {
            bad(`${where}.name must be a non-empty string`);
          }
          if (!COMPONENT_STATUSES.includes(component.status)) {
            bad(`${where}.status must be one of ${COMPONENT_STATUSES.join('|')}`);
          }
          if (component.uptime != null) {
            if (typeof component.uptime !== 'number' || !Number.isFinite(component.uptime)) {
              bad(`${where}.uptime must be a number or null`);
            } else if (component.uptime < 0 || component.uptime > 100) {
              bad(`${where}.uptime must be between 0 and 100`);
            }
          }
        });
      }
      if (!Number.isInteger(status.active_incidents) || status.active_incidents < 0) {
        bad('status.active_incidents must be a non-negative integer');
      }
    }
  }

  if (metrics.latency != null) {
    const latency = metrics.latency;
    if (!isPlainObject(latency)) {
      bad('latency must be an object or null');
    } else {
      if (typeof latency.ok !== 'boolean') bad('latency.ok must be a boolean');
      if (!Number.isInteger(latency.samples) || latency.samples < 0) {
        bad('latency.samples must be a non-negative integer');
      }
      if (latency.ok) {
        if (typeof latency.ms !== 'number' || !Number.isFinite(latency.ms)) {
          bad('latency.ms must be a finite number when latency.ok is true');
        }
        if (typeof latency.p50_ms !== 'number' || !Number.isFinite(latency.p50_ms)) {
          bad('latency.p50_ms must be a finite number when latency.ok is true');
        }
      } else {
        if (latency.ms !== null) bad('latency.ms must be null when latency.ok is false');
        if (latency.p50_ms !== null) {
          bad('latency.p50_ms must be null when latency.ok is false');
        }
      }
      if (typeof latency.endpoint !== 'string' || !latency.endpoint) {
        bad('latency.endpoint must be a non-empty string');
      }
      if (!isIsoUtc(latency.checked_at)) {
        bad('latency.checked_at must be an ISO-8601 UTC string');
      }
    }
  }

  if (metrics.balance != null) {
    const balance = metrics.balance;
    if (!isPlainObject(balance)) {
      bad('balance must be an object or null');
    } else {
      if (typeof balance.available !== 'boolean') {
        bad('balance.available must be a boolean');
      } else if (balance.available) {
        if (typeof balance.currency !== 'string' || !/^[A-Z]{3}$/.test(balance.currency)) {
          bad('balance.currency must be a 3-letter uppercase code when available');
        }
        for (const field of ['total', 'top_up', 'granted']) {
          if (typeof balance[field] !== 'number' || !Number.isFinite(balance[field])) {
            bad(`balance.${field} must be a finite number when available`);
          }
        }
        if (typeof balance.key_hint !== 'string' || !balance.key_hint.startsWith('sk-…')) {
          bad('balance.key_hint must be a masked string starting with "sk-…" when available');
        }
      } else if (typeof balance.reason !== 'string' || !balance.reason) {
        bad('balance.reason must be a non-empty string when not available');
      }
    }
  }

  if (metrics.error != null && typeof metrics.error !== 'string') {
    bad('error must be null or a string');
  }
  if (metrics.warnings != null) {
    if (!Array.isArray(metrics.warnings)) {
      bad('warnings must be an array when present');
    } else if (metrics.warnings.some((warning) => typeof warning !== 'string')) {
      bad('warnings must contain only strings');
    }
  }

  return { ok: errors.length === 0, errors };
}

// ---------------------------------------------------------------------------
// Metrics assembly
// ---------------------------------------------------------------------------

export function unknownStatus(reason = 'status page unavailable') {
  return {
    overall: 'unknown',
    label: STATUS_LABELS.unknown,
    components: [],
    active_incidents: 0,
    _reason: reason,
  };
}

/**
 * Load the previous metrics.json as a last-good baseline. Only trustworthy
 * values are reused; anything involving an `unknown` / failed source is
 * skipped so a stale failure can never mask a real recovery.
 */
export function extractLastGood(metrics) {
  if (!isPlainObject(metrics) || metrics.schema !== SCHEMA_VERSION) return null;
  const status =
    isPlainObject(metrics.status) &&
    OVERALL_STATUSES.includes(metrics.status.overall) &&
    metrics.status.overall !== 'unknown' &&
    Array.isArray(metrics.status.components) &&
    metrics.status.components.length > 0
      ? metrics.status
      : null;
  const latency =
    isPlainObject(metrics.latency) &&
    metrics.latency.ok === true &&
    typeof metrics.latency.ms === 'number'
      ? metrics.latency
      : null;
  const balance =
    isPlainObject(metrics.balance) && metrics.balance.available === true
      ? metrics.balance
      : null;
  if (!status && !latency && !balance) return null;
  return {
    generated_at: typeof metrics.generated_at === 'string' ? metrics.generated_at : null,
    status,
    latency,
    balance,
  };
}

export async function loadLastGood(outFile) {
  try {
    const raw = await readFile(resolve(outFile), 'utf8');
    return extractLastGood(JSON.parse(raw));
  } catch {
    return null;
  }
}

function staleWarning(source, error, lastGood) {
  const snapshot = lastGood && lastGood.generated_at ? lastGood.generated_at : 'an earlier run';
  return `stale_source:${source} — source failed this cycle (${error}); serving last-good snapshot from ${snapshot}`;
}

/**
 * Run one collection cycle and (optionally) atomically write the metrics file.
 * Sources run concurrently; each is independently failure-tolerant.
 *
 * @returns {Promise<{metrics: object, warnings: string[], errors: string[], wrote: boolean}>}
 */
export async function collectOnce(options = {}) {
  const {
    outFile = DEFAULT_OUT,
    fetchImpl = globalThis.fetch,
    env = process.env,
    nowMs = Date.now(),
    lastGood = null,
    urls = {},
    timeouts = {},
    write = true,
  } = options;

  const warnings = [];
  const errors = [];

  const statusTask = collectStatus({
    fetchImpl,
    nowMs,
    url: urls.status ?? STATUS_URL,
    timeoutMs: timeouts.status ?? SOURCE_TIMEOUT_MS,
  });
  const latencyTask = collectLatency({
    fetchImpl,
    url: urls.latency ?? LATENCY_URL,
    budgetMs: timeouts.latencyBudget ?? LATENCY_SOURCE_BUDGET_MS,
    perProbeTimeoutMs: timeouts.latencyProbe ?? LATENCY_PROBE_TIMEOUT_MS,
  });
  const balanceTask = collectBalance({
    fetchImpl,
    env,
    url: urls.balance ?? BALANCE_URL,
    timeoutMs: timeouts.balance ?? SOURCE_TIMEOUT_MS,
  });

  const [statusResult, latencyResult, balanceResult] = await Promise.allSettled([
    statusTask,
    latencyTask,
    balanceTask,
  ]);

  // --- status -------------------------------------------------------------
  let status;
  if (statusResult.status === 'fulfilled') {
    status = statusResult.value.status;
  } else {
    const message = errorText(statusResult.reason);
    errors.push(`status: ${message}`);
    if (lastGood && lastGood.status) {
      status = lastGood.status;
      warnings.push(staleWarning('status', message, lastGood));
    } else {
      status = unknownStatus(message);
    }
  }
  if (status && '_reason' in status) delete status._reason;

  // --- latency ------------------------------------------------------------
  let latency;
  if (latencyResult.status === 'fulfilled') {
    latency = latencyResult.value.latency;
    for (const message of latencyResult.value.errors) errors.push(message);
    if (!latency.ok && lastGood && lastGood.latency) {
      latency = lastGood.latency;
      warnings.push(
        staleWarning('latency', latencyResult.value.errors.join('; ') || 'all probes failed', lastGood),
      );
    }
  } else {
    const message = errorText(latencyResult.reason);
    errors.push(`latency: ${message}`);
    if (lastGood && lastGood.latency) {
      latency = lastGood.latency;
      warnings.push(staleWarning('latency', message, lastGood));
    } else {
      latency = {
        ok: false,
        ms: null,
        p50_ms: null,
        samples: 0,
        endpoint: LATENCY_ENDPOINT,
        checked_at: nowIso(nowMs),
      };
    }
  }

  // --- balance ------------------------------------------------------------
  let balance;
  if (balanceResult.status === 'fulfilled') {
    balance = balanceResult.value.balance;
    for (const message of balanceResult.value.errors) errors.push(message);
  } else {
    const message = errorText(balanceResult.reason);
    errors.push(`balance: ${message}`);
    if (lastGood && lastGood.balance) {
      balance = lastGood.balance;
      warnings.push(staleWarning('balance', message, lastGood));
    } else {
      balance = { available: false, reason: 'internal_error' };
    }
  }

  const metrics = {
    schema: SCHEMA_VERSION,
    generated_at: nowIso(nowMs),
    source: STATUS_SOURCE,
    status,
    latency,
    balance,
    error: errors.length > 0 ? errors.join('; ') : null,
    warnings,
  };

  const validation = validateMetrics(metrics);
  if (!validation.ok) {
    // Never write a file consumers cannot trust.
    const message = `internal: built metrics failed schema validation: ${validation.errors.join('; ')}`;
    const fallback = {
      schema: SCHEMA_VERSION,
      generated_at: nowIso(nowMs),
      source: STATUS_SOURCE,
      status: unknownStatus(message),
      latency: {
        ok: false,
        ms: null,
        p50_ms: null,
        samples: 0,
        endpoint: LATENCY_ENDPOINT,
        checked_at: nowIso(nowMs),
      },
      balance: { available: false, reason: 'internal_error' },
      error: message,
      warnings,
    };
    if (write) await writeMetrics(outFile, fallback);
    return { metrics: fallback, warnings, errors: [message], wrote: write };
  }

  if (write) await writeMetrics(outFile, metrics);
  return { metrics, warnings, errors, wrote: write };
}

// ---------------------------------------------------------------------------
// Atomic JSON output
// ---------------------------------------------------------------------------

/**
 * Write `value` atomically: temp file in the same directory, then rename(2).
 * Readers therefore always observe either the previous or the new document.
 */
export async function atomicWriteJson(file, value) {
  const target = resolve(file);
  await mkdir(dirname(target), { recursive: true });
  const tmp = `${target}.tmp.${process.pid}.${Date.now()}`;
  const body = `${JSON.stringify(value, null, 2)}\n`;
  try {
    await writeFile(tmp, body, { encoding: 'utf8', mode: 0o644 });
    await rename(tmp, target);
  } catch (err) {
    try {
      await unlink(tmp);
    } catch {
      // best-effort cleanup
    }
    throw err;
  }
  return target;
}

export async function writeMetrics(outFile, metrics) {
  return atomicWriteJson(outFile, metrics);
}

// ---------------------------------------------------------------------------
// Local HTTP server (`--serve`)
// ---------------------------------------------------------------------------

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Cache-Control',
};
const NO_STORE = 'no-store';

function send(res, statusCode, headers, body) {
  res.writeHead(statusCode, headers);
  res.end(body);
}

/**
 * Create the tiny read-only metrics server. `metrics.json` is read from disk
 * on every request so the file can be re-collected while the server runs.
 */
export function createMetricsServer(options = {}) {
  const {
    outFile = DEFAULT_OUT,
    nowMsFn = Date.now,
    startedAt = nowMsFn(),
    log = logEvent,
  } = options;

  return createServer(async (req, res) => {
    const method = req.method || 'GET';
    let pathname = '/';
    try {
      pathname = new URL(req.url || '/', 'http://localhost').pathname;
    } catch {
      pathname = '/';
    }

    if (method === 'OPTIONS') {
      send(res, 204, { ...CORS_HEADERS, 'Cache-Control': NO_STORE }, '');
      return;
    }
    if (method !== 'GET' && method !== 'HEAD') {
      send(
        res,
        405,
        {
          ...CORS_HEADERS,
          'Cache-Control': NO_STORE,
          'Content-Type': 'application/json; charset=utf-8',
          Allow: 'GET, HEAD, OPTIONS',
        },
        JSON.stringify({ error: 'method_not_allowed' }),
      );
      return;
    }

    if (pathname === '/health') {
      let present = false;
      let generatedAt = null;
      try {
        const raw = await readFile(resolve(outFile), 'utf8');
        const parsed = JSON.parse(raw);
        present = true;
        generatedAt =
          parsed && typeof parsed.generated_at === 'string' ? parsed.generated_at : null;
      } catch {
        present = false;
      }
      const body = JSON.stringify({
        status: 'ok',
        out: outFile,
        metrics_present: present,
        generated_at: generatedAt,
        uptime_s: round1((nowMsFn() - startedAt) / 1000),
      });
      send(
        res,
        200,
        {
          ...CORS_HEADERS,
          'Cache-Control': NO_STORE,
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Length': Buffer.byteLength(body),
        },
        method === 'HEAD' ? '' : body,
      );
      return;
    }

    if (pathname === '/metrics.json' || pathname === '/') {
      let body;
      try {
        body = await readFile(resolve(outFile), 'utf8');
      } catch (err) {
        const missing = err && err.code === 'ENOENT';
        const payload = JSON.stringify({
          error: missing ? 'metrics_not_collected' : 'metrics_read_failed',
          out: outFile,
        });
        log('serve_error', { path: pathname, code: err && err.code ? err.code : 'unknown' });
        send(
          res,
          missing ? 404 : 500,
          {
            ...CORS_HEADERS,
            'Cache-Control': NO_STORE,
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Length': Buffer.byteLength(payload),
          },
          method === 'HEAD' ? '' : payload,
        );
        return;
      }
      send(
        res,
        200,
        {
          ...CORS_HEADERS,
          'Cache-Control': NO_STORE,
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Length': Buffer.byteLength(body),
        },
        method === 'HEAD' ? '' : body,
      );
      return;
    }

    const payload = JSON.stringify({ error: 'not_found', path: pathname });
    send(
      res,
      404,
      {
        ...CORS_HEADERS,
        'Cache-Control': NO_STORE,
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(payload),
      },
      method === 'HEAD' ? '' : payload,
    );
  });
}

export function startServer(options = {}) {
  const {
    port = DEFAULT_SERVE_PORT,
    host = DEFAULT_SERVE_HOST,
    outFile = DEFAULT_OUT,
  } = options;
  const server = createMetricsServer({ outFile });
  return new Promise((resolvePromise, rejectPromise) => {
    server.once('error', rejectPromise);
    server.listen(port, host, () => {
      server.removeListener('error', rejectPromise);
      resolvePromise(server);
    });
  });
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

export class ConfigError extends Error {}

const USAGE = `DeepSeek Tracker metrics collector (schema v1)

Usage:
  node collector/status-collector.mjs [options]

Options:
  --once                Collect one cycle and exit (default).
  --interval <seconds>  Collect continuously, sleeping <seconds> between cycles.
  --out <path>          Output file. Default: ${DEFAULT_OUT}
  --serve [port]        Serve the metrics JSON over HTTP on
                        ${DEFAULT_SERVE_HOST}:<port> (default ${DEFAULT_SERVE_PORT}).
                        With --interval: collect and serve.
                        With --once: collect once, then serve.
                        Alone: serve the file already on disk.
  --help                Show this help.

Environment:
  DEEPSEEK_API_KEY      Optional. Enables the /user/balance source. The key is
                        never written to metrics.json (only "sk-…abcd").

Logs: one JSON line per cycle on stderr ({"event":"cycle",...}).
Exit: non-zero only for fatal configuration errors.
`;

/** Parse argv into options; throws ConfigError on invalid input. */
export function parseArgs(argv = []) {
  const options = {
    once: false,
    interval: null,
    out: DEFAULT_OUT,
    serve: false,
    servePort: DEFAULT_SERVE_PORT,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else if (arg === '--once') {
      options.once = true;
    } else if (arg === '--interval' || arg.startsWith('--interval=')) {
      const raw = arg.includes('=') ? arg.slice(arg.indexOf('=') + 1) : argv[(i += 1)];
      const seconds = Number(raw);
      if (!Number.isFinite(seconds) || seconds <= 0) {
        throw new ConfigError(`--interval requires a positive number of seconds (got "${raw}")`);
      }
      options.interval = seconds;
    } else if (arg === '--out' || arg.startsWith('--out=')) {
      const raw = arg.includes('=') ? arg.slice(arg.indexOf('=') + 1) : argv[(i += 1)];
      if (!raw || typeof raw !== 'string') throw new ConfigError('--out requires a path');
      options.out = raw;
    } else if (arg === '--serve' || arg.startsWith('--serve=')) {
      options.serve = true;
      let raw = null;
      if (arg.includes('=')) {
        raw = arg.slice(arg.indexOf('=') + 1);
      } else if (i + 1 < argv.length && /^\d+$/.test(argv[i + 1])) {
        raw = argv[(i += 1)];
      }
      if (raw != null) {
        const port = Number(raw);
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          throw new ConfigError(`--serve port must be an integer in 1..65535 (got "${raw}")`);
        }
        options.servePort = port;
      }
    } else {
      throw new ConfigError(`unknown argument "${arg}" (try --help)`);
    }
  }
  if (options.once && options.interval != null) {
    throw new ConfigError('--once and --interval are mutually exclusive');
  }
  return options;
}

function collectOptionsFromCli(options, lastGood) {
  return {
    outFile: options.out,
    lastGood,
    nowMs: Date.now(),
  };
}

async function runCycle(options, lastGoodRef) {
  const started = performance.now();
  let result;
  try {
    result = await collectOnce(collectOptionsFromCli(options, lastGoodRef.value));
  } catch (err) {
    logEvent('cycle', {
      ms: Math.round(performance.now() - started),
      overall: 'unknown',
      latency_ms: null,
      error: errorText(err),
    });
    return;
  }
  lastGoodRef.value = extractLastGood(result.metrics) || lastGoodRef.value;
  const { metrics } = result;
  logEvent('cycle', {
    ms: Math.round(performance.now() - started),
    overall: metrics.status ? metrics.status.overall : 'unknown',
    latency_ms: metrics.latency ? metrics.latency.ms : null,
    components: metrics.status ? metrics.status.components.length : 0,
    active_incidents: metrics.status ? metrics.status.active_incidents : 0,
    warnings: result.warnings.length,
    error: metrics.error,
  });
}

function installSignalHandlers(cleanup) {
  let done = false;
  const handler = async (signal) => {
    if (done) return;
    done = true;
    logEvent('shutdown', { signal });
    try {
      await cleanup();
    } finally {
      process.exit(0);
    }
  };
  process.once('SIGINT', () => handler('SIGINT'));
  process.once('SIGTERM', () => handler('SIGTERM'));
}

/**
 * CLI entry point. Resolves with an exit code for finite modes; infinite modes
 * keep the process alive via a listening server / sleep loop and resolve only
 * after SIGINT/SIGTERM.
 */
export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);

  if (options.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  const nodeMajor = Number(process.versions.node.split('.')[0]);
  if (nodeMajor < 20) {
    throw new ConfigError(`Node >= 20 is required (running ${process.version})`);
  }

  // Validate that we can write the output before touching the network.
  const outTarget = resolve(options.out);
  try {
    await mkdir(dirname(outTarget), { recursive: true });
  } catch (err) {
    throw new ConfigError(`cannot create output directory for "${options.out}": ${errorText(err)}`);
  }

  const lastGoodRef = { value: await loadLastGood(options.out) };
  const servers = [];

  if (options.serve) {
    let server;
    try {
      server = await startServer({ port: options.servePort, outFile: options.out });
    } catch (err) {
      throw new ConfigError(
        `cannot listen on ${DEFAULT_SERVE_HOST}:${options.servePort}: ${errorText(err)}`,
      );
    }
    servers.push(server);
    logEvent('serve', {
      url: `http://${DEFAULT_SERVE_HOST}:${options.servePort}/metrics.json`,
      health: `http://${DEFAULT_SERVE_HOST}:${options.servePort}/health`,
      out: options.out,
    });
  }

  installSignalHandlers(async () => {
    for (const server of servers) {
      await new Promise((res) => server.close(res));
    }
  });

  const runOne = () => runCycle(options, lastGoodRef);

  // Serve-only: no collection loop (the file is re-read on each request).
  if (options.serve && options.interval == null && !options.once) {
    return 0;
  }

  if (options.interval == null) {
    await runOne();
    if (!options.serve) return 0;
    // --serve --once: collect once, then keep serving.
    return 0;
  }

  await runOne();
  while (true) {
    await sleep(options.interval * 1000);
    await runOne();
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const invokedDirectly =
  process.argv[1] != null &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) {
  main()
    .then((code) => {
      if (typeof code === 'number' && code !== 0) process.exitCode = code;
    })
    .catch((err) => {
      if (err instanceof ConfigError) {
        logEvent('fatal', { error: err.message });
      } else {
        logEvent('fatal', { error: errorText(err), stack: err && err.stack ? String(err.stack) : null });
      }
      process.exitCode = 1;
    });
}
