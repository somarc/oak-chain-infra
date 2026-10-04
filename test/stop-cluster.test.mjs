import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const stopScript = path.join(repoRoot, 'modes/mock/validators/lifecycle/stop-cluster.sh');

// A stand-in validator: its command line names this root's validator-N store (so stop-cluster
// recognises it) and it takes 2 s to shut down after SIGTERM, longer than the old 1 s SIGKILL.
// Launched through a short-lived shell so it is reparented and reaped like a real validator
// (start-cluster double-forks); a child of this test would linger as a zombie that kill -0 sees.
function fakeValidator(root, node) {
  const script = 'trap "sleep 2; exit 0" TERM; while true; do sleep 0.2; done';
  const launched = spawnSync('bash', ['-c', `nohup bash -c '${script}' oak-segment-consensus "$1" >/dev/null 2>&1 & echo $!`, 'launcher', `${root}/validator-${node}`], { encoding: 'utf8' });
  return Number(launched.stdout.trim());
}

const alive = (pid) => spawnSync('kill', ['-0', String(pid)]).status === 0;

test('plain stop keeps the Aeron log and archive, removes media dirs, and stops validators gracefully', { timeout: 30_000 }, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'oak-stop-test-'));
  const pids = [];
  try {
    await mkdir(path.join(root, 'pids'), { recursive: true });
    for (const node of [0, 1, 2]) {
      const store = path.join(root, `validator-${node}`);
      await mkdir(path.join(store, `aeron-cluster-node-${node}`, 'cluster'), { recursive: true });
      await mkdir(path.join(store, `aeron-cluster-node-${node}`, 'archive'), { recursive: true });
      await mkdir(path.join(store, `aeron-media-${node}-driver`), { recursive: true });
      await writeFile(path.join(store, `aeron-cluster-node-${node}`, 'cluster', 'recording.log'), 'log');
      await writeFile(path.join(store, `aeron-cluster-node-${node}`, 'archive', 'archive.catalog'), 'catalog');
      await writeFile(path.join(store, `aeron-media-${node}-driver`, 'cnc.dat'), 'cnc');
      await writeFile(path.join(store, 'data00000a.tar'), 'oak');
      const pid = fakeValidator(root, node);
      pids.push(pid);
      await writeFile(path.join(root, 'pids', `validator-${node}.pid`), `${pid}\n`);
    }
    const started = Date.now();
    const result = spawnSync('bash', [stopScript, '--cluster-size', '3'], {
      encoding: 'utf8',
      env: {
        ...process.env,
        AERON_CLUSTER_BASE_PORT: '39000',
        CLUSTER_RUNTIME_ROOT: root,
        OAK_VALIDATOR_HTTP_BASE_PORT: '38090',
        OPS_PROXY_PORT: '38787',
        PID_DIR: path.join(root, 'pids'),
        STOP_WAIT_SECONDS: '10',
      },
      timeout: 25_000,
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.ok(pids.every((pid) => !alive(pid)), 'every validator stopped');
    assert.doesNotMatch(result.stdout, /force kill/, 'validators that exit within STOP_WAIT_SECONDS are not SIGKILLed');
    assert.ok(Date.now() - started >= 2_000, 'stop waited for the graceful shutdown');
    for (const node of [0, 1, 2]) {
      const store = path.join(root, `validator-${node}`);
      assert.ok(existsSync(path.join(store, `aeron-cluster-node-${node}`, 'cluster', 'recording.log')), `node ${node} keeps its cluster log`);
      assert.ok(existsSync(path.join(store, `aeron-cluster-node-${node}`, 'archive', 'archive.catalog')), `node ${node} keeps its archive`);
      assert.ok(!existsSync(path.join(store, `aeron-media-${node}-driver`)), `node ${node} media dir removed`);
      assert.ok(existsSync(path.join(store, 'data00000a.tar')), `node ${node} keeps its Oak store`);
    }
  } finally {
    for (const pid of pids) if (alive(pid)) spawnSync('kill', ['-9', String(pid)]);
    await rm(root, { force: true, recursive: true });
  }
});
