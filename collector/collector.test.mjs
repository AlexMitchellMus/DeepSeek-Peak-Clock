/**
 * Offline test suite for the DeepSeek Tracker metrics collector.
 *
 * Run with:  node --test collector/
 *
 * Everything here is deterministic and network-free. The status-page parser is
 * exercised against a gzip copy of the real page (`fixtures/status-page.html.gz`,
 * captured 2026-10-30) plus synthetic payloads for edge cases.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
} from 'node:fs';
import { promises as fsp } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  AGE_LIVE_MS,
  AGE_STALE_MS,
  COMPONENT_STATUSES,
  LATENCY_ENDPOINT,
  MAX_COMPONENTS,
  OVERALL_STATUSES,
  SCHEMA_VERSION,
  STATUS_SOURCE,
  ageState,
  atomicWriteJson,
  cleanComponentName,
  collectBalance,
  collectLatency,
  collectOnce,
  collectStatus,
  computeP50,
  deriveStatus,
  errorText,
  extractFlightPayload,
  extractLastGood,
  formatAge,
  loadLastGood,
  maskKey,
  mapBalance,
  nowIso,
  parseStatusPage,
  statusFromHtml,
  summarizeLatency,
  validateMetrics,
} from './status-collector.mjs';

// ---------------------------------------------------------------------------
// Fixtures / helpers
// ---------------------------------------------------------------------------

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const SCRATCH = join(ROOT, '.tmp', 'collector-test');

rmSync(SCRATCH, { recursive: true, force: true });
mkdirSync(SCRATCH, { recursive: true });

const STATUS_HTML = gunzipSync(
  readFileSync(join(HERE, 'fixtures', 'status-page.html.gz')),
).toString('utf8');

/** Epoch seconds from the saved page: 2026-10-30T09:06:58.067Z. */
const PAGE_UPDATED_AT_MS = 1793351218067;
/** A deterministic "now" two seconds after the saved page snapshot. */
const SNAPSHOT_NOW_MS = PAGE_UPDATED_AT_MS + 2000;

function loadFixture(name) {
  return JSON.parse(readFileSync(join(ROOT, 'metrics', 'fixtures', `${name}.json`), 'utf8'));
}

function mockResponse(status, body = '', { json } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => body,
    json: async () => {
      if (json !== undefined) return json;
      return JSON.parse(body);
    },
  };
}

function htmlResponse(html) {
  return mockResponse(200, html);
}

function jsonResponse(json, status = 200) {
  return mockResponse(status, JSON.stringify(json), { json });
}

function resolveHandler(handler, url, init) {
  if (typeof handler === 'function') return handler(url, init);
  return handler;
}

/**
 * Fake fetch with per-source routing. `handlers` keys: status, latency, balance.
 * Each value is either a Response-like object or a function returning one.
 */
function makeFetch(handlers = {}) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    const target = String(url);
    calls.push({ url: target, init });
    if (target.includes('status.deepseek.com')) {
      return resolveHandler(handlers.status, target, init);
    }
    if (target.includes('/user/balance')) {
      return resolveHandler(handlers.balance, target, init);
    }
    if (target.includes('api.deepseek.com')) {
      return resolveHandler(handlers.latency, target, init);
    }
    throw new Error(`unexpected fetch URL: ${target}`);
  };
  fetchImpl.calls = calls;
  fetchImpl.callCount = () => calls.length;
  return fetchImpl;
}

/** Build HTML containing one or more `self.__next_f.push` flight chunks. */
function flightHtml(chunks) {
  const scripts = chunks
    .map((chunk) => `self.__next_f.push(${JSON.stringify([1, chunk])})`)
    .join(';');
  return `<html><body><script>${scripts}</script></body></html>`;
}

function syntheticPage(overrides = {}) {
  return {
    page_id: 1,
    name: 'DeepSeek',
    components: [
      {
        component_id: 'c-v4-flash',
        name: 'DeepSeek V4.1 Flash API服务(API Service)',
        order_id: 1,
      },
    ],
    sections: [],
    ...overrides,
  };
}

function syntheticStatusData(overrides = {}) {
  return {
    section_uptimes: [],
    section_impacts: [],
    component_impacts: [],
    component_uptimes: [{ component_id: 'c-v4-flash', uptime: 99.9 }],
    linked_changes: [],
    ...overrides,
  };
}

function isoAgeMs(generatedAt, referenceIso) {
  return Date.parse(referenceIso) - Date.parse(generatedAt);
}

const VALID_LATENCY = {
  ok: true,
  ms: 200,
  p50_ms: 190,
  samples: 5,
  endpoint: 'api.deepseek.com',
  checked_at: '2026-10-30T09:12:00Z',
};

// ---------------------------------------------------------------------------
// Flight-payload parser (real page)
// ---------------------------------------------------------------------------

test('extractFlightPayload finds the real page flight data', () => {
  const { payload, chunks } = extractFlightPayload(STATUS_HTML);
  assert.equal(chunks, 1);
  assert.ok(payload.length > 10_000);
  assert.ok(payload.includes('"initialPageConfig":'));
  assert.ok(payload.includes('"initialData":'));
  assert.ok(payload.includes('"initialCalendarData":'));
});

