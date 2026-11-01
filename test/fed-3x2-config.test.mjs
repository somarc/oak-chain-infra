// Enterprise-federation 3x2 config pack (modes/mock/validators/config/fed-3x2-*.env) and its root
// guard (lifecycle/lib/fed-3x2.sh). Every run sources the pack under a temporary HOME.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, rm, symlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const configDir = path.join(repoRoot, 'modes/mock/validators/config');
const lifecycleDir = path.join(repoRoot, 'modes/mock/validators/lifecycle');

const VARS = ['FED_3X2_ROOT', 'CLUSTER_RUNTIME_ROOT', 'PID_DIR', 'LOG_DIR', 'AERON_DIR_BASE', 'CLUSTER_WALLET_FILE', 'OAK_CLUSTER_NAME',
  'OAK_CLUSTER_SIZE', 'OAK_VALIDATOR_HTTP_BASE_PORT', 'OAK_VALIDATOR_HTTP_PORT_STEP', 'AERON_CLUSTER_BASE_PORT', 'OPS_PROXY_PORT',
  'EXTRA_JAVA_OPTS', 'FED_3X2_DIRECTORY_FILE', 'FED_3X2_ENTERPRISE_ID', 'AUTO_START_IPFS'];

// Source mock.env, ipfs.env and one cluster file exactly as the wrappers do; print the result as JSON.
function loadPack(file, env) {
  const script = `set -euo pipefail; set -a; source "$1/mock.env"; source "$1/ipfs.env"; source "$1/$2"; set +a
node -e 'const o={}; for (const k of process.argv.slice(1)) o[k]=process.env[k]; console.log(JSON.stringify(o))' ${VARS.join(' ')}`;
  const result = spawnSync('bash', ['-c', script, 'pack', configDir, file], { encoding: 'utf8', env });
  return { ...result, vars: result.status === 0 ? JSON.parse(result.stdout) : null };
}

function cleanEnv(home, extra = {}) {
  const env = { HOME: home, PATH: process.env.PATH, ...extra };
  return env;
}

function ports(vars) {
  const base = Number(vars.OAK_VALIDATOR_HTTP_BASE_PORT);
  const step = Number(vars.OAK_VALIDATOR_HTTP_PORT_STEP);
  const aeron = Number(vars.AERON_CLUSTER_BASE_PORT);
  const out = [];
  for (let node = 0; node < Number(vars.OAK_CLUSTER_SIZE); node += 1) {
    out.push(base + node * step, base + 1 + node * step);
    for (let offset = 0; offset <= 6; offset += 1) out.push(aeron + node * 100 + offset);
  }
  out.push(Number(vars.OPS_PROXY_PORT));
  return out;
}

const range = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
// The long-lived user cluster (HTTP 8090-8095 + standby, OPS 8787, Aeron 9000-9206), the shared IPFS
// daemon (5001 API, 5080 gateway) and the usual local services.
const RESERVED = new Set([...range(8090, 8095), 8787, ...range(9000, 9206), 5001, 5080, 8080, 8081, 8088, 8099]);

test('fed-3x2 cluster ports never overlap each other, the 3x2 pack, or the reserved local ports', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-pack-'));
  try {
    const a = loadPack('fed-3x2-cluster-a.env', cleanEnv(home));
    const b = loadPack('fed-3x2-cluster-b.env', cleanEnv(home));
    assert.equal(a.status, 0, a.stderr);
    assert.equal(b.status, 0, b.stderr);
    const pa = ports(a.vars);
    const pb = ports(b.vars);
    assert.equal(new Set(pa).size, pa.length, 'no overlap within cluster A');
    assert.equal(new Set(pb).size, pb.length, 'no overlap within cluster B');
    assert.deepEqual(pa.filter((p) => pb.includes(p)), [], 'no overlap between A and B');
    assert.deepEqual([...pa, ...pb].filter((p) => RESERVED.has(p)), [], 'no reserved port');
    const legacyA = loadPack('3x2-cluster-a.env', cleanEnv(home));
    const legacyB = loadPack('3x2-cluster-b.env', cleanEnv(home));
    const legacy = new Set([...ports(legacyA.vars), ...ports(legacyB.vars)]);
    assert.deepEqual([...pa, ...pb].filter((p) => legacy.has(p)), [], 'can run next to the 3x2 sharding pack');

    assert.equal(a.vars.OAK_VALIDATOR_HTTP_BASE_PORT, '8290');
    assert.equal(a.vars.AERON_CLUSTER_BASE_PORT, '9800');
    assert.equal(a.vars.OPS_PROXY_PORT, '8797');
    assert.equal(b.vars.OAK_VALIDATOR_HTTP_BASE_PORT, '8390');
    assert.equal(b.vars.AERON_CLUSTER_BASE_PORT, '10200');
    assert.equal(b.vars.OPS_PROXY_PORT, '8798');
  } finally {
    await rm(home, { force: true, recursive: true });
  }
});

