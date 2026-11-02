// Enterprise-federation 3x2 GC scenario (modes/mock/validators/tests/routing/federation-3x2-gc.sh).
//
// Runs against the clusters as the smoke leaves them (directory committed, B owns nsB1, A mounts B)
// with cluster B launched with the GC test profile (FED_3X2_B_GC_JAVA_OPTS=test, lib/fed-3x2.sh) and
// cluster A on the runtime defaults. It never starts, stops or signals anything.
//
//   G0 preflight   six members up, one jar, B's launch record carries the GC test profile and A's no
//                  GC option, /v1/gc/status on all six (B = profile, A = defaults), B owns nsB1, every
//                  A mount of B verified and available; baseline binary delete counters
//   G1 write       into nsB1: small control messages, bulk messages (several MB) and validator-hosted
//                  binaries (multipart upload); committed, present on every B member, binaries in the
//                  replicated binary index on every B member, everything readable on A through the mount
//   G2 delete      a continuous reader starts on A (control items, a sample of the doomed items and
//                  the nsB1 listing, through A's mount); every bulk message and every binary but the
//                  control ones is deleted; absent on every B member and through every A mount
//   G3 GC          up to FED_GC_SECONDS (600): every B member reports two completed full GC runs that
//                  started after the deletes, reclaimed bytes and a smaller store; binary GC released
//                  the deleted binaries (index entries gone on every B member, every member's delete
//                  counters cover them) while the control binaries stay indexed
//   G4 end state   reader stopped and judged (control never missing, never a 500, mount 503s bounded,
//                  doomed items present until deleted); B and A logically converged on what remains;
//                  control content readable on A and the control binary's bytes on B; pids unchanged
//
// Evidence: $FED_3X2_ROOT/evidence/gc-<UTC>/ in the smoke's format (manifest.json, requests.ndjson,
// snapshots/, assertions.tsv, log-scan.json, summary.json, report.md) plus gc.json (items, timeline,
// every reader read, every GC run seen per member, binary GC state). Large payloads are recorded as
// length + sha256. Exit 0 PASS, 1 FAIL (or aborted), 2 refused before any action.

import { createHash, randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';

import { compareAcrossNodes, compareExpected, readEverywhere, waitAbsentEverywhere } from './harness/oracle.mjs';
import { Abort, STATUS, configFromEnv, createFederationSession, namespaceRoot } from './federation-session.mjs';
import { buildDelete, buildWrite } from './tx.mjs';

// Mirrors FED_3X2_GC_TEST_JAVA_OPTS in modes/mock/validators/lifecycle/lib/fed-3x2.sh.
export const GC_TEST_PROFILE = Object.freeze({
  'oak.gc.tail.interval.ms': '60000',
  'oak.gc.full.interval.ms': '120000',
  'oak.gc.backoff': '0',
  'oak.gc.estimation.size.delta.bytes': '0',
  'oak.gc.binary.interval.ms': '60000',
  'oak.gc.binary.grace.ms': '60000',
  'oak.gc.binary.delete.delay.ms': '30000',
});

// Runtime defaults (somarc/jackrabbit-oak feature/consensus-gc-safety) cluster A must keep.
export const GC_RUNTIME_DEFAULTS = Object.freeze({ binaryIntervalMs: 86_400_000, fullIntervalMs: 604_800_000, tailIntervalMs: 86_400_000 });

export const GC_DEFAULTS = Object.freeze({
  binaries: 4, // validator-hosted binaries written
  binaryBytes: 20_480, // >= 16 KiB so the DataStore keeps them out of the segments; <= the small fixture (charter 4.1)
  bulkChars: 180_000, // per bulk message: under Jetty's 200000-byte form limit
  bulkWrites: 16, // bulk messages: 16 x 180000 chars ~ 2.9 MB of segment content
  controlBinaries: 1, // binaries kept (the rest are deleted)
  controlMessages: 2, // small messages kept
  gcDeadlineMs: 600_000, // from the last delete commit to segment and binary GC done
  gcPollMs: 5_000, // GC status poll: well under the 60 s slot, so no run is missed
  lingerMs: 60_000, // a deleted item still read on A this long after its delete committed is reported
  max503Fraction: 0.1, // mount_stale/mount_unavailable answers among A's control reads
  max503StreakMs: 30_000, // longest run of 503s for one A member
  maxOperations: 50, // charter 4.1: <= 50 operations for a functional campaign
  readerIntervalMs: 2_000,
});

const MOUNT_503 = new Set(['mount_stale', 'mount_unavailable']);

export const sha256Hex = (value) => createHash('sha256').update(value).digest('hex');

// -D system properties of a JVM option string (the launch record's EXTRA_JAVA_OPTS).
export function parseJavaOpts(text) {
  const props = {};
  for (const token of String(text ?? '').split(/\s+/)) {
    const match = /^-D([^=]+)=(.*)$/.exec(token);
    if (match) props[match[1]] = match[2];
  }
  return props;
}

// Which profile entries the launch options miss or set differently; [] when the profile is in force.
export function gcProfileMismatches(javaOpts, profile = GC_TEST_PROFILE) {
  const props = parseJavaOpts(javaOpts);
  return Object.entries(profile).filter(([key, value]) => props[key] !== value).map(([key, value]) => ({ expected: value, key, observed: props[key] ?? null }));
}

export const gcOptionsIn = (javaOpts) => Object.keys(parseJavaOpts(javaOpts)).filter((key) => key.startsWith('oak.gc.'));

// Shape problems of a GET /v1/gc/status body; [] when it has the segment block (and a binary block or null).
export function gcStatusProblems(body) {
  const problems = [];
  const segment = body?.segment;
  if (!segment || typeof segment !== 'object') return ['no segment block'];
  for (const key of ['enabled', 'retainedGenerations', 'tailIntervalMs', 'fullIntervalMs', 'memberIndex', 'memberCount', 'memberOffsetMs']) {
    if (segment[key] === undefined || segment[key] === null) problems.push(`segment.${key} missing`);
  }
  if (!segment.lastRun || typeof segment.lastRun !== 'object') problems.push('segment.lastRun missing');
  if (!segment.nextRun || typeof segment.nextRun !== 'object') problems.push('segment.nextRun missing');
  if (!('binary' in body)) problems.push('binary key missing');
  else if (body.binary !== null && (typeof body.binary !== 'object' || !body.binary.deletes)) problems.push('binary.deletes missing');
  return problems;
}

// B's /v1/gc/status against the test profile; [] when the runtime applied every override.
export function gcTestSettingsProblems(body) {
  const s = body?.segment ?? {};
  const b = body?.binary;
  const problems = [];
  const want = (label, observed, expected) => { if (observed !== expected) problems.push(`${label}=${observed} (want ${expected})`); };
  want('segment.enabled', s.enabled, true);
  want('segment.tailIntervalMs', s.tailIntervalMs, Number(GC_TEST_PROFILE['oak.gc.tail.interval.ms']));
  want('segment.fullIntervalMs', s.fullIntervalMs, Number(GC_TEST_PROFILE['oak.gc.full.interval.ms']));
  want('segment.estimationSizeDeltaBytes', s.estimationSizeDeltaBytes, Number(GC_TEST_PROFILE['oak.gc.estimation.size.delta.bytes']));
  if (!b) problems.push('binary GC disabled (binary: null)');
  else {
    want('binary.enabled', b.enabled, true);
    want('binary.intervalMs', b.intervalMs, Number(GC_TEST_PROFILE['oak.gc.binary.interval.ms']));
    want('binary.graceMs', b.graceMs, Number(GC_TEST_PROFILE['oak.gc.binary.grace.ms']));
    want('binary.deleteDelayMs', b.deleteDelayMs, Number(GC_TEST_PROFILE['oak.gc.binary.delete.delay.ms']));
  }
  return problems;
}

// A's /v1/gc/status keeps the runtime defaults.
export function gcDefaultSettingsProblems(body) {
  const s = body?.segment ?? {};
  const problems = [];
  if (s.tailIntervalMs !== GC_RUNTIME_DEFAULTS.tailIntervalMs) problems.push(`segment.tailIntervalMs=${s.tailIntervalMs}`);
  if (s.fullIntervalMs !== GC_RUNTIME_DEFAULTS.fullIntervalMs) problems.push(`segment.fullIntervalMs=${s.fullIntervalMs}`);
  if (body?.binary && body.binary.intervalMs !== GC_RUNTIME_DEFAULTS.binaryIntervalMs) problems.push(`binary.intervalMs=${body.binary.intervalMs}`);
  return problems;
}

// Adds the last tail and full run of a status body to `history` (key type:startedAt) and returns it.
export function recordRuns(history, body) {
  for (const run of [body?.segment?.lastRun?.tail, body?.segment?.lastRun?.full]) {
    if (run && Number.isFinite(run.startedAt)) history.set(`${run.type}:${run.startedAt}`, run);
  }
  return history;
}

// Segment GC of one member after `since` (ms): >= 2 completed full runs, reclaimed bytes > 0 over all
// completed runs, and the latest completed run's sizeAfter below the earliest completed run's sizeBefore.
export function evaluateSegmentGc(runs, since, { minFullRuns = 2 } = {}) {
  const after = [...runs].filter((run) => run.startedAt >= since).sort((x, y) => x.startedAt - y.startedAt);
  const completed = after.filter((run) => run.outcome === 'completed');
  const fullCompleted = completed.filter((run) => run.type === 'full');
  const reclaimedBytes = completed.reduce((sum, run) => sum + (Number(run.reclaimedBytes) || 0), 0);
  const sized = completed.filter((run) => Number.isFinite(run.sizeBefore) && Number.isFinite(run.sizeAfter));
  const firstSizeBefore = sized.length ? sized[0].sizeBefore : null;
  const lastSizeAfter = sized.length ? sized[sized.length - 1].sizeAfter : null;
  const shrank = firstSizeBefore !== null && lastSizeAfter !== null && lastSizeAfter < firstSizeBefore;
  return {
    completedFull: fullCompleted.length,
    completedTail: completed.length - fullCompleted.length,
    firstSizeBefore,
    lastSizeAfter,
    notCompleted: after.filter((run) => run.outcome !== 'completed').map((run) => ({ outcome: run.outcome, reason: run.reason ?? run.error ?? null, startedAt: run.startedAt, type: run.type })),
    ok: fullCompleted.length >= minFullRuns && reclaimedBytes > 0 && shrank,
    reclaimedBytes,
    shrank,
  };
}

// Binary GC delete counters of one member against its G0 baseline: the deleted binaries must be
// covered by ok + absent (a member that does not hold a record counts it absent) with nothing pending.
export function evaluateBinaryDeletes(baseline, current, expected) {
  const b = baseline ?? {};
  const c = current ?? {};
  const delta = (key) => (Number(c[key]) || 0) - (Number(b[key]) || 0);
  const covered = delta('ok') + delta('absent');
  return {
    absent: delta('absent'), covered, failed: delta('failed'), ok: covered >= expected && (Number(c.pending) || 0) === 0,
    pending: Number(c.pending) || 0, skippedRecent: delta('skippedRecent'), skippedReferenced: delta('skippedReferenced'), deleted: delta('ok'),
  };
}

// The replicated binary index entry of a DataStore blob id (<sha-256>[#length]); null for other ids.
export function binaryIndexPath(blobId) {
  const identifier = String(blobId ?? '').split('#')[0].toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(identifier)) return null;
  return { identifier, path: `/:oak-chain-binaries/${identifier.slice(0, 2)}/${identifier.slice(2, 4)}/${identifier}` };
}

