// The federation failover scenario against the fake federation (fixtures/fake-federation.mjs): victim
// choice from B's mount activeEndpoints, the never-missing rule for B reads during the fault, leader
// and mount failover, and the recovery checks. The member control is a fake; nothing real is signalled.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chmod, copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { readTsv, setupFederation } from '../fixtures/fake-federation.mjs';
import {
  chooseVictim, classifyRead, createMemberControl, memberControlCommand, normalizeEndpoint, runFederationFailover,
} from '../src/federation-failover.mjs';
import { testKey } from '../src/tx.mjs';

const aMembers = [8290, 8292, 8294].map((port, index) => ({ index, port, url: `http://127.0.0.1:${port}` }));
const obs = (...endpoints) => endpoints.map((activeEndpoint, i) => ({ activeEndpoint, reader: `b${i}` }));

test('the victim is the A endpoint most B mounts read from; ties go to the lowest member', () => {
  assert.equal(chooseVictim(obs('http://127.0.0.1:8290', 'http://localhost:8290/', 'http://127.0.0.1:8290'), aMembers).victim.index, 0);
  assert.equal(chooseVictim(obs('http://127.0.0.1:8290', 'http://127.0.0.1:8290', 'http://127.0.0.1:8290'), aMembers).unanimous, true);
  const majority = chooseVictim(obs('http://127.0.0.1:8292', 'http://127.0.0.1:8290', 'http://127.0.0.1:8292'), aMembers);
  assert.equal(majority.victim.index, 1);
  assert.equal(majority.unanimous, false);
  assert.deepEqual(majority.votes, { 0: ['b1'], 1: ['b0', 'b2'], 2: [] });
  assert.equal(chooseVictim(obs('http://127.0.0.1:8294', 'http://127.0.0.1:8292', null), aMembers).victim.index, 1, 'tie: lowest index');
  const none = chooseVictim(obs(null, 'http://127.0.0.1:9999', null), aMembers);
  assert.equal(none.victim, null);
  assert.equal(none.unmapped.length, 3);
  assert.equal(normalizeEndpoint('http://localhost:8290/'), 'http://127.0.0.1:8290');
});

test('a B read of committed A content is the content or a 503, anything else violates the rule', () => {
  const body = (messages) => ({ content: messages.map((message) => ({ message })) });
  assert.equal(classifyRead({ json: body(['m1', 'x']), status: 200 }, ['m1']), 'content');
  assert.equal(classifyRead({ json: { code: 'mount_unavailable' }, status: 503 }, ['m1']), 'unavailable');
  assert.equal(classifyRead({ json: body([]), status: 200 }, ['m1']), 'missing', 'an empty answer is missing, never acceptable');
  assert.equal(classifyRead({ json: body(['other']), status: 200 }, ['m1']), 'missing');
  assert.equal(classifyRead({ json: null, status: 404 }, ['m1']), 'other');
  assert.equal(classifyRead({ json: null, status: 0 }, ['m1']), 'other');
});

test('the member control is lifecycle/member.sh under the fed-3x2 cluster-a pack, start or stop of one member only', () => {
  const config = { configDir: '/infra/config', fedRoot: '/home/u/oak-chain-federation/3x2', lifecycleDir: '/infra/lifecycle' };
  const { argv, display, env } = memberControlCommand(config, 'stop', 1);
  assert.equal(argv[0], 'bash');
  assert.match(argv[2], /fed_3x2_load_cluster_env "\$2" a; unset OAK_CONSENSUS_JAR OAK_CONSENSUS_JAR_SHA256; exec "\$1\/member.sh" "\$3" "\$4"/);
  assert.deepEqual(argv.slice(3), ['fed-member-control', '/infra/lifecycle', '/infra/config', 'stop', '1']);
  assert.deepEqual(env, { FED_3X2_ROOT: config.fedRoot });
  assert.match(display, /^FED_3X2_ROOT=\/home\/u\/oak-chain-federation\/3x2 bash -c '.*' fed-member-control \/infra\/lifecycle \/infra\/config stop 1$/);
  assert.throws(() => memberControlCommand(config, 'kill', 1), /start or stop/);
  assert.throws(() => memberControlCommand(config, 'stop', -1), /non-negative/);
});

