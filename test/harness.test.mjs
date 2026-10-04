import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { classifyOperation, harnessSigner, newProposalId, OUTCOME } from '../src/harness/client.mjs';
import { recoverSigner } from '../src/tx.mjs';
import { createRun, STATUS, summarize } from '../src/harness/evidence.mjs';
import { createHttp, normalizeNodeUrl } from '../src/harness/http.mjs';
import { formatSummary, listCampaigns, runCampaign } from '../src/harness/index.mjs';
import { compareAcrossNodes, compareExpected } from '../src/harness/oracle.mjs';
import { authorizeRiskClass } from '../src/harness/target.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json', ...headers }, status });
}

// In-memory 3-validator cluster. Follower writes redirect (307) to the leader; the leader
// "commits" immediately; every node stores what `store(form)` returns.
function fakeCluster({ leaderPort = 8094, store = (form) => Object.fromEntries(form), timestamps = () => 1 } = {}) {
  const ports = [8090, 8092, 8094];
  const content = new Map();
  const operations = new Map();
  const seen = [];
  const fetchImpl = async (url, init = {}) => {
    const target = new URL(url);
    const port = Number(target.port);
    seen.push(`${init.method ?? 'GET'} ${port}${target.pathname}`);
    if (!ports.includes(port)) throw new Error('connection refused');
    const isLeader = port === leaderPort;
    if (target.pathname === '/health') {
      return json({ clusterHealthy: true, currentRole: isLeader ? 'LEADER' : 'FOLLOWER', reachableCount: 3, totalMembers: 3 });
    }
    if (target.pathname === '/v1/propose-write') {
      if (!isLeader) return new Response(null, { headers: { location: `http://localhost:${leaderPort}/v1/propose-write` }, status: 307 });
      const form = new URLSearchParams(String(init.body));
      const proposalId = form.get('proposalId');
      const storagePath = `/oak-chain/test/${form.get('organization')}/content/page-${content.size + 1}`;
      const stored = store(form);
      content.set(storagePath, stored);
      operations.set(proposalId, { durabilityState: 'ACKED', sourceState: 'PROCESSED', state: 'COMMITTED' });
      return json({ operationId: proposalId, proposalId, storagePath }, 202);
    }
    if (target.pathname.startsWith('/v1/ops/operations/')) {
      if (!isLeader) return json({ error: 'Operation not found' }, 404);
      const status = operations.get(decodeURIComponent(target.pathname.split('/').pop()));
      return status ? json(status) : json({ error: 'Operation not found' }, 404);
    }
    if (target.pathname === '/api/explore') {
      const stored = content.get(target.searchParams.get('path'));
      if (!stored) return json({ error: 'Node not found' }, 404);
      return json({ children: [], path: target.searchParams.get('path'), properties: { ...stored, timestamp: String(timestamps(port)) } });
    }
    return json({ error: 'not found' }, 404);
  };
  return { content, fetchImpl, seen };
}

function storeProperties(form) {
  return {
    contentType: form.get('contentType'),
    message: form.get('message'),
    'oak:proposalId': form.get('proposalId'),
    organization: form.get('organization'),
    wallet: form.get('walletAddress').toLowerCase(),
  };
}

test('operation outcomes map ops.v1 states to charter outcomes', () => {
  assert.equal(classifyOperation({ state: 'QUEUED' }), null);
  assert.equal(classifyOperation({ state: 'PROCESSING' }), null);
  assert.deepEqual(classifyOperation({ state: 'COMMITTED' }), { outcome: OUTCOME.COMMITTED, reason: null });
  assert.equal(classifyOperation({ rejectionReason: 'nope', sourceState: 'REJECTED', state: 'FAILED' }).outcome, OUTCOME.REJECTED);
  assert.equal(classifyOperation({ durabilityError: 'disk', sourceState: 'PROCESSED', state: 'FAILED' }).outcome, OUTCOME.FAILED);
  assert.equal(classifyOperation({ state: 'TIMED_OUT' }).outcome, OUTCOME.FAILED);
  assert.match(newProposalId(), /^0x[0-9a-f]{64}$/);
  assert.match(harnessSigner('seed').address, /^0x[0-9a-f]{40}$/);
  assert.deepEqual(harnessSigner('seed'), harnessSigner('seed'));
  assert.equal(normalizeNodeUrl('http://localhost:8094/'), 'http://127.0.0.1:8094');
});