test('parseStatusPage extracts page config, uptimes, impacts and calendar from the real page', () => {
  const parsed = parseStatusPage(STATUS_HTML, { nowMs: SNAPSHOT_NOW_MS });

  assert.equal(parsed.page.components.length, 7);
  assert.equal(parsed.page.sections.length, 1);
  assert.ok(Array.isArray(parsed.statusData.component_uptimes));
  assert.equal(parsed.statusData.component_uptimes.length, 7);
  assert.ok(Array.isArray(parsed.statusData.component_impacts));
  assert.ok(parsed.statusData.component_impacts.length > 0);
  assert.ok(Array.isArray(parsed.calendarData.changes));
  assert.ok(parsed.calendarData.changes.length > 0);
  assert.equal(parsed.updatedAtMs, PAGE_UPDATED_AT_MS);
});

test('parseStatusPage concatenates a flight payload split over multiple pushes', () => {
  const pageConfigLiteral = `3b:["$","$L44",null,{"pageId":1,"initialPageConfig":${JSON.stringify(
    syntheticPage(),
  )}}]\n`;
  const statusLiteral = `3a:["$","$L44",null,{"initialData":${JSON.stringify(
    syntheticStatusData(),
  )},"initialDataUpdatedAt":1793351218067}]\n`;
  const html = flightHtml([pageConfigLiteral, statusLiteral]);

  const parsed = parseStatusPage(html, { nowMs: SNAPSHOT_NOW_MS });
  assert.equal(parsed.page.components.length, 1);
  assert.equal(parsed.statusData.component_uptimes[0].uptime, 99.9);
  assert.equal(parsed.updatedAtMs, PAGE_UPDATED_AT_MS);
});

test('parseStatusPage throws (never fabricates) when the page shape is wrong', () => {
  assert.throws(() => extractFlightPayload('<html>no flight data</html>'), /flight payload/);
  assert.throws(
    () =>
      parseStatusPage(
        flightHtml([`3b:["$","$L44",null,{"initialPageConfig":${JSON.stringify(
          syntheticPage(),
        )}}]`]),
      ),
    /uptime\/impact data/,
  );
  assert.throws(
    () => parseStatusPage(flightHtml([`3b:["$","$L44",null,{"initialData":{}}]`])),
    /page configuration/,
  );
  assert.throws(
    () =>
      parseStatusPage(
        flightHtml([
          `3b:{"initialPageConfig":${JSON.stringify(syntheticPage())},"initialData":${JSON.stringify(
            syntheticStatusData(),
          )}}`,
        ]).slice(0, 120),
      ),
    /flight payload/,
  );
});

test('statusFromHtml derives the live state from the real saved page', () => {
  const { status, updatedAtMs } = statusFromHtml(STATUS_HTML, { nowMs: SNAPSHOT_NOW_MS });
  assert.equal(updatedAtMs, PAGE_UPDATED_AT_MS);
  assert.equal(status.overall, 'operational');
  assert.equal(status.label, 'All systems operational');
  assert.equal(status.active_incidents, 0);
  assert.equal(status.components.length, MAX_COMPONENTS);
  for (const component of status.components) {
    assert.equal(component.status, 'operational');
    assert.equal(typeof component.uptime, 'number');
  }
});

test('component names are short English labels (Chinese parentheticals stripped)', () => {
  const { status } = statusFromHtml(STATUS_HTML, { nowMs: SNAPSHOT_NOW_MS });
  const names = status.components.map((component) => component.name);
  assert.deepEqual(names.slice(0, 4), [
    'DeepSeek V4 Pro API',
    'DeepSeek V4.1 Flash API',
    'Search API Service',
    'Fetch API Service',
  ]);
  for (const name of names) {
    assert.ok(!name.includes('服务'), `unexpected Chinese suffix in ${name}`);
    assert.ok(!name.includes('(API Service)'), `unexpected parenthetical in ${name}`);
    assert.ok(name.length > 2);
  }
});

test('cleanComponentName handles the page labels and edge cases', () => {
  assert.equal(
    cleanComponentName('DeepSeek V4.1 Flash API服务(API Service)'),
    'DeepSeek V4.1 Flash API',
  );
  assert.equal(cleanComponentName('DeepSeek V4 Pro API服务(API Service)'), 'DeepSeek V4 Pro API');
  assert.equal(cleanComponentName('搜索API服务(Search API Service)'), 'Search API Service');
  assert.equal(cleanComponentName('抓取API服务(Fetch API Service)'), 'Fetch API Service');
  assert.equal(cleanComponentName('上传文件服务(File Upload Service)'), 'File Upload Service');
  assert.equal(cleanComponentName('对话服务(Chatservice)'), 'Chat Service');
  assert.equal(cleanComponentName('对话服务(Chat Service)'), 'Chat Service');
  assert.equal(cleanComponentName('   '), 'Unknown component');
  assert.equal(cleanComponentName(null), 'Unknown component');
});

test('status order is stable: standalone API components first, then sections', () => {
  const { status } = statusFromHtml(STATUS_HTML, { nowMs: SNAPSHOT_NOW_MS });
  assert.equal(status.components[0].name, 'DeepSeek V4 Pro API');
  assert.equal(status.components[1].name, 'DeepSeek V4.1 Flash API');
  // Section children come after the standalone API services.
  assert.ok(status.components.findIndex((c) => c.name === 'Chat Service') >= 4);
  // The 7th page component is beyond the SPEC cap.
  assert.ok(status.components.length <= MAX_COMPONENTS);
});

