// Shell transaction builders against a validating fixture leader (TRANSACTION-CONTRACT.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import { recoverSigner, testKey, testKeyForPrefix } from '../src/tx.mjs';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const walletsFile = path.join(repoRoot, 'modes/mock/lib/test-wallets.tsv');

// Leader that accepts only conformant writes/deletes (form or multipart); a follower port answers 307.
async function startValidatingLeader() {
  const seen = { accepted: [], rejected: [] };
  const servers = [];
  let leader;
  const listen = (handler) => new Promise((resolve) => {
    const server = http.createServer(handler);
    servers.push(server);
    server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`));
  });
  const validate = (op, f) => {
    const required = ['walletAddress', 'proposalId', 'ethereumTxHash', 'signature', op === 'write' ? 'message' : 'contentPath'];
    for (const key of required) if (f[key] === undefined) return `missing ${key}`;
    if ('paymentTier' in f) return 'paymentTier present';
    if (!/^0x[0-9a-f]{64}$/i.test(f.proposalId)) return 'proposalId not 0x+64 hex';
    if (f.ethereumTxHash !== f.proposalId) return 'ethereumTxHash != proposalId';
    if (f.organization !== undefined && !/^[a-zA-Z0-9_-]{1,64}$/.test(f.organization)) return 'bad organization';
    try {
      if (recoverSigner(op === 'write' ? f.message : f.contentPath, f.signature) !== f.walletAddress.toLowerCase()) return 'signer != walletAddress';
    } catch (error) {
      return `bad signature: ${error.message}`;
    }
    return null;
  };
  leader = await listen((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', async () => {
      const reply = (code, body) => response.writeHead(code, { 'content-type': 'application/json' }).end(JSON.stringify(body));
      if (request.url === '/v1/consensus/status') return reply(200, { currentLeader: leader });
      if (request.url === '/v1/register-client') return reply(200, { registered: true });
      const op = { '/v1/propose-write': 'write', '/v1/propose-delete': 'delete' }[request.url];
      if (!op) return reply(404, {});
      const form = await new Response(Buffer.concat(chunks), { headers: { 'content-type': request.headers['content-type'] ?? '' } }).formData();
      const fields = {};
      let file = false;
      for (const [key, value] of form.entries()) if (typeof value === 'string') fields[key] = value; else file = true;
      const reason = validate(op, fields);
      const kind = `${op}/${request.headers['content-type']?.startsWith('multipart/') ? 'multipart' : 'form'}${file ? '+file' : ''}`;
      if (reason) {
        seen.rejected.push({ kind, reason });
        return reply(400, { error: reason });
      }
      seen.accepted.push({ kind, wallet: fields.walletAddress });
      const storagePath = op === 'write' ? `/oak-chain/${fields.walletAddress}/${fields.organization ?? 'default'}/content/${fields.proposalId.slice(2, 10)}` : fields.contentPath;
      return reply(202, { operationId: fields.proposalId, proposalId: fields.proposalId, storagePath });
    });
  });
  const follower = await listen((request, response) => {
    request.resume();
    request.on('end', () => response.writeHead(307, { location: `${leader}${request.url}` }).end());
  });
  return { close: () => Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve)))), follower, leader, seen };
}

test('test-wallets.tsv lists test keys we hold (client N = --index N, prefix HH = --prefix HH)', async () => {
  const rows = (await readFile(walletsFile, 'utf8')).split('\n').filter((line) => line && !line.startsWith('#')).map((line) => line.split('\t'));
  assert.equal(rows.length, 60 + 256);
  for (const [role, address, index] of rows) {
    assert.equal(testKey(index).address, address, role);
    if (role.startsWith('client-')) assert.equal(index, role.slice('client-'.length));
    else assert.equal(address.slice(2, 4), role.slice('prefix-'.length), role);
  }
  for (const prefix of ['00', '11', '7f', 'ff']) {
    assert.equal(rows.find(([role]) => role === `prefix-${prefix}`)[1], testKeyForPrefix(prefix).address);
  }
});

test('shell builders send only conformant transactions (cluster lib, suite-lib, load engine)', async () => {
  const fixture = await startValidatingLeader();
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'oak-tx-shell-'));
  const env = { ...process.env, CLUSTER_RUNTIME_ROOT: tempDir, LOG_DIR: tempDir, LEADER: fixture.leader, FOLLOWER: fixture.follower };
  try {
    // Cluster test lib: submit_write / submit_delete keep their output formats.
    const { stdout: lib } = await execFileAsync('bash', ['-c', `
      source modes/mock/validators/tests/lib/_cluster_test_lib.sh
      w=$(resolve_wallet_for_local_shard 0x3333333333333333333333333333333333333333 0)
      r=$(submit_write "$LEADER" "$w" 'label with & = % "quotes" ü' AtlasNorth); echo "$r"
      p=$(echo "$r" | cut -d'|' -f3)
      submit_delete "$LEADER" "$w" "$p"
      submit_write "$LEADER" 0x3300000000000000000000000000000000000000 x || echo "unheld rc=$?"`], { cwd: repoRoot, env });
    const [write, del, unheld, unheldStatus] = lib.trim().split('\n');
    assert.match(write, /^202\|0x[0-9a-f]{64}\|\/oak-chain\/0x33[0-9a-f]{38}\/AtlasNorth\/content\/[0-9a-f]+\|\{/);
    assert.match(del, /^202\|0x[0-9a-f]{64}\|/);
    assert.match(unheld, /^000\|\|\|\{"error":"could not build a signed write/);
    assert.equal(unheldStatus, 'unheld rc=1');

    // Load-test suite-lib: delete proposals (direct and through a follower's 307).
    const { stdout: suite } = await execFileAsync('bash', ['-c', `
      source modes/mock/load-tests/suite-lib.sh
      out=$(mktemp)
      submit_delete_proposal "$LEADER" "\${WALLETS[0]}" /oak-chain/a/b "$out"; echo
      submit_delete_proposal "$FOLLOWER" "\${WALLETS[1]}" /oak-chain/a/c "$out"; echo`], { cwd: repoRoot, env });
    assert.deepEqual(suite.trim().split('\n'), ['202', '202']);

    // Load engine: two clients, pre-signed batches, form and multipart (binary) writes.
    await execFileAsync('bash', ['modes/mock/load-tests/run-load-test.sh'], {
      cwd: repoRoot,
      env: {
        ...env, BINARY_PERCENT: '50', MAX_WRITES_PER_CLIENT: '4', MIN_WRITES_PER_CLIENT: '4', NUM_CLIENTS: '2',
        SLEEP_MAX_MS: '2', SLEEP_MIN_MS: '1', TEST_NAME: 'tx-shell', VALIDATOR_BINARY_PERCENT: '100', VALIDATOR_URL: fixture.follower,
      },
    });

    assert.deepEqual(fixture.seen.rejected, []);
    assert.equal(fixture.seen.accepted.length, 2 + 2 + 8);
    assert.ok(fixture.seen.accepted.some(({ kind }) => kind === 'write/form'));
    assert.ok(fixture.seen.accepted.some(({ kind }) => kind.startsWith('write/multipart')));

    // The fixture is not a rubber stamp: a tampered message fails signature recovery.
    const { stdout: tampered } = await execFileAsync('bash', ['-c', `
      source modes/mock/lib/oak-tx.sh
      body=$(oak_tx_as "$(test_wallet_for_prefix 11)" write --message original)
      curl -s -o /dev/null -w '%{http_code}' --data-binary "\${body/message=original/message=forged}" "$LEADER/v1/propose-write"`], { cwd: repoRoot, env });
    assert.equal(tampered, '400');
    assert.deepEqual(fixture.seen.rejected, [{ kind: 'write/form', reason: 'signer != walletAddress' }]);
  } finally {
    await fixture.close();
    await rm(tempDir, { force: true, recursive: true });
  }
});