test('oracles separate strict equality, volatile properties and submitted-value fidelity', () => {
  const reads = [
    { id: 0, properties: { message: 'a', timestamp: '1' }, status: 200 },
    { id: 1, properties: { message: 'a', timestamp: '2' }, status: 200 },
    { id: 2, properties: { message: 'a', timestamp: '1' }, status: 200 },
  ];
  const strict = compareAcrossNodes(reads);
  assert.equal(strict.equal, false);
  assert.deepEqual(strict.differing.map((entry) => entry.name), ['timestamp']);
  assert.equal(compareAcrossNodes(reads, { ignore: ['timestamp'] }).equal, true);
  assert.equal(compareExpected(reads, { message: 'a' }).equal, true);
  const missing = compareExpected([...reads.slice(0, 2), { id: 2, properties: null, status: 404 }], { message: 'a' });
  assert.equal(missing.equal, false);
  assert.equal(missing.mismatches[0].observed, 'http 404');
});

test('evidence bundle: UNKNOWN or FAIL on a required assertion fails the run; diagnostics do not', async () => {
  assert.equal(summarize([{ kind: 'required', status: STATUS.PASS }, { kind: 'diagnostic', status: STATUS.FAIL }]).status, STATUS.PASS);
  assert.equal(summarize([{ kind: 'required', status: STATUS.PASS }, { kind: 'required', status: STATUS.UNKNOWN }]).status, STATUS.FAIL);
  assert.equal(summarize([]).status, STATUS.FAIL, 'a run with no required assertions proves nothing');

  const runsDir = await mkdtemp(path.join(os.tmpdir(), 'oak-harness-evidence-'));
  try {
    const campaign = { charter: ['F1-01'], id: 'demo', riskClass: 'A', title: 'Demo' };
    const run = await createRun({ campaign, runsDir });
    await run.appendLedger({ kind: 'write', proposalId: '0x1' });
    await run.event('x', { n: 1 });
    run.assert({ assertionId: 'a', expected: 'e', observed: 'o\twith tab', scenarioId: 'F1-01', status: STATUS.PASS });
    const summary = await run.finish({ target: { runtimeRoot: '/tmp/x', size: 3 } });
    assert.equal(summary.status, STATUS.PASS);
    const tsv = await readFile(path.join(run.dir, 'assertions.tsv'), 'utf8');
    assert.match(tsv, /^scenarioId\tassertionId\tkind\texpected\tobserved\tstatus\tevidencePath\tnote\n/);
    assert.match(tsv, /F1-01\ta\trequired\te\to with tab\tPASS/);
    assert.match(await readFile(path.join(run.dir, 'ledger.ndjson'), 'utf8'), /"proposalId":"0x1"/);
    assert.match(await readFile(path.join(run.dir, 'report.md'), 'utf8'), /# Demo — PASS/);
  } finally {
    await rm(runsDir, { force: true, recursive: true });
  }
});

test('risk classes: writes need explicit approval, the legacy root needs a second one', () => {
  const disposable = { isLegacyRoot: false, runtimeRoot: '/tmp/disposable' };
  const legacy = { isLegacyRoot: true, runtimeRoot: '/Users/x/oak-chain' };
  assert.deepEqual(authorizeRiskClass(legacy, 'A', {}), []);
  assert.throws(() => authorizeRiskClass(disposable, 'B', {}), /--allow-class B/);
  assert.deepEqual(authorizeRiskClass(disposable, 'B', { 'allow-class': 'B' }), ['class B']);
  assert.throws(() => authorizeRiskClass(legacy, 'B', { 'allow-class': 'B' }), /--allow-live-root/);
  assert.deepEqual(authorizeRiskClass(legacy, 'B', { 'allow-class': 'b', 'allow-live-root': true }), ['class B', 'live legacy root']);
  assert.throws(() => authorizeRiskClass(disposable, 'C', { 'allow-class': 'C' }), /not available/);
});

test('http client follows 307 keeping method and body, and reports transport failure as status 0', async () => {
  const cluster = fakeCluster();
  const http = createHttp({ fetchImpl: cluster.fetchImpl });
  const response = await http.request('http://127.0.0.1:8090/v1/propose-write', {
    form: { message: 'm', organization: 'Org', proposalId: '0xab', walletAddress: '0xAA' }, method: 'POST',
  });
  assert.equal(response.status, 202);
  assert.equal(response.hops.length, 1);
  assert.equal(response.hops[0].status, 307);
  assert.deepEqual(cluster.seen.slice(-2), ['POST 8090/v1/propose-write', 'POST 8094/v1/propose-write']);
  const refused = await http.request('http://127.0.0.1:9999/health');
  assert.equal(refused.status, 0);
  assert.match(refused.error, /connection refused/);
});

test('campaign definitions are well-formed and name known scenarios', async () => {
  const campaigns = await listCampaigns(repoRoot);
  assert.deepEqual(campaigns.map((campaign) => campaign.id).sort(), ['f1-one-write', 'p0-preflight', 'reconcile-accepted']);
  for (const campaign of campaigns) {
    assert.match(campaign.riskClass, /^[AB]$/);
    assert.ok(campaign.charter.length > 0);
  }
});

async function runOneWrite(cluster) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'oak-harness-run-'));
  const env = { CLUSTER_RUNTIME_ROOT: root, HOME: os.homedir(), OAK_VALIDATOR_HTTP_BASE_PORT: '8090', OPS_PROXY_PORT: '7' };
  try {
    const result = await runCampaign('f1-one-write', { 'allow-class': 'B' }, { env, fetchImpl: cluster.fetchImpl, repoRoot });
    const tsv = await readFile(path.join(result.dir, 'assertions.tsv'), 'utf8');
    const manifest = JSON.parse(await readFile(path.join(result.dir, 'manifest.json'), 'utf8'));
    const ledger = (await readFile(path.join(result.dir, 'ledger.ndjson'), 'utf8')).trim().split('\n').map((line) => JSON.parse(line));
    return { formatted: formatSummary(result, tsv), ledger, manifest, result, root, tsv };
  } finally {
    await rm(root, { force: true, recursive: true });
  }
}

