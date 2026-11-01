import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { keccak_256 as keccak256 } from '@noble/hashes/sha3.js';
import * as secp from '@noble/secp256k1';

import {
  addressOf, buildDelete, buildWrite, personalSign, recoverSigner, runtimeMessageDigest, testKey, testKeyForPrefix, toForm,
} from '../src/tx.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const jar = process.env.OAK_CONSENSUS_JAR || path.resolve(repoRoot, '../jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar');
const HARDHAT_0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

test('keys, signatures and recovery follow Ethereum conventions', () => {
  assert.equal(addressOf(HARDHAT_0), '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266');
  // EIP-191 vector: Hardhat account #0 signing "hello" (ASCII, so runtime and standard prefixes agree).
  assert.equal(
    personalSign('hello', HARDHAT_0),
    '0xf16ea9a3478698f695fd1401bfe27e9e4a7e8e3da94aa72b021125e31fa899cc573c48ea3fe1d4ab61a9db10c19032026e3ed2dbccba5a178235ac27f94504311c',
  );
  for (const message of ['', 'plain', 'quotes "a" \\b', 'ünïcødé ✓', 'astral 🌳']) {
    assert.equal(recoverSigner(message, personalSign(message, HARDHAT_0)), addressOf(HARDHAT_0), message);
  }
  assert.deepEqual(testKey(3), testKey(3), 'test keys are deterministic');
  assert.notEqual(testKey(3).address, testKey(4).address);
  assert.notEqual(testKey(3, 'other-seed').address, testKey(3).address);
  assert.equal(testKeyForPrefix('7f').address.slice(2, 4), '7f');
  assert.equal(testKeyForPrefix('0x00').address.slice(2, 4), '00');
});

test('write and delete transactions carry exactly the fields the runtime contract defines', () => {
  const write = buildWrite({ keyIndex: 1, message: 'm', organization: 'Org_1-x' });
  assert.deepEqual(Object.keys(write).sort(), ['contentType', 'ethereumTxHash', 'message', 'organization', 'proposalId', 'signature', 'walletAddress']);
  assert.match(write.proposalId, /^0x[0-9a-f]{64}$/);
  assert.equal(write.ethereumTxHash, write.proposalId, 'mock settlement tx hash is the proposal id');
  assert.equal(write.walletAddress, testKey(1).address);
  assert.equal(recoverSigner('m', write.signature), write.walletAddress);
  assert.equal('paymentTier' in write, false, 'paymentTier is not read by the runtime');
  assert.throws(() => buildWrite({ message: 'm', organization: 'bad org' }), /organization must match/);
  assert.throws(() => buildWrite({}), /needs a message/);
  const chainBacked = buildWrite({ ethereumTxHash: '0xabc12345', message: 'm', proposalId: `0x${'1'.repeat(64)}` });
  assert.equal(chainBacked.ethereumTxHash, '0xabc12345');

  const del = buildDelete({ contentPath: '/oak-chain/a/b', keyIndex: 2 });
  assert.equal(recoverSigner('/oak-chain/a/b', del.signature), testKey(2).address, 'delete signs contentPath');
  assert.throws(() => buildDelete({}), /needs a contentPath/);
  assert.match(toForm({ message: 'a "b" & c=d' }), /^message=a\+%22b%22\+%26\+c%3Dd$/);
});

test('the optional federation namespace is sent lower-cased, validated, and never signed', () => {
  const namespace = testKey(3).address;
  const write = buildWrite({ keyIndex: 4, message: 'm', namespace: namespace.toUpperCase().replace('0X', '0x') });
  assert.equal(write.namespace, namespace);
  assert.equal(write.walletAddress, testKey(4).address, 'the signer stays the writer, not the namespace');
  assert.equal(recoverSigner('m', write.signature), write.walletAddress);
  assert.equal('namespace' in buildWrite({ message: 'm' }), false, 'absent by default (the signer\'s own wallet)');
  assert.throws(() => buildWrite({ message: 'm', namespace: '0x1234' }), /namespace must be/);

  const del = buildDelete({ contentPath: '/oak-chain/a/b', keyIndex: 4, namespace });
  assert.equal(del.namespace, namespace);
  assert.equal(recoverSigner('/oak-chain/a/b', del.signature), testKey(4).address);
  assert.equal('namespace' in buildDelete({ contentPath: '/x' }), false);
});

