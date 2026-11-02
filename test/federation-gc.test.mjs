// The federation GC scenario: its pure judgements (launch profile, /v1/gc/status parsing, segment and
// binary GC verdicts, reader classification and bounds, stagger) and end-to-end runs against the fake
// GC federation (fixtures/fake-gc-federation.mjs). Nothing real is started or signalled.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { readTsv, setupFederation } from '../fixtures/fake-federation.mjs';
import { startGcFederation } from '../fixtures/fake-gc-federation.mjs';
import {
  GC_TEST_PROFILE, binaryIndexPath, classifyItemRead, classifyListingRead, evaluateBinaryDeletes, evaluateReader, evaluateSegmentGc,
  gcDefaultSettingsProblems, gcOptionsFromEnv, gcOptionsIn, gcPlan, gcProfileMismatches, gcStatusProblems, gcTestSettingsProblems,
  parseJavaOpts, recordRuns, runFederationGc, staggerOf,
} from '../src/federation-gc.mjs';
import { compactValue } from '../src/federation-session.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PROFILE_OPTS = Object.entries(GC_TEST_PROFILE).map(([key, value]) => `-D${key}=${value}`).join(' ');

test('the JS test profile is exactly what FED_3X2_B_GC_JAVA_OPTS=test puts into cluster B\'s EXTRA_JAVA_OPTS', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-gc-'));
  try {
    const script = 'set -euo pipefail; set -a; source "$1/mock.env"; source "$1/ipfs.env"; source "$1/$2"; set +a; printf %s "$EXTRA_JAVA_OPTS"';
    const load = (file, extra = {}) => spawnSync('bash', ['-c', script, 'pack', path.join(repoRoot, 'modes/mock/validators/config'), file],
      { encoding: 'utf8', env: { HOME: home, PATH: process.env.PATH, ...extra } });
    const b = load('fed-3x2-cluster-b.env', { FED_3X2_B_GC_JAVA_OPTS: 'test' });
    assert.equal(b.status, 0, b.stderr);
    assert.deepEqual(gcProfileMismatches(b.stdout), []);
    assert.ok(b.stdout.endsWith(PROFILE_OPTS), 'appended after the federation flags');
    const a = load('fed-3x2-cluster-a.env', { FED_3X2_B_GC_JAVA_OPTS: 'test' });
    assert.deepEqual(gcOptionsIn(a.stdout), [], 'cluster A never takes B\'s GC options');
    const plain = load('fed-3x2-cluster-b.env');
    assert.deepEqual(gcOptionsIn(plain.stdout), [], 'unset: runtime defaults');
    const explicit = load('fed-3x2-cluster-b.env', { FED_3X2_B_GC_JAVA_OPTS: '-Doak.gc.tail.interval.ms=90000' });
    assert.deepEqual(parseJavaOpts(explicit.stdout)['oak.gc.tail.interval.ms'], '90000');
    assert.equal(gcProfileMismatches(explicit.stdout).length, Object.keys(GC_TEST_PROFILE).length, 'every profile value missing, the tail interval differing');
    for (const bad of ['-Dfoo.bar=1', '-Doak.gc.x=$(id)', 'test extra', '-Doak.gc.*=1']) {
      const refused = load('fed-3x2-cluster-b.env', { FED_3X2_B_GC_JAVA_OPTS: bad });
      assert.notEqual(refused.status, 0, bad);
      assert.match(refused.stderr, /Refusing federation 3x2: GC option/);
    }
  } finally {
    await rm(home, { force: true, recursive: true });
  }
});

const status = (segment = {}, binary = {}) => ({
  binary: binary === null ? null : { deleteDelayMs: 30_000, deletes: { absent: 0, failed: 0, ok: 0, pending: 0 }, enabled: true, graceMs: 60_000, intervalMs: 60_000, ...binary },
  segment: {
    enabled: true, estimationSizeDeltaBytes: 0, fullIntervalMs: 120_000, lastRun: { full: null, tail: null }, memberCount: 3, memberIndex: 0,
    memberOffsetMs: 0, nextRun: { full: 1, tail: 1 }, retainedGenerations: 2, tailIntervalMs: 60_000, ...segment,
  },
});

