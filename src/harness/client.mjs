// Operation client (charter §2.3): unique 32-byte proposal IDs, one ledger row per attempt,
// and terminal reconciliation. HTTP 202 means accepted, not committed. Every accepted
// operation must end COMMITTED, REJECTED or FAILED; anything else is UNKNOWN.
//
// Operation status lives only on the leader (/v1/ops/operations/{id}; followers 404), so
// reconciliation re-discovers the leader on every poll. If leadership moves before the
// outcome is observed, the operation stays UNKNOWN — the harness never guesses.

import { performance } from 'node:perf_hooks';

import { buildDelete, buildWrite, newProposalId as newTxProposalId, testKey } from '../tx.mjs';
import { findLeader } from './observe.mjs';

export const OUTCOME = Object.freeze({
  COMMITTED: 'COMMITTED',
  FAILED: 'FAILED',
  REJECTED: 'REJECTED',
  UNKNOWN: 'UNKNOWN',
});

export const newProposalId = newTxProposalId;

// Deterministic test signer per run seed. Every harness transaction is signed by a key we
// hold, as the runtime contract requires (modes/mock/TRANSACTION-CONTRACT.md).
export function harnessSigner(seed) {
  return testKey(`harness/${seed}`);
}

// Map the ops.v1 lifecycle to charter outcomes. Returns null while still in flight.
export function classifyOperation(status) {
  if (!status) return null;
  switch (status.state) {
    case 'COMMITTED':
      return { outcome: OUTCOME.COMMITTED, reason: null };
    case 'FAILED':
      return status.sourceState === 'REJECTED'
        ? { outcome: OUTCOME.REJECTED, reason: status.rejectionReason ?? 'rejected without reason' }
        : { outcome: OUTCOME.FAILED, reason: status.durabilityError ?? status.rejectionReason ?? 'operation failed' };
    case 'TIMED_OUT':
      return { outcome: OUTCOME.FAILED, reason: status.rejectionReason ?? 'timed out' };
    case 'ABORTED':
      return { outcome: OUTCOME.FAILED, reason: status.rejectionReason ?? 'aborted' };
    default:
      return null;
  }
}

function truncate(text, max = 2_000) {
  const value = String(text ?? '');
  return value.length > max ? `${value.slice(0, max)}…` : value;
}

// One POST to the leader (or `leaderUrl` when the caller already resolved it, so a burst can
// leave back to back), recorded as one ledger row.
async function submitSigned(http, target, run, { endpoint, form, kind, leaderUrl, record }) {
  const leader = leaderUrl ? { url: leaderUrl } : await findLeader(http, target);
  const base = leader?.url ?? target.nodes[0].url;
  const invokedAt = new Date().toISOString();
  const started = performance.now();
  const response = await http.request(`${base}${endpoint}`, { form, method: 'POST', timeout: 30_000 });
  const row = {
    body: truncate(response.text),
    error: response.error,
    hops: response.hops,
    httpStatus: response.status,
    invokedAt,
    kind,
    latencyMs: Math.round(performance.now() - started),
    leaderAtSubmit: leader?.url ?? null,
    operationId: response.json?.operationId ?? null,
    proposalId: form.proposalId,
    signature: form.signature,
    wallet: form.walletAddress,
    ...record,
    storagePath: response.json?.storagePath ?? record.storagePath ?? null,
  };
  await run.appendLedger(row);
  return row;
}

export async function submitWrite(http, target, run, { contentType = 'page', leaderUrl, message, organization, proposalId = newProposalId(), signer }) {
  const form = buildWrite({ contentType, key: signer.privateKey, message, organization, proposalId });
  return submitSigned(http, target, run, { endpoint: '/v1/propose-write', form, kind: 'write', leaderUrl, record: { message, organization } });
}

// Deletes sign contentPath and need a registered wallet (DeleteProposalHandler).
export async function submitDelete(http, target, run, { contentPath, leaderUrl, proposalId = newProposalId(), signer }) {
  const form = buildDelete({ contentPath, key: signer.privateKey, proposalId });
  return submitSigned(http, target, run, { endpoint: '/v1/propose-delete', form, kind: 'delete', leaderUrl, record: { storagePath: contentPath } });
}

// The runtime reads no signature on registration (RegistrationHandler); it maps clientId to
// wallet and answers 409 if a clientId returns with another wallet, so the id names the wallet.
export async function registerWallet(http, target, run, signer) {
  const leader = await findLeader(http, target);
  const base = leader?.url ?? target.nodes[0].url;
  const clientId = `harness-${signer.address.slice(2, 10)}`;
  const response = await http.request(`${base}/v1/register-client`, {
    form: { clientId, clientUrl: `http://${clientId}.local`, walletAddress: signer.address }, method: 'POST', timeout: 15_000,
  });
  const row = { body: truncate(response.text), clientId, error: response.error, httpStatus: response.status, kind: 'register', wallet: signer.address };
  await run.appendLedger(row);
  return row;
}

export async function fetchOperation(http, target, operationId) {
  const leader = await findLeader(http, target);
  if (!leader) return { leader: null, response: null };
  const response = await http.request(`${leader.url}/v1/ops/operations/${encodeURIComponent(operationId)}`);
  return { leader: leader.url, response };
}

export async function reconcile(http, target, run, operationId, { deadlineMs = 90_000, intervalMs = 1_000, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
  const started = Date.now();
  let lastState = null;
  let last = { leader: null, status: null };
  while (Date.now() - started <= deadlineMs) {
    const { leader, response } = await fetchOperation(http, target, operationId);
    const status = response?.status === 200 ? response.json : null;
    last = { httpStatus: response?.status ?? 0, leader, status };
    if (status?.state && status.state !== lastState) {
      lastState = status.state;
      await run.event('operation.state', { leader, operationId, sourceState: status.sourceState, state: status.state });
    }
    const verdict = classifyOperation(status);
    if (verdict) {
      return { ...verdict, elapsedMs: Date.now() - started, leader, state: status.state, status };
    }
    await sleep(intervalMs);
  }
  return {
    elapsedMs: Date.now() - started,
    leader: last.leader,
    outcome: OUTCOME.UNKNOWN,
    reason: last.status ? `still ${last.status.state} at deadline` : `no status from leader (http ${last.httpStatus ?? 0})`,
    state: last.status?.state ?? null,
    status: last.status,
  };
}