const mountCode = (response) => (response.status === 503 && MOUNT_503.has(response.json?.code) ? response.json.code : null);

// One A read of an item through the mount. Control and not-yet-deleted items: `content` or a mount 503
// (`stale` / `unavailable`); deleted items may also be absent (`deleted`) or still present (`content`,
// `lingering` once `lingerMs` after the delete committed). Anything else is a violation: `missing`
// (absent or wrong while it must be there), `error5xx`, `transport`, `other`.
export function classifyItemRead(response, item, { at, lingerMs = GC_DEFAULTS.lingerMs } = {}) {
  const code = mountCode(response);
  if (code) return code === 'mount_stale' ? 'stale' : 'unavailable';
  if (response.status === 0) return 'transport';
  if (response.status >= 500) return 'error5xx';
  const when = at ?? Date.now();
  const deleting = item.deleteSubmittedAt !== undefined && item.deleteSubmittedAt !== null && when >= item.deleteSubmittedAt;
  if (response.status === 404) return deleting ? 'deleted' : 'missing';
  if (response.status !== 200) return 'other';
  const props = response.json?.properties ?? {};
  const matches = item.kind === 'binary' ? props['jcr:blobId'] === item.blobId : props.message === item.message;
  if (!matches) return 'missing';
  if (deleting && item.deleteCommittedAt && when - item.deleteCommittedAt > lingerMs) return 'lingering';
  return 'content';
}

// One A read of the nsB1 listing: every control message present, or a mount 503.
export function classifyListingRead(response, controlMessages) {
  const code = mountCode(response);
  if (code) return code === 'mount_stale' ? 'stale' : 'unavailable';
  if (response.status === 0) return 'transport';
  if (response.status >= 500) return 'error5xx';
  if (response.status !== 200) return 'other';
  const items = Array.isArray(response.json?.content) ? response.json.content : [];
  return controlMessages.every((message) => items.some((entry) => entry.message === message)) ? 'content' : 'missing';
}

const VIOLATIONS = ['missing', 'error5xx', 'transport', 'other'];

// The reader's verdicts. reads: [{ at (ms), member, role: control|doomed|listing, outcome }].
export function evaluateReader(reads, { max503Fraction = GC_DEFAULTS.max503Fraction, max503StreakMs = GC_DEFAULTS.max503StreakMs } = {}) {
  const count = (rows) => rows.reduce((acc, row) => ({ ...acc, [row.outcome]: (acc[row.outcome] ?? 0) + 1 }), {});
  const control = reads.filter((read) => read.role !== 'doomed');
  const doomed = reads.filter((read) => read.role === 'doomed');
  const controlCounts = count(control);
  const doomedCounts = count(doomed);
  const unavailable = (controlCounts.stale ?? 0) + (controlCounts.unavailable ?? 0);
  // Longest span of consecutive mount 503s per A member (first to last 503 of the run).
  const streaks = {};
  for (const member of new Set(control.map((read) => read.member))) {
    let start = null;
    let longest = 0;
    for (const read of control.filter((r) => r.member === member).sort((x, y) => x.at - y.at)) {
      if (read.outcome === 'stale' || read.outcome === 'unavailable') {
        start ??= read.at;
        longest = Math.max(longest, read.at - start);
      } else start = null;
    }
    streaks[member] = longest;
  }
  const longestStreakMs = Math.max(0, ...Object.values(streaks));
  const fraction = control.length ? unavailable / control.length : 0;
  return {
    control: { counts: controlCounts, reads: control.length, violations: VIOLATIONS.reduce((n, key) => n + (controlCounts[key] ?? 0), 0) },
    doomed: { counts: doomedCounts, lingering: doomedCounts.lingering ?? 0, reads: doomed.length, violations: VIOLATIONS.reduce((n, key) => n + (doomedCounts[key] ?? 0), 0) },
    mount503: { fraction, longestStreakMs, ok: fraction <= max503Fraction && longestStreakMs <= max503StreakMs, streaks, total: unavailable },
  };
}