test('F1-01 passes end to end against a faithful, deterministic cluster', async () => {
  const { formatted, ledger, manifest, result } = await runOneWrite(fakeCluster({ store: storeProperties }));
  assert.equal(result.summary.status, STATUS.PASS, formatted);
  assert.equal(result.summary.required.total, 10);
  assert.equal(ledger.length, 2);
  assert.ok(ledger.every((row) => row.leaderAtSubmit === 'http://127.0.0.1:8094' && row.httpStatus === 202));
  assert.ok(ledger.every((row) => recoverSigner(row.message, row.signature) === row.wallet), 'every harness write is signed by its wallet');
  assert.deepEqual(manifest.approvals, ['class B']);
  assert.equal(manifest.target.isLegacyRoot, false);
  assert.ok(manifest.provenance.repos.oakChainInfra.head, 'records the infra HEAD');
  assert.equal(JSON.stringify(manifest.provenance.environment).includes('TOKEN'), false);
});

test('F1-01 fails on server-side truncation and on per-node apply timestamps', async () => {
  const truncating = (form) => {
    const stored = storeProperties(form);
    const message = stored.message;
    stored.message = message.includes('"') ? message.slice(0, message.indexOf('"') + 2) : message;
    return stored;
  };
  const { result, tsv } = await runOneWrite(fakeCluster({ store: truncating, timestamps: (port) => port }));
  assert.equal(result.summary.status, STATUS.FAIL);
  const rows = Object.fromEntries(tsv.trim().split('\n').slice(1).map((line) => {
    const cells = line.split('\t');
    return [`${cells[0]} ${cells[1]}`, cells[5]];
  }));
  assert.equal(rows['F1-01 value-fidelity'], 'PASS', 'plain ascii survives');
  assert.equal(rows['F1-01b value-fidelity'], 'FAIL', 'quoted message is truncated');
  assert.equal(rows['F1-01 strict-equality'], 'FAIL', 'per-node timestamps break strict equality');
  assert.equal(rows['F1-01 semantic-equality'], 'PASS', 'semantic comparison is only a diagnostic');
});
