import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  clip,
  formatDuration,
  formatLaunched,
  handleKey,
  initialUiState,
  memberState,
  parseEtime,
  parseLaunchRecord,
  probeCluster,
  renderConsole,
  resolveConsoleConfig,
  splitKeys,
  stripAnsi,
} from '../src/mock-console.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const memberScript = path.join(repoRoot, 'modes/mock/validators/lifecycle/member.sh');

async function tempRuntime() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'oak-console-test-'));
  await mkdir(path.join(root, 'pids'), { recursive: true });
  await mkdir(path.join(root, 'logs'), { recursive: true });
  return root;
}

async function baseConfig(env = {}, options = {}) {
  const root = await tempRuntime();
  const config = await resolveConsoleConfig({
    env: { HOME: '/home/op', CLUSTER_RUNTIME_ROOT: root, ...env },
    options,
    repoRoot,
  });
  return { config, root };
}

function snapshotFor(config, states) {
  const members = states.map((state, id) => ({
    alive: ['up', 'unhealthy', 'starting'].includes(state),
    clusterHealthy: state === 'up',
    httpCode: state === 'up' ? 200 : 0,
    id,
    pid: state === 'stopped' ? null : 1000 + id,
    port: config.httpBase + id * config.step,
    reachable: null,
    role: id === 0 && state === 'up' ? 'LEADER' : (state === 'up' ? 'FOLLOWER' : null),
    state,
    total: null,
    uptimeMs: state === 'up' ? 65_000 : null,
  }));
  const running = members.filter((member) => ['up', 'unhealthy'].includes(member.state)).length;
  return {
    at: 0,
    ipfs: { code: 200 },
    members,
    ops: { alive: true, code: 200, pid: 4242 },
    quorum: { healthy: running > 0, leader: running > 0 ? 0 : null, need: Math.floor(config.size / 2) + 1, running, size: config.size },
    sidecars: { observer: null, sleep: true, watchdog: false },
    wallet: '0x1234567890abcdef1234567890abcdef12345678',
  };
}

test('small helpers parse launch records, ps etime and durations', () => {
  assert.deepEqual(parseLaunchRecord('# c\nOAK_CLUSTER_SIZE=5\nIPFS_API_HTTP=http://h:5001/?a=b\n\nbad\n'), {
    IPFS_API_HTTP: 'http://h:5001/?a=b',
    OAK_CLUSTER_SIZE: '5',
  });
  assert.equal(parseEtime('03:04'), 184_000);
  assert.equal(parseEtime('1-02:03:04'), ((26 * 60 + 3) * 60 + 4) * 1000);
  assert.equal(parseEtime('garbage'), null);
  assert.equal(formatDuration(5_000), '5s');
  assert.equal(formatDuration(65_000), '1m05s');
  assert.equal(formatDuration(2 * 3_600_000 + 13 * 60_000), '2h13m');
  assert.deepEqual(splitKeys('a\u001b[Bq'), ['a', '\u001b[B', 'q']);
  const launchedAt = Date.parse('2026-10-04T12:46:30Z');
  assert.match(formatLaunched('2026-10-04T12:46:30Z', launchedAt + 125_000), /^\d\d:\d\d \(2m05s ago\)$/);
  assert.equal(formatLaunched('', 0), '');
  assert.equal(formatLaunched('not-a-date', 0), 'not-a-date');
});

test('member state distinguishes tracked, untracked, crashed and stopped members', () => {
  assert.equal(memberState({ alive: true, httpCode: 200, pid: 1 }), 'up');
  assert.equal(memberState({ alive: true, httpCode: 503, pid: 1 }), 'unhealthy');
  assert.equal(memberState({ alive: true, httpCode: 0, pid: 1 }), 'starting');
  assert.equal(memberState({ alive: false, httpCode: 200, pid: null }), 'untracked');
  assert.equal(memberState({ alive: false, httpCode: 0, pid: 7 }), 'crashed');
  assert.equal(memberState({ alive: false, httpCode: 0, pid: null }), 'stopped');
});