// Stagger diagnostics: where each completed run started inside its member's slot, and runs of
// different members that overlapped in time.
export function staggerOf(runsByMember, { periodMs, offsets }) {
  const phase = {};
  const all = [];
  for (const [member, runs] of Object.entries(runsByMember)) {
    const offset = offsets[member] ?? 0;
    phase[member] = runs.map((run) => ((run.startedAt - offset) % periodMs + periodMs) % periodMs);
    for (const run of runs) all.push({ ...run, member });
  }
  const overlaps = [];
  for (let i = 0; i < all.length; i += 1) {
    for (let j = i + 1; j < all.length; j += 1) {
      const x = all[i];
      const y = all[j];
      if (x.member !== y.member && x.startedAt < y.finishedAt && y.startedAt < x.finishedAt) overlaps.push([`${x.member}:${x.type}@${x.startedAt}`, `${y.member}:${y.type}@${y.startedAt}`]);
    }
  }
  return { maxSlotLagMs: Object.fromEntries(Object.entries(phase).map(([member, lags]) => [member, lags.length ? Math.max(...lags) : null])), overlaps, slotLagMs: phase };
}

// Deterministic alphanumeric filler (URL-encodes 1:1), so a bulk message is exactly `chars` long.
export function filler(seed, chars) {
  let out = '';
  let block = seed;
  while (out.length < chars) {
    block = sha256Hex(block);
    out += block;
  }
  return out.slice(0, chars);
}

export function gcPlan(options = {}) {
  const o = { ...GC_DEFAULTS, ...options };
  const problems = [];
  const int = (key, min, max) => { if (!Number.isInteger(o[key]) || o[key] < min || o[key] > max) problems.push(`${key}=${o[key]} (allowed ${min}..${max})`); };
  int('bulkWrites', 1, 40);
  int('bulkChars', 1_000, 190_000);
  int('controlMessages', 1, 5);
  int('binaries', 2, 8);
  int('controlBinaries', 1, Math.max(1, o.binaries - 1));
  int('binaryBytes', 16_385, 22_216);
  const writes = o.bulkWrites + o.controlMessages + o.binaries;
  const deletes = o.bulkWrites + (o.binaries - o.controlBinaries);
  if (writes + deletes > o.maxOperations) problems.push(`${writes} writes + ${deletes} deletes exceed ${o.maxOperations} operations (charter 4.1)`);
  return { deletes, options: o, problems, writes };
}