test('historical snapshot: an active degraded impact surfaces as overall degraded', () => {
  // component_impacts row (V4 Pro): 1793084859 → 1793085714, status degraded.
  const nowMs = 1_793_085_000_000;
  const { status } = statusFromHtml(STATUS_HTML, { nowMs });
  assert.equal(status.overall, 'degraded');
  assert.equal(status.active_incidents, 1);
  const flash = status.components.find((c) => c.id === '01KY4MVS8BM3F9JSYWACGQVG7A');
  assert.equal(flash.status, 'degraded');
});

test('historical snapshot: a section partial_outage degrades every component in the section', () => {
  // section_impacts row 1792488015 → 1792488533, status partial_outage.
  const nowMs = 1_792_488_200_000;
  const { status } = statusFromHtml(STATUS_HTML, { nowMs });
  assert.equal(status.overall, 'partial_outage');
  assert.equal(status.active_incidents, 1);
  const chat = status.components.find((c) => c.name === 'Chat Service');
  assert.equal(chat.status, 'partial_outage');
  // Section uptime is the fallback but component uptime exists, so it wins.
  assert.equal(chat.uptime, 99.62);
});

test('overall status uses full_outage > partial_outage > degraded > operational', () => {
  const page = syntheticPage({
    components: [
      { component_id: 'a', name: 'A', order_id: 1 },
      { component_id: 'b', name: 'B', order_id: 2 },
      { component_id: 'c', name: 'C', order_id: 3 },
    ],
  });
  const statusData = syntheticStatusData({
    component_uptimes: [],
    component_impacts: [
      { component_id: 'a', start_at_seconds: 1_000, end_at_seconds: 2_000, status: 'degraded', change_id: 1 },
      { component_id: 'b', start_at_seconds: 1_000, end_at_seconds: 2_000, status: 'partial_outage', change_id: 2 },
    ],
  });
  const status = deriveStatus({ page, statusData, nowMs: 1_500_000 });
  assert.equal(status.overall, 'partial_outage');
  assert.equal(status.active_incidents, 2);

  statusData.component_impacts.push({
    component_id: 'c',
    start_at_seconds: 1_000,
    end_at_seconds: 2_000,
    status: 'full_outage',
    change_id: 3,
  });
  const worse = deriveStatus({ page, statusData, nowMs: 1_500_000 });
  assert.equal(worse.overall, 'full_outage');
  assert.equal(worse.components.find((c) => c.id === 'c').status, 'full_outage');
});

test('scheduled maintenance is reported as overall maintenance only when nothing worse is active', () => {
  const page = syntheticPage();
  const statusData = syntheticStatusData();
  const nowMs = 1_500_000;
  const calendarData = {
    changes: [
      {
        change_id: 99,
        type: 'maintenance',
        status: 'scheduled',
        start_at_seconds: 1_000,
        close_at_seconds: 2_000,
      },
    ],
  };
  const maintenance = deriveStatus({ page, statusData, calendarData, nowMs });
  assert.equal(maintenance.overall, 'maintenance');

  statusData.component_impacts.push({
    component_id: 'c-v4-flash',
    start_at_seconds: 1_000,
    end_at_seconds: 2_000,
    status: 'full_outage',
    change_id: 100,
  });
  const outage = deriveStatus({ page, statusData, calendarData, nowMs });
  assert.equal(outage.overall, 'full_outage');
});

test('unknown status is emitted when parsing fails; collectStatus rejects', async () => {
  const fetchImpl = makeFetch({ status: htmlResponse('<html>not a status page</html>') });
  await assert.rejects(() => collectStatus({ fetchImpl, nowMs: SNAPSHOT_NOW_MS }), /flight payload/);
});

test('collectStatus fetches and parses the page (mock fetch)', async () => {
  const fetchImpl = makeFetch({ status: htmlResponse(STATUS_HTML) });
  const { status, updatedAtMs } = await collectStatus({ fetchImpl, nowMs: SNAPSHOT_NOW_MS });
  assert.equal(updatedAtMs, PAGE_UPDATED_AT_MS);
  assert.equal(status.overall, 'operational');
  assert.equal(fetchImpl.calls.length, 1);
  assert.ok(fetchImpl.calls[0].url.includes('status.deepseek.com'));
});

test('collectStatus rejects on HTTP errors', async () => {
  const fetchImpl = makeFetch({ status: mockResponse(503, 'down') });
  await assert.rejects(() => collectStatus({ fetchImpl }), /HTTP 503/);
});

// ---------------------------------------------------------------------------
// Latency reducer + source
// ---------------------------------------------------------------------------

test('computeP50 returns the median (odd + even sample counts)', () => {
  assert.equal(computeP50([100, 200, 300, 400, 500]), 300);
  assert.equal(computeP50([500, 100, 300]), 300);
  assert.equal(computeP50([100, 200, 300, 400]), 250);
  assert.equal(computeP50([42]), 42);
  assert.equal(computeP50([]), null);
  assert.equal(computeP50(null), null);
  assert.equal(computeP50(['x', NaN, -1, 50]), 50);
});