test('/v1/gc/status: shape, the test profile on B and the defaults on A', () => {
  assert.deepEqual(gcStatusProblems(status()), []);
  assert.deepEqual(gcStatusProblems({}), ['no segment block']);
  assert.deepEqual(gcStatusProblems({ segment: status().segment }), ['binary key missing']);
  assert.deepEqual(gcStatusProblems(status({}, null)), [], 'binary: null is a valid (disabled) answer');
  assert.deepEqual(gcStatusProblems(status({ memberIndex: null })), ['segment.memberIndex missing']);
  assert.deepEqual(gcTestSettingsProblems(status()), []);
  assert.deepEqual(gcTestSettingsProblems(status({ tailIntervalMs: 86_400_000 })), ['segment.tailIntervalMs=86400000 (want 60000)']);
  assert.deepEqual(gcTestSettingsProblems(status({}, null)), ['binary GC disabled (binary: null)']);
  assert.deepEqual(gcTestSettingsProblems(status({}, { deleteDelayMs: 600_000 })), ['binary.deleteDelayMs=600000 (want 30000)']);
  assert.deepEqual(gcDefaultSettingsProblems(status({ fullIntervalMs: 604_800_000, tailIntervalMs: 86_400_000 }, { intervalMs: 86_400_000 })), []);
  assert.deepEqual(gcDefaultSettingsProblems(status()), ['segment.tailIntervalMs=60000', 'segment.fullIntervalMs=120000', 'binary.intervalMs=60000']);
});

const run = (type, startedAt, extra = {}) => ({ finishedAt: startedAt + 100, outcome: 'completed', reclaimedBytes: 10, sizeAfter: 90, sizeBefore: 100, startedAt, type, ...extra });

test('segment GC: two completed full runs after the deletes, bytes reclaimed, the store smaller', () => {
  const history = new Map();
  recordRuns(history, { segment: { lastRun: { full: run('full', 1_000, { sizeAfter: 95, sizeBefore: 100 }), tail: run('tail', 500) } } });
  recordRuns(history, { segment: { lastRun: { full: run('full', 1_000, { sizeAfter: 95, sizeBefore: 100 }), tail: run('tail', 1_500, { sizeAfter: 94, sizeBefore: 95 }) } } });
  recordRuns(history, { segment: { lastRun: { full: run('full', 2_000, { sizeAfter: 80, sizeBefore: 94 }), tail: run('tail', 1_500) } } });
  assert.equal(history.size, 4, 'a run seen twice is kept once');
  const ok = evaluateSegmentGc(history.values(), 900);
  assert.equal(ok.ok, true);
  assert.equal(ok.completedFull, 2);
  assert.equal(ok.completedTail, 1, 'the tail run at 500 started before the deletes');
  assert.equal(ok.firstSizeBefore, 100);
  assert.equal(ok.lastSizeAfter, 80);
  assert.equal(ok.reclaimedBytes, 30);

  assert.equal(evaluateSegmentGc([run('full', 1_000)], 0).ok, false, 'one full run is not enough');
  assert.equal(evaluateSegmentGc([run('full', 1_000, { reclaimedBytes: 0 }), run('full', 2_000, { reclaimedBytes: 0 })], 0).ok, false, 'nothing reclaimed');
  assert.equal(evaluateSegmentGc([run('full', 1_000, { sizeAfter: 100 }), run('full', 2_000, { sizeAfter: 120, sizeBefore: 100 })], 0).ok, false, 'store grew');
  const skipped = evaluateSegmentGc([run('full', 1_000), run('full', 2_000, { outcome: 'skipped', reason: 'backoff', reclaimedBytes: null, sizeAfter: null, sizeBefore: null })], 0);
  assert.equal(skipped.ok, false, 'a skipped run does not count');
  assert.deepEqual(skipped.notCompleted, [{ outcome: 'skipped', reason: 'backoff', startedAt: 2_000, type: 'full' }]);
  assert.equal(evaluateSegmentGc([run('full', 1_000), run('full', 2_000)], 1_500).ok, false, 'runs before the deletes do not count');
});

test('binary GC deletes are covered by ok + absent against the baseline, with nothing pending', () => {
  assert.equal(evaluateBinaryDeletes({ absent: 0, ok: 5 }, { absent: 0, ok: 8, pending: 0 }, 3).ok, true);
  assert.equal(evaluateBinaryDeletes({}, { absent: 3, ok: 0, pending: 0 }, 3).ok, true, 'a member that does not hold the record counts it absent');
  assert.equal(evaluateBinaryDeletes({}, { absent: 1, ok: 1, pending: 0 }, 3).ok, false);
  assert.equal(evaluateBinaryDeletes({}, { ok: 3, pending: 1 }, 3).ok, false, 'pending deletes are not done');
  assert.equal(evaluateBinaryDeletes({ failed: 1 }, { failed: 3, ok: 3, pending: 0 }, 3).failed, 2);
  assert.equal(evaluateBinaryDeletes({}, undefined, 1).ok, false);
});

