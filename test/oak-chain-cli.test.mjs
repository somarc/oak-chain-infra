import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';

const repoRoot = '/Users/mhess/aem/aem-code/OAK/oak-chain-infra';
const cliPath = path.join(repoRoot, 'bin/oak-chain.mjs');

function runCli(args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn('node', [cliPath, ...args], {
      cwd: repoRoot,
      env: { ...process.env, ...options.env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', reject);
    child.on('exit', (code) => {
      resolve({ code, stderr, stdout });
    });
  });
}

function startFixtureServer(handler) {
  const server = http.createServer((request, response) => {
    const result = handler(request.url, request);
    if (!result) {
      response.writeHead(404, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: 'not found' }));
      return;
    }

    const statusCode = result.statusCode || 200;
    response.writeHead(statusCode, { 'content-type': 'application/json' });
    response.end(JSON.stringify(result.body ?? result));
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve({
        close: () => new Promise((done) => server.close(done)),
        url: `http://127.0.0.1:${address.port}`,
      });
    });
  });
}

async function startClusterFixture(options = {}) {
  const state = {
    peerUrl: '',
    seedUrl: '',
  };

  const peer = await startFixtureServer((url) => {
    const payloads = {
      '/health/local': { body: { status: 'UP', success: true } },
      '/v1/consensus/status': {
        body: {
          consensusType: 'aeron-cluster',
          contractVersion: 'consensus.status.v1',
          currentEpoch: 33,
          currentLeader: state.seedUrl,
          currentRole: 'FOLLOWER',
          currentTerm: 7,
          isLeader: false,
          reachableValidators: 2,
        },
      },
      '/v1/ops/snapshots/replication': {
        body: {
          contractVersion: 'ops.v1',
          data: {
            healthy: true,
            replicationLag: 0,
          },
          degraded: false,
          degradedReason: null,
        },
      },
      '/v1/peers': {
        body: [
          { status: 'READY', validatorId: '0xpeer', validatorUrl: state.peerUrl },
          { status: 'READY', validatorId: '0xseed', validatorUrl: state.seedUrl },
        ],
      },
    };
    return payloads[url];
  });
  state.peerUrl = peer.url;

  const seed = await startFixtureServer((url) => {
    const payloads = {
      '/health/local': { body: { status: 'UP', success: true } },
      '/v1/consensus/leader': {
        body: {
          contractVersion: 'consensus.leader.v1',
          currentLeader: state.seedUrl,
          currentRole: 'LEADER',
          currentTerm: 7,
          isLeader: true,
          leaderKnown: true,
        },
      },
      '/v1/consensus/status': {
        body: {
          consensusType: 'aeron-cluster',
          contractVersion: 'consensus.status.v1',
          currentEpoch: 33,
          currentLeader: state.seedUrl,
          currentRole: 'LEADER',
          currentTerm: 7,
          isLeader: true,
          reachableValidators: 2,
        },
      },
      '/v1/events/recent': { body: [] },
      '/v1/index': { body: { routes: ['/v1/consensus/status'] } },
      '/v1/ops/snapshots/health': {
        body: { contractVersion: 'ops.v1', status: 'healthy' },
      },
      '/v1/ops/snapshots/queue': {
        body: { queuePending: 3, mempoolPendingCount: 5 },
      },
      '/v1/ops/snapshots/replication': {
        body: options.replicationContradiction
          ? {
              contractVersion: 'ops.v1',
              data: {
                healthy: false,
                reason: 'leader_log_position_unknown',
                replicationLag: -1,
              },
              degraded: false,
              degradedReason: null,
            }
          : {
              contractVersion: 'ops.v1',
              data: {
                healthy: true,
                replicationLag: 0,
              },
              degraded: false,
              degradedReason: null,
            },
      },
      '/v1/peers': {
        body: [
          { status: 'READY', validatorId: '0xseed', validatorUrl: state.seedUrl },
          { status: 'READY', validatorId: '0xpeer', validatorUrl: state.peerUrl },
        ],
      },
      '/v1/proposals/proposal-123/status': {
        body: { proposalId: 'proposal-123', status: 'COMMITTED' },
      },
      '/v1/proposals/release-flow': {
        body: {
          releaseMode: 'adaptive',
          releaseStages: { verifiedResidentProposalCount: 2 },
        },
      },
    };
    return payloads[url];
  });
  state.seedUrl = seed.url;

  return {
    close: async () => {
      await peer.close();
      await seed.close();
    },
    peer,
    seed,
  };
}

