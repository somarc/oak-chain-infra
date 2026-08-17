import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';

import { createOpsSnapshot, renderOpsBoard } from '../src/ops-tui.mjs';

function fixturePayload(pathname) {
  const payloads = {
    '/ops/v1/overview': {
      status: 'healthy',
      cluster: { nodeCount: 3, reachableNodes: 3 },
      leader: { nodeId: 2, term: 9 },
    },
    '/ops/v1/health': { status: 'up' },
    '/ops/v1/cluster': {
      clusterState: 'HEALTHY',
      leaderNodeId: 2,
      term: 9,
      nodes: [
        { nodeId: 0, role: 'FOLLOWER', status: 'ACTIVE', url: 'http://node-0', wallet: '0x0000' },
        { nodeId: 1, role: 'FOLLOWER', status: 'ACTIVE', url: 'http://node-1', wallet: '0x1111' },
        { nodeId: 2, role: 'LEADER', status: 'ACTIVE', url: 'http://node-2', wallet: '0x2222' },
      ],
    },
    '/ops/v1/queue': {
      backpressureActive: false,
      epochQueueDepth: 2,
      mempoolCount: 0,
      pendingCount: 0,
    },
    '/ops/v1/signals': {
      status: 'warn',
      summary: { critical: 0, ok: 14, unknown: 0, warn: 1 },
      signals: [{ id: 'disk.usage', label: 'Disk Usage', severity: 'warn', unit: '%', value: 81 }],
    },
    '/ops/v1/events/recent': {
      events: [{ eventType: 'proposal.committed', message: 'proposal-1 committed' }],
    },
  };
  return payloads[pathname];
}

async function startOpsFixture() {
  const server = http.createServer((request, response) => {
    const payload = fixturePayload(new URL(request.url, 'http://fixture').pathname);
    if (!payload) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ version: 'v1', clusterId: 'test', data: payload }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  return {
    close: () => new Promise((resolve) => server.close(resolve)),
    url: `http://127.0.0.1:${address.port}`,
  };
}

test('OPS board composes governed edge envelopes into an operator view', async () => {
  const fixture = await startOpsFixture();
  try {
    const snapshot = await createOpsSnapshot({
      'no-local-logs': true,
      'ops-url': fixture.url,
    });
    const output = renderOpsBoard(snapshot, { width: 100 });

    assert.match(output, /OAK CHAIN OPS BOARD/);
    assert.match(output, /leader=2/);
    assert.match(output, /2\s+LEADER\s+● ACTIVE/);
    assert.match(output, /Disk Usage: 81 % \(warn\)/);
    assert.match(output, /proposal\.committed proposal-1 committed/);
    assert.equal(Object.values(snapshot.sources).every((source) => source.ok), true);
  } finally {
    await fixture.close();
  }
});

test('OPS board exposes source failures instead of converting missing telemetry to healthy zeroes', () => {
  const output = renderOpsBoard({
    generatedAt: '2026-01-01T00:00:00.000Z',
    localErrors: [],
    opsUrl: 'http://ops.invalid',
    sources: {
      cluster: { data: {}, name: 'cluster', ok: true },
      events: { data: {}, name: 'events', ok: true },
      health: { error: '503 Service Unavailable', name: 'health', ok: false },
      overview: { data: {}, name: 'overview', ok: true },
      queue: { data: {}, name: 'queue', ok: true },
      signals: { data: {}, name: 'signals', ok: true },
    },
  }, { width: 100 });

  assert.match(output, /○ UNKNOWN/);
  assert.match(output, /telemetry source health: 503 Service Unavailable/);
  assert.match(output, /queue pending=\?/);
});

test('OPS board applies semantic ANSI colour only when requested', () => {
  const snapshot = {
    generatedAt: '2026-01-01T00:00:00.000Z',
    localErrors: ['[validator.log] ERROR test failure'],
    opsUrl: 'http://ops.test',
    sources: {
      cluster: { data: { clusterState: 'HEALTHY', nodes: [] }, name: 'cluster', ok: true },
      events: { data: { events: [] }, name: 'events', ok: true },
      health: { data: { status: 'up' }, name: 'health', ok: true },
      overview: { data: { status: 'healthy' }, name: 'overview', ok: true },
      queue: { data: { backpressureActive: false }, name: 'queue', ok: true },
      signals: { data: { signals: [], summary: { critical: 0, ok: 1, unknown: 0, warn: 0 } }, name: 'signals', ok: true },
    },
  };

  const colored = renderOpsBoard(snapshot, { color: true, width: 100 });
  const plain = renderOpsBoard(snapshot, { 'no-color': true, width: 100 });

  assert.match(colored, /\u001b\[32m● UP\u001b\[0m/);
  assert.match(colored, /\u001b\[31m\[validator\.log\] ERROR test failure\u001b\[0m/);
  assert.doesNotMatch(plain, /\u001b\[/);
});