export async function runFederationGc(config, deps = {}) {
  const plan = gcPlan(config.options);
  if (plan.problems.length) throw new Error(`Refusing federation GC: ${plan.problems.join('; ')}`);
  const go = plan.options;
  // Every write/delete attempt counts against the session budget: the operations plus no_quorum retries.
  config.options = { ...config.options, maxWrites: plan.writes + plan.deletes + 10 };
  const s = createFederationSession(config, deps, { dirName: (stamp) => `gc-${stamp}`, initialPhase: 'G0', scenario: 'federation gc', title: 'Federation 3x2 GC' });
  const { A, B, addr, allMembers, assert, call, committed, federationViews, leaderOf, log, snapshot, stats, submit, waitFor, wallets } = s;
  const sleep = deps.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const now = () => Date.now();
  // a0..a2, b0..b2 by URL: cluster.members carry no cluster reference (only allMembers do).
  const labels = new Map(allMembers.map((member) => [member.url, `${member.cluster.label}${member.index}`]));
  const tag = (member) => labels.get(member.url);
  const message = (what) => `[fed gc ${s.nonce}] ${what}`;
  const facts = { binary: {}, gcSince: null, items: [], reader: null, runs: {}, settings: {}, timeline: {} };
  let aborted = null;

  // 5xx bookkeeping for tolerated reads: mount 503s on A are allowed (and counted), the rest unexpected.
  const note5xx = (label, response, { mount = false } = {}) => {
    if (response.status < 500) return;
    const row = { code: response.json?.code ?? null, label, phase: s.phase, seq: response.seq, status: response.status };
    if (mount && mountCode(response)) stats.allowed5xx.push(row);
    else stats.unexpected5xx.push(row);
  };
  // The harness oracle's http contract (src/harness/oracle.mjs) over the recorded session.
  const httpVia = (label, { mount = false } = {}) => ({
    request: async (url) => {
      const response = await call(`${label} ${url}`, 'GET', url, { tolerate: true });
      note5xx(label, response, { mount });
      return { error: response.error, json: response.json, status: response.status, text: response.text };
    },
  });
  const targetOf = (cluster) => ({ nodes: cluster.members.map((member) => ({ id: `${cluster.label}${member.index}`, url: member.url })), size: cluster.members.length });
  const explore = (member, nodePath) => `${member.url}/api/explore?path=${encodeURIComponent(nodePath)}`;
  const gcStatusOf = async (label, member) => {
    const response = await call(`${label} gc ${tag(member)}`, 'GET', `${member.url}/v1/gc/status`, { tolerate: true });
    if (response.status !== 200) {
      note5xx(label, response);
      if (response.status === 0) throw new Abort(`member down: ${member.url}/v1/gc/status did not answer [requests.ndjson#${response.seq}]`);
    }
    return response;
  };

  // ── the continuous reader on A ────────────────────────────────────────────────────────────────
  const reader = { reads: [], rounds: 0, running: false, stopRequested: false, loop: null };
  const readerItems = () => {
    const control = facts.items.filter((item) => item.role === 'control');
    const bulk = facts.items.filter((item) => item.role === 'doomed' && item.kind === 'message');
    const doomedBinaries = facts.items.filter((item) => item.role === 'doomed' && item.kind === 'binary');
    return [...control, ...new Set([bulk[0], bulk[bulk.length - 1]].filter(Boolean)), ...doomedBinaries];
  };
  const readRound = async () => {
    const controlMessages = facts.items.filter((item) => item.role === 'control' && item.kind === 'message').map((item) => item.message);
    for (const member of A.members) {
      for (const item of readerItems()) {
        const response = await call(`reader ${tag(member)} ${item.id}`, 'GET', explore(member, item.storagePath), { tolerate: true });
        // Judged at completion: a 404 that arrives before the item's delete was submitted is a violation.
        const at = now();
        note5xx('reader', response, { mount: true });
        const outcome = classifyItemRead(response, item, { at, lingerMs: go.lingerMs });
        reader.reads.push({ at, code: response.json?.code ?? null, item: item.id, member: tag(member), outcome, phase: s.phase, role: item.role, seq: response.seq, status: response.status });
      }
      const listing = await call(`reader ${tag(member)} nsB1 listing`, 'GET', `${member.url}/v1/wallets/content?wallet=${addr.nsB1}`, { tolerate: true });
      const at = now();
      note5xx('reader', listing, { mount: true });
      reader.reads.push({ at, code: listing.json?.code ?? null, item: 'listing', member: tag(member), outcome: classifyListingRead(listing, controlMessages), phase: s.phase, role: 'listing', seq: listing.seq, status: listing.status });
    }
    reader.rounds += 1;
  };
  const startReader = () => {
    reader.running = true;
    reader.startedAt = now();
    reader.loop = (async () => {
      while (!reader.stopRequested) {
        await readRound();
        if (!reader.stopRequested) await sleep(go.readerIntervalMs);
      }
    })();
  };
  const stopReader = async () => {
    if (!reader.running) return;
    reader.stopRequested = true;
    try {
      await reader.loop;
    } finally {
      reader.running = false;
      reader.stoppedAt = now();
    }
  };

  try {
    // ── G0 preflight ──────────────────────────────────────────────────────────────────────────
    s.phase = 'G0';
    log('━━ G0 preflight');
    const up = await waitFor('all members answer /health/local', async () => {
      const codes = {};
      for (const member of allMembers) codes[member.url] = (await call(`G0 health/local ${tag(member)}`, 'GET', `${member.url}/health/local`, { tolerate: true })).status;
      return { codes, done: Object.values(codes).every((code) => code === 200) };
    });
    assert('members-up', { expected: 'all 6 members answer /health/local 200', observed: up.codes, ok: up.ok });
    if (!up.ok) throw new Abort('not every member is up');
    const jarShas = s.clusters.map((cluster) => cluster.launchRecord.OAK_CONSENSUS_JAR_SHA256 || null);
    const jarOk = jarShas.every((sha) => sha && sha === jarShas[0]) && (!s.manifest.jar.sha256 || s.manifest.jar.sha256 === jarShas[0]);
    assert('same-jar', { expected: 'both launch records pin one OAK_CONSENSUS_JAR sha256 (= the env jar, when given)', observed: { env: s.manifest.jar.sha256, records: jarShas }, ok: jarShas.every(Boolean) ? jarOk : null });
    if (!jarOk) throw new Abort('the clusters do not run one recorded jar');

    const bOpts = B.launchRecord.EXTRA_JAVA_OPTS ?? '';
    const mismatches = gcProfileMismatches(bOpts);
    assert('b-launched-with-gc-profile', {
      evidence: 'manifest.json clusters[1].launchRecord', expected: GC_TEST_PROFILE,
      note: 'launch cluster B with FED_3X2_B_GC_JAVA_OPTS=test (lifecycle/start-fed-3x2.sh)', observed: mismatches.length ? mismatches : 'all present', ok: Boolean(bOpts) && mismatches.length === 0,
    });
    const aGc = gcOptionsIn(A.launchRecord.EXTRA_JAVA_OPTS ?? '');
    assert('a-launched-with-gc-defaults', { evidence: 'manifest.json clusters[0].launchRecord', expected: 'no -Doak.gc.* option in cluster A\'s EXTRA_JAVA_OPTS', observed: aGc, ok: A.launchRecord.EXTRA_JAVA_OPTS !== undefined ? aGc.length === 0 : null });
    if (mismatches.length) throw new Abort('cluster B was not launched with the GC test profile');

    const statuses = {};
    for (const member of allMembers) statuses[tag(member)] = await gcStatusOf('G0', member);
    const shapes = Object.fromEntries(Object.entries(statuses).map(([key, r]) => [key, r.status === 200 ? gcStatusProblems(r.json) : [`http ${r.status}`]]));
    assert('gc-status-present', { expected: 'GET /v1/gc/status 200 with a segment block and a binary key on all 6', observed: shapes, ok: Object.values(shapes).every((p) => p.length === 0) });
    if (!Object.values(shapes).every((p) => p.length === 0)) throw new Abort('the runtime does not serve /v1/gc/status (wrong jar?)');
    const bSettings = Object.fromEntries(B.members.map((m) => [tag(m), gcTestSettingsProblems(statuses[tag(m)].json)]));
    assert('b-gc-settings-applied', { expected: 'B members report the test profile (tail 60000, full 120000, delta 0; binary 60000/60000/30000)', observed: bSettings, ok: Object.values(bSettings).every((p) => p.length === 0) });
    const aSettings = Object.fromEntries(A.members.map((m) => [tag(m), gcDefaultSettingsProblems(statuses[tag(m)].json)]));
    assert('a-gc-settings-default', { expected: `A members report the runtime defaults (tail ${GC_RUNTIME_DEFAULTS.tailIntervalMs}, full ${GC_RUNTIME_DEFAULTS.fullIntervalMs})`, observed: aSettings, ok: Object.values(aSettings).every((p) => p.length === 0) });
    if (!Object.values(bSettings).every((p) => p.length === 0)) throw new Abort('cluster B does not run the GC test profile');
    const bSeg = B.members.map((m) => statuses[tag(m)].json.segment);
    const indexes = bSeg.map((seg) => seg.memberIndex);
    assert('b-gc-members', { expected: 'memberIndex 0..2 once each, memberCount 3', kind: 'diagnostic', observed: bSeg.map((seg) => `${seg.memberIndex}/${seg.memberCount}@${seg.memberOffsetMs}`), ok: new Set(indexes).size === 3 && bSeg.every((seg) => seg.memberCount === 3) });
    facts.settings = Object.fromEntries(Object.entries(statuses).map(([key, r]) => [key, r.json]));

    const views = await federationViews('G0 federation');
    const epochs = new Set(views.map(({ view }) => view.status?.directoryEpoch ?? null));
    const digests = new Set(views.map(({ view }) => view.directoryDigest ?? null));
    const entryB = (views[0].view.directory?.entries ?? []).find((entry) => String(entry.enterpriseId).toLowerCase() === B.enterpriseId);
    const dirOk = epochs.size === 1 && Number([...epochs][0]) >= 1 && digests.size === 1 && !digests.has(null);
    assert('directory-uniform', { expected: 'one directory epoch (>= 1) and digest on all 6 members', observed: views.map(({ member, view }) => `${tag(member)}:${view.status?.directoryEpoch}/${view.directoryDigest}`), ok: dirOk });
    const nsOk = Boolean(entryB?.namespaces?.map((n) => n.toLowerCase()).includes(addr.nsB1)) && entryB?.status === 'ACTIVE';
    assert('nsB1-owned-by-B', { expected: `enterprise B ACTIVE and owns ${addr.nsB1} (run federation-3x2-smoke.sh first)`, observed: entryB ? { namespaces: entryB.namespaces, status: entryB.status } : null, ok: nsOk });
    if (!dirOk || !nsOk) throw new Abort('the smoke\'s directory state is not committed');
    const windows = views.filter(({ member }) => member.cluster === B).map(({ member, view }) => ({ member: tag(member), readerWindowMs: view.gc?.readerWindowMs ?? null }));
    assert('b-federation-reader-window', { expected: '/v1/federation gc.readerWindowMs on B = segment.readerWindowMs', kind: 'diagnostic', observed: windows, ok: windows.every((w, i) => w.readerWindowMs !== null && w.readerWindowMs === bSeg[i].readerWindowMs) });

    const mounts = [];
    for (const member of A.members) {
      const response = await call(`G0 health ${tag(member)}`, 'GET', `${member.url}/health`);
      const mount = (response.json?.sharding?.remoteMounts ?? []).find((m) => String(m.enterpriseId ?? '').toLowerCase() === B.enterpriseId);
      mounts.push({ activeEndpoint: mount?.activeEndpoint ?? null, available: mount?.available === true, member: tag(member), seq: response.seq, verified: mount?.verified === true });
      const gcBlock = response.json?.gc;
      if (member.index === 0) assert('health-gc-block', { expected: '/health carries the gc block', kind: 'diagnostic', observed: gcBlock ? Object.keys(gcBlock) : null, ok: Boolean(gcBlock?.segment) });
    }
    assert('a-mounts-b-ready', { expected: 'every A member mounts enterprise B verified and available', observed: mounts, ok: mounts.every((m) => m.verified && m.available) });
    if (!mounts.every((m) => m.verified && m.available)) throw new Abort('A\'s mounts of enterprise B are not ready');
    const baselineDeletes = Object.fromEntries(B.members.map((m) => [tag(m), statuses[tag(m)].json.binary?.deletes ?? {}]));
    facts.binary.baseline = baselineDeletes;
    await snapshot('G0-preflight');

    // ── G1 write ─────────────────────────────────────────────────────────────────────────────
    s.phase = 'G1';
    log(`━━ G1 write: ${go.controlMessages} control + ${go.bulkWrites} bulk messages (${go.bulkChars} chars), ${go.binaries} binaries (${go.binaryBytes} bytes)`);
    const key = wallets.nsB1.privateKey;
    const items = facts.items;
    for (let i = 0; i < go.controlMessages; i += 1) items.push({ id: `control-${i}`, kind: 'message', message: message(`control message ${i}`), role: 'control' });
    for (let i = 0; i < go.bulkWrites; i += 1) {
      const head = message(`bulk ${i} `);
      items.push({ id: `bulk-${String(i).padStart(2, '0')}`, kind: 'message', message: head + filler(`${s.nonce}/${i}`, go.bulkChars - head.length), role: 'doomed' });
    }
    for (let i = 0; i < go.binaries; i += 1) {
      const role = i < go.controlBinaries ? 'control' : 'doomed';
      const bytes = randomBytes(go.binaryBytes);
      items.push({ bytes, id: `binary-${i}`, kind: 'binary', message: message(`binary ${i} (${role})`), role, sha256: sha256Hex(bytes) });
    }
    const leaderB = await leaderOf(B);
    for (const item of items) {
      const form = buildWrite({ contentType: item.kind === 'binary' ? 'file' : 'page', key, message: item.message });
      item.proposalId = form.proposalId;
      const files = item.kind === 'binary' ? [{ bytes: item.bytes, field: 'file', name: `${item.id}.bin`, type: 'application/octet-stream' }] : null;
      const response = await submit(`G1 write ${item.id}`, B, leaderB, form, '/v1/propose-write', { files });
      item.writeSeq = response.seq;
      item.storagePath = response.json?.storagePath ?? null;
      if (response.status !== 202 || !item.storagePath?.startsWith(`${namespaceRoot(addr.nsB1)}/`)) {
        assert('writes-accepted', { evidence: `requests.ndjson#${response.seq}`, expected: `202 with a storagePath under ${namespaceRoot(addr.nsB1)}`, observed: `${s.observedOf(response)} ${item.storagePath ?? ''}`, ok: false });
        throw new Abort(`write ${item.id} was not accepted`);
      }
    }
    assert('writes-accepted', { expected: `${items.length} writes 202 with storage paths under nsB1`, observed: items.length, ok: true });
    const commits = [];
    for (const item of items) {
      const done = await committed(`G1 ${item.id}`, B, item.proposalId);
      commits.push({ id: item.id, outcome: done.verdict?.outcome ?? done.state, seq: done.seq });
    }
    const allCommitted = commits.every((c) => c.outcome === 'COMMITTED');
    assert('writes-committed', { expected: 'every write COMMITTED', observed: allCommitted ? commits.length : commits.filter((c) => c.outcome !== 'COMMITTED'), ok: allCommitted });
    if (!allCommitted) throw new Abort('not every write committed');
    facts.timeline.writesCommittedAt = new Date().toISOString();

    const httpB = httpVia('G1 B read');
    const onB = await waitFor('writes present on every B member', async () => {
      const missing = [];
      for (const item of items) {
        const reads = await readEverywhere(httpB, targetOf(B), item.storagePath);
        if (!reads.every((read) => read.status === 200)) missing.push({ id: item.id, statuses: reads.map((read) => read.status) });
      }
      return { done: missing.length === 0, missing };
    });
    assert('writes-on-every-b-member', { expected: 'every item present (/api/explore 200) on all 3 B members', observed: onB.ok ? items.length : onB.missing, ok: onB.ok });
    if (!onB.ok) throw new Abort('writes did not reach every B member');

    for (const item of items.filter((x) => x.kind === 'binary')) {
      const node = await call(`G1 binary node ${item.id}`, 'GET', explore(B.members[0], item.storagePath));
      const props = node.json?.properties ?? {};
      item.blobId = props['jcr:blobId'] ?? null;
      item.ipfsCid = props.ipfsCid ?? null;
      item.storageMode = props['oak:binaryStorageMode'] ?? null;
      const index = binaryIndexPath(item.blobId);
      item.identifier = index?.identifier ?? null;
      item.indexPath = index?.path ?? null;
    }
    const binaries = items.filter((x) => x.kind === 'binary');
    assert('binaries-stored', {
      expected: 'every binary node has a <sha-256>[#length] jcr:blobId and an ipfsCid (validator-hosted, IPFS DataStore)',
      observed: binaries.map((b) => ({ blobId: b.blobId, id: b.id, ipfsCid: b.ipfsCid, mode: b.storageMode })), ok: binaries.every((b) => b.indexPath && b.ipfsCid),
    });
    assert('blob-id-is-content-sha256', { expected: 'blob identifier = sha256 of the uploaded bytes', kind: 'diagnostic', note: 'differs when IPFS encryption is on', observed: binaries.map((b) => `${b.id}:${b.identifier === b.sha256}`), ok: binaries.every((b) => b.identifier === b.sha256) });
    if (!binaries.every((b) => b.indexPath && b.ipfsCid)) throw new Abort('binaries are not stored in the IPFS DataStore with a sha-256 blob id; binary GC cannot be observed');
    const indexed = await waitFor('binary index entries on every B member', async () => {
      const rows = [];
      for (const b of binaries) rows.push({ id: b.id, statuses: (await readEverywhere(httpB, targetOf(B), b.indexPath)).map((read) => read.status) });
      return { done: rows.every((row) => row.statuses.every((code) => code === 200)), rows };
    });
    assert('binaries-indexed', { expected: 'every binary\'s /:oak-chain-binaries entry present on all 3 B members', observed: indexed.rows, ok: indexed.ok });
    if (!indexed.ok) throw new Abort('the replicated binary index does not hold the binaries');

    const httpA = httpVia('G1 A read', { mount: true });
    const onA = await waitFor('every item readable on A through the mount', async () => {
      const pending = [];
      for (const item of items) {
        const reads = await readEverywhere(httpA, targetOf(A), item.storagePath);
        const bad = reads.filter((read) => classifyItemRead({ json: { properties: read.properties }, status: read.status }, item) !== 'content');
        if (bad.length) pending.push({ id: item.id, statuses: reads.map((read) => read.status) });
      }
      return { done: pending.length === 0, pending };
    });
    assert('a-reads-before-delete', { expected: 'every item (message or blob id) read on all 3 A members through the mount of B', observed: onA.ok ? items.length : onA.pending, ok: onA.ok });
    if (!onA.ok) throw new Abort('A cannot read the written content through its mount');
    await snapshot('G1-written');

    // ── G2 reader + deletes ──────────────────────────────────────────────────────────────────
    s.phase = 'G2';
    log('━━ G2 reader on A, deletes on B');
    startReader();
    facts.timeline.readerStartedAt = new Date(reader.startedAt).toISOString();
    const doomed = items.filter((item) => item.role === 'doomed');
    const deleteLeader = await leaderOf(B);
    for (const item of doomed) {
      item.deleteSubmittedAt = now();
      const form = buildDelete({ contentPath: item.storagePath, key });
      item.deleteProposalId = form.proposalId;
      const response = await submit(`G2 delete ${item.id}`, B, deleteLeader, form, '/v1/propose-delete');
      item.deleteSeq = response.seq;
      if (response.status !== 202) {
        assert('deletes-accepted', { evidence: `requests.ndjson#${response.seq}`, expected: '202', observed: s.observedOf(response), ok: false });
        throw new Abort(`delete of ${item.id} was not accepted`);
      }
    }
    assert('deletes-accepted', { expected: `${doomed.length} deletes 202`, observed: doomed.length, ok: true });
    const deleteCommits = [];
    for (const item of doomed) {
      const done = await committed(`G2 delete ${item.id}`, B, item.deleteProposalId);
      item.deleteCommittedAt = now();
      deleteCommits.push({ id: item.id, outcome: done.verdict?.outcome ?? done.state, seq: done.seq });
    }
    const deletesOk = deleteCommits.every((c) => c.outcome === 'COMMITTED');
    assert('deletes-committed', { expected: 'every delete COMMITTED', observed: deletesOk ? deleteCommits.length : deleteCommits.filter((c) => c.outcome !== 'COMMITTED'), ok: deletesOk });
    if (!deletesOk) throw new Abort('not every delete committed');
    facts.gcSince = now();
    facts.timeline.deletesCommittedAt = new Date(facts.gcSince).toISOString();

    const absentB = [];
    for (const item of doomed) absentB.push({ id: item.id, ...(await waitAbsentEverywhere(httpVia('G2 B absent'), targetOf(B), item.storagePath, { deadlineMs: s.opts.deadlineMs, intervalMs: s.opts.pollMs, sleep })) });
    assert('deletes-absent-on-b', { expected: 'every deleted item 404 on all 3 B members', observed: absentB.filter((r) => !r.absent).map((r) => ({ id: r.id, statuses: r.reads.map((read) => read.status) })), ok: absentB.every((r) => r.absent) });
    const absentA = [];
    for (const item of doomed) absentA.push({ id: item.id, ...(await waitAbsentEverywhere(httpVia('G2 A absent', { mount: true }), targetOf(A), item.storagePath, { deadlineMs: s.opts.deadlineMs, intervalMs: s.opts.pollMs, sleep })) });
    assert('deletes-absent-through-a', { expected: 'every deleted item 404 on all 3 A members through the mount', observed: absentA.filter((r) => !r.absent).map((r) => ({ id: r.id, statuses: r.reads.map((read) => read.status) })), ok: absentA.every((r) => r.absent) });
    if (!absentB.every((r) => r.absent)) throw new Abort('deleted content is still present on B');
    await snapshot('G2-deleted');

    // ── G3 GC ────────────────────────────────────────────────────────────────────────────────
    s.phase = 'G3';
    log(`━━ G3 waiting up to ${go.gcDeadlineMs / 1000} s for segment and binary GC on B`);
    const history = Object.fromEntries(B.members.map((m) => [tag(m), new Map()]));
    const releases = Object.fromEntries(B.members.map((m) => [tag(m), new Map()]));
    const latest = {};
    let index = { control: [], doomed: [], done: false };
    const doomedBinaries = binaries.filter((b) => b.role === 'doomed');
    const controlBinaries = binaries.filter((b) => b.role === 'control');
    const evaluate = () => {
      const segment = Object.fromEntries(B.members.map((m) => [tag(m), evaluateSegmentGc(history[tag(m)].values(), facts.gcSince)]));
      const deletes = Object.fromEntries(B.members.map((m) => [tag(m), evaluateBinaryDeletes(baselineDeletes[tag(m)], latest[tag(m)]?.binary?.deletes, doomedBinaries.length)]));
      const released = Object.fromEntries(B.members.map((m) => [tag(m), [...releases[tag(m)].values()]]));
      const releaseSeen = Object.values(released).every((list) => list.some((r) => (Number(r.released) || 0) > 0));
      return {
        binaryDone: releaseSeen && index.done && Object.values(deletes).every((d) => d.ok), deletes, releaseSeen, released, segment,
        segmentDone: Object.values(segment).every((seg) => seg.ok),
      };
    };
    const gcStarted = now();
    const gcWait = await waitFor('segment and binary GC on B', async () => {
      for (const member of B.members) {
        const response = await gcStatusOf('G3', member);
        if (response.status !== 200) continue;
        latest[tag(member)] = response.json;
        recordRuns(history[tag(member)], response.json);
        const release = response.json?.binary?.lastRelease;
        if (release && Number(release.at) >= facts.gcSince) releases[tag(member)].set(`${release.position}:${release.at}`, release);
      }
      if (Object.values(releases).some((map) => map.size > 0) && !index.done) {
        const httpIndex = httpVia('G3 index');
        index = { control: [], doomed: [] };
        for (const b of doomedBinaries) index.doomed.push({ id: b.id, statuses: (await readEverywhere(httpIndex, targetOf(B), b.indexPath)).map((read) => read.status) });
        for (const b of controlBinaries) index.control.push({ id: b.id, statuses: (await readEverywhere(httpIndex, targetOf(B), b.indexPath)).map((read) => read.status) });
        index.done = index.doomed.every((row) => row.statuses.every((code) => code === 404));
        index.checkedAt = new Date().toISOString();
      }
      const verdict = evaluate();
      return { ...verdict, done: verdict.segmentDone && verdict.binaryDone };
    }, { deadlineMs: Math.max(0, facts.gcSince + go.gcDeadlineMs - now()), pollMs: go.gcPollMs });
    facts.timeline.gcWaitMs = now() - gcStarted;
    const verdict = evaluate();
    for (const member of B.members) {
      const seg = verdict.segment[tag(member)];
      assert(`segment-gc-${tag(member)}`, {
        evidence: 'gc.json runs', expected: '>= 2 completed full runs started after the deletes, reclaimedBytes > 0, latest sizeAfter < first sizeBefore',
        observed: { completedFull: seg.completedFull, completedTail: seg.completedTail, firstSizeBefore: seg.firstSizeBefore, lastSizeAfter: seg.lastSizeAfter, reclaimedBytes: seg.reclaimedBytes },
        ok: seg.ok, note: seg.notCompleted.length ? `not completed: ${JSON.stringify(seg.notCompleted).slice(0, 200)}` : '',
      });
    }
    assert('segment-gc-no-failures', { expected: 'no failed or cancelled run after the deletes', kind: 'diagnostic', observed: Object.fromEntries(Object.entries(verdict.segment).map(([k, v]) => [k, v.notCompleted.filter((r) => r.outcome === 'failed' || r.outcome === 'cancelled')])), ok: Object.values(verdict.segment).every((v) => v.notCompleted.every((r) => r.outcome === 'skipped')) });
    assert('binary-gc-released', { evidence: 'gc.json binary.releases', expected: 'every B member applied a BINARY_RELEASE after the deletes with released > 0', observed: Object.fromEntries(Object.entries(verdict.released).map(([k, list]) => [k, list.map((r) => `${r.released}@${r.position}`)])), ok: verdict.releaseSeen });
    assert('binary-index-entries-released', { expected: `the ${doomedBinaries.length} deleted binaries' index entries 404 on all 3 B members`, observed: index.doomed.length ? index.doomed : 'not checked (no release seen)', ok: index.doomed.length ? index.done : false });
    assert('binary-records-deleted', {
      expected: `per B member deletes.ok + deletes.absent grew by >= ${doomedBinaries.length} since G0 and nothing is pending`,
      observed: verdict.deletes, ok: Object.values(verdict.deletes).every((d) => d.ok),
    });
    assert('binary-delete-failures', { expected: 'deletes.failed did not grow', kind: 'diagnostic', observed: Object.fromEntries(Object.entries(verdict.deletes).map(([k, d]) => [k, d.failed])), ok: Object.values(verdict.deletes).every((d) => d.failed === 0) });
    const released = Object.values(verdict.released)[0] ?? [];
    assert('binary-released-count', { expected: `released entries after the deletes >= ${doomedBinaries.length} (other unreferenced entries may be released too)`, kind: 'diagnostic', observed: released.reduce((n, r) => n + (Number(r.released) || 0), 0), ok: released.reduce((n, r) => n + (Number(r.released) || 0), 0) >= doomedBinaries.length });
    facts.runs = Object.fromEntries(Object.entries(history).map(([k, map]) => [k, [...map.values()].sort((x, y) => x.startedAt - y.startedAt)]));
    facts.binary = { ...facts.binary, index, latest: Object.fromEntries(Object.entries(latest).map(([k, v]) => [k, v?.binary ?? null])), releases: verdict.released, verdict: verdict.deletes };
    const period = Math.min(...bSeg.map((seg) => Math.min(seg.tailIntervalMs, seg.fullIntervalMs)));
    const afterRuns = Object.fromEntries(Object.entries(facts.runs).map(([k, runs]) => [k, runs.filter((run) => run.startedAt >= facts.gcSince && run.outcome === 'completed')]));
    const stagger = staggerOf(afterRuns, { offsets: Object.fromEntries(B.members.map((m, i) => [tag(m), bSeg[i].memberOffsetMs])), periodMs: period });
    facts.stagger = stagger;
    assert('gc-stagger', { expected: 'runs start shortly after their member slot (member i at i x period / 3); no two members compact at once', kind: 'diagnostic', observed: { maxSlotLagMs: stagger.maxSlotLagMs, overlaps: stagger.overlaps.length }, ok: stagger.overlaps.length === 0 });
    assert('gc-timings', {
      expected: 'per member: runs after the deletes (type, duration, reclaimed, size)', kind: 'diagnostic',
      observed: Object.fromEntries(Object.entries(afterRuns).map(([k, runs]) => [k, runs.map((r) => `${r.type}:${r.finishedAt - r.startedAt}ms:-${r.reclaimedBytes}:${r.sizeBefore}->${r.sizeAfter}`)])), ok: true,
    });
    await snapshot('G3-gc');

    // ── G4 end state ─────────────────────────────────────────────────────────────────────────
    s.phase = 'G4';
    log('━━ G4 end state');
    await stopReader();
    const judged = evaluateReader(reader.reads, go);
    facts.reader = { ...judged, rounds: reader.rounds, startedAt: new Date(reader.startedAt).toISOString(), stoppedAt: new Date(reader.stoppedAt).toISOString() };
    assert('a-reader-sampled', { expected: 'the A reader ran through G2 and G3', kind: 'diagnostic', observed: { reads: reader.reads.length, rounds: reader.rounds }, ok: reader.rounds > 1 });
    assert('a-control-never-missing', {
      evidence: 'gc.json reader.reads', expected: 'every A read of control content (items and the nsB1 listing) is the content or a mount 503: never missing, never a 500, never unanswered',
      observed: judged.control.counts, ok: reader.rounds > 0 && judged.control.violations === 0,
    });
    assert('a-mount-503-bounded', {
      evidence: 'gc.json reader.reads', expected: `mount_stale/mount_unavailable <= ${go.max503Fraction * 100}% of control reads and no streak longer than ${go.max503StreakMs} ms per A member`,
      observed: { fraction: Number(judged.mount503.fraction.toFixed(4)), longestStreakMs: judged.mount503.longestStreakMs, total: judged.mount503.total }, ok: judged.mount503.ok,
    });
    assert('a-doomed-present-until-deleted', { evidence: 'gc.json reader.reads', expected: 'deleted items read as content until their delete was submitted, then content or 404; never a 500', observed: judged.doomed.counts, ok: judged.doomed.violations === 0 });
    assert('a-doomed-not-lingering', { expected: `no deleted item still read on A ${go.lingerMs} ms after its delete committed`, kind: 'diagnostic', observed: judged.doomed.lingering, ok: judged.doomed.lingering === 0 });

    const control = items.filter((item) => item.role === 'control');
    const expectedProps = (item) => (item.kind === 'binary' ? { 'jcr:blobId': item.blobId } : { message: item.message });
    const converge = async (label, cluster, { mount = false } = {}) => {
      const http = httpVia(`G4 ${label}`, { mount });
      const result = await waitFor(`${label} converged`, async () => {
        const present = [];
        for (const item of control) {
          const reads = await readEverywhere(http, targetOf(cluster), item.storagePath);
          present.push({ expected: compareExpected(reads, expectedProps(item)), id: item.id, strict: compareAcrossNodes(reads) });
        }
        const absent = [];
        for (const item of doomed) absent.push({ id: item.id, statuses: (await readEverywhere(http, targetOf(cluster), item.storagePath)).map((read) => read.status) });
        const listings = [];
        for (const member of cluster.members) {
          const response = await call(`G4 ${label} listing ${tag(member)}`, 'GET', `${member.url}/v1/wallets/content?wallet=${addr.nsB1}`, { tolerate: true });
          note5xx(`G4 ${label}`, response, { mount });
          listings.push({ member: tag(member), names: response.status === 200 ? (response.json?.content ?? []).map((entry) => entry.name).sort() : null, status: response.status });
        }
        const done = present.every((p) => p.strict.equal && p.expected.equal) && absent.every((a) => a.statuses.every((code) => code === 404))
          && listings.every((l) => l.names && JSON.stringify(l.names) === JSON.stringify(listings[0].names));
        return { absent, done, listings, present };
      });
      const names = (path) => path.split('/').pop();
      const listingOk = result.listings.every((l) => l.names && JSON.stringify(l.names) === JSON.stringify(result.listings[0].names))
        && control.every((item) => result.listings[0].names?.includes(names(item.storagePath))) && doomed.every((item) => !result.listings[0].names?.includes(names(item.storagePath)));
      return { ...result, listingOk };
    };
    const convB = await converge('B', B);
    assert('b-converged-control', { expected: 'control items present, strictly equal across the 3 B members and equal to what was written', observed: convB.present.map((p) => ({ differing: p.strict.differing.map((d) => d.name), id: p.id, mismatches: p.expected.mismatches.length, missing: p.strict.missing })), ok: convB.present.every((p) => p.strict.equal && p.expected.equal) });
    assert('b-converged-deleted', { expected: 'deleted items 404 on all 3 B members', observed: convB.absent.filter((a) => !a.statuses.every((code) => code === 404)), ok: convB.absent.every((a) => a.statuses.every((code) => code === 404)) });
    assert('b-listing-converged', { expected: 'one nsB1 listing on all 3 B members: control items in, deleted items out', observed: convB.listings.map((l) => `${l.member}:${l.status}:${l.names?.length ?? '-'}`), ok: convB.listingOk });
    const convA = await converge('A', A, { mount: true });
    assert('a-converged-control', { expected: 'control items read through the mount on all 3 A members, strictly equal and equal to what was written', observed: convA.present.map((p) => ({ differing: p.strict.differing.map((d) => d.name), id: p.id, mismatches: p.expected.mismatches.length, missing: p.strict.missing })), ok: convA.present.every((p) => p.strict.equal && p.expected.equal) });
    assert('a-converged-deleted', { expected: 'deleted items 404 on all 3 A members', observed: convA.absent.filter((a) => !a.statuses.every((code) => code === 404)), ok: convA.absent.every((a) => a.statuses.every((code) => code === 404)) });
    assert('a-listing-converged', { expected: 'one nsB1 listing through the mount on all 3 A members: control in, deleted out', observed: convA.listings.map((l) => `${l.member}:${l.status}:${l.names?.length ?? '-'}`), ok: convA.listingOk });
    const own = [];
    for (const member of A.members) {
      const response = await call(`G4 A own listing ${tag(member)}`, 'GET', `${member.url}/v1/wallets/content?wallet=${addr.nsA1}`);
      own.push({ member: tag(member), names: (response.json?.content ?? []).map((entry) => entry.name).sort(), status: response.status });
    }
    assert('a-own-content-converged', { expected: 'one nsA1 listing on all 3 A members (A\'s own content, untouched by B\'s GC)', observed: own.map((o) => `${o.member}:${o.status}:${o.names.length}`), ok: own.every((o) => o.status === 200 && JSON.stringify(o.names) === JSON.stringify(own[0].names)) });

    const blobs = [];
    for (const member of B.members) {
      for (const b of controlBinaries) {
        const response = await call(`G4 control blob ${tag(member)} ${b.id}`, 'GET', `${member.url}/api/blob/${b.identifier}`, { binary: true, tolerate: true });
        note5xx('G4 control blob', response);
        blobs.push({ id: b.id, member: tag(member), ok: response.status === 200 && response.bytes && sha256Hex(response.bytes) === b.sha256, status: response.status });
      }
    }
    assert('control-binary-kept', { expected: 'control binaries\' index entries present and their bytes (sha256) served by all 3 B members', observed: { blobs, index: index.control }, ok: blobs.every((b) => b.ok) && index.control.length > 0 && index.control.every((row) => row.statuses.every((code) => code === 200)) });
    const doomedBlobs = [];
    for (const b of doomedBinaries) {
      const response = await call(`G4 deleted blob ${B.members[0].url} ${b.id}`, 'GET', `${B.members[0].url}/api/blob/${b.identifier}`, { binary: true, tolerate: true });
      doomedBlobs.push({ id: b.id, status: response.status });
    }
    assert('deleted-binary-unreadable', { expected: 'deleted binaries\' bytes no longer served by B (404)', kind: 'diagnostic', note: 'Kubo keeps blocks until its own GC; a shared local Kubo may still serve them', observed: doomedBlobs, ok: doomedBlobs.every((b) => b.status === 404) });

    const health = [];
    for (const member of allMembers) health.push(`${tag(member)}:${(await call(`G4 health/local ${tag(member)}`, 'GET', `${member.url}/health/local`)).status}`);
    assert('members-up-end', { expected: 'all 6 members answer /health/local 200', observed: health, ok: health.every((h) => h.endsWith(':200')) });
    const pids = s.memberFacts.map((fact) => ({ after: s.memberProcess(s.clusters.find((c) => c.label === fact.cluster), fact.index).pid, before: fact.pid, member: `${fact.cluster}${fact.index}` }));
    assert('no-restarts', { expected: 'every member keeps its G0 pid', observed: pids, ok: pids.every((p) => p.before) ? pids.every((p) => p.before === p.after) : null });
    const scenarioStart = Date.parse(s.manifest.startedAt);
    const aGcEnd = [];
    for (const member of A.members) {
      const response = await gcStatusOf('G4 A', member);
      const runs = [response.json?.segment?.lastRun?.tail, response.json?.segment?.lastRun?.full].filter((run) => run && run.startedAt >= scenarioStart);
      aGcEnd.push({ member: tag(member), runs: runs.map((run) => `${run.type}:${run.outcome}`) });
    }
    assert('a-gc-idle', { expected: 'cluster A (defaults: daily tail, weekly full) started no GC run during the scenario', kind: 'diagnostic', observed: aGcEnd, ok: aGcEnd.every((row) => row.runs.length === 0) });
    await snapshot('G4-end');
  } catch (error) {
    if (!(error instanceof Abort)) {
      await stopReader().catch(() => {});
      throw error;
    }
    aborted = await s.recordAbort(error);
  }
  await stopReader();
  if (!facts.reader && reader.reads.length) facts.reader = { ...evaluateReader(reader.reads, go), rounds: reader.rounds };
  s.write('gc.json', {
    ...facts,
    items: facts.items.map(({ bytes, message: text, ...item }) => ({ ...item, messageChars: text.length, messageSha256: sha256Hex(text) })),
    options: go,
    reads: reader.reads,
  });
  const seg = facts.runs;
  return s.finish({
    aborted,
    extraReport: [
      `- Items: ${facts.items.length} written into nsB1 (${facts.items.filter((i) => i.role === 'doomed').length} deleted); deletes committed at ${facts.timeline.deletesCommittedAt ?? 'n/a'}`,
      `- GC wait: ${facts.timeline.gcWaitMs ?? 'n/a'} ms; completed runs after the deletes: ${Object.entries(seg).map(([k, runs]) => `${k}=${runs.filter((r) => r.startedAt >= facts.gcSince && r.outcome === 'completed').length}`).join(' ') || 'n/a'}`,
      `- A reader: ${reader.reads.length} reads in ${reader.rounds} rounds; control ${JSON.stringify(facts.reader?.control?.counts ?? null)}; deleted ${JSON.stringify(facts.reader?.doomed?.counts ?? null)}`,
    ],
    extraSummary: { gcSince: facts.gcSince ? new Date(facts.gcSince).toISOString() : null, reader: facts.reader ? { control: facts.reader.control, doomed: facts.reader.doomed, mount503: facts.reader.mount503, rounds: reader.rounds } : null, timeline: facts.timeline },
    finalPhase: 'G4',
    logScanKind: 'diagnostic',
    seal: deps.seal ?? true,
    tolerated5xx: 'no 5xx except 503 mount_stale/mount_unavailable on A reads of B content and no_quorum retries',
  });
}