test('summarizeLatency reports latest ms, p50, sample count and endpoint', () => {
  const latency = summarizeLatency([210, 190, 180, 200, 220], {
    endpoint: LATENCY_ENDPOINT,
    checkedAt: '2026-10-30T09:12:00Z',
  });
  assert.equal(latency.ok, true);
  assert.equal(latency.ms, 220);
  assert.equal(latency.p50_ms, 200);
  assert.equal(latency.samples, 5);
  assert.equal(latency.endpoint, 'api.deepseek.com');
  assert.equal(latency.checked_at, '2026-10-30T09:12:00Z');
});

test('collectLatency performs 5 sequential probes and a 401 counts as reachable', async () => {
  const fetchImpl = makeFetch({ latency: mockResponse(401, '{"error":"no key"}') });
  const { latency, errors } = await collectLatency({ fetchImpl, nowMsFn: () => Date.now() });
  assert.equal(latency.ok, true);
  assert.equal(latency.samples, 5);
  assert.ok(latency.ms >= 1);
  assert.ok(latency.p50_ms >= 1);
  assert.equal(latency.endpoint, 'api.deepseek.com');
  assert.match(latency.checked_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.deepEqual(errors, []);
  assert.equal(fetchImpl.calls.length, 5);
});

test('collectLatency tolerates a failed probe and still reports ok', async () => {
  let probe = 0;
  const fetchImpl = makeFetch({
    latency: () => {
      probe += 1;
      if (probe === 2) throw new Error('ECONNRESET');
      return mockResponse(401, '');
    },
  });
  const { latency, errors } = await collectLatency({ fetchImpl });
  assert.equal(latency.ok, true);
  assert.equal(latency.samples, 4);
  assert.ok(errors.some((e) => e.includes('ECONNRESET')));
});

test('collectLatency reports ok=false when every probe fails', async () => {
  const fetchImpl = makeFetch({
    latency: () => {
      throw new Error('ENETDOWN');
    },
  });
  const { latency, errors } = await collectLatency({ fetchImpl });
  assert.equal(latency.ok, false);
  assert.equal(latency.ms, null);
  assert.equal(latency.p50_ms, null);
  assert.equal(latency.samples, 0);
  assert.equal(errors.length, 5);
});

test('collectLatency treats 5xx responses as failed probes', async () => {
  const fetchImpl = makeFetch({ latency: mockResponse(503, 'busy') });
  const { latency, errors } = await collectLatency({ fetchImpl });
  assert.equal(latency.ok, false);
  assert.equal(latency.samples, 0);
  assert.ok(errors.some((e) => e.includes('HTTP 503')));
});

test('collectLatency enforces the 3s-style per-probe timeout via AbortController', async () => {
  const fetchImpl = async (url, { signal }) =>
    new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    });
  const { latency, errors } = await collectLatency({
    fetchImpl,
    perProbeTimeoutMs: 15,
    budgetMs: 500,
    probes: 2,
  });
  assert.equal(latency.ok, false);
  assert.equal(errors.length, 2);
  assert.ok(errors.every((e) => /timeout/i.test(e)));
});

test('collectLatency stops probing when the source budget is exhausted', async () => {
  const fetchImpl = makeFetch({ latency: mockResponse(401, '') });
  const { latency, errors } = await collectLatency({ fetchImpl, budgetMs: 10 });
  assert.equal(latency.ok, false);
  assert.equal(fetchImpl.calls.length, 0);
  assert.ok(errors.some((e) => e.includes('budget exhausted')));
});

// ---------------------------------------------------------------------------
// Balance mapper
// ---------------------------------------------------------------------------

test('maskKey never exposes more than the last four characters', () => {
  assert.equal(maskKey('sk-abcdef1234abcd'), 'sk-…abcd');
  assert.equal(maskKey('abcd'), 'sk-…abcd');
  assert.equal(maskKey(''), 'sk-…');
  assert.equal(maskKey(undefined), 'sk-…');
});

test('mapBalance maps the SPEC §4 balance object (and prefers USD)', () => {
  const json = {
    is_available: true,
    balance_infos: [
      {
        currency: 'CNY',
        total_balance: '999.99',
        granted_balance: '10.00',
        topped_up_balance: '989.99',
      },
      {
        currency: 'USD',
        total_balance: '12.34',
        granted_balance: '2.34',
        topped_up_balance: '10.00',
      },
    ],
  };
  const balance = mapBalance(json, { key: 'sk-test-secret-abcd' });
  assert.deepEqual(balance, {
    available: true,
    currency: 'USD',
    total: 12.34,
    top_up: 10,
    granted: 2.34,
    key_hint: 'sk-…abcd',
  });
});

test('mapBalance: 401/403 and null payloads mean unauthorized', () => {
  assert.deepEqual(mapBalance(null, { key: 'sk-x', httpStatus: 200 }), {
    available: false,
    reason: 'unauthorized',
  });
  assert.deepEqual(mapBalance({ is_available: true }, { httpStatus: 401 }), {
    available: false,
    reason: 'unauthorized',
  });
  assert.deepEqual(mapBalance({ is_available: true }, { httpStatus: 403 }), {
    available: false,
    reason: 'unauthorized',
  });
});

