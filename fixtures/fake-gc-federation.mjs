// Fake federation with GC for test/federation-gc.test.mjs: six HTTP members implementing the parts of
// the jackrabbit-oak feature/consensus-gc-safety contract the GC scenario uses. Cluster B (owner of
// nsB1, launched with the GC test profile) stores writes (form or multipart with a file), deletes,
// serves /api/explore (content nodes and /:oak-chain-binaries entries), /api/blob and
// /v1/wallets/content, and simulates member-local GC: once a delete has committed, every `runEvery`-th
// /v1/gc/status poll of a member finishes a run (full and tail alternate) that reclaims bytes; when
// member 0 has two full runs, binary GC releases every unreferenced index entry on all members and
// the next poll counts the record deletes (member 0 ok, the others absent: one shared store).
// Cluster A (defaults) reads nsB1 through a "mount" of B.
// Lives outside test/ so `node --test` does not run it as a test file.
import { createHash } from 'node:crypto';

import { A_ID, B_ID, listen } from './fake-federation.mjs';
import { namespaceRoot } from '../src/federation-session.mjs';
import { testKey } from '../src/tx.mjs';

const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');

// faults:
//   runEvery         gc/status polls per finished run (default 3)
//   noReclaim        runs reclaim nothing and the store does not shrink
//   noBinaryRelease  binary GC never releases
//   releaseControl   binary GC also releases (and deletes) the control binary
//   staleReads       A mount reads answering 503 mount_stale once the first run finished (default 0)
//   missingRead      one A read of a control message answers 404 after the first delete
//   read500          one A mount read answers 500 after the deletes
export async function startGcFederation({ faults = {} }) {
  const nsA1 = testKey(1).address;
  const nsB1 = testKey(3).address;
  const clusters = [
    { enterpriseId: A_ID, label: 'a', members: [], namespaces: [nsA1, testKey(2).address] },
    { enterpriseId: B_ID, label: 'b', members: [], namespaces: [nsB1] },
  ];
  const [clusterA, clusterB] = clusters;
  const content = new Map(); // B content: storagePath -> node
  const index = new Map(); // B binary index: identifier -> cid
  const store = new Map(); // shared DataStore records: identifier -> bytes
  const operations = new Map();
  const state = { clock: 0, deletesCommitted: 0, release: null, staleLeft: faults.staleReads ?? 0, missingLeft: faults.missingRead ? 1 : 0, read500Left: faults.read500 ? 1 : 0, gcActive: false };
  const tick = () => { state.clock = Math.max(state.clock + 1, Date.now()); return state.clock; };
  const json = (response, code, body, headers = {}) => response.writeHead(code, { 'content-type': 'application/json', ...headers }).end(JSON.stringify(body));
  const directory = () => ({
    directoryEpoch: 2,
    entries: clusters.map((cluster) => ({ endpoints: cluster.members.map((m) => m.url), enterpriseId: cluster.enterpriseId, namespaces: cluster.namespaces, status: 'ACTIVE', writers: [] })),
  });

  const gcOf = (cluster, index_) => {
    const test = cluster === clusterB;
    const tail = test ? 60_000 : 86_400_000;
    const full = test ? 120_000 : 604_800_000;
    return { full, index: index_, polls: 0, runs: 0, size: 50_000_000, lastTail: null, lastFull: null, fullAfterDelete: 0, deletes: { absent: 0, failed: 0, ok: 0, pending: 0, skippedRecent: 0, skippedReferenced: 0 }, lastRelease: null, countedRelease: null, tail, test };
  };
  const gcBody = (gc) => ({
    segment: {
      enabled: true, retainedGenerations: 2, tailIntervalMs: gc.tail, fullIntervalMs: gc.full, forceTimeoutSeconds: 0,
      estimationSizeDeltaBytes: gc.test ? 0 : 1_073_741_824, memoryThresholdPercent: 15, readerWindowMs: Math.min(gc.tail, gc.full),
      memberIndex: gc.index, memberCount: 3, memberOffsetMs: (Math.min(gc.tail, gc.full) * gc.index) / 3,
      generation: { compacted: gc.runs > 0, full: gc.runs, generation: gc.runs }, running: null, oakStatus: 'idle',
      lastRun: { full: gc.lastFull, tail: gc.lastTail }, nextRun: { full: Date.now() + gc.full, tail: Date.now() + gc.tail },
    },
    binary: {
      enabled: true, intervalMs: gc.test ? 60_000 : 86_400_000, graceMs: gc.test ? 60_000 : 86_400_000, deleteDelayMs: gc.test ? 30_000 : 600_000,
      unpinOnDelete: false, nextMarkAt: Date.now() + 60_000, lastMark: null, lastRelease: gc.lastRelease, deletes: { ...gc.deletes },
    },
  });
  const advanceGc = (gc) => {
    gc.polls += 1;
    if (!gc.test || state.deletesCommitted === 0) return;
    if (state.release && gc.countedRelease !== state.release) {
      // The record deletes after the release (the delay is folded into one poll here).
      gc.lastRelease = { at: state.release.at, markedAtPosition: 999, position: state.release.position, released: state.release.ids.length, skipped: 0 };
      if (gc.index === 0) gc.deletes.ok += state.release.ids.length;
      else gc.deletes.absent += state.release.ids.length;
      gc.countedRelease = state.release;
      if (gc.index === 0) for (const id of state.release.ids) store.delete(id);
      return;
    }
    if (gc.polls % (faults.runEvery ?? 3) !== 0) return;
    gc.runs += 1;
    const type = gc.runs % 2 === 1 ? 'full' : 'tail';
    const startedAt = tick();
    const reclaimed = faults.noReclaim ? 0 : 1_000_000;
    const run = { type, startedAt, finishedAt: startedAt + 5, outcome: 'completed', reclaimedBytes: reclaimed, sizeBefore: gc.size, sizeAfter: gc.size - reclaimed, reason: null };
    gc.size -= reclaimed;
    if (type === 'full') { gc.lastFull = run; gc.fullAfterDelete += 1; } else gc.lastTail = run;
    state.gcActive = true;
    if (gc.index === 0 && gc.fullAfterDelete >= 2 && !state.release && !faults.noBinaryRelease) {
      const referenced = new Set([...content.values()].map((node) => node.identifier).filter(Boolean));
      const ids = [...index.keys()].filter((id) => !referenced.has(id) || faults.releaseControl);
      for (const id of ids) index.delete(id);
      state.release = { at: tick(), ids, position: 1000 };
    }
  };
  const nodeBody = (nodePath, node) => ({
    children: [],
    path: nodePath,
    properties: Object.fromEntries(Object.entries({
      contentType: node.contentType, ipfsCid: node.ipfsCid, 'jcr:blobId': node.blobId,
      'jcr:data': node.blobId ? `[Binary: ${node.length} bytes, id=${node.blobId}]` : undefined,
      message: node.message, 'oak:binaryStorageMode': node.blobId ? 'validator' : undefined, timestamp: String(node.timestamp), wallet: node.wallet,
    }).filter(([, value]) => value !== undefined)),
  });
  const exploreB = (response, nodePath) => {
    const node = content.get(nodePath);
    if (node) return json(response, 200, nodeBody(nodePath, node));
    const match = /^\/:oak-chain-binaries\/[0-9a-f]{2}\/[0-9a-f]{2}\/([0-9a-f]{64})$/.exec(nodePath);
    if (match && index.has(match[1])) return json(response, 200, { children: [], path: nodePath, properties: { cid: index.get(match[1]), refPosition: '7', refTime: '1' } });
    return json(response, 404, { code: 'not_found', error: 'Node not found', success: false });
  };
  const listingB = (wallet) => ({ content: [...content.entries()].filter(([p]) => p.startsWith(`${namespaceRoot(wallet)}/`)).map(([p, node]) => ({ contentType: node.contentType, message: node.message, name: p.split('/').pop(), timestamp: node.timestamp })) });
  // A's mount of B: the injected faults first, then B's view.
  const mountFault = (response) => {
    if (state.gcActive && state.staleLeft > 0) {
      state.staleLeft -= 1;
      json(response, 503, { code: 'mount_stale', error: 'stale', success: false }, { 'retry-after': '1' });
      return true;
    }
    if (state.deletesCommitted > 0 && state.read500Left > 0) {
      state.read500Left -= 1;
      json(response, 500, { code: 'internal_error', success: false });
      return true;
    }
    return false;
  };

  for (const cluster of clusters) {
    for (let i = 0; i < 3; i += 1) {
      const gc = gcOf(cluster, i);
      const server = await listen(async (request, response) => {
        const url = new URL(request.url, 'http://x');
        const p = url.pathname;
        const isLeader = i === 0;
        if (p === '/health/local') return json(response, 200, { ok: true });
        if (p === '/v1/consensus/status') return json(response, 200, { currentRole: isLeader ? 'LEADER' : 'FOLLOWER' });
        if (p === '/v1/gc/status') {
          advanceGc(gc);
          return json(response, 200, gcBody(gc));
        }
        if (p === '/v1/federation') {
          return json(response, 200, { charterDigest: `0x${cluster.label}`, clusterId: `0x${cluster.label}c`, directory: directory(), directoryDigest: '0xd1', gc: { readerWindowMs: Math.min(gc.tail, gc.full) }, status: { directoryEpoch: 2 } });
        }
        if (p === '/health') {
          const other = cluster === clusterA ? clusterB : clusterA;
          return json(response, 200, { gc: gcBody(gc), sharding: { mountSource: 'directory', remoteMounts: [{ activeEndpoint: other.members[0].url, available: true, enterpriseId: other.enterpriseId, namespaces: other.namespaces, verified: true }] } });
        }
        if (p.startsWith('/v1/ops/operations/')) {
          if (!isLeader) return json(response, 404, {});
          const op = operations.get(p.split('/').pop());
          return op ? json(response, 200, { state: op }) : json(response, 404, {});
        }
        if (cluster === clusterB && request.method === 'POST' && (p === '/v1/propose-write' || p === '/v1/propose-delete')) {
          const chunks = [];
          for await (const chunk of request) chunks.push(chunk);
          const body = Buffer.concat(chunks);
          const type = request.headers['content-type'] ?? '';
          let fields;
          let file = null;
          if (type.startsWith('multipart/')) {
            const form = await new Request('http://x', { body, headers: { 'content-type': type }, method: 'POST' }).formData();
            fields = {};
            for (const [key, value] of form.entries()) {
              if (typeof value === 'string') fields[key] = value;
              else file = Buffer.from(await value.arrayBuffer());
            }
          } else fields = Object.fromEntries(new URLSearchParams(body.toString()));
          if (!isLeader) return json(response, 307, { code: 'not_leader' }, { location: `${cluster.members[0].url}${p}` });
          operations.set(fields.proposalId, 'COMMITTED');
          if (p === '/v1/propose-delete') {
            content.delete(fields.contentPath);
            state.deletesCommitted += 1;
            return json(response, 202, { proposalId: fields.proposalId });
          }
          const storagePath = `${namespaceRoot(fields.walletAddress.toLowerCase())}/content/${fields.contentType}-${tick()}-${fields.proposalId.slice(2, 10)}`;
          const node = { contentType: fields.contentType, message: fields.message, timestamp: 1_700_000_000_000 + content.size, wallet: fields.walletAddress.toLowerCase() };
          if (file) {
            node.identifier = sha(file);
            node.blobId = `${node.identifier}#${file.length}`;
            node.ipfsCid = `bafy${node.identifier.slice(0, 40)}`;
            node.length = file.length;
            index.set(node.identifier, node.ipfsCid);
            store.set(node.identifier, file);
          }
          content.set(storagePath, node);
          return json(response, 202, { proposalId: fields.proposalId, state: 'PENDING', storagePath });
        }
        if (p === '/api/explore') {
          const nodePath = url.searchParams.get('path');
          if (cluster === clusterA && nodePath.startsWith(`${namespaceRoot(nsB1)}/`)) {
            if (mountFault(response)) return undefined;
            if (state.deletesCommitted > 0 && state.missingLeft > 0 && content.get(nodePath)?.message?.includes('control message')) {
              state.missingLeft -= 1;
              return json(response, 404, { code: 'not_found', success: false });
            }
          }
          if (cluster === clusterB || nodePath.startsWith(`${namespaceRoot(nsB1)}/`)) return exploreB(response, nodePath);
          return json(response, 404, { code: 'not_found', success: false });
        }
        if (p === '/v1/wallets/content') {
          const wallet = url.searchParams.get('wallet');
          if (wallet === nsB1) {
            if (cluster === clusterA && mountFault(response)) return undefined;
            return json(response, 200, listingB(nsB1));
          }
          return json(response, 200, { content: wallet === nsA1 ? [{ message: 'a own', name: 'page-1' }] : [] });
        }
        if (cluster === clusterB && p.startsWith('/api/blob/')) {
          const bytes = store.get(p.slice('/api/blob/'.length));
          if (!bytes) return json(response, 404, { code: 'blob_not_found', success: false });
          return response.writeHead(200, { 'content-type': 'application/octet-stream' }).end(bytes);
        }
        return json(response, 404, {});
      });
      cluster.members.push({ gc, port: server.address().port, server, url: `http://127.0.0.1:${server.address().port}` });
    }
  }
  return {
    clusters,
    close: () => Promise.all(clusters.flatMap((cluster) => cluster.members.map((m) => new Promise((resolve) => m.server.close(resolve))))),
    content,
    index,
    state,
    store,
  };
}
