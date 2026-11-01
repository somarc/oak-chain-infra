// The federation smoke against a fixture federation: six HTTP members that implement the runtime
// contract of jackrabbit-oak feature/enterprise-federation (charter, static-file directory with
// epochs and prevDigest, namespace authority, wrong_cluster redirects, directory mounts).
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { appendFile } from 'node:fs/promises';
import path from 'node:path';

import { A_ID, B_ID, readTsv, setupFederation } from '../fixtures/fake-federation.mjs';
import { directoryDocument, federationRootProblem, runFederationSmoke } from '../src/federation-smoke.mjs';

const setup = (t, faults) => setupFederation(t, faults);

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