test('the real member control loads the cluster-a pack, drops the env jar and execs member.sh with one action', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const dir = await mkdtemp(path.join(os.tmpdir(), 'oak-member-control-'));
  try {
    // A copy of lib/fed-3x2.sh beside a stand-in member.sh that reports what it was given.
    const lifecycleDir = path.join(dir, 'lifecycle');
    await mkdir(path.join(lifecycleDir, 'lib'), { recursive: true });
    await copyFile(path.join(repoRoot, 'modes/mock/validators/lifecycle/lib/fed-3x2.sh'), path.join(lifecycleDir, 'lib/fed-3x2.sh'));
    await writeFile(path.join(lifecycleDir, 'member.sh'), '#!/bin/bash\necho "args=$* root=$CLUSTER_RUNTIME_ROOT pids=$PID_DIR jar=${OAK_CONSENSUS_JAR:-unset} sha=${OAK_CONSENSUS_JAR_SHA256:-unset}"\n');
    await chmod(path.join(lifecycleDir, 'member.sh'), 0o755);
    const fedRoot = path.join(dir, 'home/oak-chain-federation/3x2');
    const control = createMemberControl({ configDir: path.join(repoRoot, 'modes/mock/validators/config'), fedRoot, lifecycleDir },
      { HOME: path.join(dir, 'home'), OAK_CONSENSUS_JAR: '/other.jar', OAK_CONSENSUS_JAR_SHA256: 'f'.repeat(64), PATH: process.env.PATH });
    const result = await control('stop', 2);
    assert.equal(result.code, 0, result.output);
    assert.equal(result.output.trim(), `args=stop 2 root=${fedRoot}/cluster-a pids=${fedRoot}/cluster-a/pids jar=unset sha=unset`);
    assert.match(result.display, /fed-member-control .* stop 2$/);

    const refused = createMemberControl({ configDir: path.join(repoRoot, 'modes/mock/validators/config'), fedRoot: path.join(dir, 'home/oak-chain/x'), lifecycleDir },
      { HOME: path.join(dir, 'home'), PATH: process.env.PATH });
    const denied = await refused('stop', 0);
    assert.notEqual(denied.code, 0);
    assert.match(denied.output, /Refusing federation 3x2/);
    assert.doesNotMatch(denied.output, /args=/, 'member.sh never runs for a protected root');
  } finally {
    await rm(dir, { force: true, recursive: true });
  }
});

// The directory as the smoke leaves it: epoch 2, A owns nsA1+nsA2 with no writers, B owns nsB1.
function directoryAtEpoch2(clusters) {
  const urls = (cluster) => cluster.members.map((m) => m.url);
  return {
    directoryEpoch: 2,
    entries: [
      { endpoints: urls(clusters[0]), enterpriseId: clusters[0].enterpriseId, namespaces: [testKey(1).address, testKey(2).address], status: 'ACTIVE', writers: [] },
      { endpoints: urls(clusters[1]), enterpriseId: clusters[1].enterpriseId, namespaces: [testKey(3).address], status: 'ACTIVE', writers: [] },
    ],
  };
}

async function setup(t, faults = {}) {
  const fixture = await setupFederation(t, faults);
  const { writeFile } = await import('node:fs/promises');
  await writeFile(fixture.directoryFile, `${JSON.stringify(directoryAtEpoch2(fixture.federation.clusters))}\n`);
  fixture.config.options = { ...fixture.config.options, deadlineMs: 3_000, failoverDeadlineMs: 5_000, recoveryDeadlineMs: 5_000, stopDeadlineMs: 2_000 };
  return fixture;
}

const run = (fixture, extra = {}) => runFederationFailover(fixture.config, {
  env: fixture.env, exec: fixture.exec, log: () => {}, memberControl: fixture.memberControl, ...extra,
});