test('cluster snapshot aggregates governed source endpoints and peer discovery', async () => {
  const cluster = await startClusterFixture();
  try {
    const result = await runCli(['cluster', 'snapshot', '--base-url', cluster.seed.url]);
    assert.equal(result.code, 0, result.stderr);
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.baseUrl, cluster.seed.url);
    assert.equal(payload.sources.health.ok, true);
    assert.equal(payload.sources.queue.data.queuePending, 3);
    assert.equal(payload.sources.releaseFlow.data.releaseMode, 'adaptive');
    assert.equal(payload.discoveredPeerCount, 2);
    assert.deepEqual(payload.discoveredPeerUrls.sort(), [cluster.peer.url, cluster.seed.url].sort());
  } finally {
    await cluster.close();
  }
});

test('peer list reads the seed cluster peer discovery surface', async () => {
  const cluster = await startClusterFixture();
  try {
    const result = await runCli(['peer', 'list', '--base-url', cluster.seed.url]);
    assert.equal(result.code, 0, result.stderr);
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.length, 2);
    assert.deepEqual(payload.map((entry) => entry.validatorUrl).sort(), [cluster.peer.url, cluster.seed.url].sort());
  } finally {
    await cluster.close();
  }
});

test('peer probe fans out from one seed validator across discovered peers', async () => {
  const cluster = await startClusterFixture();
  try {
    const result = await runCli(['peer', 'probe', '--base-url', cluster.seed.url]);
    assert.equal(result.code, 0, result.stderr);
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.seedUrl, cluster.seed.url);
    assert.equal(payload.probes.length, 2);
    const seedProbe = payload.probes.find((entry) => entry.seed);
    const peerProbe = payload.probes.find((entry) => !entry.seed);
    assert.equal(seedProbe.peerUrl, cluster.seed.url);
    assert.equal(seedProbe.consensus.currentRole, 'LEADER');
    assert.equal(peerProbe.peerUrl, cluster.peer.url);
    assert.equal(peerProbe.consensus.currentRole, 'FOLLOWER');
  } finally {
    await cluster.close();
  }
});

test('doctor reports source-plane contradictions discovered from one seed validator', async () => {
  const cluster = await startClusterFixture({ replicationContradiction: true });
  try {
    const result = await runCli(['doctor', '--base-url', cluster.seed.url]);
    assert.equal(result.code, 0, result.stderr);
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.status, 'warn');
    assert.match(JSON.stringify(payload.findings), /replication_contract_contradiction/);
  } finally {
    await cluster.close();
  }
});

test('proposal status reads proposal lifecycle endpoint', async () => {
  const cluster = await startClusterFixture();
  try {
    const result = await runCli(['proposal', 'status', 'proposal-123', '--base-url', cluster.seed.url, '--field', 'status', '--raw']);
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'COMMITTED');
  } finally {
    await cluster.close();
  }
});

test('mock up dry-run resolves the underlying single-cluster lifecycle script and passthrough args', async () => {
  const result = await runCli(['mock', 'up', '--dry-run', '--', '--fresh', '--build']);
  assert.equal(result.code, 0, result.stderr);
  const payload = JSON.parse(result.stdout);
  assert.match(payload.script, /modes\/mock\/validators\/lifecycle\/start-cluster\.sh$/);
  assert.deepEqual(payload.argv, ['--fresh', '--build']);
});

test('legacy local command path is rejected in favor of the mock namespace', async () => {
  const result = await runCli(['local', 'up', '--dry-run']);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /moved under mock/);
});
