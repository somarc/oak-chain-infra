// Enterprise-federation 3x2 live smoke (modes/mock/validators/tests/routing/federation-3x2-smoke.sh).
//
// Assumes both federation clusters are already running (lifecycle/start-fed-3x2.sh) and never
// starts, stops or signals anything. It writes the shared static directory file, sends fewer than
// 30 signed writes/deletes, and records everything in one immutable evidence directory:
//
//   $FED_3X2_ROOT/evidence/<UTC timestamp>/
//     manifest.json        provenance: git SHAs and dirty state, jar path + sha256, java -version,
//                          ports, PIDs with exact command lines, launch records, log offsets
//     requests.ndjson      every request/response (status, headers incl. Location, body)
//     snapshots/<phase>/   GET /v1/federation and /health of all six members per phase
//     directory-epoch-N.json  each directory file this run wrote
//     log-scan.json        ERROR lines appended to the validator logs during the run
//     assertions.tsv       phase | assertionId | kind | expected | observed | status | evidence | note
//     summary.json, report.md
//
// Phases: P0 preflight, P1 charter, P2 directory epoch E1, P3 writes and deletes, P4 cross-cluster
// reads through the directory mounts, P5 directory epoch E2 (writer removed), P6 end state.
// Bounded: every wait has a deadline; the first unexpected 5xx or a member that stops answering
// aborts the run (everything stays running for inspection). A required assertion that is not
// PASS fails the run; UNKNOWN fails it too.

import { renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  Abort, STATUS, clusterMembers, configFromEnv, createFederationSession, namespaceRoot, readIf, sameList, short,
} from './federation-session.mjs';
import { buildDelete, buildWrite } from './tx.mjs';

export { DEFAULTS, WALLET_ROLES, federationRootProblem, namespaceRoot, utcStamp } from './federation-session.mjs';

// The directory file this smoke writes for epoch N. The runtime defaults chainId/registry from the charter.
export function directoryDocument({ clusters, epoch, wallets, writersA }) {
  const [a, b] = clusters;
  return {
    directoryEpoch: epoch,
    entries: [
      {
        endpoints: clusterMembers(a).map((member) => member.url),
        enterpriseId: a.enterpriseId,
        namespaces: [wallets.nsA1, wallets.nsA2],
        status: 'ACTIVE',
        writers: writersA,
      },
      {
        endpoints: clusterMembers(b).map((member) => member.url),
        enterpriseId: b.enterpriseId,
        namespaces: [wallets.nsB1],
        status: 'ACTIVE',
        writers: [],
      },
    ],
  };
}