test('mapBalance: invalid payload shapes degrade cleanly', () => {
  assert.deepEqual(mapBalance({ is_available: false }), {
    available: false,
    reason: 'not_available',
  });
  assert.deepEqual(mapBalance({ is_available: true, balance_infos: [] }), {
    available: false,
    reason: 'bad_payload',
  });
  assert.deepEqual(
    mapBalance({
      is_available: true,
      balance_infos: [{ currency: 'USD', total_balance: 'NaN', granted_balance: '1', topped_up_balance: '1' }],
    }),
    { available: false, reason: 'bad_payload' },
  );
});

test('collectBalance does not attempt a request when DEEPSEEK_API_KEY is unset', async () => {
  const fetchImpl = makeFetch({});
  const { balance, errors } = await collectBalance({ fetchImpl, env: {} });
  assert.deepEqual(balance, { available: false, reason: 'no_api_key' });
  assert.deepEqual(errors, []);
  assert.equal(fetchImpl.calls.length, 0);
});

test('collectBalance maps 401 to unauthorized without leaking the key', async () => {
  const fetchImpl = makeFetch({ balance: mockResponse(401, 'nope') });
  const { balance } = await collectBalance({
    fetchImpl,
    env: { DEEPSEEK_API_KEY: 'sk-test-secret-abcd' },
  });
  assert.deepEqual(balance, { available: false, reason: 'unauthorized' });
  assert.ok(!JSON.stringify(balance).includes('sk-test-secret-abcd'));
});

test('collectBalance parses a valid /user/balance response', async () => {
  const payload = {
    is_available: true,
    balance_infos: [
      { currency: 'USD', total_balance: '12.34', granted_balance: '2.34', topped_up_balance: '10.00' },
    ],
  };
  const fetchImpl = makeFetch({ balance: jsonResponse(payload) });
  const { balance, errors } = await collectBalance({
    fetchImpl,
    env: { DEEPSEEK_API_KEY: 'sk-test-secret-abcd' },
  });
  assert.equal(balance.available, true);
  assert.equal(balance.currency, 'USD');
  assert.equal(balance.total, 12.34);
  assert.equal(balance.key_hint, 'sk-…abcd');
  assert.deepEqual(errors, []);
  assert.ok(fetchImpl.calls[0].init.headers.authorization.startsWith('Bearer sk-'));
});

test('collectBalance reports network errors as unavailable, never throwing', async () => {
  const fetchImpl = makeFetch({
    balance: () => {
      throw new Error('ECONNREFUSED');
    },
  });
  const { balance, errors } = await collectBalance({
    fetchImpl,
    env: { DEEPSEEK_API_KEY: 'sk-test-secret-abcd' },
  });
  assert.deepEqual(balance, { available: false, reason: 'network_error' });
  assert.ok(errors[0].includes('ECONNREFUSED'));
});

// ---------------------------------------------------------------------------
// Age / staleness helpers
// ---------------------------------------------------------------------------

test('ageState implements the SPEC age policy boundaries', () => {
  const now = Date.parse('2026-10-30T09:20:00Z');
  assert.equal(ageState('2026-10-30T09:19:59Z', now).state, 'live');
  assert.equal(ageState('2026-10-30T09:18:00Z', now).state, 'aged');
  assert.equal(ageState('2026-10-30T09:18:00Z', now).label, 'updated 2m ago');
  // Exactly 15 minutes is still "aged"; one second later is stale.
  assert.equal(ageState('2026-10-30T09:05:00Z', now).state, 'aged');
  assert.equal(ageState('2026-10-30T09:04:59Z', now).state, 'stale');
  assert.equal(ageState('2026-10-30T09:10:00Z', now).label, 'updated 10m ago');
  assert.equal(ageState(null, now).state, 'unavailable');
  assert.equal(ageState('not-a-date', now).state, 'unavailable');
  // Clock skew should not mark a future timestamp stale.
  assert.equal(ageState('2026-10-30T09:21:00Z', now).state, 'live');
  assert.equal(AGE_LIVE_MS, 2 * 60 * 1000);
  assert.equal(AGE_STALE_MS, 15 * 60 * 1000);
});

test('formatAge produces compact human labels', () => {
  assert.equal(formatAge(30_000), 'just now');
  assert.equal(formatAge(4 * 60_000), '4m');
  assert.equal(formatAge(90 * 60_000), '1h 30m');
  assert.equal(formatAge(60 * 60_000), '1h');
  assert.equal(formatAge((24 + 2) * 60 * 60_000), '1d 2h');
  assert.equal(formatAge(-5), '0m');
  assert.equal(formatAge(NaN), '0m');
});

test('nowIso emits second-precision ISO-8601 UTC', () => {
  assert.equal(nowIso(Date.parse('2026-10-30T09:12:00.987Z')), '2026-10-30T09:12:00Z');
});

// ---------------------------------------------------------------------------
// Schema validator
// ---------------------------------------------------------------------------

test('schema v1 validator accepts the live fixture', () => {
  const live = loadFixture('live');
  const result = validateMetrics(live);
  assert.deepEqual(result, { ok: true, errors: [] });
});

