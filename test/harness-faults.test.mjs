import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

import { STATUS } from '../src/harness/evidence.mjs';
import { createFaultController, FAULT_ACTIONS, waitSettled } from '../src/harness/faults.mjs';
import { gcActivity, renderSuiteReport } from '../src/harness/index.mjs';
import { launchedJarPath } from '../src/harness/target.mjs';

const nodes = [0, 1, 2].map((id) => ({ id, pidFile: `/tmp/none/validator-${id}.pid`, port: 8490 + 2 * id, storeDir: `/tmp/r/validator-${id}`, url: `http://127.0.0.1:${8490 + 2 * id}` }));
const target = { isLegacyRoot: false, lifecycleDir: '/repo/modes/mock/validators/lifecycle', logDir: '/tmp/r/logs', nodes, pidDir: '/tmp/r/pids', runtimeRoot: '/tmp/r', size: 3 };

test('fault controller refuses the long-lived legacy root', () => {
  assert.throws(() => createFaultController({ ...target, isLegacyRoot: true, runtimeRoot: '/Users/x/oak-chain' }), /legacy root/);
});

test('fault controller runs member.sh for this root only, never with the live-root override', async () => {
  const calls = [];
  const previous = process.env.OAK_ALLOW_LIVE_ROOT;
  process.env.OAK_ALLOW_LIVE_ROOT = '1';
  try {
    const execFileImpl = (file, args, options, callback) => {
      calls.push({ args, env: options.env, file });
      callback(null, 'ok', '');
    };
    const events = [];
    const controller = createFaultController(target, { execFileImpl, run: { event: async (type, detail) => events.push({ detail, type }) } });
    const record = await controller.member('stop', 1);
    assert.equal(record.exitCode, 0);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].file, path.join(target.lifecycleDir, 'member.sh'));
    assert.deepEqual(calls[0].args, ['stop', '1']);
    assert.equal(calls[0].env.CLUSTER_RUNTIME_ROOT, '/tmp/r');
    assert.equal(calls[0].env.PID_DIR, '/tmp/r/pids');
    assert.equal(calls[0].env.STOP_ESCALATE, 'false', 'a graceful stop never escalates to SIGKILL');
    assert.equal(calls[0].env.OAK_ALLOW_LIVE_ROOT, undefined);
    assert.deepEqual(events.map((event) => event.type), ['fault.stop.begin', 'fault.stop.end']);
    await assert.rejects(controller.member('reboot', 1), /Unknown fault action/);
    await assert.rejects(controller.member('kill', 7), /No member 7/);
  } finally {
    if (previous === undefined) delete process.env.OAK_ALLOW_LIVE_ROOT;
    else process.env.OAK_ALLOW_LIVE_ROOT = previous;
  }
  assert.equal(FAULT_ACTIONS.kill.signal, 'SIGKILL');
});

function fakeHttp(views) {
  return {
    async request(url) {
      const port = Number(new URL(url).port);
      const view = views[port];
      if (!view) return { status: 0 };
      if (url.endsWith('/health')) return { json: { currentRole: view.role }, status: 200 };
      return { json: { currentLeader: view.leader }, status: 200 };
    },
  };
}

test('settled means every listed member up, one LEADER, and all agree on it', async () => {
  const agreed = { 8490: { leader: 'http://localhost:8490', role: 'LEADER' }, 8492: { leader: 'http://127.0.0.1:8490', role: 'FOLLOWER' }, 8494: { leader: 'http://127.0.0.1:8490', role: 'FOLLOWER' } };
  const settled = await waitSettled(fakeHttp(agreed), target, { deadlineMs: 0 });
  assert.equal(settled.settled, true);
  assert.equal(settled.leader.id, 0);

  const split = { ...agreed, 8494: { leader: 'http://127.0.0.1:8494', role: 'LEADER' } };
  assert.equal((await waitSettled(fakeHttp(split), target, { deadlineMs: 0, intervalMs: 1 })).settled, false);

  const oneDown = { 8490: agreed[8490], 8492: agreed[8492] };
  assert.equal((await waitSettled(fakeHttp(oneDown), target, { deadlineMs: 0, intervalMs: 1 })).settled, false);
  assert.equal((await waitSettled(fakeHttp(oneDown), target, { deadlineMs: 0, members: [0, 1] })).settled, true, 'a majority can be settled on its own');
});