test('binary index paths come from <sha-256>[#length] blob ids only', () => {
  const id = 'ab'.repeat(32);
  assert.deepEqual(binaryIndexPath(`${id}#20480`), { identifier: id, path: `/:oak-chain-binaries/ab/ab/${id}` });
  assert.deepEqual(binaryIndexPath(id.toUpperCase()), { identifier: id, path: `/:oak-chain-binaries/ab/ab/${id}` });
  assert.equal(binaryIndexPath('QmSomething'), null);
  assert.equal(binaryIndexPath(null), null);
});

test('A reads through the mount: content or a mount 503 for control; absent only once the delete was submitted', () => {
  const control = { kind: 'message', message: 'm' };
  const ok = { json: { properties: { message: 'm' } }, status: 200 };
  assert.equal(classifyItemRead(ok, control), 'content');
  assert.equal(classifyItemRead({ json: { code: 'mount_stale' }, status: 503 }, control), 'stale');
  assert.equal(classifyItemRead({ json: { code: 'mount_unavailable' }, status: 503 }, control), 'unavailable');
  assert.equal(classifyItemRead({ json: { code: 'no_quorum' }, status: 503 }, control), 'error5xx', 'only the mount codes are tolerated');
  assert.equal(classifyItemRead({ json: {}, status: 500 }, control), 'error5xx');
  assert.equal(classifyItemRead({ json: null, status: 0 }, control), 'transport');
  assert.equal(classifyItemRead({ json: {}, status: 404 }, control), 'missing');
  assert.equal(classifyItemRead({ json: { properties: { message: 'other' } }, status: 200 }, control), 'missing');
  assert.equal(classifyItemRead({ json: {}, status: 403 }, control), 'other');
  const binary = { blobId: 'x#1', kind: 'binary' };
  assert.equal(classifyItemRead({ json: { properties: { 'jcr:blobId': 'x#1' } }, status: 200 }, binary), 'content');
  assert.equal(classifyItemRead({ json: { properties: {} }, status: 200 }, binary), 'missing');

  const doomed = { deleteCommittedAt: 2_000, deleteSubmittedAt: 1_000, kind: 'message', message: 'm' };
  assert.equal(classifyItemRead({ json: {}, status: 404 }, doomed, { at: 999 }), 'missing', 'absent before its delete');
  assert.equal(classifyItemRead({ json: {}, status: 404 }, doomed, { at: 1_000 }), 'deleted');
  assert.equal(classifyItemRead(ok, doomed, { at: 1_500 }), 'content');
  assert.equal(classifyItemRead(ok, doomed, { at: 2_000 + 60_001, lingerMs: 60_000 }), 'lingering');
  assert.equal(classifyItemRead({ json: {}, status: 404 }, { kind: 'message', message: 'm' }, { at: 5_000 }), 'missing', 'never deleted: missing');

  const listing = (messages) => ({ json: { content: messages.map((message) => ({ message })) }, status: 200 });
  assert.equal(classifyListingRead(listing(['a', 'b', 'x']), ['a', 'b']), 'content');
  assert.equal(classifyListingRead(listing(['a']), ['a', 'b']), 'missing');
  assert.equal(classifyListingRead(listing([]), ['a']), 'missing', 'an empty listing is missing, never acceptable');
  assert.equal(classifyListingRead({ json: { code: 'mount_stale' }, status: 503 }, ['a']), 'stale');
});

test('the reader verdicts: violations, the 503 fraction and the longest 503 streak per member', () => {
  const r = (member, at, outcome, role = 'control') => ({ at, member, outcome, role });
  const reads = [
    r('a0', 0, 'content'), r('a0', 1_000, 'stale'), r('a0', 2_000, 'stale'), r('a0', 5_000, 'unavailable'), r('a0', 6_000, 'content'),
    r('a1', 0, 'content', 'listing'), r('a1', 1_000, 'stale', 'listing'), r('a1', 2_000, 'content', 'listing'),
    r('a2', 0, 'content', 'doomed'), r('a2', 1_000, 'deleted', 'doomed'), r('a2', 2_000, 'lingering', 'doomed'),
  ];
  const v = evaluateReader(reads, { max503Fraction: 0.6, max503StreakMs: 4_000 });
  assert.deepEqual(v.control.counts, { content: 4, stale: 3, unavailable: 1 });
  assert.equal(v.control.violations, 0);
  assert.equal(v.mount503.total, 4);
  assert.equal(v.mount503.longestStreakMs, 4_000);
  assert.deepEqual(v.mount503.streaks, { a0: 4_000, a1: 0 });
  assert.equal(v.mount503.ok, true);
  assert.equal(evaluateReader(reads, { max503Fraction: 0.6, max503StreakMs: 3_999 }).mount503.ok, false, 'streak bound');
  assert.equal(evaluateReader(reads, { max503Fraction: 0.4, max503StreakMs: 10_000 }).mount503.ok, false, 'fraction bound');
  assert.equal(v.doomed.lingering, 1);
  assert.equal(v.doomed.violations, 0, 'lingering is reported, not a violation');
  const bad = evaluateReader([r('a0', 0, 'missing'), r('a0', 1, 'error5xx'), r('a1', 0, 'missing', 'doomed')]);
  assert.equal(bad.control.violations, 2);
  assert.equal(bad.doomed.violations, 1);
  assert.equal(evaluateReader([]).mount503.ok, true);
});

