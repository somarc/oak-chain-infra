import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const validatorsDir = path.join(repoRoot, 'modes/mock/validators');
const configDir = path.join(validatorsDir, 'config');
const lifecycleDir = path.join(validatorsDir, 'lifecycle');
const memberScript = path.join(lifecycleDir, 'member.sh');

function bash(script, args = [], env = {}) {
  const clean = { ...process.env, ...env };
  for (const key of ['IPFS_GATEWAY_BASE', 'IPFS_LOCAL_GATEWAY_BASE']) if (!(key in env)) delete clean[key];
  return spawnSync('bash', ['-c', script, 'test', ...args], { cwd: lifecycleDir, encoding: 'utf8', env: clean });
}

test('the IPFS gateway port is outside every port of every mock topology', async () => {
  const topologies = (await readdir(configDir))
    .filter((name) => name.endsWith('.env') && !/^(mock|ipfs)\.env$|common\.env$/.test(name));
  assert.ok(topologies.length >= 10, `found ${topologies.length} topology configs`);
  for (const name of topologies) {
    const result = bash(`
      set -a
      source "$1/mock.env"; source "$1/ipfs.env"; source "$1/$2"
      set +a
      source lib/root-guard.sh
      echo "gateway $(oak_guard_url_port "$IPFS_GATEWAY_BASE") $(oak_guard_url_port "$IPFS_LOCAL_GATEWAY_BASE")"
      echo "ports $(oak_guard_cluster_ports "\${OAK_CLUSTER_SIZE:-3}" "\${OAK_VALIDATOR_HTTP_BASE_PORT:-8090}" \
        "\${OAK_VALIDATOR_HTTP_PORT_STEP:-2}" "\${AERON_CLUSTER_BASE_PORT:-9000}" | tr '\\n' ' ') \${OPS_PROXY_PORT:-8787}"
    `, [configDir, name]);
    assert.equal(result.status, 0, `${name}: ${result.stderr}`);
    const gateways = result.stdout.match(/^gateway (.*)$/m)[1].split(' ');
    const ports = new Set(result.stdout.match(/^ports (.*)$/m)[1].trim().split(/\s+/));
    assert.deepEqual(gateways, ['5080', '5080'], name);
    for (const port of gateways) assert.ok(!ports.has(port), `${name}: gateway port ${port} collides with a cluster port`);
  }

  // The regression this guards: the old 8099 default is validator-4's second port at base 8090.
  const five = bash('source lib/root-guard.sh; oak_guard_cluster_ports 5 8090 2 9000');
  assert.ok(five.stdout.split('\n').includes('8099'));
});