test('provenance names the jar the cluster was launched with', () => {
  const launched = launchedJarPath({ launch: { OAK_CONSENSUS_JAR: '/jars/x.jar', OAK_CONSENSUS_JAR_SHA256: 'abc' }, oakRoot: '/oak' });
  assert.deepEqual(launched, { path: '/jars/x.jar', recordedSha256: 'abc', source: 'launch record' });
  const workspace = launchedJarPath({ launch: {}, oakRoot: '/oak' });
  assert.equal(workspace.path, '/oak/jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar');
  assert.equal(workspace.source, 'workspace build');
});

test('GC activity between two snapshots is reported per member', () => {
  const snap = (lastMark, generation) => ({ nodes: [{ binary: { lastMark }, id: 0, segment: { generation, lastRun: null }, status: 200 }, { id: 1, status: 0 }] });
  assert.deepEqual(gcActivity(snap(null, { generation: 0 }), snap(null, { generation: 0 })), ['member 1: GC status unavailable']);
  assert.deepEqual(gcActivity(snap(null, { generation: 0 }), snap({ at: 1 }, { generation: 1 })), [
    'member 0: segment GC state changed', 'member 0: binary mark state changed', 'member 1: GC status unavailable',
  ]);
});

test('suite report lists every campaign, the ones not run, and each failing required assertion', () => {
  const campaign = (id, riskClass) => ({ charter: ['X'], id, riskClass });
  const summary = (status, fail) => ({ diagnostics: { fail: 0, total: 1 }, required: { fail, pass: 3, total: 3 + fail, unknown: 0 }, status });
  const report = renderSuiteReport({
    manifest: { jar: { path: '/j.jar', sha256: 'ff', source: 'launch record' }, target: { runtimeRoot: '/tmp/r', size: 3 } },
    results: [
      { campaign: campaign('p0', 'A'), dir: '/s/p0-1', failing: [], summary: summary(STATUS.PASS, 0) },
      { campaign: campaign('s3', 'C'), dir: '/s/s3-1', failing: [{ assertionId: 'catch-up', observed: '4/5', scenarioId: 'S3-01', status: STATUS.FAIL }], summary: summary(STATUS.FAIL, 1) },
    ],
    suite: { campaigns: ['p0', 's3', 'r6'], id: 'rebaseline', title: 'Re-baseline' },
    summary: { abortReason: 'cluster did not settle', abortedAfter: 's3', endedAt: 'b', gcDuringSuite: [], required: { fail: 1, pass: 6, total: 7, unknown: 0 }, startedAt: 'a', status: STATUS.FAIL },
  });
  assert.match(report, /# Re-baseline — FAIL/);
  assert.match(report, /\*\*Aborted\*\* after `s3`/);
  assert.match(report, /\| `r6` \| \| \| NOT RUN/);
  assert.match(report, /\| `s3` \| S3-01 \| catch-up \| \*\*FAIL\*\* \| 4\/5 \|/);
  assert.match(report, /GC during the suite: none observed/);
});

test('jar provenance sidecar names the source commit the cluster runs', async () => {
  const { parseJarProvenance } = await import('../src/harness/target.mjs');
  assert.deepEqual(parseJarProvenance('source=1900068ce65bda610d540b71662a591b31a70184 dirtyFiles=0 branch=feature/x\n'), {
    branch: 'feature/x', dirtyCount: 0, head: '1900068ce65bda610d540b71662a591b31a70184',
  });
  assert.equal(parseJarProvenance('garbage'), null);
});