test('config follows script precedence and flags membership drift from the launch record', async () => {
  const root = await tempRuntime();
  try {
    await writeFile(path.join(root, 'pids/cluster-launch.env'), [
      'OAK_CLUSTER_NAME=from-record',
      'OAK_CLUSTER_SIZE=5',
      'OAK_VALIDATOR_HTTP_BASE_PORT=18090',
      'OPS_PROXY_PORT=18787',
      '',
    ].join('\n'));
    const fromRecord = await resolveConsoleConfig({ env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root }, repoRoot });
    assert.equal(fromRecord.size, 5);
    assert.equal(fromRecord.sizeSource, 'launch record');
    assert.equal(fromRecord.httpBase, 18090);
    assert.equal(fromRecord.opsPort, 18787);
    assert.equal(fromRecord.clusterName, 'from-record');
    assert.deepEqual(fromRecord.warnings, []);
    assert.equal(fromRecord.childEnv.PID_DIR, path.join(root, 'pids'));
    assert.equal(fromRecord.childEnv.OAK_TUI, '0');

    const drifted = await resolveConsoleConfig({
      env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root, OAK_CLUSTER_SIZE: '3' },
      repoRoot,
    });
    assert.equal(drifted.size, 3);
    assert.equal(drifted.sizeSource, 'env');
    assert.match(drifted.warnings.join('\n'), /OAK_CLUSTER_SIZE=3 differs .*\(5\)/);

    await assert.rejects(
      resolveConsoleConfig({ env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root }, options: { 'cluster-size': '4' }, repoRoot }),
      /Unsupported cluster size 4/,
    );
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('config infers a 5-member cluster from pid files when no record exists', async () => {
  const root = await tempRuntime();
  try {
    await writeFile(path.join(root, 'pids/validator-4.pid'), '999999\n');
    const config = await resolveConsoleConfig({ env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root }, repoRoot });
    assert.equal(config.size, 5);
    assert.equal(config.sizeSource, 'pid files');
    assert.equal(config.lifecycleDir, path.join(repoRoot, 'modes/mock/validators/lifecycle'));
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('keys map to lifecycle script actions with confirmation for destructive ones', async () => {
  const { config, root } = await baseConfig();
  try {
    const snapshot = snapshotFor(config, ['up', 'up', 'up']);
    const ctx = { busy: false, config, snapshot };
    let ui = initialUiState();

    let result = handleKey(ui, 's', ctx);
    assert.equal(result.action, null, 'nothing to start when every member and the OPS proxy are up');
    assert.match(result.state.message.text, /already running; nothing to start/);

    const partial = { busy: false, config, snapshot: snapshotFor(config, ['up', 'up', 'crashed']) };
    result = handleKey(ui, 's', partial);
    assert.deepEqual(result.action, { args: ['--cluster-size', '3'], label: 'start cluster', script: 'start-cluster.sh', type: 'run' });

    ui = handleKey(handleKey(ui, 'f', ctx).state, 'b', ctx).state;
    result = handleKey(ui, 's', ctx);
    assert.equal(result.action, null);
    assert.match(result.state.confirm.prompt, /Fresh start wipes validator runtime state under/);
    const confirmed = handleKey({ ...result.state, view: 'member' }, 'y', ctx);
    assert.deepEqual(confirmed.action.args, ['--cluster-size', '3', '--fresh', '--build']);
    assert.equal(confirmed.state.confirm, null);
    assert.equal(confirmed.state.view, 'ops', 'a dispatched start shows its own output');
    assert.equal(confirmed.state.fresh, false, 'fresh is one-shot');
    assert.equal(confirmed.state.build, false, 'build is one-shot');
    const cancelled = handleKey(result.state, 'n', ctx);
    assert.equal(cancelled.action, null);
    assert.equal(cancelled.state.message.text, 'cancelled');

    result = handleKey(initialUiState(), 'x', ctx);
    assert.equal(handleKey(result.state, 'y', ctx).action.script, 'stop-cluster.sh');

    ui = handleKey(initialUiState(), '2', ctx).state;
    assert.equal(ui.selected, 2);
    assert.deepEqual(handleKey(ui, 'u', ctx).action.args, ['start', '2']);
    assert.deepEqual(handleKey(ui, 't', ctx).action.args, ['stop', '2']);
    assert.deepEqual(handleKey(ui, 'r', ctx).action.args, ['restart', '2']);
    const kill = handleKey(ui, 'k', ctx);
    assert.equal(kill.action, null);
    assert.deepEqual(handleKey(kill.state, 'Y', ctx).action.args, ['kill', '2']);

    assert.equal(handleKey(ui, '\u001b[B', ctx).state.selected, 0);
    assert.equal(handleKey(ui, '\u001b[A', ctx).state.selected, 1);
    assert.equal(handleKey(ui, '7', ctx).state.message.text, 'no member 7');
    assert.equal(handleKey(ui, 'l', ctx).state.view, 'member');
    const fromLogView = handleKey({ ...ui, view: 'member', fresh: true }, 'u', ctx);
    assert.equal(fromLogView.state.view, 'ops', 'member actions also switch to their output');
    assert.equal(fromLogView.state.fresh, true, 'member actions leave start toggles alone');
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('stopping a member that would break quorum asks first; busy blocks mutations', async () => {
  const { config, root } = await baseConfig();
  try {
    const degraded = snapshotFor(config, ['up', 'up', 'stopped']);
    const ui = { ...initialUiState(), selected: 1 };
    const stop = handleKey(ui, 't', { busy: false, config, snapshot: degraded });
    assert.equal(stop.action, null);
    assert.match(stop.state.confirm.prompt, /Leaves 1\/3 running; quorum needs 2\./);

    const busy = handleKey(ui, 'u', { busy: true, config, snapshot: degraded });
    assert.equal(busy.action, null);
    assert.match(busy.state.message.text, /operation is running/);

    const quit = handleKey(ui, 'q', { busy: true, config, snapshot: degraded });
    assert.equal(quit.action, null);
    assert.deepEqual(handleKey(quit.state, 'y', { busy: true, config, snapshot: degraded }).action, { interrupt: true, type: 'quit' });
    assert.deepEqual(handleKey(ui, 'q', { busy: false, config, snapshot: degraded }).action, { interrupt: false, type: 'quit' });
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('render shows members, quorum, runtime root and keys within the terminal width', async () => {
  const { config, root } = await baseConfig();
  try {
    const snapshot = snapshotFor(config, ['up', 'up', 'crashed']);
    const op = { args: ['stop', '2'], code: 0, endedAt: 5_000, label: 'stop validator-2', script: 'member.sh', startedAt: 2_000 };
    const width = 160;
    const lines = renderConsole({
      color: false,
      config,
      height: 32,
      now: 10_000,
      op,
      output: ['• Stopping validator-2', `✅ ${'x'.repeat(200)}`],
      snapshot,
      ui: { ...initialUiState(), selected: 2 },
      width,
    });
    const text = lines.join('\n');
    assert.equal(lines.length, 32);
    assert.match(text, /OAK CHAIN mock console/);
    assert.match(text, new RegExp(`runtime ${root.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
    assert.match(text, /quorum ✔ 2\/3 running · need 2 · leader 0 · healthy/);
    assert.match(text, /▸ 2\s+✕ crashed/);
    assert.match(text, /0\s+● up\s+LEADER\s+:8090/);
    assert.match(text, /✔ stop validator-2 · 3s/);
    assert.match(text, /ops :8787/);
    assert.match(text, /wallet 0x1234…5678/);
    assert.match(text, /s start {2}x stop all/);
    for (const narrow of [60, 96]) {
      for (const colorOn of [false, true]) {
        const clipped = renderConsole({ color: colorOn, config, height: 32, op, output: [`✅ ${'x'.repeat(200)}`], snapshot, ui: initialUiState(), width: narrow });
        for (const line of clipped) {
          assert.ok(Array.from(stripAnsi(line)).length <= narrow, `line wider than ${narrow}: ${stripAnsi(line)}`);
        }
      }
    }

    const colored = renderConsole({ color: true, config, height: 32, snapshot, ui: initialUiState(), width });
    assert.match(colored.join('\n'), /\u001b\[/);
    assert.equal(stripAnsi(colored.join('\n')).includes('undefined'), false);
    assert.equal(stripAnsi(clip(`\u001b[1mabcdef\u001b[0m`, 4)), 'abc…');
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('a fresh console attaches to a running cluster instead of offering a cold start', async () => {
  const { config, root } = await baseConfig();
  try {
    config.launch.LAUNCHED_AT = new Date(Date.now() - 120_000).toISOString();
    const view = (states) => renderConsole({
      color: false, config, height: 30, now: Date.now(), snapshot: snapshotFor(config, states), ui: initialUiState(), width: 140,
    }).join('\n');

    const running = view(['up', 'up', 'up']);
    assert.match(running, /ATTACHED {2}● cluster already running · 3\/3 up · launched \d\d:\d\d \(2m0\ds ago\)/);
    assert.match(running, /Picked up the cluster running under/);
    assert.match(running, /Nothing to start/);
    assert.doesNotMatch(running, /press s to start the cluster/);

    const degraded = view(['up', 'up', 'crashed']);
    assert.match(degraded, /2\/3 up/);
    assert.match(degraded, /validator-2 is down \(crashed, stale pid file\): select it and press u/);
    assert.match(degraded, /s start missing members/);

    const stopped = view(['stopped', 'stopped', 'stopped']);
    assert.match(stopped, /OPERATION {2}none yet · press s to start the cluster/);
    assert.doesNotMatch(stopped, /ATTACHED/);
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('member log view says which run the visible lines belong to', async () => {
  const { config, root } = await baseConfig();
  try {
    const now = Date.now();
    const render = (states, memberLogMtime) => renderConsole({
      color: false,
      config,
      height: 30,
      memberLog: ['2026-10-04 08:58:23.643 INFO shutdown'],
      memberLogMtime,
      now,
      snapshot: snapshotFor(config, states),
      ui: { ...initialUiState(), view: 'member' },
      width: 160,
    }).join('\n');

    assert.match(render(['stopped', 'stopped', 'stopped'], now - 40_000), /LOG {2}validator-0\.log · member down: previous run · last write \d\d:\d\d:\d\d \(40s ago\)/);
    // snapshotFor gives running members 65s of uptime: a 90s-old write predates the process.
    assert.match(render(['up', 'up', 'up'], now - 90_000), /validator-0\.log · earlier run; nothing from the current process yet · last write/);
    const live = render(['up', 'up', 'up'], now - 1_000);
    assert.match(live, /last write \d\d:\d\d:\d\d \(1s ago\)/);
    assert.doesNotMatch(live, /previous run|earlier run/);
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('probe reads pid files and validator health without touching real ports', async () => {
  const root = await tempRuntime();
  try {
    await writeFile(path.join(root, 'pids/validator-0.pid'), `${process.pid}\n`);
    await writeFile(path.join(root, 'pids/validator-2.pid'), '999999\n');
    await writeFile(path.join(root, 'cluster-keystore.properties'), 'walletAddress=0xabc\n');
    const config = await resolveConsoleConfig({
      env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root, OAK_VALIDATOR_HTTP_BASE_PORT: '18090' },
      repoRoot,
    });
    const seen = [];
    const fetchImpl = async (url) => {
      seen.push(url);
      if (url === 'http://127.0.0.1:18090/health') {
        return new Response(JSON.stringify({ clusterHealthy: true, currentRole: 'LEADER', reachableCount: 3, totalMembers: 3 }), { status: 200 });
      }
      if (url.endsWith('/api/v0/version')) return new Response('{}', { status: 200 });
      throw new Error('connection refused');
    };
    const snapshot = await probeCluster(config, { fetchImpl, psImpl: async () => new Map([[process.pid, 42_000]]) });
    const [zero, one, two] = snapshot.members;
    assert.equal(zero.state, 'up');
    assert.equal(zero.role, 'LEADER');
    assert.equal(zero.uptimeMs, 42_000);
    assert.equal(one.state, 'stopped');
    assert.equal(two.state, 'crashed');
    assert.deepEqual(snapshot.quorum, { healthy: true, leader: 0, need: 2, running: 1, size: 3 });
    assert.equal(snapshot.ipfs.code, 200);
    assert.equal(snapshot.ops.code, 0);
    assert.equal(snapshot.wallet, '0xabc');
    assert.ok(seen.every((url) => url.startsWith('http://127.0.0.1:')));
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

function run(command, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: repoRoot, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('exit', (code) => resolve({ code, stderr, stdout }));
  });
}

test('oak-chain mock console --once prints a plain status snapshot', async () => {
  const root = await tempRuntime();
  try {
    const env = {
      ...process.env,
      CLUSTER_RUNTIME_ROOT: root,
      IPFS_API_HTTP: 'http://127.0.0.1:9',
      NO_COLOR: '1',
      OAK_VALIDATOR_HTTP_BASE_PORT: '1',
      OPS_PROXY_PORT: '7',
    };
    delete env.PID_DIR;
    delete env.LOG_DIR;
    delete env.OAK_CLUSTER_SIZE;
    const result = await run('node', ['bin/oak-chain.mjs', 'mock', 'console', '--once'], env);
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /OAK CHAIN mock console/);
    assert.match(result.stdout, /3 members \(default\)/);
    assert.match(result.stdout, /cluster stopped/);
    assert.match(result.stdout, /0\s+○ stopped/);
    assert.equal(result.stdout.includes('\u001b['), false);
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function waitFor(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return false;
}

async function healthCode(port) {
  try {
    return (await fetch(`http://127.0.0.1:${port}/health/local`, { signal: AbortSignal.timeout(500) })).status;
  } catch (_error) {
    return 0;
  }
}

test('member.sh starts, stops, kills and refuses membership drift', { timeout: 60_000 }, async () => {
  const root = await tempRuntime();
  const port = await freePort();
  const stub = path.join(root, 'stub-validator.sh');
  await writeFile(stub, [
    '#!/bin/bash',
    'node_id="$1"',
    'port=$((OAK_VALIDATOR_HTTP_BASE_PORT + node_id * OAK_VALIDATOR_HTTP_PORT_STEP))',
    'exec node -e "require(\'http\').createServer((q,s)=>{s.writeHead(200,{\'content-type\':\'application/json\'});s.end(JSON.stringify({size:process.env.OAK_CLUSTER_SIZE}))}).listen(Number(process.argv[1]),\'127.0.0.1\')" "$port" --store "$CLUSTER_RUNTIME_ROOT/validator-$node_id"',
    '',
  ].join('\n'));
  await chmod(stub, 0o755);
  const env = {
    ...process.env,
    CLUSTER_RUNTIME_ROOT: root,
    OAK_VALIDATOR_HTTP_BASE_PORT: String(port),
    OAK_VALIDATOR_HTTP_PORT_STEP: '2',
    STOP_WAIT_SECONDS: '5',
    VALIDATOR_SCRIPT: stub,
  };
  delete env.PID_DIR;
  delete env.LOG_DIR;
  delete env.OAK_CLUSTER_SIZE;
  delete env.AERON_DIR_BASE;
  delete env.AERON_RAMDISK_ROOT;
  const pidFile = path.join(root, 'pids/validator-0.pid');
  const mediaDir = path.join(root, 'validator-0/aeron-media-0-driver');

  try {
    await mkdir(mediaDir, { recursive: true });
    let result = await run('bash', [memberScript, 'start', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /Clearing Aeron media-driver dir/);
    assert.ok(await waitFor(async () => (await healthCode(port)) === 200, 10_000), 'stub validator never answered');
    const pid = Number((await readFile(pidFile, 'utf8')).trim());
    assert.ok(pid > 0);

    result = await run('bash', [memberScript, 'start', '0'], env);
    assert.match(result.stdout, /already running/);

    result = await run('bash', [memberScript, 'status'], env);
    assert.match(result.stdout, new RegExp(`validator-0 state=UP pid=${pid} port=${port} http=200`));
    assert.match(result.stdout, /validator-1 state=DOWN/);

    result = await run('bash', [memberScript, 'stop', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /validator-0 stopped/);
    assert.ok(await waitFor(async () => (await healthCode(port)) === 0, 5_000));
    await assert.rejects(readFile(pidFile, 'utf8'));

    result = await run('bash', [memberScript, 'start', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.ok(await waitFor(async () => (await healthCode(port)) === 200, 10_000));
    result = await run('bash', [memberScript, 'kill', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /SIGKILL/);
    assert.ok(await waitFor(async () => (await healthCode(port)) === 0, 5_000));

    result = await run('bash', [memberScript, 'start', '3'], env);
    assert.equal(result.code, 1);
    assert.match(result.stdout, /outside this 3-member cluster/);

    await writeFile(path.join(root, 'pids/cluster-launch.env'), 'OAK_CLUSTER_SIZE=5\n');
    result = await run('bash', [memberScript, 'start', '0'], { ...env, OAK_CLUSTER_SIZE: '3' });
    assert.equal(result.code, 1);
    assert.match(result.stdout, /launched with OAK_CLUSTER_SIZE=5/);
  } finally {
    try {
      const pid = Number((await readFile(pidFile, 'utf8')).trim());
      if (pid > 0) process.kill(pid, 'SIGKILL');
    } catch (_error) {
      // Already stopped.
    }
    await rm(root, { force: true, recursive: true });
  }
});