export async function runFederationSmoke(config, deps = {}) {
  const s = createFederationSession(config, deps, { initialPhase: 'P0', scenario: 'federation smoke', title: 'Federation 3x2 smoke' });
  const {
    A, B, addr, allMembers, assertions, assert, call, clusters, committed, contentOn, dir, directoryFile, expectStatus,
    federationViews, leaderOf, log, manifest, memberFacts, nonce, observedOf, opts, snapshot, stats, submit, waitFor, wallets, write,
  } = s;
  let aborted = null;
  const directoryDigests = {};
  try {
    // ── P0 preflight ──────────────────────────────────────────────────────────────────────────
    s.phase = 'P0';
    log('━━ P0 preflight');
    const up = await waitFor('all members answer /health/local', async () => {
      const codes = {};
      for (const member of allMembers) {
        codes[member.url] = (await call(`preflight ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health/local`, { tolerate: true })).status;
      }
      return { codes, done: Object.values(codes).every((code) => code === 200) };
    });
    assert('members-up', { expected: 'all 6 members answer /health/local 200', observed: up.codes, ok: up.ok });
    if (!up.ok) throw new Abort('not every member is up');
    const pidsKnown = memberFacts.every((fact) => fact.pid && fact.command && fact.command.includes(`validator-${fact.index}`));
    assert('pids-recorded', { expected: 'a live pid per member whose command line names its store', observed: memberFacts.map((f) => `${f.cluster}${f.index}:${f.pid ?? '-'}`), ok: pidsKnown || null, note: pidsKnown ? '' : 'pid files or ps unavailable' });
    const jarShas = clusters.map((cluster) => cluster.launchRecord.OAK_CONSENSUS_JAR_SHA256 || null);
    const jarAgrees = jarShas.every((sha) => sha && sha === jarShas[0]) && (!manifest.jar.sha256 || manifest.jar.sha256 === jarShas[0]);
    assert('same-jar', { expected: 'both launch records pin one OAK_CONSENSUS_JAR sha256 (= the env jar, when given)', observed: { env: manifest.jar.sha256, records: jarShas }, ok: jarShas.every(Boolean) ? jarAgrees : null });
    for (const cluster of clusters) {
      const opts2 = cluster.launchRecord.EXTRA_JAVA_OPTS ?? '';
      assert(`launch-config-${cluster.label}`, {
        expected: `EXTRA_JAVA_OPTS has enterpriseId ${short(cluster.enterpriseId)}, mode=mock, registry=static, directoryFile, no oak.sharding.*`,
        observed: opts2 || '(no launch record)',
        ok: opts2 ? opts2.includes(`-Doak.federation.enterpriseId=${cluster.enterpriseId}`) && opts2.includes('-Doak.federation.mode=mock')
          && opts2.includes('-Doak.federation.registry=static') && opts2.includes(`-Doak.federation.directoryFile=${directoryFile}`)
          && !opts2.includes('oak.sharding.') : null,
      });
    }

    // ── P1 charter ────────────────────────────────────────────────────────────────────────────
    s.phase = 'P1';
    log('━━ P1 charter');
    const charters = await waitFor('charter committed on all members', async () => {
      const views = await federationViews('P1 federation');
      return { done: views.every(({ view }) => view.charter?.enterpriseId && view.charterDigest && view.clusterId), views };
    });
    const p1 = await snapshot('P1-charter');
    const clusterIds = {};
    for (const cluster of clusters) {
      const views = charters.views.filter(({ member }) => member.cluster === cluster);
      const ev = `${p1}; requests.ndjson#${views.map((v) => v.response.seq).join(',')}`;
      const ids = views.map(({ view }) => view.charter?.enterpriseId?.toLowerCase());
      const digests = new Set(views.map(({ view }) => view.charterDigest));
      const cids = new Set(views.flatMap(({ view }) => [view.clusterId, view.status?.clusterId]));
      clusterIds[cluster.label] = [...cids][0];
      assert(`charter-enterprise-${cluster.label}`, { evidence: ev, expected: cluster.enterpriseId, observed: ids, ok: charters.ok ? ids.every((id) => id === cluster.enterpriseId) : false });
      assert(`charter-digest-uniform-${cluster.label}`, { evidence: ev, expected: 'one charterDigest across 3 members', observed: [...digests], ok: digests.size === 1 && !digests.has(undefined) });
      assert(`cluster-id-uniform-${cluster.label}`, { evidence: ev, expected: 'one clusterId (top level and status) across 3 members', observed: [...cids], ok: cids.size === 1 && !cids.has(undefined) && !cids.has(null) });
      assert(`charter-matches-config-${cluster.label}`, { evidence: ev, expected: 'status.charterMatchesConfig=true on 3 members', observed: views.map(({ view }) => view.status?.charterMatchesConfig), ok: views.every(({ view }) => view.status?.charterMatchesConfig === true) });
      assert(`charter-fields-${cluster.label}`, {
        evidence: ev, expected: 'mode=mock registry=static chainId=0',
        observed: views.map(({ view }) => `${view.charter?.mode}/${view.charter?.registry}/${view.charter?.chainId}`),
        ok: views.every(({ view }) => view.charter?.mode === 'mock' && view.charter?.registry === 'static' && Number(view.charter?.chainId) === 0),
      });
    }
    assert('cluster-ids-differ', { evidence: p1, expected: 'cluster A and cluster B report different clusterIds', observed: clusterIds, ok: Boolean(clusterIds.a && clusterIds.b && clusterIds.a !== clusterIds.b) });
    if (!charters.ok) throw new Abort('the charter was not committed on every member');

    const committedEpochs = charters.views.map(({ view }) => Number(view.status?.directoryEpoch ?? view.directory?.directoryEpoch ?? 0) || 0);
    const baseEpoch = Math.max(...committedEpochs);
    let fileEpoch = 0;
    const existingFile = readIf(directoryFile);
    if (existingFile !== null) {
      try {
        fileEpoch = Number(JSON.parse(existingFile).directoryEpoch) || 0;
      } catch {
        fileEpoch = 0;
      }
    }
    const baseDigests = new Set(charters.views.map(({ view }) => view.directoryDigest || ''));
    const baseDigest = baseEpoch > 0 ? [...baseDigests][0] : '';
    if (baseEpoch > 0) {
      assert('pre-directory-namespace-refused', {
        expected: '400 namespace_requires_federation (wA into nsA2 before any directory)', kind: 'diagnostic',
        note: `directory epoch ${baseEpoch} already committed: start with --fresh to cover the unfederated rule`, observed: 'not run', ok: null,
      });
    } else {
      const leaderA = await leaderOf(A);
      const form = buildWrite({ key: wallets.wA.privateKey, message: `[fed smoke ${nonce}] wA into nsA2 before directory`, namespace: addr.nsA2 });
      const response = await submit('P1 wA->nsA2 unfederated', A, leaderA, form);
      assert('pre-directory-namespace-refused', { evidence: `requests.ndjson#${response.seq}`, expected: '400 namespace_requires_federation', observed: observedOf(response), ok: expectStatus(response, 400, 'namespace_requires_federation') });
    }

    // ── P2 directory epoch E1 ─────────────────────────────────────────────────────────────────
    s.phase = 'P2';
    const e1 = Math.max(baseEpoch, fileEpoch) + 1;
    log(`━━ P2 directory epoch ${e1}`);
    const writeDirectory = (document) => {
      const tmp = `${directoryFile}.tmp-${process.pid}`;
      writeFileSync(tmp, `${JSON.stringify(document, null, 2)}\n`);
      renameSync(tmp, directoryFile);
      write(`directory-epoch-${document.directoryEpoch}.json`, document);
    };
    const doc1 = directoryDocument({ clusters, epoch: e1, wallets: addr, writersA: [addr.wA] });
    writeDirectory(doc1);
    const converge = async (epoch) => waitFor(`directory epoch ${epoch} on all members`, async () => {
      const views = await federationViews(`directory ${epoch}`);
      const digests = new Set(views.map(({ view }) => view.directoryDigest));
      return {
        digests,
        done: views.every(({ view }) => Number(view.status?.directoryEpoch) === epoch && Number(view.directory?.directoryEpoch) === epoch)
          && digests.size === 1 && !digests.has(undefined) && !digests.has(''),
        views,
      };
    });
    const c1 = await converge(e1);
    const p2 = await snapshot(`P2-directory-${e1}`);
    const e1Digest = [...c1.digests][0];
    directoryDigests[e1] = e1Digest;
    assert('directory-converged', { evidence: p2, expected: `all 6 members at epoch ${e1} with one directoryDigest within ${opts.deadlineMs} ms`, observed: c1.views.map(({ member, view }) => `${member.cluster.label}${member.index}:${view.status?.directoryEpoch}/${short(view.directoryDigest)}`), ok: c1.ok, note: c1.ok ? `${c1.waitedMs} ms` : '' });
    if (!c1.ok) {
      assert('directory-source-error', { evidence: p2, expected: 'no sourceError', kind: 'diagnostic', observed: c1.views.map(({ view }) => view.status?.sourceError ?? null), ok: c1.views.every(({ view }) => !view.status?.sourceError) });
      throw new Abort(`directory epoch ${e1} did not converge`);
    }
    const committedDir = c1.views[0].view.directory ?? {};
    const entryFor = (directory, id) => (directory?.entries ?? []).find((entry) => String(entry.enterpriseId).toLowerCase() === id);
    const contentMatches = (directory, document) => document.entries.every((expected) => {
      const actual = entryFor(directory, expected.enterpriseId);
      return actual && actual.status === 'ACTIVE' && sameList(actual.namespaces, expected.namespaces)
        && sameList(actual.writers, expected.writers) && JSON.stringify(actual.endpoints) === JSON.stringify(expected.endpoints);
    }) && (directory?.entries ?? []).length === document.entries.length;
    assert('directory-content', { evidence: p2, expected: doc1.entries, observed: committedDir.entries, ok: contentMatches(committedDir, doc1) });
    assert('directory-prev-digest', { evidence: p2, expected: baseDigest || '(empty: first directory)', observed: [...new Set(c1.views.map(({ view }) => view.directory?.prevDigest ?? null))], ok: c1.views.every(({ view }) => (view.directory?.prevDigest ?? '') === baseDigest) });
    for (const cluster of clusters) {
      const views = c1.views.filter(({ member }) => member.cluster === cluster);
      const expectedNs = cluster === A ? [addr.nsA1, addr.nsA2] : [addr.nsB1];
      assert(`federated-${cluster.label}`, {
        // status.localNamespaces is the count of namespaces the local enterprise owns; directory-content checks which
        evidence: p2, expected: `federated=true localStatus=ACTIVE localNamespaces=${expectedNs.length}`,
        observed: views.map(({ view }) => `${view.status?.federated}/${view.status?.localStatus}/${view.status?.localNamespaces}`),
        ok: views.every(({ view }) => view.status?.federated === true && view.status?.localStatus === 'ACTIVE' && view.status?.localNamespaces === expectedNs.length),
      });
    }
    assert('no-source-error', { evidence: p2, expected: 'no member reports a sourceError', kind: 'diagnostic', observed: c1.views.map(({ view }) => view.status?.sourceError ?? null), ok: c1.views.every(({ view }) => !view.status?.sourceError) });

    // ── P3 writes and deletes ─────────────────────────────────────────────────────────────────
    s.phase = 'P3';
    log('━━ P3 writes');
    const message = (what) => `[fed smoke ${nonce}] ${what}`;
    const accepted = async (id, label, cluster, form, namespace) => {
      const leader = await leaderOf(cluster);
      const response = await submit(label, cluster, leader, form);
      const ok = assert(`${id}-accepted`, { evidence: `requests.ndjson#${response.seq}`, expected: '202', observed: observedOf(response), ok: response.status === 202 });
      const storagePath = response.json?.storagePath ?? '';
      assert(`${id}-storage-path`, { evidence: `requests.ndjson#${response.seq}`, expected: `${namespaceRoot(namespace)}/…`, observed: storagePath, ok: storagePath.startsWith(`${namespaceRoot(namespace)}/`) });
      if (!ok) return { response, storagePath };
      const done = await committed(id, cluster, form.proposalId);
      assert(`${id}-committed`, { evidence: `requests.ndjson#${done.seq}`, expected: 'COMMITTED', observed: done.verdict?.outcome ?? done.state, ok: done.verdict ? done.verdict.outcome === 'COMMITTED' : false });
      const visible = await contentOn(`${id} visible`, cluster.members, namespace, form.message);
      assert(`${id}-visible-${cluster.label}`, { evidence: Object.values(visible.seen).map((s) => `requests.ndjson#${s.seq}`).join(','), expected: `message on all ${cluster.members.length} members of cluster ${cluster.label}`, observed: Object.fromEntries(Object.entries(visible.seen).map(([url, s]) => [url, s.found])), ok: visible.ok });
      return { response, storagePath };
    };

    const w1Form = buildWrite({ key: wallets.nsA1.privateKey, message: message('nsA1 own write on A') });
    const w1 = await accepted('w1-nsA1-on-A', 'P3 nsA1 -> A leader', A, w1Form, addr.nsA1);
    const w2Form = buildWrite({ key: wallets.nsB1.privateKey, message: message('nsB1 own write on B') });
    const w2 = await accepted('w2-nsB1-on-B', 'P3 nsB1 -> B leader', B, w2Form, addr.nsB1);

    const bEndpoint = `${B.members[0].url}/v1/propose-write`;
    const w3 = await submit('P3 nsB1 -> A (wrong cluster)', A, A.members[0], buildWrite({ key: wallets.nsB1.privateKey, message: message('nsB1 sent to A') }), '/v1/propose-write', { follow: false });
    assert('w3-nsB1-on-A-redirect', { evidence: `requests.ndjson#${w3.seq}`, expected: `307 wrong_cluster Location=${bEndpoint}`, observed: `${observedOf(w3)} Location=${w3.location}`, ok: expectStatus(w3, 307, 'wrong_cluster') && w3.location === bEndpoint });
    assert('w3-redirect-body', { evidence: `requests.ndjson#${w3.seq}`, expected: { endpoints: B.members.map((m) => m.url), enterpriseId: B.enterpriseId }, observed: { endpoints: w3.json?.endpoints, enterpriseId: w3.json?.enterpriseId }, ok: w3.json?.enterpriseId === B.enterpriseId && JSON.stringify(w3.json?.endpoints) === JSON.stringify(B.members.map((m) => m.url)) });

    const w4Form = buildWrite({ key: wallets.wA.privateKey, message: message('wA writes into nsA2'), namespace: addr.nsA2 });
    const w4 = await accepted('w4-wA-into-nsA2', 'P3 wA -> nsA2', A, w4Form, addr.nsA2);
    if (w4.response.status === 202) {
      const walletPath = namespaceRoot(addr.nsA2);
      const walletProps = [];
      for (const member of A.members) {
        const nav = await call(`P3 explorer nav ${member.url}`, 'GET', `${member.url}/v1/explorer/content/nav`);
        const clusterId = nav.json?.localCluster?.clusterId;
        if (!clusterId) {
          walletProps.push({ member: member.url, seq: nav.seq, wallet: null });
          continue;
        }
        const node = await call(`P3 explorer wallet node ${member.url}`, 'GET', `${member.url}/v1/explorer/content/clusters/${encodeURIComponent(clusterId)}/node?path=${encodeURIComponent(walletPath)}`);
        const prop = (node.json?.properties ?? []).find((p) => p.name === 'wallet');
        walletProps.push({ member: member.url, seq: node.seq, wallet: prop?.value ?? null });
        if (member === A.members[0] && w4.storagePath) {
          const content = await call(`P3 explorer content node ${member.url}`, 'GET', `${member.url}/v1/explorer/content/clusters/${encodeURIComponent(clusterId)}/node?path=${encodeURIComponent(w4.storagePath)}`);
          const signer = (content.json?.properties ?? []).find((p) => p.name === 'wallet')?.value ?? null;
          assert('w4-content-signer', { evidence: `requests.ndjson#${content.seq}`, expected: `content node wallet = signer ${addr.wA}`, kind: 'diagnostic', observed: signer, ok: signer === null ? null : signer === addr.wA });
        }
      }
      assert('w4-wallet-node-is-namespace', { evidence: walletProps.map((p) => `requests.ndjson#${p.seq}`).join(','), expected: `wallet property of ${walletPath} = ${addr.nsA2} on all A members`, observed: walletProps.map((p) => p.wallet), ok: walletProps.every((p) => p.wallet === addr.nsA2) ? true : walletProps.some((p) => p.wallet && p.wallet !== addr.nsA2) ? false : null });
    }

    const leaderA = await leaderOf(A);
    const w5 = await submit('P3 stranger -> nsA1', A, leaderA, buildWrite({ key: wallets.stranger.privateKey, message: message('stranger into nsA1'), namespace: addr.nsA1 }));
    assert('w5-stranger-not-writer', { evidence: `requests.ndjson#${w5.seq}`, expected: '403 writer_not_authorized', observed: observedOf(w5), ok: expectStatus(w5, 403, 'writer_not_authorized') });
    const w6 = await submit('P3 unclaimed own namespace', A, leaderA, buildWrite({ key: wallets.unclaimed.privateKey, message: message('unclaimed namespace') }));
    assert('w6-unclaimed-namespace', { evidence: `requests.ndjson#${w6.seq}`, expected: '403 namespace_unclaimed', observed: observedOf(w6), ok: expectStatus(w6, 403, 'namespace_unclaimed') });

    if (w1.storagePath) {
      const d1 = await submit('P3 stranger deletes nsA1 content', A, leaderA, buildDelete({ contentPath: w1.storagePath, key: wallets.stranger.privateKey, namespace: addr.nsA1 }), '/v1/propose-delete');
      assert('d1-stranger-delete-refused', { evidence: `requests.ndjson#${d1.seq}`, expected: '403 writer_not_authorized', observed: observedOf(d1), ok: expectStatus(d1, 403, 'writer_not_authorized') });
    }
    if (w2.storagePath) {
      const bDelete = `${B.members[0].url}/v1/propose-delete`;
      const d2 = await submit('P3 nsB1 delete sent to A', A, A.members[0], buildDelete({ contentPath: w2.storagePath, key: wallets.nsB1.privateKey }), '/v1/propose-delete', { follow: false });
      assert('d2-delete-wrong-cluster', { evidence: `requests.ndjson#${d2.seq}`, expected: `307 wrong_cluster Location=${bDelete}`, observed: `${observedOf(d2)} Location=${d2.location}`, ok: expectStatus(d2, 307, 'wrong_cluster') && d2.location === bDelete });
    }
    await snapshot('P3-writes');

    // ── P4 cross-cluster reads through the directory mounts ──────────────────────────────────
    s.phase = 'P4';
    log('━━ P4 cross-cluster reads');
    const mounts = await waitFor('directory mounts verified and available', async () => {
      const rows = [];
      for (const member of allMembers) {
        const other = member.cluster === A ? B : A;
        const response = await call(`P4 health ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health`);
        const sharding = response.json?.sharding ?? {};
        const mount = (sharding.remoteMounts ?? []).find((m) => String(m.enterpriseId ?? '').toLowerCase() === other.enterpriseId);
        rows.push({ available: mount?.available === true, member, mount, mountSource: sharding.mountSource, seq: response.seq, verified: mount?.verified === true });
      }
      return { done: rows.every((row) => row.mountSource === 'directory' && row.verified && row.available), rows };
    });
    const p4 = await snapshot('P4-reads');
    for (const cluster of clusters) {
      const rows = mounts.rows.filter((row) => row.member.cluster === cluster);
      const other = cluster === A ? B : A;
      const otherNs = other === A ? [addr.nsA1, addr.nsA2] : [addr.nsB1];
      assert(`mount-source-${cluster.label}`, { evidence: p4, expected: 'sharding.mountSource=directory on 3 members', observed: rows.map((row) => row.mountSource), ok: rows.every((row) => row.mountSource === 'directory') });
      assert(`mount-verified-${cluster.label}`, { evidence: p4, expected: `mount of enterprise ${short(other.enterpriseId)} verified=true available=true on 3 members`, observed: rows.map((row) => `${row.verified}/${row.available}`), ok: rows.every((row) => row.verified && row.available) });
      assert(`mount-namespaces-${cluster.label}`, { evidence: p4, expected: otherNs, observed: rows.map((row) => row.mount?.namespaces ?? null), ok: rows.every((row) => sameList(row.mount?.namespaces, otherNs)) });
      assert(`mount-epoch-${cluster.label}`, { evidence: p4, expected: e1, kind: 'diagnostic', observed: rows.map((row) => row.mount?.directoryEpoch ?? null), ok: rows.every((row) => Number(row.mount?.directoryEpoch) === e1) });
    }
    if (!mounts.ok) throw new Abort('directory mounts did not become verified and available');
    const readAcross = async (id, readers, namespace, text) => {
      const seen = await contentOn(`P4 ${id}`, readers, namespace, text, { remote: true });
      const unavailable = stats.allowed5xx.filter((row) => row.label.startsWith(`P4 ${id}`)).length;
      assert(id, { evidence: Object.values(seen.seen).map((s) => `requests.ndjson#${s.seq}`).join(','), expected: 'committed message readable on every member of the other cluster', observed: Object.fromEntries(Object.entries(seen.seen).map(([url, s]) => [url, s.found ? 'found' : `missing (http ${s.status})`])), ok: seen.ok, note: unavailable ? `${unavailable} 503 answer(s) while the mount was unavailable` : '' });
    };
    if (w1.response.status === 202) await readAcross('b-reads-nsA1', B.members, addr.nsA1, w1Form.message);
    if (w2.response.status === 202) await readAcross('a-reads-nsB1', A.members, addr.nsB1, w2Form.message);
    if (w4.response.status === 202) await readAcross('b-reads-nsA2', B.members, addr.nsA2, w4Form.message);

    // ── P5 directory epoch E2: wA removed ─────────────────────────────────────────────────────
    s.phase = 'P5';
    const e2 = e1 + 1;
    log(`━━ P5 directory epoch ${e2} (wA removed)`);
    const doc2 = directoryDocument({ clusters, epoch: e2, wallets: addr, writersA: [] });
    writeDirectory(doc2);
    const c2 = await converge(e2);
    const p5 = await snapshot(`P5-directory-${e2}`);
    directoryDigests[e2] = [...c2.digests][0];
    assert('directory-converged', { evidence: p5, expected: `all 6 members at epoch ${e2} with one directoryDigest within ${opts.deadlineMs} ms`, observed: c2.views.map(({ member, view }) => `${member.cluster.label}${member.index}:${view.status?.directoryEpoch}/${short(view.directoryDigest)}`), ok: c2.ok, note: c2.ok ? `${c2.waitedMs} ms` : '' });
    if (!c2.ok) throw new Abort(`directory epoch ${e2} did not converge`);
    assert('directory-prev-digest', { evidence: p5, expected: e1Digest, observed: [...new Set(c2.views.map(({ view }) => view.directory?.prevDigest ?? null))], ok: c2.views.every(({ view }) => view.directory?.prevDigest === e1Digest) });
    assert('directory-content', { evidence: p5, expected: doc2.entries, observed: c2.views[0].view.directory?.entries, ok: contentMatches(c2.views[0].view.directory, doc2) });
    const w7 = await submit('P5 wA -> nsA2 after removal', A, await leaderOf(A), buildWrite({ key: wallets.wA.privateKey, message: message('wA into nsA2 after removal'), namespace: addr.nsA2 }));
    assert('w7-removed-writer-refused', { evidence: `requests.ndjson#${w7.seq}`, expected: '403 writer_not_authorized', observed: observedOf(w7), ok: expectStatus(w7, 403, 'writer_not_authorized') });
    const mounts2 = await waitFor(`mounts at epoch ${e2}`, async () => {
      const epochs = [];
      for (const member of allMembers) {
        const response = await call(`P5 health ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health`);
        epochs.push(Number(response.json?.sharding?.directoryEpoch));
      }
      return { done: epochs.every((epoch) => epoch === e2), epochs };
    });
    assert('mounts-follow-epoch', { evidence: p5, expected: `/health sharding.directoryEpoch=${e2} on all 6`, kind: 'diagnostic', observed: mounts2.epochs, ok: mounts2.ok });

    // ── P6 end state ──────────────────────────────────────────────────────────────────────────
    s.phase = 'P6';
    log('━━ P6 end state');
    const p6 = await snapshot('P6-end');
    const health = [];
    for (const member of allMembers) {
      const local = await call(`P6 health/local ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health/local`);
      health.push({ code: local.status, member });
    }
    assert('members-healthy', { evidence: p6, expected: 'all 6 members answer /health/local 200', observed: health.map((h) => `${h.member.cluster.label}${h.member.index}:${h.code}`), ok: health.every((h) => h.code === 200) });
    const pidsNow = memberFacts.map((fact) => {
      const cluster = clusters.find((c) => c.label === fact.cluster);
      return (readIf(path.join(cluster.pidDir ?? '', `validator-${fact.index}.pid`)) ?? '').trim() || null;
    });
    assert('no-restarts', { expected: 'the pid of every member is unchanged', observed: pidsNow, ok: memberFacts.every((fact) => fact.pid) ? memberFacts.every((fact, i) => fact.pid === pidsNow[i]) : null });
  } catch (error) {
    if (!(error instanceof Abort)) throw error;
    aborted = await s.recordAbort(error);
  }

  return s.finish({ aborted, extraSummary: { directoryDigests }, finalPhase: 'P6', seal: deps.seal ?? true });
}

// CLI: the shell entry point passes the resolved topology as FED_SMOKE_CONFIG (JSON).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let config;
  try {
    config = configFromEnv(process.env, { script: 'tests/routing/federation-3x2-smoke.sh' });
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
  runFederationSmoke(config).then(
    (summary) => process.exit(summary.status === STATUS.PASS ? 0 : 1),
    (error) => {
      process.stderr.write(`❌ ${error.message}\n`);
      process.exit(2);
    },
  );
}