test('schema v1 validator rejects malformed documents field by field', () => {
  const cases = [
    ['not an object', null],
    ['schema', { ...loadFixture('live'), schema: 2 }],
    ['generated_at', { ...loadFixture('live'), generated_at: 'yesterday' }],
    ['source', { ...loadFixture('live'), source: '' }],
    ['overall enum', (() => {
      const m = structuredClone(loadFixture('live'));
      m.status.overall = 'onfire';
      return m;
    })()],
    ['component status enum', (() => {
      const m = structuredClone(loadFixture('live'));
      m.status.components[0].status = 'melted';
      return m;
    })()],
    ['component uptime type', (() => {
      const m = structuredClone(loadFixture('live'));
      m.status.components[0].uptime = '99%';
      return m;
    })()],
    ['component uptime range', (() => {
      const m = structuredClone(loadFixture('live'));
      m.status.components[0].uptime = 101;
      return m;
    })()],
    ['component cap', (() => {
      const m = structuredClone(loadFixture('live'));
      m.status.components = Array.from({ length: 7 }, (_, i) => ({
        id: `c${i}`,
        name: `C${i}`,
        status: 'operational',
        uptime: 100,
      }));
      return m;
    })()],
    ['active_incidents', (() => {
      const m = structuredClone(loadFixture('live'));
      m.status.active_incidents = -1;
      return m;
    })()],
    ['latency ok/ms consistency', (() => {
      const m = structuredClone(loadFixture('live'));
      m.latency.ms = null;
      return m;
    })()],
    ['latency samples', (() => {
      const m = structuredClone(loadFixture('live'));
      m.latency.samples = -2;
      return m;
    })()],
    ['latency checked_at', (() => {
      const m = structuredClone(loadFixture('live'));
      m.latency.checked_at = 'whenever';
      return m;
    })()],
    ['balance currency', (() => {
      const m = structuredClone(loadFixture('live'));
      m.balance.currency = 'dollars';
      return m;
    })()],
    ['balance numbers', (() => {
      const m = structuredClone(loadFixture('live'));
      m.balance.total = '12.34';
      return m;
    })()],
    ['balance reason', (() => {
      const m = structuredClone(loadFixture('live'));
      m.balance = { available: false };
      return m;
    })()],
    ['error type', { ...loadFixture('live'), error: 42 }],
    ['warnings type', { ...loadFixture('live'), warnings: 'oops' }],
    ['warnings entries', { ...loadFixture('live'), warnings: [42] }],
  ];
  for (const [label, value] of cases) {
    const result = validateMetrics(value);
    assert.equal(result.ok, false, `expected ${label} to be rejected`);
    assert.ok(result.errors.length > 0);
  }
});

test('schema validator accepts ok:false latency and unavailable balance', () => {
  const metrics = {
    schema: SCHEMA_VERSION,
    generated_at: '2026-10-30T09:12:00Z',
    source: STATUS_SOURCE,
    status: {
      overall: 'unknown',
      label: 'Status unknown',
      components: [],
      active_incidents: 0,
    },
    latency: {
      ok: false,
      ms: null,
      p50_ms: null,
      samples: 0,
      endpoint: LATENCY_ENDPOINT,
      checked_at: '2026-10-30T09:12:00Z',
    },
    balance: { available: false, reason: 'no_api_key' },
    error: 'status: timeout',
    warnings: ['stale_source:status — test'],
  };
  assert.deepEqual(validateMetrics(metrics), { ok: true, errors: [] });
});

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const FIXTURE_NAMES = ['live', 'stale', 'unavailable', 'degraded'];

test('all four fixtures are valid JSON documents', () => {
  for (const name of FIXTURE_NAMES) {
    const fixture = loadFixture(name);
    assert.equal(typeof fixture, 'object');
    assert.equal(fixture.schema, SCHEMA_VERSION);
  }
});

test('live / stale / degraded fixtures satisfy the schema', () => {
  for (const name of ['live', 'stale', 'degraded']) {
    const result = validateMetrics(loadFixture(name));
    assert.deepEqual(result, { ok: true, errors: [] }, `${name}.json must validate`);
  }
});

test('unavailable fixture models "nothing was ever collected" (documented null shape)', () => {
  const unavailable = loadFixture('unavailable');
  assert.equal(unavailable.status, null);
  assert.equal(unavailable.latency, null);
  assert.equal(unavailable.balance, null);
  assert.equal(unavailable.generated_at, null);
  assert.equal(typeof unavailable.error, 'string');
  assert.deepEqual(validateMetrics(unavailable), { ok: true, errors: [] });
});

test('fixture timestamps are fixed and stale.json is 20+ minutes old with error:null', () => {
  const live = loadFixture('live');
  const stale = loadFixture('stale');
  assert.equal(live.generated_at, '2026-10-30T09:12:00Z');
  assert.equal(stale.generated_at, '2026-10-30T08:45:00Z');
  assert.equal(stale.error, null);
  const age = isoAgeMs(stale.generated_at, live.generated_at);
  assert.ok(age >= 20 * 60 * 1000, `stale fixture must be 20+ min old, got ${age}ms`);
  assert.equal(ageState(stale.generated_at, Date.parse(live.generated_at)).state, 'stale');
});

