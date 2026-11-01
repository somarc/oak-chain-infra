import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lib = path.join(repoRoot, 'modes/mock/validators/tests/lib/_sharding_health_lib.sh');

const DIGEST = 'a'.repeat(64);

function mount(overrides = {}) {
  return {
    available: true, circuit: 'CLOSED', connected: true, endpoint: 'http://127.0.0.1:8190',
    lastError: null, lastRefreshAt: 1, prefixes: '80-ff', revision: 'r1', ...overrides,
  };
}

function sharding(overrides = {}) {
  return {
    authoritativeStoreSeparated: true,
    configDigest: DIGEST,
    enabled: true,
    localPrefixes: '00-7f',
    remoteEndpointCount: 1,
    remoteEndpointsAvailable: 1,
    remoteMountCount: 128,
    remoteMounts: [mount()],
    ...overrides,
  };
}

// Fake members: each answers GET /health with whatever its health() returns at that moment.
async function members(healths) {
  const servers = await Promise.all(healths.map((health) => new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(health()));
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  })));
  return {
    close: () => Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve)))),
    ports: servers.map((server) => String(server.address().port)),
  };
}

function bash(script, args) {
  return new Promise((resolve) => {
    const child = spawn('bash', ['-c', `set -euo pipefail; source "$0"; ${script}`, lib, ...args], {
      env: { ...process.env, SHARDING_HEALTH_POLL_SECONDS: '0.2' },
    });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stdout += chunk; });
    child.on('close', (code) => resolve({ code, stdout }));
  });
}

const assertMembers = (ports) => bash('sharding_assert_cluster_members cluster-a 00-7f 128 "$@"', ports);
const waitMounts = (ports, timeout = 5) => bash(`sharding_wait_mounts_available ${timeout} "$@"`, ports);

test('every member sharded with one digest and all mounts available passes', async () => {
  const cluster = await members([() => ({ sharding: sharding() }), () => ({ sharding: sharding() }), () => ({ sharding: sharding() })]);
  try {
    let result = await assertMembers(cluster.ports);
    assert.equal(result.code, 0, result.stdout);
    for (const port of cluster.ports) assert.match(result.stdout, new RegExp(`✅ cluster-a port ${port} sharding: enabled`));
    assert.match(result.stdout, new RegExp(`configDigest identical on all 3 members: ${DIGEST}`));
    result = await waitMounts(cluster.ports);
    assert.equal(result.code, 0, result.stdout);
    assert.match(result.stdout, /remote mounts available on all 3 members/);
  } finally {
    await cluster.close();
  }
});

test('a member with a different configDigest is named', async () => {
  const other = 'b'.repeat(64);
  const cluster = await members([() => ({ sharding: sharding() }), () => ({ sharding: sharding({ configDigest: other }) }), () => ({ sharding: sharding() })]);
  try {
    const result = await assertMembers(cluster.ports);
    assert.equal(result.code, 1);
    assert.match(result.stdout, new RegExp(`configDigest diverges: port\\(s\\) ${cluster.ports[1]} differ from port ${cluster.ports[0]}`));
    assert.match(result.stdout, new RegExp(`port ${cluster.ports[1]}: ${other}`));
  } finally {
    await cluster.close();
  }
});

test('an unsharded member that is not validator-0 fails the cluster', async () => {
  const cluster = await members([() => ({ sharding: sharding() }), () => ({ sharding: sharding() }), () => ({ sharding: { enabled: false } })]);
  try {
    const result = await assertMembers(cluster.ports);
    assert.equal(result.code, 1);
    assert.match(result.stdout, new RegExp(`❌ cluster-a port ${cluster.ports[2]} sharding: sharding.enabled is false`));
  } finally {
    await cluster.close();
  }
});

test('a wrong remoteMountCount still fails as config sanity', async () => {
  const cluster = await members([() => ({ sharding: sharding({ remoteMountCount: 127 }) })]);
  try {
    const result = await assertMembers(cluster.ports);
    assert.equal(result.code, 1);
    assert.match(result.stdout, /remoteMountCount is 127, expected 128/);
  } finally {
    await cluster.close();
  }
});

test('a runtime without per-mount health fails fast instead of passing', async () => {
  const legacy = { authoritativeStoreSeparated: true, enabled: true, localPrefixes: '00-7f', remoteMountCount: 128 };
  const cluster = await members([() => ({ sharding: legacy })]);
  try {
    let result = await assertMembers(cluster.ports);
    assert.equal(result.code, 1);
    assert.match(result.stdout, /requires oak-segment-consensus with per-mount health \(fix\/cluster-of-clusters-phase0\)/);
    const started = Date.now();
    result = await waitMounts(cluster.ports, 30);
    assert.equal(result.code, 1);
    assert.match(result.stdout, /requires oak-segment-consensus with per-mount health/);
    assert.ok(Date.now() - started < 10_000, 'did not wait out the deadline');
  } finally {
    await cluster.close();
  }
});

test('mounts that stay unavailable fail at the deadline with each mount\'s lastError', async () => {
  const down = sharding({
    remoteEndpointsAvailable: 0,
    remoteMounts: [mount({ available: false, circuit: 'OPEN', connected: false, lastError: 'Connection refused' })],
  });
  const cluster = await members([() => ({ sharding: sharding() }), () => ({ sharding: down })]);
  try {
    const result = await waitMounts(cluster.ports, 1);
    assert.equal(result.code, 1);
    assert.match(result.stdout, new RegExp(`not all available after 1s on port\\(s\\) ${cluster.ports[1]}:`));
    assert.match(result.stdout, /0\/1 remote endpoints available/);
    assert.match(result.stdout, /http:\/\/127\.0\.0\.1:8190 \[80-ff\] connected=false available=false circuit=OPEN .*lastError="Connection refused"/);
  } finally {
    await cluster.close();
  }
});

test('the mount gate waits for mounts that come up before the deadline', async () => {
  let calls = 0;
  const cluster = await members([() => {
    calls += 1;
    return { sharding: calls < 3 ? sharding({ remoteEndpointsAvailable: 0, remoteMounts: [mount({ available: false })] }) : sharding() };
  }]);
  try {
    const result = await waitMounts(cluster.ports, 10);
    assert.equal(result.code, 0, result.stdout);
    assert.ok(calls >= 3);
  } finally {
    await cluster.close();
  }
});

test('a member that does not answer keeps the gate waiting, then fails', async () => {
  const cluster = await members([() => ({ sharding: sharding() })]);
  const port = cluster.ports[0];
  await cluster.close();
  const result = await waitMounts([port], 1);
  assert.equal(result.code, 1);
  assert.match(result.stdout, /no \/health JSON/);
});