test('stagger: lag of each run behind its member slot, and runs of different members that overlap', () => {
  const runs = { b0: [run('full', 120_050)], b1: [run('tail', 80_010)], b2: [run('full', 160_020, { finishedAt: 161_000 }), run('tail', 220_000)] };
  const { maxSlotLagMs, overlaps } = staggerOf(runs, { offsets: { b0: 0, b1: 20_000, b2: 40_000 }, periodMs: 60_000 });
  assert.deepEqual(maxSlotLagMs, { b0: 50, b1: 10, b2: 20 });
  assert.deepEqual(overlaps, []);
  const clash = staggerOf({ b0: [run('full', 1_000, { finishedAt: 5_000 })], b1: [run('full', 4_000)] }, { offsets: {}, periodMs: 60_000 });
  assert.equal(clash.overlaps.length, 1);
});

test('the plan stays inside the charter budget and the form limit; env options parse', () => {
  const plan = gcPlan();
  assert.deepEqual(plan.problems, []);
  assert.equal(plan.writes, 22);
  assert.equal(plan.deletes, 19);
  assert.match(gcPlan({ bulkWrites: 30 }).problems.join(), /exceed 50 operations/);
  assert.match(gcPlan({ bulkChars: 250_000 }).problems.join(), /bulkChars/);
  assert.match(gcPlan({ binaryBytes: 4_096 }).problems.join(), /binaryBytes/, 'small binaries would be inlined in the segments');
  assert.match(gcPlan({ controlBinaries: 4 }).problems.join(), /controlBinaries/, 'at least one binary must be deleted');
  assert.deepEqual(gcOptionsFromEnv({ FED_GC_MAX_503_STREAK_SECONDS: '20', FED_GC_SECONDS: '900' }), { gcDeadlineMs: 900_000, max503StreakMs: 20_000 });
  assert.throws(() => gcOptionsFromEnv({ FED_GC_SECONDS: 'soon' }), /positive number/);
});

test('recorded requests keep short values and fingerprint long ones', () => {
  const long = 'x'.repeat(2_000);
  const compact = compactValue({ list: [long], message: long, n: 1, short: 'ok' });
  assert.equal(compact.short, 'ok');
  assert.equal(compact.n, 1);
  assert.match(compact.message, /^<2000 chars sha256:[0-9a-f]{64}>$/);
  assert.equal(compact.list[0], compact.message);
});

// ── end to end against the fake GC federation ──────────────────────────────────────────────────

const FAST = {
  binaries: 3, binaryBytes: 16_400, bulkChars: 2_000, bulkWrites: 3, controlBinaries: 1, controlMessages: 2,
  deadlineMs: 3_000, gcDeadlineMs: 5_000, gcPollMs: 5, lingerMs: 60_000, pollMs: 5, readerIntervalMs: 5,
};

async function setup(t, faults = {}, { profile = true } = {}) {
  const fixture = await setupFederation(t, faults, { launchOpts: { b: profile ? PROFILE_OPTS : '' }, start: startGcFederation });
  fixture.config.options = { ...fixture.config.options, ...FAST };
  return fixture;
}
const runGc = (fixture, extra = {}) => runFederationGc(fixture.config, { env: fixture.env, exec: fixture.exec, log: () => {}, ...extra });
const rowsOf = (summary) => readTsv(path.join(summary.evidenceDir, 'assertions.tsv'));
const statusOf = (rows, id) => rows.find((row) => row[1] === id)?.[5];