test('fed-3x2 roots live under the federation root, outside $HOME/oak-chain, and share one directory file', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-pack-'));
  try {
    const a = loadPack('fed-3x2-cluster-a.env', cleanEnv(home)).vars;
    const b = loadPack('fed-3x2-cluster-b.env', cleanEnv(home)).vars;
    const fedRoot = path.join(home, 'oak-chain-federation/3x2');
    assert.equal(a.FED_3X2_ROOT, fedRoot);
    assert.equal(a.CLUSTER_RUNTIME_ROOT, `${fedRoot}/cluster-a`);
    assert.equal(b.CLUSTER_RUNTIME_ROOT, `${fedRoot}/cluster-b`);
    for (const vars of [a, b]) {
      for (const key of ['CLUSTER_RUNTIME_ROOT', 'PID_DIR', 'LOG_DIR', 'AERON_DIR_BASE', 'CLUSTER_WALLET_FILE', 'FED_3X2_DIRECTORY_FILE']) {
        assert.ok(vars[key].startsWith(`${fedRoot}/`), `${key}=${vars[key]}`);
        assert.ok(!`${vars[key]}/`.startsWith(`${home}/oak-chain/`), `${key} outside $HOME/oak-chain`);
      }
      assert.doesNotMatch(vars.EXTRA_JAVA_OPTS, /oak\.sharding\./, 'the directory replaces static shard routes');
      assert.match(vars.EXTRA_JAVA_OPTS, /-Doak\.federation\.mode=mock -Doak\.federation\.registry=static /);
      assert.ok(vars.EXTRA_JAVA_OPTS.includes(`-Doak.federation.directoryFile=${fedRoot}/directory.json`));
      assert.match(vars.EXTRA_JAVA_OPTS, /-Doak\.federation\.pollMs=2000$/);
      assert.equal(vars.AUTO_START_IPFS, 'false', 'never starts the shared IPFS daemon');
    }
    assert.equal(a.FED_3X2_DIRECTORY_FILE, b.FED_3X2_DIRECTORY_FILE);
    assert.equal(a.FED_3X2_ENTERPRISE_ID, `0x${'a1'.repeat(32)}`);
    assert.equal(b.FED_3X2_ENTERPRISE_ID, `0x${'b2'.repeat(32)}`);
    assert.ok(a.EXTRA_JAVA_OPTS.includes(`-Doak.federation.enterpriseId=0x${'a1'.repeat(32)} `));
    assert.ok(b.EXTRA_JAVA_OPTS.includes(`-Doak.federation.enterpriseId=0x${'b2'.repeat(32)} `));

    const custom = loadPack('fed-3x2-cluster-b.env', cleanEnv(home, { FED_3X2_ROOT: path.join(home, 'elsewhere/fed') })).vars;
    assert.equal(custom.CLUSTER_RUNTIME_ROOT, path.join(home, 'elsewhere/fed/cluster-b'));
  } finally {
    await rm(home, { force: true, recursive: true });
  }
});

test('fed-3x2 refuses federation roots at, under, above or symlinked into $HOME/oak-chain', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-pack-'));
  try {
    await mkdir(path.join(home, 'oak-chain'), { recursive: true });
    await symlink(path.join(home, 'oak-chain'), path.join(home, 'alias'));
    const refused = [
      path.join(home, 'oak-chain'),
      path.join(home, 'oak-chain/'),
      path.join(home, 'oak-chain/federation/3x2'),
      path.join(home, 'alias/fed'),
      home,
      path.dirname(home),
      'relative/fed',
      `${home}/with space`,
      `${home}/x/../oak-chain/y`,
    ];
    for (const root of refused) {
      for (const file of ['fed-3x2-cluster-a.env', 'fed-3x2-cluster-b.env']) {
        const result = loadPack(file, cleanEnv(home, { FED_3X2_ROOT: root }));
        assert.notEqual(result.status, 0, `${file} must refuse ${root}`);
        assert.match(result.stderr, /Refusing federation 3x2/, root);
      }
    }
    const extra = loadPack('fed-3x2-cluster-a.env', cleanEnv(home, { FED_3X2_ROOT: '/tmp/fed-x', OAK_PROTECTED_ROOTS: '/tmp' }));
    assert.notEqual(extra.status, 0, 'OAK_PROTECTED_ROOTS extends the protected set');
    const sibling = loadPack('fed-3x2-cluster-a.env', cleanEnv(home, { FED_3X2_ROOT: path.join(home, 'oak-chain-federation/3x2') }));
    assert.equal(sibling.status, 0, `a sibling of oak-chain is fine: ${sibling.stderr}`);
  } finally {
    await rm(home, { force: true, recursive: true });
  }
});

test('fed_3x2_load_cluster_env keeps every lifecycle path under the federation root', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-pack-'));
  try {
    const run = (extra) => spawnSync('bash', ['-c', 'source "$1/lib/fed-3x2.sh"; fed_3x2_load_cluster_env "$2" a && echo "$CLUSTER_RUNTIME_ROOT|$PID_DIR"', 'x', lifecycleDir, configDir], {
      encoding: 'utf8', env: cleanEnv(home, extra),
    });
    const ok = run({ PID_DIR: '/somewhere/else', CLUSTER_RUNTIME_ROOT: '/also/else' });
    assert.equal(ok.status, 0, ok.stderr);
    assert.equal(ok.stdout.trim(), `${home}/oak-chain-federation/3x2/cluster-a|${home}/oak-chain-federation/3x2/cluster-a/pids`, 'the pack wins over a stray environment');
    const refused = run({ FED_3X2_ROOT: path.join(home, 'oak-chain/x') });
    assert.notEqual(refused.status, 0);
    assert.equal(refused.stdout, '', 'nothing is printed (nor run) after a refusal');
  } finally {
    await rm(home, { force: true, recursive: true });
  }
});