test('degraded fixture has an active incident and exactly one partial_outage component', () => {
  const degraded = loadFixture('degraded');
  assert.ok(degraded.status.active_incidents >= 1);
  const partial = degraded.status.components.filter((c) => c.status === 'partial_outage');
  assert.equal(partial.length, 1);
  // Severity derives upward: one partial_outage component ⇒ overall partial_outage.
  assert.equal(degraded.status.overall, 'partial_outage');
  assert.notEqual(degraded.status.overall, 'operational');
  assert.ok(degraded.status.components.length <= MAX_COMPONENTS);
  for (const name of new Set([...(degraded.status.components.map((c) => c.status))])) {
    assert.ok(COMPONENT_STATUSES.includes(name));
  }
});

test('every fixture status enum is in the SPEC §4 contract', () => {
  for (const name of ['live', 'stale', 'degraded']) {
    const fixture = loadFixture(name);
    assert.ok(OVERALL_STATUSES.includes(fixture.status.overall));
    for (const component of fixture.status.components) {
      assert.ok(COMPONENT_STATUSES.includes(component.status));
    }
  }
});

// ---------------------------------------------------------------------------
// Atomic writes
// ---------------------------------------------------------------------------

test('atomicWriteJson creates parent directories and leaves no temp files', async () => {
  const file = join(SCRATCH, 'atomic', 'nested', 'metrics.json');
  await atomicWriteJson(file, { hello: 'world' });
  const parsed = JSON.parse(await fsp.readFile(file, 'utf8'));
  assert.deepEqual(parsed, { hello: 'world' });
  const leftovers = readdirSync(dirname(file)).filter((entry) => entry.includes('.tmp.'));
  assert.deepEqual(leftovers, []);
});

test('concurrent readers never observe a partial metrics.json', async () => {
  const file = join(SCRATCH, 'atomic-race', 'metrics.json');
  await atomicWriteJson(file, { n: 0, pad: '' });
  const writes = (async () => {
    for (let n = 1; n <= 40; n += 1) {
      await atomicWriteJson(file, { n, pad: 'x'.repeat(4096) });
    }
  })();
  const reads = [];
  for (let i = 0; i < 80; i += 1) {
    reads.push(fsp.readFile(file, 'utf8').then((text) => JSON.parse(text)));
  }
  await writes;
  const snapshots = await Promise.all(reads);
  for (const snapshot of snapshots) {
    assert.equal(typeof snapshot.n, 'number');
    assert.equal(snapshot.pad.length, snapshot.n === 0 ? 0 : 4096);
  }
  const leftovers = readdirSync(dirname(file)).filter((entry) => entry.includes('.tmp.'));
  assert.deepEqual(leftovers, []);
});

// ---------------------------------------------------------------------------
// collectOnce end-to-end (offline)
// ---------------------------------------------------------------------------

const FAST_NOW_MS = PAGE_UPDATED_AT_MS + 2000;

test('collectOnce builds a schema-valid document, writes atomically and logs no errors', async () => {
  const outFile = join(SCRATCH, 'cycle', 'metrics.json');
  const fetchImpl = makeFetch({
    status: htmlResponse(STATUS_HTML),
    latency: mockResponse(401, ''),
  });
  const result = await collectOnce({
    outFile,
    fetchImpl,
    env: {},
    nowMs: FAST_NOW_MS,
    lastGood: null,
  });

  assert.deepEqual(validateMetrics(result.metrics), { ok: true, errors: [] });
  assert.equal(result.metrics.status.overall, 'operational');
  assert.equal(result.metrics.status.components.length, MAX_COMPONENTS);
  assert.equal(result.metrics.balance.reason, 'no_api_key');
  assert.equal(result.metrics.latency.samples, 5);
  assert.equal(result.metrics.error, null);
  assert.deepEqual(result.warnings, []);
  assert.equal(result.metrics.generated_at, nowIso(FAST_NOW_MS));
  assert.equal(result.metrics.source, 'status.deepseek.com');

  const written = JSON.parse(await fsp.readFile(outFile, 'utf8'));
  assert.deepEqual(written, result.metrics);
  // No /user/balance call without a key.
  assert.ok(!fetchImpl.calls.some((call) => call.url.includes('/user/balance')));
});

test('collectOnce degrades to overall unknown on a first-run status failure', async () => {
  const outFile = join(SCRATCH, 'first-failure', 'metrics.json');
  const fetchImpl = makeFetch({
    status: () => {
      throw new Error('status page down');
    },
    latency: mockResponse(401, ''),
  });
  const result = await collectOnce({ outFile, fetchImpl, env: {}, nowMs: FAST_NOW_MS });
  assert.equal(result.metrics.status.overall, 'unknown');
  assert.equal(result.metrics.status.components.length, 0);
  assert.match(result.metrics.error, /status: status page down/);
  assert.deepEqual(validateMetrics(result.metrics), { ok: true, errors: [] });
});

test('collectOnce keeps the last-good status and marks stale_source in warnings', async () => {
  const outFile = join(SCRATCH, 'stale-status', 'metrics.json');
  const lastGood = extractLastGood(loadFixture('live'));
  const fetchImpl = makeFetch({
    status: () => {
      throw new Error('boom');
    },
    latency: mockResponse(401, ''),
  });
  const result = await collectOnce({
    outFile,
    fetchImpl,
    env: {},
    nowMs: FAST_NOW_MS,
    lastGood,
  });
  assert.equal(result.metrics.status.overall, 'operational');
  assert.equal(result.metrics.status.components.length, MAX_COMPONENTS);
  assert.ok(result.warnings.some((warning) => warning.startsWith('stale_source:status')));
  assert.match(result.metrics.error, /status: boom/);
  assert.deepEqual(validateMetrics(result.metrics), { ok: true, errors: [] });
});