test('GC on B observed through A\'s mount passes with bounded mount_stale reads', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { staleReads: 2 });
  const lines = [];
  const summary = await runGc(fixture, { log: (line) => lines.push(line) });
  const rows = rowsOf(summary);
  assert.deepEqual(rows.filter((row) => row[2] === 'required' && row[5] !== 'PASS'), [], lines.join('\n'));
  assert.equal(summary.status, 'PASS');
  assert.match(path.basename(summary.evidenceDir), /^gc-\d{8}T\d{6}Z$/);
  for (const id of ['b-launched-with-gc-profile', 'a-launched-with-gc-defaults', 'gc-status-present', 'b-gc-settings-applied', 'a-gc-settings-default',
    'binaries-indexed', 'a-reads-before-delete', 'deletes-absent-through-a', 'segment-gc-b0', 'segment-gc-b1', 'segment-gc-b2', 'binary-gc-released',
    'binary-index-entries-released', 'binary-records-deleted', 'a-control-never-missing', 'a-mount-503-bounded', 'a-doomed-present-until-deleted',
    'b-converged-control', 'b-converged-deleted', 'b-listing-converged', 'a-converged-control', 'a-listing-converged', 'control-binary-kept', 'no-unexpected-5xx']) {
    assert.equal(statusOf(rows, id), 'PASS', id);
  }
  assert.ok(summary.reader.rounds > 1);
  const gc = JSON.parse(readFileSync(path.join(summary.evidenceDir, 'gc.json'), 'utf8'));
  assert.equal(gc.items.length, 8);
  assert.ok(gc.items.every((item) => item.bytes === undefined && item.messageSha256), 'payloads are fingerprinted, not stored');
  assert.ok(gc.items.filter((item) => item.kind === 'binary').every((item) => item.indexPath && item.ipfsCid && item.identifier === item.sha256));
  assert.ok(gc.runs.b1.filter((r) => r.type === 'full').length >= 2);
  const requests = readFileSync(path.join(summary.evidenceDir, 'requests.ndjson'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  const stale = requests.filter((r) => r.status === 503 && r.body?.code === 'mount_stale');
  assert.equal(stale.length, 2, 'both injected mount_stale answers were recorded and tolerated');
  assert.equal(summary.reader.mount503.total + (summary.reader.doomed.counts.stale ?? 0), stale.filter((r) => r.label.startsWith('reader ')).length,
    'the reader counts the ones it saw (control reads in mount503, deleted-item reads in doomed)');
  const upload = requests.find((r) => r.label === 'G1 write binary-0');
  assert.equal(upload.files[0].bytes, FAST.binaryBytes, 'multipart upload recorded as length + sha256');
  assert.equal(fixture.federation.index.size, 1, 'only the control binary stays indexed');
});

test('a control item missing on A after the deletes fails the never-missing rule', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { missingRead: true });
  const summary = await runGc(fixture);
  assert.equal(summary.status, 'FAIL');
  assert.equal(statusOf(rowsOf(summary), 'a-control-never-missing'), 'FAIL');
  assert.ok(summary.reader.control.counts.missing >= 1);
});

test('a 500 from A\'s mount is never tolerated', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { read500: true });
  const summary = await runGc(fixture);
  assert.equal(summary.status, 'FAIL');
  assert.equal(statusOf(rowsOf(summary), 'no-unexpected-5xx'), 'FAIL');
});

test('GC that reclaims nothing fails the segment assertions at the deadline', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { noReclaim: true, noBinaryRelease: true });
  fixture.config.options.gcDeadlineMs = 300;
  const summary = await runGc(fixture);
  assert.equal(summary.status, 'FAIL');
  const rows = rowsOf(summary);
  assert.equal(statusOf(rows, 'segment-gc-b0'), 'FAIL');
  assert.equal(statusOf(rows, 'binary-gc-released'), 'FAIL');
  assert.equal(statusOf(rows, 'binary-index-entries-released'), 'FAIL');
});

test('binary GC that releases the control binary fails control-binary-kept', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { releaseControl: true });
  const summary = await runGc(fixture);
  assert.equal(summary.status, 'FAIL');
  assert.equal(statusOf(rowsOf(summary), 'control-binary-kept'), 'FAIL');
});

test('cluster B without the GC profile in its launch record aborts in G0 before any write', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, {}, { profile: false });
  const summary = await runGc(fixture);
  assert.equal(summary.status, 'FAIL');
  assert.equal(summary.abortedInPhase, 'G0');
  assert.equal(summary.writeRequests, 0);
  assert.equal(fixture.federation.content.size, 0);
});

test('a plan over the charter budget is refused before an evidence directory exists', async (t) => {
  const fixture = await setup(t);
  await assert.rejects(runGc({ ...fixture, config: { ...fixture.config, options: { ...fixture.config.options, bulkWrites: 40 } } }), /Refusing federation GC/);
});