// CLI: tests/routing/federation-3x2-gc.sh passes the topology as FED_SMOKE_CONFIG (JSON).
export function gcOptionsFromEnv(env = process.env) {
  const out = {};
  const num = (name, key, scale = 1) => {
    if (env[name] === undefined || env[name] === '') return;
    const value = Number(env[name]);
    if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive number, got ${env[name]}`);
    out[key] = value * scale;
  };
  num('FED_GC_SECONDS', 'gcDeadlineMs', 1000);
  num('FED_GC_POLL_MS', 'gcPollMs');
  num('FED_GC_READER_MS', 'readerIntervalMs');
  num('FED_GC_BULK_WRITES', 'bulkWrites');
  num('FED_GC_BULK_CHARS', 'bulkChars');
  num('FED_GC_MAX_503_FRACTION', 'max503Fraction');
  num('FED_GC_MAX_503_STREAK_SECONDS', 'max503StreakMs', 1000);
  return out;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let config;
  try {
    config = configFromEnv(process.env, { script: 'tests/routing/federation-3x2-gc.sh' });
    config.options = { ...config.options, ...gcOptionsFromEnv(process.env) };
    const problems = gcPlan(config.options).problems;
    if (problems.length) throw new Error(`Refusing federation GC: ${problems.join('; ')}`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
  runFederationGc(config).then(
    (summary) => process.exit(summary.status === STATUS.PASS ? 0 : 1),
    (error) => {
      process.stderr.write(`❌ ${error.message}\n`);
      process.exit(2);
    },
  );
}
