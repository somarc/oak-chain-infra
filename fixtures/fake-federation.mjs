// Fake enterprise federation for the federation scenario tests (test/federation-*.test.mjs): six HTTP
// members implementing the runtime contract of jackrabbit-oak feature/enterprise-federation (charter,
// static-file directory with epochs and prevDigest, namespace authority, wrong_cluster redirects,
// directory mounts with ordered endpoint failover, leader election) plus a fake member control.
// Lives outside test/ so `node --test` does not run it as a test file.
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, readdirSync, readFileSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import { namespaceRoot } from '../src/federation-session.mjs';

export const A_ID = `0x${'a1'.repeat(32)}`;
export const B_ID = `0x${'b2'.repeat(32)}`;
const digestOf = (value) => `0x${createHash('sha256').update(JSON.stringify(value)).digest('hex')}`;

// Fixed-range ports, not ephemeral ones: other test files (run in parallel) take an ephemeral port
// and assume the next few above it are free.
export async function listen(handler) {
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

// faults:
//   federation500        one B member answers 500 on /v1/federation once a directory is committed
//   mountOrder           per B member, the order in which it tries A's endpoints (default [0, 1, 2],
//                        as the runtime does: the first usable endpoint is active)
//   outageRequests       B requests during which a mount whose active endpoint went down stays
//                        unavailable (503 reads) before it fails over (default 4)
//   missingDuringOutage  B reads answer 200 with empty content (instead of 503) while unavailable
//   electionRequests     consensus-status probes before a cluster replaces a leader that went down
//   staleAfterRestart    a restarted member reports another directory digest
export async function startFederation({ directoryFile, faults = {} }) {
  const clusters = [
    { enterpriseId: A_ID, label: 'a', leader: faults.leaderA ?? 1, members: [] },
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
    cluster.election = 0;
  }
  const [clusterA] = clusters;
  const other = (cluster) => clusters.find((c) => c !== cluster);
  const servers = [];
  const log = [];

  const tick = (cluster) => {
    if (!existsSync(directoryFile)) return;
    const file = JSON.parse(readFileSync(directoryFile, 'utf8'));
    if (cluster.directory && file.directoryEpoch <= cluster.directory.directoryEpoch) return;
    const entries = file.entries.map((entry) => ({
      ...entry,
      namespaces: [...entry.namespaces].map((n) => n.toLowerCase()).sort(),
      writers: [...entry.writers].map((n) => n.toLowerCase()).sort(),
    })).sort((x, y) => x.enterpriseId.localeCompare(y.enterpriseId));
    cluster.directory = {
      blockHash: '', blockNumber: 0, chainId: 0, directoryEpoch: file.directoryEpoch, entries,
      prevDigest: cluster.directoryDigest, registry: 'static',
    };
    cluster.directoryDigest = digestOf(cluster.directory);
  };
  // Leader election: a leader that is down is replaced by the lowest live member after a few probes.
  const electIfNeeded = (cluster) => {
    if (!cluster.members[cluster.leader]?.down) return;
    cluster.election += 1;
    if (cluster.election < (faults.electionRequests ?? 3)) return;
    cluster.leader = cluster.members.findIndex((m) => !m.down);
    cluster.election = 0;
  };
  // A B member's mount of A: ordered endpoints (the first live one is active); when the active one
  // goes down the mount is unavailable for `outageRequests` B requests, then fails over.
  const touchMount = (member) => {
    const firstLive = member.mountOrder.find((i) => !clusterA.members[i].down);
    if (member.outage > 0) {
      member.outage -= 1;
      if (member.outage === 0) member.mountActive = firstLive ?? null;
    } else if (member.mountActive === null || clusterA.members[member.mountActive].down) {
      member.outage = faults.outageRequests ?? 4;
    } else if (firstLive !== undefined && firstLive !== member.mountActive) {
      member.mountActive = firstLive;
    }
    const available = member.outage === 0 && member.mountActive !== null && !clusterA.members[member.mountActive].down;
    return { active: available ? clusterA.members[member.mountActive].url : null, available };
  };
  const ownerOf = (cluster, namespace) => cluster.directory?.entries.find((entry) => entry.namespaces.includes(namespace));
  const status = (cluster, self) => {
    const local = cluster.directory?.entries.find((entry) => entry.enterpriseId === cluster.enterpriseId);
    const digest = self?.restarted && faults.staleAfterRestart ? digestOf('stale') : cluster.directoryDigest;
    return {
      charterDigest: cluster.charterDigest, charterMatchesConfig: true, checkedAtMs: Date.now(), clusterId: cluster.clusterId,
      configuredEnterpriseId: cluster.enterpriseId, directoryDigest: digest || null,
      directoryEpoch: cluster.directory?.directoryEpoch ?? null, enterprises: cluster.directory?.entries.length ?? 0,
      federated: Boolean(cluster.directory), lastAction: 'committed', localNamespaces: local?.namespaces.length ?? 0,
      localStatus: local?.status ?? null, sourceError: null,
    };
  };
  const json = (response, code, body, headers = {}) => response.writeHead(code, { 'content-type': 'application/json', ...headers }).end(JSON.stringify(body));

  for (const cluster of clusters) {
    for (let index = 0; index < 3; index += 1) {
      const server = await listen(async (request, response) => {
        const self = cluster.members[index];
        if (self.down) {
          request.socket.destroy();
          return undefined;
        }
        tick(cluster);
        const url = new URL(request.url, 'http://x');
        log.push({ cluster: cluster.label, index, path: url.pathname });
        const mount = cluster.label === 'b' ? touchMount(self) : null;
        if (url.pathname === '/v1/consensus/status') electIfNeeded(cluster);
        const isLeader = cluster.leader === index;
        if (url.pathname === '/health/local') return json(response, 200, { ok: true });
        if (url.pathname === '/v1/consensus/status') return json(response, 200, { currentRole: isLeader ? 'LEADER' : 'FOLLOWER' });
        if (url.pathname === '/v1/federation') {
          if (faults.federation500 && cluster.directory && cluster.label === 'b' && index === 2) return json(response, 500, { code: 'boom' });
          const st = status(cluster, self);
          return json(response, 200, {
            charter: cluster.charter, charterDigest: cluster.charterDigest, clusterId: cluster.clusterId,
            directory: cluster.directory, directoryDigest: st.directoryDigest, status: st,
          });
        }
        if (url.pathname === '/health') {
          const remote = cluster.directory?.entries.filter((entry) => entry.enterpriseId !== cluster.enterpriseId) ?? [];
          return json(response, 200, {
            clusterHealthy: true,
            currentRole: isLeader ? 'LEADER' : 'FOLLOWER',
            federation: { ...status(cluster, self), available: true },
            sharding: {
              directoryEpoch: cluster.directory?.directoryEpoch ?? null,
              mountSource: cluster.directory ? 'directory' : 'static',
              remoteMountCount: remote.reduce((n, entry) => n + entry.namespaces.length, 0),
              remoteMounts: remote.map((entry) => {
                const state = mount ?? { active: entry.endpoints[0], available: true };
                return {
                  activeEndpoint: state.active, available: state.available, directoryEpoch: cluster.directory.directoryEpoch,
                  endpoints: entry.endpoints.map((u) => ({ available: u === state.active, circuit: 'CLOSED', connected: true, lastError: null, url: u, verified: u === state.active || u === entry.endpoints[0] })),
                  enterpriseId: entry.enterpriseId, namespaces: entry.namespaces, verified: true,
                };
              }),
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
          const remote = owner && owner.enterpriseId !== cluster.enterpriseId;
          if (remote && mount && !mount.available) {
            if (faults.missingDuringOutage) return json(response, 200, { content: [] });
            return json(response, 503, { code: 'mount_unavailable', success: false });
          }
          const source = remote ? other(cluster) : cluster;
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
      const order = cluster.label === 'b' ? (faults.mountOrder?.[index] ?? [0, 1, 2]) : null;
      cluster.members.push({ down: false, mountOrder: order, outage: 0, port: server.address().port, url: `http://127.0.0.1:${server.address().port}` });
    }
  }
  for (const member of clusters[1].members) member.mountActive = member.mountOrder[0];
  return { clusters, close: () => Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve)))), log };
}

export function chmodTree(dir) {
  if (!existsSync(dir)) return;
  chmodSync(dir, 0o755);
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) chmodTree(full);
    else chmodSync(full, 0o644);
  }
}

export const readTsv = (file) => readFileSync(file, 'utf8').trim().split('\n').slice(1).map((line) => line.split('\t'));

const pidBase = (label) => (label === 'a' ? 40000 : 41000);

// A temporary federation root with launch records, pid files and logs for the fake members, a `ps`
// stub, and a fake member control that stops/starts a fake member like lifecycle/member.sh would.
// `start` replaces the fake federation (same { clusters, close } shape); `launchOpts[label]` is
// appended to that cluster's recorded EXTRA_JAVA_OPTS.
export async function setupFederation(t, faults, { directory, launchOpts = {}, start = startFederation } = {}) {
  const home = await mkdtemp(path.join(os.tmpdir(), 'oak-fed-test-'));
  const fedRoot = path.join(home, 'oak-chain-federation', '3x2');
  const directoryFile = path.join(fedRoot, 'directory.json');
  await mkdir(fedRoot, { recursive: true });
  if (directory) await writeFile(directoryFile, `${JSON.stringify(directory)}\n`);
  const federation = await start({ directoryFile, faults });
  const jar = path.join(home, 'oak-segment-consensus.jar');
  await writeFile(jar, 'fixture jar');
  const jarSha = createHash('sha256').update('fixture jar').digest('hex');
  const clusters = [];
  const commands = new Map();
  for (const cluster of federation.clusters) {
    const runtimeRoot = path.join(fedRoot, `cluster-${cluster.label}`);
    const pidDir = path.join(runtimeRoot, 'pids');
    const logDir = path.join(runtimeRoot, 'logs');
    await mkdir(pidDir, { recursive: true });
    await mkdir(logDir, { recursive: true });
    const opts = `-Doak.federation.enterpriseId=${cluster.enterpriseId} -Doak.federation.mode=mock -Doak.federation.registry=static -Doak.federation.directoryFile=${directoryFile} -Doak.federation.pollMs=2000${launchOpts[cluster.label] ? ` ${launchOpts[cluster.label]}` : ''}`;
    await writeFile(path.join(pidDir, 'cluster-launch.env'), `# test\nOAK_CLUSTER_SIZE=3\nEXTRA_JAVA_OPTS=${opts}\nOAK_CONSENSUS_JAR=${jar}\nOAK_CONSENSUS_JAR_SHA256=${jarSha}\n`);
    for (let i = 0; i < 3; i += 1) {
      const pid = pidBase(cluster.label) + i;
      commands.set(String(pid), `java -jar ${jar} --port ${cluster.members[i].port} --store ${runtimeRoot}/validator-${i}`);
      await writeFile(path.join(pidDir, `validator-${i}.pid`), `${pid}\n`);
      // An ERROR from before the run must not count: the scenarios scan only what the run appends.
      await writeFile(path.join(logDir, `validator-${i}.log`), 'old ERROR federation directory rejected\n');
    }
    clusters.push({
      enterpriseId: cluster.enterpriseId, httpStep: 2, label: cluster.label, logDir, members: cluster.members.map(({ port }) => ({ port })),
      name: `fed-cluster-${cluster.label}`, pidDir, runtimeRoot, size: 3,
    });
  }
  const exec = (command, args) => {
    if (command === 'ps') {
      const stdout = commands.get(String(args[1]));
      return stdout ? { code: 0, stderr: '', stdout: `${stdout}\n` } : { code: 1, stderr: '', stdout: '' };
    }
    if (command === 'java') return { code: 0, stderr: 'openjdk version "21" (fixture)', stdout: '' };
    if (command === 'git') return { code: 0, stderr: '', stdout: args.includes('--porcelain') ? '' : 'fixture\n' };
    return { code: 1, stderr: 'unexpected command', stdout: '' };
  };
  // Fake lifecycle/member.sh for cluster A: stop removes the pid file, start writes a new pid.
  const controls = [];
  const memberControl = async (action, index) => {
    controls.push({ action, index });
    const member = federation.clusters[0].members[index];
    const pidFile = path.join(clusters[0].pidDir, `validator-${index}.pid`);
    if (action === 'stop') {
      member.down = true;
      await rm(pidFile, { force: true });
      return { code: 0, command: ['member.sh', 'stop', String(index)], output: `✅ validator-${index} stopped (1s)\n` };
    }
    if (action === 'start') {
      member.down = false;
      member.restarted = true;
      const pid = 50000 + index;
      commands.set(String(pid), `java -jar ${jar} --port ${member.port} --store ${clusters[0].runtimeRoot}/validator-${index}`);
      await writeFile(pidFile, `${pid}\n`);
      return { code: 0, command: ['member.sh', 'start', String(index)], output: `✅ validator-${index} launched (pid ${pid})\n` };
    }
    return { code: 1, command: ['member.sh', action, String(index)], output: 'unsupported' };
  };
  t.after(async () => {
    await federation.close();
    chmodTree(home);
    await rm(home, { force: true, recursive: true });
  });
  const config = { clusters, directoryFile, fedRoot, infraDir: home, options: { deadlineMs: 3_000, pollMs: 10, requestTimeoutMs: 2_000 } };
  const env = { HOME: home, OAK_CONSENSUS_JAR: jar };
  return { config, controls, directoryFile, env, exec, federation, fedRoot, home, jar, jarSha, memberControl };
}