function prefixedSign(message, privateKeyHex, length) {
  const bytes = new TextEncoder().encode(message);
  const digest = keccak256(new Uint8Array([...new TextEncoder().encode(`\u0019Ethereum Signed Message:\n${length}`), ...bytes]));
  const recovered = secp.sign(digest, Uint8Array.from(Buffer.from(privateKeyHex.slice(2), 'hex')), { format: 'recovered', prehash: false });
  return `0x${Buffer.from([...recovered.slice(1), 27 + recovered[0]]).toString('hex')}`;
}

const standardEip191Sign = (message, key) => prefixedSign(message, key, new TextEncoder().encode(message).length);
// What the runtime verified before a1741502c6 (Java String.length(), UTF-16 code units).
const utf16LengthSign = (message, key) => prefixedSign(message, key, message.length);

const javaReady = existsSync(jar)
  && spawnSync('javac', ['-version']).status === 0
  && spawnSync('java', ['-version']).status === 0;

test('the validator jar\'s own EthereumSignatureVerifier accepts what this builder signs', { skip: javaReady ? false : 'needs the built oak-segment-consensus jar plus java/javac', timeout: 120_000 }, async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'oak-tx-verify-'));
  try {
    await writeFile(path.join(dir, 'VerifyVectors.java'), `
import org.apache.jackrabbit.oak.segment.consensus.security.EthereumSignatureVerifier;
import java.io.*; import java.nio.charset.StandardCharsets; import java.util.Base64;
public class VerifyVectors {
  public static void main(String[] a) throws Exception {
    if (!EthereumSignatureVerifier.isFullVerificationAvailable()) { System.out.println("UNAVAILABLE"); return; }
    BufferedReader r = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    for (String line; (line = r.readLine()) != null; ) {
      String[] p = line.split("\\t");
      String m = new String(Base64.getDecoder().decode(p[0]), StandardCharsets.UTF_8);
      System.out.println("RESULT " + EthereumSignatureVerifier.verifySignature(m, p[1], p[2]));
    }
  }
}`);
    const compiled = spawnSync('javac', ['-proc:none', '-cp', jar, '-d', dir, path.join(dir, 'VerifyVectors.java')], { encoding: 'utf8' });
    assert.equal(compiled.status, 0, compiled.stderr);

    const signer = testKey(5);
    const other = testKey(6);
    const write = buildWrite({ keyIndex: 5, message: 'F1-01b {"quote":"a \\"b\\" c"} ünïcødé ✓ 漢字 🌳' });
    const del = buildDelete({ contentPath: '/oak-chain/aa/bb/cc/x/content/page-1', keyIndex: 5 });
    const vectors = [
      ['ascii', 'hello oak', personalSign('hello oak', signer.privateKey), true],
      ['empty', '', personalSign('', signer.privateKey), true],
      ['write with quotes/unicode/astral', write.message, write.signature, true],
      ['delete over contentPath', del.contentPath, del.signature, true],
      ['long', 'x'.repeat(5_000), personalSign('x'.repeat(5_000), signer.privateKey), true],
      ['wrong signer', 'hello oak', personalSign('hello oak', other.privateKey), false],
      ['wrong message', 'tampered', personalSign('hello oak', signer.privateKey), false],
      // The runtime verifies standard EIP-191 (UTF-8 byte length) since a1741502c6; the old
      // UTF-16-length prefix now fails for non-ASCII messages.
      ['standard EIP-191, ascii', 'hello oak', standardEip191Sign('hello oak', signer.privateKey), true],
      ['standard EIP-191, non-ascii', 'ünïcødé 🌳', standardEip191Sign('ünïcødé 🌳', signer.privateKey), true],
      ['utf-16 length prefix, non-ascii', 'ünïcødé 🌳', utf16LengthSign('ünïcødé 🌳', signer.privateKey), false],
    ];
    const input = vectors.map(([, message, signature]) => [Buffer.from(message, 'utf8').toString('base64'), signature, signer.address].join('\t')).join('\n');
    const output = await new Promise((resolve, reject) => {
      const child = spawn('java', ['-cp', `${jar}${path.delimiter}${dir}`, 'VerifyVectors'], { stdio: ['pipe', 'pipe', 'pipe'] });
      let stdout = '';
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.on('error', reject);
      child.on('exit', () => resolve(stdout));
      child.stdin.end(`${input}\n`);
    });
    assert.doesNotMatch(output, /UNAVAILABLE/, 'Bouncy Castle verification must be available in the jar');
    const results = output.split('\n').filter((line) => line.startsWith('RESULT ')).map((line) => line === 'RESULT true');
    assert.equal(results.length, vectors.length, output);
    vectors.forEach(([name, , , expected], index) => assert.equal(results[index], expected, name));
    assert.ok(runtimeMessageDigest('x').length === 32);
  } finally {
    await rm(dir, { force: true, recursive: true });
  }
});
