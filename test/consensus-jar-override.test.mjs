// The OAK_CONSENSUS_JAR override: both validator launchers run the given jar and pin its sha256, and
// member.sh restarts a member with the jar its launch record names. Every run uses a temporary HOME,
// runtime root and stubs (a stand-in `java` and launcher); no real validator is started.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lifecycleDir = path.join(repoRoot, 'modes/mock/validators/lifecycle');
const mockLauncher = path.join(repoRoot, 'modes/mock/validators/debug/run-validator-node.sh');
const sepoliaLauncher = path.join(repoRoot, 'modes/sepolia/validators/debug/run-validator-node.sh');

// A stand-in `java` on PATH: records its arguments and the jar-related environment, then exits.
async function stubJava(dir) {
  const bin = path.join(dir, 'bin');
  await mkdir(bin, { recursive: true });
  await writeFile(path.join(bin, 'java'), '#!/bin/bash\nprintf "%s\\n" "$@" > "$STUB_ARGS_FILE"\n');
  await chmod(path.join(bin, 'java'), 0o755);
  return bin;
}

async function launcherFixture() {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'oak-jar-override-'));
  const bin = await stubJava(dir);
  const workspace = path.join(dir, 'workspace');
  await mkdir(path.join(workspace, 'jackrabbit-oak'), { recursive: true });
  const jarDir = path.join(dir, 'jackrabbit-oak-fed/oak-segment-consensus/target');
  await mkdir(jarDir, { recursive: true });
  const jar = path.join(jarDir, 'oak-segment-consensus.jar');
  await writeFile(jar, 'federation jar bytes');
  const sha = createHash('sha256').update('federation jar bytes').digest('hex');
  const env = (extra = {}) => ({
    BLOBSTORE_TYPE: 'none',
    CLUSTER_RUNTIME_ROOT: path.join(dir, 'root'),
    HOME: dir,
    MODE_CONFIG_FILE: path.join(dir, 'no-such-sepolia.env'),
    OAK_BLOCKCHAIN_CONTRACT_ADDRESS: '0x0000000000000000000000000000000000000001',
    OAK_BLOCKCHAIN_RPC_URL: 'http://127.0.0.1:1',
    OAK_ROOT: workspace,
    PATH: `${bin}:${process.env.PATH}`,
    STUB_ARGS_FILE: path.join(dir, 'java-args.txt'),
    ...extra,
  });
  return { dir, env, jar, sha };
}

for (const [name, launcher] of [['mock', mockLauncher], ['sepolia', sepoliaLauncher]]) {
  test(`${name} run-validator-node.sh runs OAK_CONSENSUS_JAR, prints its sha256 and refuses a changed or bad jar`, async () => {
    const { dir, env, jar, sha } = await launcherFixture();
    try {
      const run = (extra) => spawnSync('bash', [launcher, '0'], { encoding: 'utf8', env: env(extra), timeout: 20_000 });
      const ok = run({ OAK_CONSENSUS_JAR: jar });
      assert.equal(ok.status, 0, ok.stdout + ok.stderr);
      assert.ok(ok.stdout.includes(`Consensus JAR override: ${jar} (sha256 ${sha})`), ok.stdout);
      const args = (await readFile(path.join(dir, 'java-args.txt'), 'utf8')).split('\n');
      assert.equal(args[args.indexOf('-jar') + 1], jar, 'java runs exactly the override jar');

      const pinned = run({ OAK_CONSENSUS_JAR: jar, OAK_CONSENSUS_JAR_SHA256: sha });
      assert.equal(pinned.status, 0, pinned.stdout);
      const changed = run({ OAK_CONSENSUS_JAR: jar, OAK_CONSENSUS_JAR_SHA256: 'f'.repeat(64) });
      assert.equal(changed.status, 1);
      assert.match(changed.stdout, /changed since the cluster was launched/);
      const relative = run({ OAK_CONSENSUS_JAR: 'oak-segment-consensus.jar' });
      assert.equal(relative.status, 1);
      assert.match(relative.stdout, /must be an absolute path/);
      const missing = run({ OAK_CONSENSUS_JAR: path.join(dir, 'missing.jar') });
      assert.equal(missing.status, 1);
      assert.match(missing.stdout, /does not exist/);
      const fallback = run({});
      assert.equal(fallback.status, 1, 'without the override the default workspace search is unchanged (and finds nothing here)');
      assert.match(fallback.stdout, /Cannot find oak-segment-consensus.jar/);
    } finally {
      await rm(dir, { force: true, recursive: true });
    }
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

test('member.sh restarts a member with the launch record\'s jar and sha256, and refuses another jar', { timeout: 30_000 }, async () => {
  const { dir, env, jar, sha } = await launcherFixture();
  const root = path.join(dir, 'member-root');
  const port = await freePort();
  try {
    await mkdir(path.join(root, 'pids'), { recursive: true });
    await writeFile(path.join(root, 'pids/cluster-launch.env'), [
      '# test', 'OAK_CLUSTER_SIZE=3', `OAK_VALIDATOR_HTTP_BASE_PORT=${port}`, 'OAK_VALIDATOR_HTTP_PORT_STEP=2',
      `OAK_CONSENSUS_JAR=${jar}`, `OAK_CONSENSUS_JAR_SHA256=${sha}`, '',
    ].join('\n'));
    // Stand-in launcher: records the jar it was handed, then idles briefly (it never binds a port).
    const stub = path.join(dir, 'stub-launcher.sh');
    await writeFile(stub, '#!/bin/bash\necho "$OAK_CONSENSUS_JAR|$OAK_CONSENSUS_JAR_SHA256" > "$STUB_ARGS_FILE.member"\nexec sleep 3\n');
    await chmod(stub, 0o755);
    const base = { ...env(), CLUSTER_RUNTIME_ROOT: root, VALIDATOR_SCRIPT: stub };
    const started = spawnSync('bash', [path.join(lifecycleDir, 'member.sh'), 'start', '0'], { encoding: 'utf8', env: base, timeout: 20_000 });
    assert.equal(started.status, 0, started.stdout + started.stderr);
    assert.match(started.stdout, new RegExp(`Consensus jar: ${jar.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} \\(sha256 ${sha}\\)`));
    assert.equal((await readFile(path.join(dir, 'java-args.txt.member'), 'utf8')).trim(), `${jar}|${sha}`);

    const other = spawnSync('bash', [path.join(lifecycleDir, 'member.sh'), 'status', '0'], {
      encoding: 'utf8', env: { ...base, OAK_CONSENSUS_JAR: path.join(dir, 'other.jar') }, timeout: 20_000,
    });
    assert.equal(other.status, 1);
    assert.match(other.stdout, /A member must run the jar its peers run/);
  } finally {
    // The stub exits by itself after 3 s; its command line names no store, so nothing else could match it.
    await rm(dir, { force: true, recursive: true });
  }
});