test('failover of the endpoint B reads from (here A\'s leader) passes with 503s but no missing reads', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { leaderA: 1, mountOrder: [[1, 0, 2], [1, 0, 2], [0, 1, 2]], outageRequests: 3 });
  const lines = [];
  const summary = await run(fixture, { log: (line) => lines.push(line) });
  const rows = readTsv(path.join(summary.evidenceDir, 'assertions.tsv'));
  assert.deepEqual(rows.filter((row) => row[2] === 'required' && row[5] !== 'PASS'), [], lines.join('\n'));
  assert.equal(summary.status, 'PASS');
  assert.equal(summary.victim.index, 1, 'two of three B mounts read from A1');
  assert.equal(summary.victim.wasLeader, true);
  assert.equal(summary.victim.unanimous, false);
  assert.deepEqual(fixture.controls, [{ action: 'stop', index: 1 }, { action: 'start', index: 1 }], 'only the victim is ever controlled');
  assert.ok(summary.readOutcomes.unavailable > 0, 'the outage was observed as 503s');
  assert.equal(summary.readOutcomes.missing, 0);
  assert.ok(summary.readOutcomes.content > 0);
  assert.equal(summary.victimLeftStopped, false);
  for (const id of ['victim-chosen', 'victim-stopped', 'victim-down', 'others-untouched', 'a-leader-within-deadline', 'fault-write-on-survivors',
    'b-mount-failover', 'b-reads-never-missing', 'b-reads-both-writes', 'victim-identity', 'victim-serves-both-writes', 'victim-same-jar', 'no-other-restarts', 'no-unexpected-5xx']) {
    assert.ok(rows.some((row) => row[1] === id && row[5] === 'PASS'), `${id} PASS`);
  }
  assert.match(path.basename(summary.evidenceDir), /^failover-\d{8}T\d{6}Z$/);
  const failover = JSON.parse(readFileSync(path.join(summary.evidenceDir, 'failover.json'), 'utf8'));
  assert.equal(failover.stop.output.includes('stopped'), true);
  assert.ok(failover.readOutcomes.reads.some((read) => read.status === 503 && read.code === 'mount_unavailable'));
  for (const name of ['F0-preflight', 'F1-baseline', 'F3-during-fault', 'F4-recovery', 'F5-end']) {
    assert.ok(readFileSync(path.join(summary.evidenceDir, 'snapshots', name, 'b0-health.json'), 'utf8').includes('remoteMounts'), name);
  }
  const during = JSON.parse(readFileSync(path.join(summary.evidenceDir, 'snapshots', 'F3-during-fault', 'a1-health.json'), 'utf8'));
  assert.equal(during.status, 0, 'the stopped victim is recorded, not fatal');
});

test('an empty B read while the mount is unavailable fails the never-missing rule', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { missingDuringOutage: true, outageRequests: 3 });
  const summary = await run(fixture);
  assert.equal(summary.status, 'FAIL');
  assert.equal(summary.victim.index, 0, 'every B mount reads from the first endpoint by default');
  assert.ok(summary.readOutcomes.missing > 0);
  const row = readTsv(path.join(summary.evidenceDir, 'assertions.tsv')).find((r) => r[1] === 'b-reads-never-missing');
  assert.equal(row[5], 'FAIL');
  assert.equal(summary.victimLeftStopped, false, 'the scenario still recovers the victim');
});

test('a restarted member with another directory digest fails the recovery identity check', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t, { staleAfterRestart: true });
  fixture.config.options.recoveryDeadlineMs = 1_000;
  const summary = await run(fixture);
  assert.equal(summary.status, 'FAIL');
  const rows = readTsv(path.join(summary.evidenceDir, 'assertions.tsv'));
  assert.equal(rows.find((r) => r[1] === 'victim-identity')[5], 'FAIL');
  assert.equal(rows.find((r) => r[1] === 'victim-serves-both-writes')[5], 'PASS');
});

test('a failed restart aborts, leaves everything as it is and names the restart command', { timeout: 60_000 }, async (t) => {
  const fixture = await setup(t);
  const memberControl = async (action, index) => (action === 'start'
    ? { code: 1, command: ['member.sh', 'start', String(index)], output: 'port held' }
    : fixture.memberControl(action, index));
  const summary = await run(fixture, { memberControl });
  assert.equal(summary.status, 'FAIL');
  assert.equal(summary.abortedInPhase, 'F4');
  assert.equal(summary.victimLeftStopped, true);
  assert.equal(fixture.federation.clusters[0].members[0].down, true, 'no retry, no other action');
  const report = readFileSync(path.join(summary.evidenceDir, 'report.md'), 'utf8');
  assert.match(report, /still STOPPED\. Restart: `member\.sh start 0`/);
});

test('the failover refuses to run without a committed directory owning nsA1', { timeout: 60_000 }, async (t) => {
  const fixture = await setupFederation(t);
  fixture.config.options = { ...fixture.config.options, deadlineMs: 500 };
  const summary = await run(fixture);
  assert.equal(summary.abortedInPhase, 'F0');
  assert.deepEqual(fixture.controls, [], 'nothing was stopped');
});