test('collectOnce keeps the last-good latency and marks stale_source:latency', async () => {
  const outFile = join(SCRATCH, 'stale-latency', 'metrics.json');
  const lastGood = extractLastGood(loadFixture('live'));
  const fetchImpl = makeFetch({
    status: htmlResponse(STATUS_HTML),
    latency: () => {
      throw new Error('no network');
    },
  });
  const result = await collectOnce({
    outFile,
    fetchImpl,
    env: {},
    nowMs: FAST_NOW_MS,
    lastGood,
  });
  assert.equal(result.metrics.latency.ok, true);
  assert.equal(result.metrics.latency.ms, lastGood.latency.ms);
  assert.ok(result.warnings.some((warning) => warning.startsWith('stale_source:latency')));
  assert.deepEqual(validateMetrics(result.metrics), { ok: true, errors: [] });
});

test('collectOnce never writes the API key, only the masked hint', async () => {
  const outFile = join(SCRATCH, 'balance-key', 'metrics.json');
  const secret = 'sk-super-secret-value-abcd';
  const fetchImpl = makeFetch({
    status: htmlResponse(STATUS_HTML),
    latency: mockResponse(401, ''),
    balance: jsonResponse({
      is_available: true,
      balance_infos: [
        { currency: 'USD', total_balance: '12.34', granted_balance: '2.34', topped_up_balance: '10.00' },
      ],
    }),
  });
  const result = await collectOnce({
    outFile,
    fetchImpl,
    env: { DEEPSEEK_API_KEY: secret },
    nowMs: FAST_NOW_MS,
  });
  assert.equal(result.metrics.balance.available, true);
  assert.equal(result.metrics.balance.key_hint, 'sk-…abcd');
  const serialized = await fsp.readFile(outFile, 'utf8');
  assert.ok(!serialized.includes(secret));
  assert.ok(serialized.includes('sk-…abcd'));
  assert.ok(
    fetchImpl.calls.some(
      (call) =>
        call.url.includes('/user/balance') &&
        call.init.headers.authorization === `Bearer ${secret}`,
    ),
  );
});

test('extractLastGood ignores failed sources and handles the unavailable fixture', () => {
  assert.equal(extractLastGood(loadFixture('unavailable')), null);
  assert.equal(extractLastGood(null), null);
  const partial = {
    schema: 1,
    generated_at: '2026-10-30T09:12:00Z',
    status: { overall: 'unknown', label: 'Status unknown', components: [], active_incidents: 0 },
    latency: { ok: false, ms: null, p50_ms: null, samples: 0, endpoint: 'api.deepseek.com', checked_at: '2026-10-30T09:12:00Z' },
    balance: { available: false, reason: 'no_api_key' },
  };
  assert.equal(extractLastGood(partial), null);
  const good = extractLastGood(loadFixture('live'));
  assert.equal(good.status.overall, 'operational');
  assert.equal(good.latency.ms, 214);
  assert.equal(good.balance.available, true);
});

test('loadLastGood reads a previous file and tolerates missing/corrupt files', async () => {
  const dir = join(SCRATCH, 'last-good');
  const file = join(dir, 'metrics.json');
  await atomicWriteJson(file, loadFixture('live'));
  const good = await loadLastGood(file);
  assert.equal(good.status.overall, 'operational');
  assert.equal(await loadLastGood(join(dir, 'nope.json')), null);
  await fsp.writeFile(join(dir, 'bad.json'), '{ not json');
  assert.equal(await loadLastGood(join(dir, 'bad.json')), null);
});

test('a second collectOnce within the same store preserves atomicity (two runs in 60s)', async () => {
  const outFile = join(SCRATCH, 'double-run', 'metrics.json');
  const fetchImpl = makeFetch({
    status: htmlResponse(STATUS_HTML),
    latency: mockResponse(401, ''),
  });
  const first = await collectOnce({ outFile, fetchImpl, env: {}, nowMs: FAST_NOW_MS });
  const firstRaw = await fsp.readFile(outFile, 'utf8');

  const lastGood = await loadLastGood(outFile);
  const second = await collectOnce({
    outFile,
    fetchImpl,
    env: {},
    nowMs: FAST_NOW_MS + 30_000,
    lastGood,
  });
  const secondRaw = await fsp.readFile(outFile, 'utf8');

  assert.deepEqual(JSON.parse(firstRaw), first.metrics);
  assert.deepEqual(JSON.parse(secondRaw), second.metrics);
  assert.notEqual(first.metrics.generated_at, second.metrics.generated_at);
  assert.deepEqual(validateMetrics(JSON.parse(secondRaw)), { ok: true, errors: [] });
});

test('errorText is defensive', () => {
  assert.equal(errorText(new Error('boom')), 'boom');
  assert.equal(errorText('plain'), 'plain');
  assert.equal(errorText(null), 'unknown error');
});
