import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseLaunchRecord, resolveConsoleConfig } from '../src/mock-console.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lifecycleDir = path.join(repoRoot, 'modes/mock/validators/lifecycle');
const recordLib = path.join(lifecycleDir, 'lib/launch-record.sh');
const memberScript = path.join(lifecycleDir, 'member.sh');

// The 3x3 cluster-A sharding flags: spaces, ';', '=' and ':' all inside one value. The trailing
// `-Dx.empty=` checks that a value ending in '=' keeps it (bash `IFS='=' read` would drop it).
const SHARDED_OPTS = '-Doak.sharding.enabled=true -Doak.sharding.local.prefixes=00-55 '
  + '-Doak.sharding.remote.routes=56-aa=http://127.0.0.1:8190;ab-ff=http://127.0.0.1:8290 -Dx.empty=';

async function tempRuntime() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'oak-launch-record-test-'));
  await mkdir(path.join(root, 'pids'), { recursive: true });
  await mkdir(path.join(root, 'logs'), { recursive: true });
  return root;
}

// Write the record with the same shell function start-cluster.sh uses.
function writeRecord(file, ...pairs) {
  return spawnSync('bash', ['-c', 'source "$1"; f="$2"; shift 2; oak_launch_record_write "$f" "$@"', 'test', recordLib, file, ...pairs], {
    encoding: 'utf8',
  });
}

function run(cmd, args, env) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd: repoRoot, env });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('close', (code) => resolve({ code, stderr, stdout }));
  });
}

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

async function reportedOpts(port, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health/local`, { signal: AbortSignal.timeout(500) });
      return (await response.json()).opts;
    } catch (_error) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error('stub validator never answered');
}

test('launch record writer keeps EXTRA_JAVA_OPTS verbatim and the console parser reads it back', async () => {
  const root = await tempRuntime();
  try {
    const record = path.join(root, 'pids/cluster-launch.env');
    const written = writeRecord(record, 'OAK_CLUSTER_SIZE=3', `EXTRA_JAVA_OPTS=${SHARDED_OPTS}`, 'AERON_DIR_BASE=');
    assert.equal(written.status, 0, written.stderr);
    assert.ok(!existsSync(`${record}.tmp`));
    const text = await readFile(record, 'utf8');
    assert.ok(text.includes(`\nEXTRA_JAVA_OPTS=${SHARDED_OPTS}\n`), text);

    const parsed = parseLaunchRecord(text);
    assert.equal(parsed.EXTRA_JAVA_OPTS, SHARDED_OPTS);
    assert.equal(parsed.AERON_DIR_BASE, '');

    const config = await resolveConsoleConfig({ env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root }, repoRoot });
    assert.equal(config.extraJavaOpts, SHARDED_OPTS);
    assert.equal(config.childEnv.EXTRA_JAVA_OPTS, SHARDED_OPTS, 'console-run scripts get the recorded sharding flags');
    assert.deepEqual(config.warnings, []);

    const overridden = await resolveConsoleConfig({
      env: { HOME: '/h', CLUSTER_RUNTIME_ROOT: root, EXTRA_JAVA_OPTS: '-Dother=1' },
      repoRoot,
    });
    assert.equal(overridden.childEnv.EXTRA_JAVA_OPTS, '-Dother=1', 'the environment wins');
    assert.match(overridden.warnings.join('\n'), /EXTRA_JAVA_OPTS differs/);
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('launch record writer refuses a value with a line break', async () => {
  const root = await tempRuntime();
  try {
    const record = path.join(root, 'pids/cluster-launch.env');
    const written = writeRecord(record, 'OAK_CLUSTER_SIZE=3', 'EXTRA_JAVA_OPTS=-Da=1\n-Db=2');
    assert.equal(written.status, 1);
    assert.match(written.stderr, /EXTRA_JAVA_OPTS contains a line break/);
    assert.ok(!existsSync(record));
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test('member.sh restores EXTRA_JAVA_OPTS from the launch record, and tolerates records without it', { timeout: 60_000 }, async () => {
  const root = await tempRuntime();
  const port = await freePort();
  const stub = path.join(root, 'stub-validator.sh');
  // Stand-in validator: names its store dir (so member.sh tracks it) and reports its EXTRA_JAVA_OPTS.
  await writeFile(stub, [
    '#!/bin/bash',
    'node_id="$1"',
    'port=$((OAK_VALIDATOR_HTTP_BASE_PORT + node_id * OAK_VALIDATOR_HTTP_PORT_STEP))',
    'exec node -e "require(\'http\').createServer((q,s)=>{s.writeHead(200,{\'content-type\':\'application/json\'});s.end(JSON.stringify({opts:process.env.EXTRA_JAVA_OPTS??null}))}).listen(Number(process.argv[1]),\'127.0.0.1\')" "$port" --store "$CLUSTER_RUNTIME_ROOT/validator-$node_id"',
    '',
  ].join('\n'));
  await chmod(stub, 0o755);
  const env = {
    ...process.env,
    CLUSTER_RUNTIME_ROOT: root,
    STOP_WAIT_SECONDS: '5',
    VALIDATOR_SCRIPT: stub,
  };
  for (const key of ['PID_DIR', 'LOG_DIR', 'OAK_CLUSTER_SIZE', 'AERON_DIR_BASE', 'AERON_RAMDISK_ROOT', 'EXTRA_JAVA_OPTS',
    'OAK_VALIDATOR_HTTP_BASE_PORT', 'OAK_VALIDATOR_HTTP_PORT_STEP', 'AERON_CLUSTER_BASE_PORT']) {
    delete env[key];
  }
  const record = path.join(root, 'pids/cluster-launch.env');
  const membership = ['OAK_CLUSTER_SIZE=3', `OAK_VALIDATOR_HTTP_BASE_PORT=${port}`, 'OAK_VALIDATOR_HTTP_PORT_STEP=2'];

  try {
    assert.equal(writeRecord(record, ...membership, `EXTRA_JAVA_OPTS=${SHARDED_OPTS}`).status, 0);
    let result = await run('bash', [memberScript, 'start', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.ok(result.stdout.includes(`Extra JVM opts (launch record): ${SHARDED_OPTS}`), result.stdout);
    assert.equal(await reportedOpts(port), SHARDED_OPTS, 'restarted member is sharded exactly as launched');
    result = await run('bash', [memberScript, 'stop', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);

    result = await run('bash', [memberScript, 'start', '0'], { ...env, EXTRA_JAVA_OPTS: '-Dother=1' });
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /EXTRA_JAVA_OPTS in your environment differs from the launch record/);
    assert.equal(await reportedOpts(port), '-Dother=1');
    result = await run('bash', [memberScript, 'stop', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);

    // A record written before EXTRA_JAVA_OPTS was persisted (single-cluster launches).
    await writeFile(record, `${membership.join('\n')}\n`);
    result = await run('bash', [memberScript, 'start', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.doesNotMatch(result.stdout, /Extra JVM opts/);
    assert.equal(await reportedOpts(port), null);
    result = await run('bash', [memberScript, 'stop', '0'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
  } finally {
    try {
      const pid = Number((await readFile(path.join(root, 'pids/validator-0.pid'), 'utf8')).trim());
      if (pid > 0) process.kill(pid, 'SIGKILL');
    } catch (_error) {
      // Already stopped.
    }
    await rm(root, { force: true, recursive: true });
  }
});
