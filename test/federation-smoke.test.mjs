// The federation smoke against a fixture federation: six HTTP members that implement the runtime
// contract of jackrabbit-oak feature/enterprise-federation (charter, static-file directory with
// epochs and prevDigest, namespace authority, wrong_cluster redirects, directory mounts).
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { appendFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import { directoryDocument, federationRootProblem, namespaceRoot, runFederationSmoke } from '../src/federation-smoke.mjs';

const A_ID = `0x${'a1'.repeat(32)}`;
const B_ID = `0x${'b2'.repeat(32)}`;
const digestOf = (value) => `0x${createHash('sha256').update(JSON.stringify(value)).digest('hex')}`;

// Fixed-range ports, not ephemeral ones: other test files (run in parallel) take an ephemeral port
// and assume the next few above it are free.
async function listen(handler) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const port = 20_000 + Math.floor(Math.random() * 10_000);
    const server = http.createServer(handler);
    const bound = await new Promise((resolve) => {
      server.once('error', () => resolve(false));
      server.listen(port, '127.0.0.1', () => resolve(true));
    });
    if (bound) return server;
  }
  throw new Error('no free fixture port in 20000-29999');
}

async function readForm(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString()));
}

// One fixture federation. `faults.federation500` makes one member fail GET /v1/federation once a
// directory is committed (to exercise the abort path).
async function startFederation({ directoryFile, faults = {} }) {
  const clusters = [
    { enterpriseId: A_ID, label: 'a', leader: 1, members: [] },
    { enterpriseId: B_ID, label: 'b', leader: 0, members: [] },
  ];
  for (const cluster of clusters) {
    cluster.charter = { chainId: 0, charterVersion: 1, enterpriseId: cluster.enterpriseId, mode: 'mock', registry: 'static' };
    cluster.charterDigest = digestOf(cluster.charter);
    cluster.clusterId = digestOf(`cluster-${cluster.label}`);
    cluster.directory = null;
    cluster.directoryDigest = '';
    cluster.content = new Map();
    cluster.operations = new Map();
  }
  const other = (cluster) => clusters.find((c) => c !== cluster);
  const servers = [];

  // The leader's poll: commit the file when its epoch is higher than the committed one.
  const tick = (cluster) => {
    if (!existsSync(directoryFile)) return;
    const file = JSON.parse(readFileSync(directoryFile, 'utf8'));
    if (cluster.directory && file.directoryEpoch <= cluster.directory.directoryEpoch) return;
    const entries = file.entries.map((entry) => ({
      ...entry,
      endpoints: entry.endpoints,
      namespaces: [...entry.namespaces].map((n) => n.toLowerCase()).sort(),
      writers: [...entry.writers].map((n) => n.toLowerCase()).sort(),
    })).sort((x, y) => x.enterpriseId.localeCompare(y.enterpriseId));
    cluster.directory = {
      blockHash: '', blockNumber: 0, chainId: 0, directoryEpoch: file.directoryEpoch, entries,
      prevDigest: cluster.directoryDigest, registry: 'static',
    };
    cluster.directoryDigest = digestOf(cluster.directory);
  };
  const ownerOf = (cluster, namespace) => cluster.directory?.entries.find((entry) => entry.namespaces.includes(namespace));
  const status = (cluster) => {
    const local = cluster.directory?.entries.find((entry) => entry.enterpriseId === cluster.enterpriseId);
    return {
      charterDigest: cluster.charterDigest, charterMatchesConfig: true, checkedAtMs: Date.now(), clusterId: cluster.clusterId,
      configuredEnterpriseId: cluster.enterpriseId, directoryDigest: cluster.directoryDigest || null,
      directoryEpoch: cluster.directory?.directoryEpoch ?? null, enterprises: cluster.directory?.entries.length ?? 0,
      federated: Boolean(cluster.directory), lastAction: 'committed', localNamespaces: local ? local.namespaces.length : null,
      localStatus: local?.status ?? null, sourceError: null,
    };
  };
  const json = (response, code, body, headers = {}) => response.writeHead(code, { 'content-type': 'application/json', ...headers }).end(JSON.stringify(body));

  for (const cluster of clusters) {
    for (let index = 0; index < 3; index += 1) {
      const server = await listen(async (request, response) => {
        tick(cluster);
        const url = new URL(request.url, 'http://x');
        const self = cluster.members[index];
        const isLeader = cluster.leader === index;
        if (url.pathname === '/health/local') return json(response, 200, { ok: true });
        if (url.pathname === '/v1/consensus/status') return json(response, 200, { currentRole: isLeader ? 'LEADER' : 'FOLLOWER' });
        if (url.pathname === '/v1/federation') {
          if (faults.federation500 && cluster.directory && cluster.label === 'b' && index === 2) return json(response, 500, { code: 'boom' });
          return json(response, 200, {
            charter: cluster.charter, charterDigest: cluster.charterDigest, clusterId: cluster.clusterId,
            directory: cluster.directory, directoryDigest: cluster.directoryDigest || null, status: status(cluster),
          });
        }
        if (url.pathname === '/health') {
          const remote = cluster.directory?.entries.filter((entry) => entry.enterpriseId !== cluster.enterpriseId) ?? [];
          return json(response, 200, {
            clusterHealthy: true,
            currentRole: isLeader ? 'LEADER' : 'FOLLOWER',
            federation: { ...status(cluster), available: true },
            sharding: {
              directoryEpoch: cluster.directory?.directoryEpoch ?? null,
              mountSource: cluster.directory ? 'directory' : 'static',
              remoteMountCount: remote.reduce((n, entry) => n + entry.namespaces.length, 0),
              remoteMounts: remote.map((entry) => ({
                activeEndpoint: entry.endpoints[0], available: true, directoryEpoch: cluster.directory.directoryEpoch,
                endpoints: entry.endpoints.map((u) => ({ available: true, circuit: 'CLOSED', connected: true, lastError: null, url: u, verified: true })),
                enterpriseId: entry.enterpriseId, namespaces: entry.namespaces, verified: true,
              })),
            },
          });
        }
        if (url.pathname === '/v1/propose-write' || url.pathname === '/v1/propose-delete') {
          const form = await readForm(request);
          const signer = form.walletAddress.toLowerCase();
          const namespace = (form.namespace || signer).toLowerCase();
          if (!cluster.directory) {
            if (namespace !== signer) return json(response, 400, { code: 'namespace_requires_federation', success: false });
          } else {
            const owner = ownerOf(cluster, namespace);
            if (!owner) return json(response, 403, { code: 'namespace_unclaimed', success: false });
            if (owner.enterpriseId !== cluster.enterpriseId) {
              const location = `${owner.endpoints[0]}${url.pathname}`;
              return json(response, 307, { code: 'wrong_cluster', endpoints: owner.endpoints, enterpriseId: owner.enterpriseId, namespace }, { location });
            }
            if (signer !== namespace && !owner.writers.includes(signer)) return json(response, 403, { code: 'writer_not_authorized', success: false });
          }
          if (!isLeader) return json(response, 307, { code: 'not_leader' }, { location: `${cluster.members[cluster.leader].url}${url.pathname}` });
          if (url.pathname === '/v1/propose-delete') return json(response, 202, { proposalId: form.proposalId });
          const storagePath = `${namespaceRoot(namespace)}/content/page-${Date.now()}-${form.proposalId.slice(2, 10)}`;
          const items = cluster.content.get(namespace) ?? [];
          items.push({ message: form.message, name: storagePath.split('/').pop(), signer, storagePath });
          cluster.content.set(namespace, items);
          cluster.operations.set(form.proposalId, 'COMMITTED');
          return json(response, 202, { proposalId: form.proposalId, state: 'PENDING', storagePath, wallet: signer });
        }
        if (url.pathname.startsWith('/v1/ops/operations/')) {
          if (!isLeader) return json(response, 404, {});
          const state = cluster.operations.get(url.pathname.split('/').pop());
          return state ? json(response, 200, { state }) : json(response, 404, {});
        }
        if (url.pathname === '/v1/wallets/content') {
          const wallet = url.searchParams.get('wallet');
          const owner = ownerOf(cluster, wallet);
          const source = owner && owner.enterpriseId !== cluster.enterpriseId ? other(cluster) : cluster;
          return json(response, 200, { content: (source.content.get(wallet) ?? []).map(({ message, name }) => ({ message, name })) });
        }
        if (url.pathname === '/v1/explorer/content/nav') return json(response, 200, { localCluster: { clusterId: `local-127-0-0-1-${self.port}` } });
        if (url.pathname.endsWith('/node')) {
          const nodePath = url.searchParams.get('path');
          const segments = nodePath.split('/');
          const namespace = segments[5];
          const item = (cluster.content.get(namespace) ?? []).find((entry) => entry.storagePath === nodePath);
          if (segments.length === 6 && cluster.content.has(namespace)) return json(response, 200, { properties: [{ name: 'wallet', value: namespace }] });
          if (item) return json(response, 200, { properties: [{ name: 'wallet', value: item.signer }] });
          return json(response, 404, { code: 'not_found' });
        }
        return json(response, 404, {});
      });
      servers.push(server);
      cluster.members.push({ port: server.address().port, url: `http://127.0.0.1:${server.address().port}` });
    }
  }
  return { clusters, close: () => Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve)))) };
}