test('ipfs-gateway helpers derive the daemon multiaddr and read the daemon config', () => {
  const result = bash(`
    source lib/ipfs-gateway.sh
    oak_ipfs_gateway_multiaddr http://127.0.0.1:5080/ipfs/
    oak_ipfs_gateway_multiaddr http://localhost/ipfs/
    oak_ipfs_gateway_multiaddr https://ipfs.io/ipfs/
    echo ---
    oak_ipfs_gateway_ports_from_config '{"Key":"Addresses.Gateway","Value":"/ip4/127.0.0.1/tcp/8099"}'
    echo ---
    oak_ipfs_gateway_ports_from_config '{"Key":"Addresses.Gateway","Value":["/ip4/127.0.0.1/tcp/5080","/ip6/::1/tcp/5080"]}'
    echo ---
    oak_ipfs_gateway_fix_hint
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, [
    '/ip4/127.0.0.1/tcp/5080', '/ip4/127.0.0.1/tcp/80', '---', '8099', '---', '5080', '---',
    'ipfs config Addresses.Gateway /ip4/127.0.0.1/tcp/5080', '',
  ].join('\n'));
});

test('root guard names the IPFS gateway when the daemon holds a validator port', () => {
  const result = bash(`
    source lib/root-guard.sh
    oak_guard_foreign_holders() { printf '%s\\n' "8099 7057 /opt/homebrew/bin/ipfs daemon --enable-gc" "9000 42 java -jar other.jar"; }
    oak_guard_require_owned_ports /tmp/root /tmp/root/pids --fresh 8099 9000
    echo "rc=$?"
    oak_guard_foreign_holders() { echo "8099 42 java -jar oak-segment-consensus.jar --store /x/validator-4"; }
    oak_guard_require_owned_ports /tmp/root /tmp/root/pids --fresh 8099
  `);
  assert.match(result.stdout, /rc=1/);
  const [withIpfs, withoutIpfs] = result.stderr.split(/(?=❌ Refusing)/);
  assert.match(withIpfs, /Port 8099 is held by the IPFS daemon \(pid 7057\)/);
  assert.match(withIpfs, /ipfs config Addresses\.Gateway \/ip4\/127\.0\.0\.1\/tcp\/5080/);
  assert.doesNotMatch(withoutIpfs, /IPFS/);
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

function run(args, env) {
  return new Promise((resolve) => {
    const child = spawn('bash', [memberScript, ...args], { cwd: repoRoot, env });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stdout += chunk; });
    child.on('close', (code) => resolve({ code, stdout }));
  });
}

async function reportedGateway(port) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      return await (await fetch(`http://127.0.0.1:${port}/`, { signal: AbortSignal.timeout(500) })).json();
    } catch (_error) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error('stub validator never answered');
}

test('member.sh restarts members with the gateway bases their cluster was launched with', { timeout: 60_000 }, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'oak-gateway-test-'));
  await mkdir(path.join(root, 'pids'), { recursive: true });
  const port = await freePort();
  const stub = path.join(root, 'stub-validator.sh');
  await writeFile(stub, [
    '#!/bin/bash',
    'port=$((OAK_VALIDATOR_HTTP_BASE_PORT + $1 * OAK_VALIDATOR_HTTP_PORT_STEP))',
    'exec node -e "require(\'http\').createServer((q,s)=>{s.end(JSON.stringify({gateway:process.env.IPFS_GATEWAY_BASE??null,local:process.env.IPFS_LOCAL_GATEWAY_BASE??null}))}).listen(Number(process.argv[1]),\'127.0.0.1\')" "$port" --store "$CLUSTER_RUNTIME_ROOT/validator-$1"',
    '',
  ].join('\n'));
  await chmod(stub, 0o755);
  const env = { ...process.env, CLUSTER_RUNTIME_ROOT: root, STOP_WAIT_SECONDS: '5', VALIDATOR_SCRIPT: stub };
  for (const key of ['PID_DIR', 'LOG_DIR', 'OAK_CLUSTER_SIZE', 'OAK_VALIDATOR_HTTP_BASE_PORT', 'OAK_VALIDATOR_HTTP_PORT_STEP',
    'AERON_CLUSTER_BASE_PORT', 'AERON_DIR_BASE', 'AERON_RAMDISK_ROOT', 'EXTRA_JAVA_OPTS', 'IPFS_GATEWAY_BASE', 'IPFS_LOCAL_GATEWAY_BASE']) {
    delete env[key];
  }
  const record = path.join(root, 'pids/cluster-launch.env');
  const membership = `OAK_CLUSTER_SIZE=3\nOAK_VALIDATOR_HTTP_BASE_PORT=${port}\nOAK_VALIDATOR_HTTP_PORT_STEP=2\n`;
  const restart = async (expected, extraEnv = {}) => {
    let result = await run(['start', '0'], { ...env, ...extraEnv });
    assert.equal(result.code, 0, result.stdout);
    assert.deepEqual(await reportedGateway(port), expected);
    result = await run(['stop', '0'], env);
    assert.equal(result.code, 0, result.stdout);
  };

  try {
    // Launched before the gateway was recorded: the cluster ran with the old 8099 default.
    await writeFile(record, membership);
    const legacy = 'http://127.0.0.1:8099/ipfs/';
    await restart({ gateway: legacy, local: legacy });
    let result = await run(['start', '0'], { ...env, IPFS_GATEWAY_BASE: 'http://127.0.0.1:5080/ipfs/' });
    assert.equal(result.code, 1);
    assert.match(result.stdout, /IPFS_GATEWAY_BASE=http:\/\/127\.0\.0\.1:5080\/ipfs\/ in your environment, but this cluster was launched with IPFS_GATEWAY_BASE=http:\/\/127\.0\.0\.1:8099\/ipfs\//);

    const current = 'http://127.0.0.1:5080/ipfs/';
    await writeFile(record, `${membership}IPFS_GATEWAY_BASE=${current}\nIPFS_LOCAL_GATEWAY_BASE=${current}\n`);
    await restart({ gateway: current, local: current });
    await restart({ gateway: current, local: current }, { IPFS_GATEWAY_BASE: current });
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
