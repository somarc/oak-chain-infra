// Conformant transaction builder for oak-segment-consensus (see modes/mock/TRANSACTION-CONTRACT.md).
//
// The runtime is the authority. This module produces exactly what it verifies:
//   - signature: secp256k1 personal_sign by walletAddress, 65 bytes r‖s‖v (v = 27/28);
//   - write message signed verbatim; delete signs contentPath;
//   - the personal_sign prefix length is the message's UTF-8 byte length (standard EIP-191,
//     EthereumSignatureVerifier.hashMessage since a1741502c6; before it, Java String.length());
//   - ethereumTxHash defaults to proposalId, which is the mock settlement's transaction hash
//     (SimpleEvmBridge). Chain-backed callers pass the real settlement tx hash.
//
// Test keys are deterministic and public by design: they exist so that local, mock and
// sepolia test traffic is signed by keys we hold. Never use them for real value.

import { randomBytes } from 'node:crypto';

import { hmac } from '@noble/hashes/hmac.js';
import { keccak_256 as keccak256 } from '@noble/hashes/sha3.js';
import { sha256 } from '@noble/hashes/sha2.js';
import * as secp from '@noble/secp256k1';

secp.hashes.hmacSha256 = (key, message) => hmac(sha256, key, message);
secp.hashes.sha256 = sha256;

const ENCODER = new TextEncoder();
const PREFIX = '\u0019Ethereum Signed Message:\n';
export const DEFAULT_KEY_SEED = 'oak-chain-mock';

const hex = (bytes) => Buffer.from(bytes).toString('hex');
const unhex = (value) => Uint8Array.from(Buffer.from(String(value).replace(/^0x/i, ''), 'hex'));

export function keccakHex(text) {
  return `0x${hex(keccak256(ENCODER.encode(text)))}`;
}

export function addressOf(privateKeyHex) {
  const publicKey = secp.getPublicKey(unhex(privateKeyHex), false);
  return `0x${hex(keccak256(publicKey.slice(1)).slice(-20))}`;
}

// Digest the runtime verifies: keccak256(prefix + utf8Length(message) + message), i.e. EIP-191.
export function runtimeMessageDigest(message) {
  const bytes = ENCODER.encode(String(message ?? ''));
  return keccak256(new Uint8Array([...ENCODER.encode(`${PREFIX}${bytes.length}`), ...bytes]));
}

export function personalSign(message, privateKeyHex) {
  const signature = secp.sign(runtimeMessageDigest(message), unhex(privateKeyHex), { format: 'recovered', prehash: false });
  // noble 'recovered' layout is [recovery, r(32), s(32)]; Ethereum is r‖s‖v with v = 27 + recovery.
  const ethereum = new Uint8Array(65);
  ethereum.set(signature.slice(1, 65), 0);
  ethereum[64] = 27 + signature[0];
  return `0x${hex(ethereum)}`;
}

export function recoverSigner(message, signatureHex) {
  const bytes = unhex(signatureHex);
  if (bytes.length !== 65) throw new Error(`signature must be 65 bytes, got ${bytes.length}`);
  const v = bytes[64] < 27 ? bytes[64] : bytes[64] - 27;
  const recovered = new Uint8Array(65);
  recovered[0] = v;
  recovered.set(bytes.slice(0, 64), 1);
  const publicKey = secp.recoverPublicKey(recovered, runtimeMessageDigest(message), { prehash: false });
  const uncompressed = secp.Point.fromBytes(publicKey).toBytes(false);
  return `0x${hex(keccak256(uncompressed.slice(1)).slice(-20))}`;
}

export function testKey(index = 0, seed = DEFAULT_KEY_SEED) {
  let candidate = keccak256(ENCODER.encode(`oak-chain/test-key/${seed}/${index}`));
  while (!secp.utils.isValidSecretKey(candidate)) candidate = keccak256(candidate);
  const privateKey = `0x${hex(candidate)}`;
  return { address: addressOf(privateKey), index, privateKey, seed };
}

// First deterministic test key whose address starts with the given byte (shard prefix).
export function testKeyForPrefix(prefixHex, seed = DEFAULT_KEY_SEED, { maxTries = 50_000 } = {}) {
  const prefix = String(prefixHex).replace(/^0x/i, '').toLowerCase().padStart(2, '0');
  if (!/^[0-9a-f]{2}$/.test(prefix)) throw new Error(`prefix must be one byte of hex, got ${prefixHex}`);
  for (let index = 0; index < maxTries; index += 1) {
    const key = testKey(`prefix-${prefix}/${index}`, seed);
    if (key.address.slice(2, 4) === prefix) return key;
  }
  throw new Error(`no test key with prefix ${prefix} within ${maxTries} tries`);
}

export function newProposalId() {
  return `0x${randomBytes(32).toString('hex')}`;
}

function resolveKey({ key, keyIndex, prefix, seed }) {
  if (key) return { address: addressOf(key), privateKey: key };
  if (prefix !== undefined && prefix !== null && prefix !== '') return testKeyForPrefix(prefix, seed);
  return testKey(keyIndex ?? 0, seed);
}

// Form fields for POST /v1/propose-write. paymentTier is deliberately absent: the runtime
// does not read it; the tier comes from the settlement proof.
export function buildWrite({ contentType = 'page', ethereumTxHash, message, organization, proposalId = newProposalId(), ...keySpec } = {}) {
  if (message === undefined || message === null) throw new Error('write needs a message (it is what gets signed)');
  const signer = resolveKey(keySpec);
  const fields = {
    contentType,
    ethereumTxHash: ethereumTxHash ?? proposalId,
    message: String(message),
    proposalId,
    signature: personalSign(String(message), signer.privateKey),
    walletAddress: signer.address,
  };
  if (organization) {
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(organization)) throw new Error(`organization must match ^[a-zA-Z0-9_-]{1,64}$: ${organization}`);
    fields.organization = organization;
  }
  return fields;
}

// Form fields for POST /v1/propose-delete. The signature binds contentPath (runtime fix
// fix/delete-signature-binds-content-path; matches oak-chain-sdk signDeleteProposal).
export function buildDelete({ contentPath, ethereumTxHash, proposalId = newProposalId(), ...keySpec } = {}) {
  if (!contentPath) throw new Error('delete needs a contentPath (it is what gets signed)');
  const signer = resolveKey(keySpec);
  return {
    contentPath,
    ethereumTxHash: ethereumTxHash ?? proposalId,
    proposalId,
    signature: personalSign(contentPath, signer.privateKey),
    walletAddress: signer.address,
  };
}

export function toForm(fields) {
  return new URLSearchParams(fields).toString();
}