async function setup(t, faults) {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-smoke-test-'));
  const fedRoot = path.join(home, 'oak-chain-federation', '3x2');
  const directoryFile = path.join(fedRoot, 'directory.json');
  await mkdir(fedRoot, { recursive: true });
  const federation = await startFederation({ directoryFile, faults });
  const jar = path.join(home, 'oak-segment-consensus.jar');
  await writeFile(jar, 'fixture jar');
  const jarSha = createHash('sha256').update('fixture jar').digest('hex');
  const clusters = [];
  for (const cluster of federation.clusters) {
    const runtimeRoot = path.join(fedRoot, `cluster-${cluster.label}`);
    const pidDir = path.join(runtimeRoot, 'pids');
    const logDir = path.join(runtimeRoot, 'logs');
    await mkdir(pidDir, { recursive: true });
    await mkdir(logDir, { recursive: true });
    const opts = `-Doak.federation.enterpriseId=${cluster.enterpriseId} -Doak.federation.mode=mock -Doak.federation.registry=static -Doak.federation.directoryFile=${directoryFile} -Doak.federation.pollMs=2000`;
    await writeFile(path.join(pidDir, 'cluster-launch.env'), `# test\nOAK_CLUSTER_SIZE=3\nEXTRA_JAVA_OPTS=${opts}\nOAK_CONSENSUS_JAR=${jar}\nOAK_CONSENSUS_JAR_SHA256=${jarSha}\n`);
    for (let i = 0; i < 3; i += 1) {
      await writeFile(path.join(pidDir, `validator-${i}.pid`), `${(cluster.label === 'a' ? 40000 : 41000) + i}\n`);
      // An ERROR from before the run must not count: the smoke scans only what the run appends.
      await writeFile(path.join(logDir, `validator-${i}.log`), 'old ERROR federation directory rejected\n');
    }
    clusters.push({
      enterpriseId: cluster.enterpriseId, httpStep: 2, label: cluster.label, logDir, members: cluster.members.map(({ port }) => ({ port })),
      name: `fed-cluster-${cluster.label}`, pidDir, runtimeRoot, size: 3,
    });
  }
  const exec = (command, args) => {
    if (command === 'ps') {
      const pid = Number(args[1]);
      const label = pid >= 41000 ? 'b' : 'a';
      return { code: 0, stderr: '', stdout: `java -jar ${jar} --store ${fedRoot}/cluster-${label}/validator-${pid % 10}\n` };
    }
    if (command === 'java') return { code: 0, stderr: 'openjdk version "21" (fixture)', stdout: '' };
    if (command === 'git') return { code: 0, stderr: '', stdout: args.includes('--porcelain') ? '' : 'fixture\n' };
    return { code: 1, stderr: 'unexpected command', stdout: '' };
  };
  t.after(async () => {
    await federation.close();
    chmodTree(home);
    await rm(home, { force: true, recursive: true });
  });
  const config = { clusters, directoryFile, fedRoot, infraDir: home, options: { deadlineMs: 3_000, pollMs: 10, requestTimeoutMs: 2_000 } };
  const env = { HOME: home, OAK_CONSENSUS_JAR: jar };
  return { config, directoryFile, env, exec, federation, fedRoot, home, jarSha };
}

function chmodTree(dir) {
  if (!existsSync(dir)) return;
  chmodSync(dir, 0o755);
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) chmodTree(full);
    else chmodSync(full, 0o644);
  }
}

const readTsv = (file) => readFileSync(file, 'utf8').trim().split('\n').slice(1).map((line) => line.split('\t'));

test('the smoke passes against a conformant federation and seals a complete evidence directory', { timeout: 60_000 }, async (t) => {
  const { config, env, exec, jarSha } = await setup(t);
  const lines = [];
  const summary = await runFederationSmoke(config, { env, exec, log: (line) => lines.push(line) });
  const rows = readTsv(path.join(summary.evidenceDir, 'assertions.tsv'));
  const failing = rows.filter((row) => row[2] === 'required' && row[5] !== 'PASS');
  assert.deepEqual(failing, [], lines.join('\n'));
  assert.equal(summary.status, 'PASS');
  assert.equal(summary.aborted, null);
  assert.ok(summary.writeRequests < 30, `bounded: ${summary.writeRequests} write requests`);

  for (const id of ['charter-digest-uniform-a', 'cluster-ids-differ', 'pre-directory-namespace-refused', 'directory-converged', 'directory-prev-digest',
    'w1-nsA1-on-A-committed', 'w3-nsB1-on-A-redirect', 'w4-wallet-node-is-namespace', 'w5-stranger-not-writer', 'w6-unclaimed-namespace',
    'd1-stranger-delete-refused', 'd2-delete-wrong-cluster', 'mount-verified-b', 'b-reads-nsA1', 'a-reads-nsB1', 'w7-removed-writer-refused',
    'no-unexpected-5xx', 'no-federation-errors-in-logs']) {
    assert.ok(rows.some((row) => row[1] === id && row[5] === 'PASS'), `${id} PASS`);
  }
  const evidence = summary.evidenceDir;
  assert.match(path.basename(evidence), /^\d{8}T\d{6}Z$/);
  const manifest = JSON.parse(readFileSync(path.join(evidence, 'manifest.json'), 'utf8'));
  assert.equal(manifest.jar.sha256, jarSha);
  assert.equal(manifest.members.length, 6);
  assert.match(manifest.members[0].command, /--store .*cluster-a\/validator-0/);
  assert.match(manifest.java, /openjdk/);
  assert.ok(manifest.git.infra.head);
  const requests = readFileSync(path.join(evidence, 'requests.ndjson'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  const redirect = requests.find((r) => r.label === 'P3 nsB1 -> A (wrong cluster)');
  assert.equal(redirect.status, 307);
  assert.equal(redirect.location, `${config.clusters[1].members[0] && `http://127.0.0.1:${config.clusters[1].members[0].port}`}/v1/propose-write`);
  assert.equal(redirect.request.walletAddress, manifest.wallets.nsB1.address);
  for (const phase of ['P1-charter', 'P2-directory-1', 'P3-writes', 'P4-reads', 'P5-directory-2', 'P6-end']) {
    assert.equal(readdirSync(path.join(evidence, 'snapshots', phase)).length, 12, `${phase}: federation + health of 6 members`);
  }
  assert.ok(existsSync(path.join(evidence, 'directory-epoch-1.json')) && existsSync(path.join(evidence, 'directory-epoch-2.json')));
  assert.equal(statSync(path.join(evidence, 'assertions.tsv')).mode & 0o222, 0, 'evidence files are read-only');
  assert.equal(statSync(evidence).mode & 0o222, 0, 'the evidence directory is sealed');
});

test('a second run on the same roots continues from the committed epoch', { timeout: 60_000 }, async (t) => {
  const { config, env, exec, directoryFile } = await setup(t);
  const first = await runFederationSmoke(config, { env, exec, log: () => {}, now: () => new Date('2030-01-01T00:00:00Z') });
  assert.equal(first.status, 'PASS');
  const second = await runFederationSmoke(config, { env, exec, log: () => {}, now: () => new Date('2030-01-01T00:00:05Z') });
  assert.equal(second.status, 'PASS');
  assert.equal(JSON.parse(readFileSync(directoryFile, 'utf8')).directoryEpoch, 4);
  const rows = readTsv(path.join(second.evidenceDir, 'assertions.tsv'));
  assert.ok(rows.some((row) => row[1] === 'pre-directory-namespace-refused' && row[2] === 'diagnostic' && row[5] === 'UNKNOWN'));
  await assert.rejects(runFederationSmoke(config, { env, exec, log: () => {}, now: () => new Date('2030-01-01T00:00:05Z') }), /EEXIST/,
    'an evidence directory is never reused');
});

test('an unexpected 5xx aborts the run, keeps the evidence and fails it', { timeout: 60_000 }, async (t) => {
  const { config, env, exec } = await setup(t, { federation500: true });
  const summary = await runFederationSmoke(config, { env, exec, log: () => {} });
  assert.equal(summary.status, 'FAIL');
  assert.match(summary.aborted, /unexpected HTTP 500/);
  assert.equal(summary.abortedInPhase, 'P2');
  const rows = readTsv(path.join(summary.evidenceDir, 'assertions.tsv'));
  assert.ok(rows.some((row) => row[1] === 'aborted' && row[5] === 'FAIL'));
  assert.ok(rows.some((row) => row[1] === 'no-unexpected-5xx' && row[5] === 'FAIL'));
  assert.ok(existsSync(path.join(summary.evidenceDir, 'snapshots', 'abort-P2')));
});

test('ERROR-level federation lines appended during the run fail the log assertion', { timeout: 60_000 }, async (t) => {
  const { config, env, exec } = await setup(t);
  const realFetch = globalThis.fetch;
  let appended = false;
  const fetchImpl = async (url, init) => {
    if (!appended && String(url).includes('/v1/propose-write')) {
      appended = true;
      await appendFile(path.join(config.clusters[0].logDir, 'validator-1.log'), '12:00 ERROR FederationCoordinator - directory rejected\n12:00 ERROR Other - unrelated\n');
    }
    return realFetch(url, init);
  };
  const summary = await runFederationSmoke(config, { env, exec, fetchImpl, log: () => {} });
  assert.equal(summary.status, 'FAIL');
  const row = readTsv(path.join(summary.evidenceDir, 'assertions.tsv')).find((r) => r[1] === 'no-federation-errors-in-logs');
  assert.equal(row[5], 'FAIL');
  assert.match(row[4], /a1=1/);
  assert.match(row[7], /a1=2/);
});

test('the smoke refuses federation roots at, under or above $HOME/oak-chain', () => {
  const home = '/Users/someone';
  assert.match(federationRootProblem('/Users/someone/oak-chain', { home }), /protected live root/);
  assert.match(federationRootProblem('/Users/someone/oak-chain/fed/3x2', { home }), /protected live root/);
  assert.match(federationRootProblem('/Users', { home }), /contains the protected live root/);
  assert.match(federationRootProblem('relative/root', { home }), /absolute/);
  assert.match(federationRootProblem('/Users/someone', { home }), /dedicated directory/);
  assert.match(federationRootProblem('/tmp/x', { home, protectedRoots: '/tmp' }), /protected live root/);
  assert.equal(federationRootProblem('/Users/someone/oak-chain-federation/3x2', { home }), null);
});

test('the directory document lists both enterprises with disjoint namespaces and lower-case addresses', () => {
  const clusters = [
    { enterpriseId: A_ID, httpBase: 8290, httpStep: 2, size: 3 },
    { enterpriseId: B_ID, httpBase: 8390, httpStep: 2, size: 3 },
  ];
  const wallets = { nsA1: '0x01', nsA2: '0x02', nsB1: '0x03', wA: '0x04' };
  const doc = directoryDocument({ clusters, epoch: 1, wallets, writersA: [wallets.wA] });
  assert.deepEqual(doc.entries[0].endpoints, ['http://127.0.0.1:8290', 'http://127.0.0.1:8292', 'http://127.0.0.1:8294']);
  assert.deepEqual(doc.entries[1].endpoints, ['http://127.0.0.1:8390', 'http://127.0.0.1:8392', 'http://127.0.0.1:8394']);
  assert.deepEqual(doc.entries.map((e) => e.status), ['ACTIVE', 'ACTIVE']);
  assert.deepEqual(doc.entries[0].writers, ['0x04']);
  assert.equal('chainId' in doc || 'registry' in doc, false, 'chainId and registry default from the charter');
});
