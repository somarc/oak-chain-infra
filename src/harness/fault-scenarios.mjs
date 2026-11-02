// Controlled-fault scenarios (risk class C) and the duplicate-proposal check (class B), charter
// §7 phases 2-6: F1-05, O2-05, S3-01/02/04/05, Q4-01/02/03, R6-01/02.
//
// Every fault scenario has the same shape:
//   1. gate: refuse to inject a fault unless the cluster is settled (one agreed leader, all up);
//   2. one scoped fault through lifecycle/member.sh (faults.mjs);
//   3. outcomes: operation status lives in the leader's memory (ProposalQueryHandler), so after a
//      leader change an accepted operation is resolved from replicated state instead:
//      APPLIED (its node is on every live member with its proposalId), ABSENT (on none),
//      DIVERGENT (on some) — divergence always fails;
//   4. same-ID retry (D5-05): ABSENT proposals are resent and must commit; APPLIED ones are
//      resent and must not create a second node (a write's node name embeds the clock, so a
//      second effect lands at a new path);
//   5. recovery: every member back, settled, and the strict state digest equal everywhere.

import { randomBytes } from 'node:crypto';

import { harnessSigner, OUTCOME, reconcile, registerWallet, resubmit, submitDelete, submitWrite } from './client.mjs';
import { STATUS } from './evidence.mjs';
import { createFaultController, waitMemberDown, waitSettled } from './faults.mjs';
import { compareAcrossNodes, compareExpected, readEverywhere } from './oracle.mjs';
import { launchedJarPath, processState } from './target.mjs';

const pass = (ok) => (ok ? STATUS.PASS : STATUS.FAIL);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function brief(value, max = 400) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

function subset(target, members) {
  return { ...target, nodes: members.map((id) => target.nodes[id]) };
}

const proposalPrefix = (proposalId) => String(proposalId).slice(2, 10).toLowerCase();
const parentOf = (storagePath) => storagePath.slice(0, storagePath.lastIndexOf('/')) || '/';

// ---------------------------------------------------------------------------------------
// Shared steps

async function gateSettled(ctx, scenarioId, label, { deadlineMs = 60_000, members } = {}) {
  const settled = await waitSettled(ctx.http, ctx.target, { deadlineMs, members });
  ctx.run.assert({
    assertionId: `settled.${label}`, expected: `${members ? members.length : ctx.target.size} members up, exactly one agreed LEADER within ${deadlineMs / 1_000}s`,
    observed: settled.settled ? `leader ${settled.leader.url} after ${settled.elapsedMs}ms (${settled.last})` : `not settled: ${settled.last}`,
    scenarioId, status: pass(settled.settled),
  });
  return settled;
}

// Commit `count` writes one at a time; returns the committed rows (with their forms).
async function commitWrites(ctx, { count, label, organization, scenarioId, signer, visibleOn }) {
  const rows = [];
  const outcomes = [];
  for (let index = 0; index < count; index += 1) {
    const row = await submitWrite(ctx.http, ctx.target, ctx.run, { message: `oak harness ${scenarioId} ${label} ${index} ${ctx.run.id}`, organization, signer });
    if (!row.operationId) {
      outcomes.push(row.httpStatus === 0 ? OUTCOME.UNKNOWN : OUTCOME.REJECTED);
      continue;
    }
    const verdict = await reconcile(ctx.http, ctx.target, ctx.run, row.operationId, { deadlineMs: ctx.terminalMs });
    outcomes.push(verdict.outcome);
    if (verdict.outcome === OUTCOME.COMMITTED) rows.push(row);
  }
  const visible = await waitVisible(ctx, rows, visibleOn);
  ctx.run.assert({
    assertionId: `${label}.committed`, evidence: 'ledger.ndjson',
    expected: `${count} writes COMMITTED and present on members ${visibleOn.join(',')}`,
    observed: `${Object.values(OUTCOME).map((o) => `${o}=${outcomes.filter((x) => x === o).length}`).join(' ')}; visible ${visible.filter(Boolean).length}/${rows.length}`,
    scenarioId, status: outcomes.includes(OUTCOME.UNKNOWN) && rows.length < count ? STATUS.UNKNOWN : pass(rows.length === count && visible.every(Boolean)),
  });
  return rows;
}

async function waitVisible(ctx, rows, members, deadlineMs = ctx.convergenceMs) {
  const scope = subset(ctx.target, members);
  return Promise.all(rows.map(async (row) => {
    const started = Date.now();
    while (Date.now() - started <= deadlineMs) {
      const reads = await readEverywhere(ctx.http, scope, row.storagePath);
      if (reads.every((read) => read.status === 200)) return true;
      await sleep(1_000);
    }
    return false;
  }));
}

function expectedProps(row, signer) {
  return { contentType: 'page', message: row.message, 'oak:proposalId': row.proposalId, organization: row.organization, wallet: signer.address.toLowerCase() };
}

// Every row present with exactly its submitted values on the given members, identical across them.
async function assertFidelity(ctx, { label, members, rows, scenarioId, signer }) {
  const scope = subset(ctx.target, members);
  const results = await Promise.all(rows.map(async (row) => {
    const reads = await readEverywhere(ctx.http, scope, row.storagePath);
    return { fidelity: compareExpected(reads, expectedProps(row, signer)), path: row.storagePath, strict: compareAcrossNodes(reads) };
  }));
  const bad = results.filter((result) => !result.fidelity.equal || !result.strict.equal);
  await ctx.run.writeJson(`reads/${scenarioId}-${label}.json`, results);
  ctx.run.assert({
    assertionId: `${label}.fidelity`, evidence: `reads/${scenarioId}-${label}.json`,
    expected: `all ${rows.length} committed writes present with their submitted values and identical on members ${members.join(',')}`,
    observed: `${rows.length - bad.length}/${rows.length}${bad.length ? `; ${brief(bad.map((b) => `${b.path}: ${brief(b.fidelity.mismatches.concat(b.strict.differing), 160)}`))}` : ''}`,
    scenarioId, status: rows.length === 0 ? STATUS.UNKNOWN : pass(bad.length === 0),
  });
  return bad.length === 0;
}

// APPLIED / ABSENT / DIVERGENT / UNREADABLE across the given members.
async function stateOf(ctx, row, members) {
  const reads = await readEverywhere(ctx.http, subset(ctx.target, members), row.storagePath);
  if (reads.some((read) => read.status !== 200 && read.status !== 404)) return { reads, state: 'UNREADABLE' };
  const applied = reads.filter((read) => read.status === 200 && read.properties?.['oak:proposalId'] === row.proposalId);
  if (applied.length === reads.length) return { reads, state: 'APPLIED' };
  if (reads.every((read) => read.status === 404)) return { reads, state: 'ABSENT' };
  return { reads, state: 'DIVERGENT' };
}

// Poll until every row is APPLIED or the deadline passes; the final reading classifies.
async function resolveByState(ctx, rows, members, deadlineMs = ctx.convergenceMs) {
  const started = Date.now();
  let states = [];
  do {
    states = await Promise.all(rows.map((row) => stateOf(ctx, row, members)));
    if (states.every((entry) => entry.state === 'APPLIED')) break;
    await sleep(2_000);
  } while (Date.now() - started <= deadlineMs);
  return states;
}

// Nodes under the write's parent whose name ends with its proposal prefix, on each member.
async function copiesOf(ctx, row, members) {
  const parent = parentOf(row.originalStoragePath ?? row.storagePath);
  const suffix = `-${proposalPrefix(row.proposalId)}`;
  const counts = await Promise.all(members.map(async (id) => {
    const node = ctx.target.nodes[id];
    const response = await ctx.http.request(`${node.url}/api/explore?path=${encodeURIComponent(parent)}`);
    if (response.status !== 200 || !Array.isArray(response.json?.children)) return null;
    return response.json.children.filter((name) => String(name).endsWith(suffix)).length;
  }));
  return counts;
}

// Strict logical-state digest (charter §8) on the given members, via the HTTP segment exporter.
async function digestGate(ctx, scenarioId, label, { members = ctx.target.nodes.map((node) => node.id), required = true } = {}) {
  let exporter;
  try {
    exporter = await import('./exporter.mjs');
  } catch (error) {
    ctx.run.assert({
      assertionId: `digest.${label}`, expected: 'strict state digest identical on every member', kind: required ? 'required' : 'diagnostic',
      observed: `exporter unavailable: ${error.message}`, scenarioId, status: STATUS.UNKNOWN,
    });
    return null;
  }
  const scope = subset(ctx.target, members);
  const jar = launchedJarPath(ctx.target).path;
  const results = await exporter.exportEverywhere(scope, { jar, paths: ['/'] });
  for (const [index, result] of results.entries()) {
    await ctx.run.writeJson(`exports/${label}-node-${scope.nodes[index].id}.json`, result.export ?? { error: result.error, exitCode: result.exitCode, stderrTail: result.stderrTail });
  }
  const comparison = exporter.compareExports(results);
  ctx.run.assert({
    assertionId: `digest.${label}`, evidence: `exports/${label}-node-*.json`, kind: required ? 'required' : 'diagnostic',
    expected: `strict recursive state digest of / identical on members ${members.join(',')}`,
    observed: comparison.unknown.length ? `export failed on ${comparison.unknown.join(',')}`
      : (comparison.equal ? `identical ${Object.values(comparison.digests)[0]?.slice(0, 16)}…` : `differs: ${brief(comparison.firstDifference)}`),
    scenarioId, status: comparison.unknown.length ? STATUS.UNKNOWN : pass(comparison.equal),
  });
  return comparison;
}

function context(base, params) {
  return {
    ...base,
    convergenceMs: Number(params.convergenceSeconds ?? 60) * 1_000,
    faults: createFaultController(base.target, { run: base.run }),
    recoveryMs: Number(params.recoverySeconds ?? 180) * 1_000,
    terminalMs: Number(params.terminalSeconds ?? 90) * 1_000,
  };
}

// Start a member the way a process supervisor would: launch, then require the process to stay
// alive and serve /health for a short stability window; if it exits, record why (the tail of its
// log) and relaunch after a backoff until the recovery deadline. member.sh start reports success
// once the JVM is launched, so its exit code alone never counts as recovery.
async function lastError(ctx, id) {
  try {
    const { readFile } = await import('node:fs/promises');
    const text = await readFile(`${ctx.target.logDir}/validator-${id}.log`, 'utf8');
    const lines = text.split('\n').slice(-400);
    const cause = [...lines].reverse().find((line) => /Caused by|ERROR/.test(line));
    return cause ? cause.replace(/^.*?(Caused by|ERROR)/, '$1').slice(0, 300) : null;
  } catch (_error) {
    return null;
  }
}

async function restartMember(ctx, scenarioId, id, { deadlineMs = ctx.recoveryMs, stableMs = 5_000, backoffMs = 5_000 } = {}) {
  const node = ctx.target.nodes[id];
  const started = Date.now();
  const attempts = [];
  let recovered = false;
  while (!recovered && Date.now() - started <= deadlineMs) {
    const start = await ctx.faults.member('start', id);
    const attempt = { exitCode: start.exitCode, pid: start.pidAfter, startedAfterMs: Date.now() - started };
    attempts.push(attempt);
    if (start.exitCode === 0 && start.pidAfter) {
      let upSince = null;
      const attemptDeadline = Math.min(started + deadlineMs, Date.now() + 120_000);
      while (Date.now() <= attemptDeadline) {
        const proc = await processState(node);
        if (proc.pid !== start.pidAfter) break;
        const health = await ctx.http.request(`${node.url}/health`, { timeout: 2_000 });
        if (health.status === 200) {
          upSince ??= Date.now();
          if (Date.now() - upSince >= stableMs) {
            recovered = true;
            break;
          }
        } else {
          upSince = null;
        }
        await sleep(1_000);
      }
    }
    if (!recovered) {
      attempt.exitedWith = await lastError(ctx, id);
      await ctx.run.event('member.start.failed', { attempt: attempts.length, member: id, ...attempt });
      if (Date.now() - started + backoffMs > deadlineMs) break;
      await sleep(backoffMs);
    }
  }
  ctx.run.assert({
    assertionId: `member-${id}.recovered`, evidence: 'timeline.ndjson',
    expected: `member ${id} running and serving /health for ${stableMs / 1_000}s within ${deadlineMs / 1_000}s, restarted on exit like a supervisor would`,
    observed: `${recovered ? 'up' : 'not up'} after ${attempts.length} start attempt(s), ${Date.now() - started}ms`,
    scenarioId, status: pass(recovered),
  });
  ctx.run.assert({
    assertionId: `member-${id}.first-start`, evidence: 'timeline.ndjson', kind: 'diagnostic',
    expected: `the first start after the fault stays up (no crash loop)`,
    observed: attempts.length === 1 && recovered ? 'first start stayed up'
      : `${attempts.length} attempts; first exited: ${brief(attempts[0]?.exitedWith ?? 'unknown', 240)}`,
    scenarioId, status: pass(recovered && attempts.length === 1),
  });
  return { attempts, recovered };
}

async function injectStop(ctx, scenarioId, id, mode) {
  const action = mode === 'kill' ? 'kill' : 'stop';
  const result = await ctx.faults.member(action, id);
  const down = await waitMemberDown(ctx.http, ctx.target.nodes[id], { deadlineMs: 60_000 });
  ctx.run.assert({
    assertionId: `member-${id}.${action}`, evidence: 'timeline.ndjson', expected: `member ${id} ${action === 'kill' ? 'SIGKILLed' : 'stopped by SIGTERM without escalation'}: pid gone, port closed`,
    observed: `exit ${result.exitCode}; down=${down.down} after ${down.elapsedMs}ms (${brief(down.last, 120)})`,
    scenarioId, status: pass(result.exitCode === 0 && down.down),
  });
  return down.down;
}

// ---------------------------------------------------------------------------------------
// F1-05 duplicate proposal ID (class B): a proposal resent after and during its terminal
// outcome has exactly one logical effect.

export async function duplicateProposal(base, params) {
  const ctx = { ...base, convergenceMs: Number(params.convergenceSeconds ?? 60) * 1_000, terminalMs: Number(params.terminalSeconds ?? 90) * 1_000 };
  const scenarioId = 'F1-05';
  const signer = harnessSigner(`${ctx.seed}/dup`);
  const organization = `Harness${randomBytes(3).toString('hex')}`;
  const all = ctx.target.nodes.map((node) => node.id);
  const [original] = await commitWrites(ctx, { count: 1, label: 'original', organization, scenarioId, signer, visibleOn: all });
  if (!original) return;

  const after = await resubmit(ctx.http, ctx.target, ctx.run, original);
  const afterVerdict = after.operationId ? await reconcile(ctx.http, ctx.target, ctx.run, after.operationId, { deadlineMs: ctx.terminalMs }) : null;
  ctx.run.assert({
    assertionId: 'retry-after-terminal.answer', evidence: 'ledger.ndjson', kind: 'diagnostic',
    expected: 'a deterministic duplicate rejection (4xx), or an accepted retry that commits nothing new',
    observed: `http ${after.httpStatus}${afterVerdict ? ` → ${afterVerdict.outcome}${afterVerdict.reason ? ` (${afterVerdict.reason})` : ''}` : ''}; body ${brief(after.body, 160)}`,
    scenarioId, status: pass(after.httpStatus >= 400 && after.httpStatus < 500),
  });

  // Same proposal twice in flight at once.
  const concurrentSigner = signer;
  const twin = await submitWrite(ctx.http, ctx.target, ctx.run, { message: `oak harness ${scenarioId} twin ${ctx.run.id}`, organization, signer: concurrentSigner });
  const twinRetry = await resubmit(ctx.http, ctx.target, ctx.run, twin);
  const twinVerdicts = await Promise.all([twin, twinRetry].filter((row) => row.operationId)
    .map((row) => reconcile(ctx.http, ctx.target, ctx.run, row.operationId, { deadlineMs: ctx.terminalMs })));
  await ctx.run.event('duplicate.twin', { first: twin.httpStatus, retry: twinRetry.httpStatus, verdicts: twinVerdicts.map((v) => v.outcome) });
  await sleep(2_000);

  const rows = [{ label: 'after-terminal', row: original }, { label: 'in-flight', row: twin }];
  for (const { label, row } of rows) {
    const counts = await copiesOf(ctx, row, all);
    ctx.run.assert({
      assertionId: `${label}.one-effect`, evidence: 'ledger.ndjson',
      expected: `exactly one node for proposal ${row.proposalId.slice(0, 12)}… on every member`,
      observed: `copies per member ${counts.map((count) => count ?? '?').join(',')}`,
      scenarioId, status: counts.includes(null) ? STATUS.UNKNOWN : pass(counts.every((count) => count === 1)),
    });
  }
}

// ---------------------------------------------------------------------------------------
// O2-05 recursive convergence (class A): strict digest identical on every member.

export async function convergence(base) {
  const ctx = { ...base };
  const settled = await gateSettled(ctx, 'O2-05', 'before-export');
  if (!settled.settled) return;
  await digestGate(ctx, 'O2-05', 'converged');
}

// ---------------------------------------------------------------------------------------
// S3-01 / S3-02 follower TERM / KILL: progress with a majority, catch-up, convergence.

export async function followerFault(base, params) {
  const ctx = context(base, params);
  const mode = params.mode === 'kill' ? 'kill' : 'term';
  const scenarioId = mode === 'kill' ? 'S3-02' : 'S3-01';
  const all = ctx.target.nodes.map((node) => node.id);
  const pre = await gateSettled(ctx, scenarioId, 'before-fault');
  if (!pre.settled) return;
  const victim = all.find((id) => id !== pre.leader.id);
  const survivors = all.filter((id) => id !== victim);
  await ctx.run.event('scenario.start', { leader: pre.leader.id, mode, scenarioId, victim });

  if (!(await injectStop(ctx, scenarioId, victim, mode))) return;
  const during = await gateSettled(ctx, scenarioId, 'majority', { deadlineMs: 30_000, members: survivors });
  const signer = harnessSigner(`${ctx.seed}/${scenarioId}`);
  const organization = `Harness${randomBytes(3).toString('hex')}`;
  const rows = during.settled
    ? await commitWrites(ctx, { count: Number(params.writes ?? 5), label: 'during-outage', organization, scenarioId, signer, visibleOn: survivors })
    : [];

  await restartMember(ctx, scenarioId, victim);
  const post = await gateSettled(ctx, scenarioId, 'after-recovery', { deadlineMs: Number(params.recoverySeconds ?? 180) * 1_000 });
  ctx.run.assert({
    assertionId: 'leader-unchanged', kind: 'diagnostic', expected: `leadership stays on member ${pre.leader.id} through a follower fault`,
    observed: `member ${post.leader?.id ?? '-'}`, scenarioId, status: post.settled ? pass(post.leader.id === pre.leader.id) : STATUS.UNKNOWN,
  });
  const caughtUp = await waitVisible(ctx, rows, [victim]);
  ctx.run.assert({
    assertionId: 'catch-up', evidence: 'reads/', expected: `member ${victim} holds all ${rows.length} writes committed while it was down, within ${ctx.convergenceMs / 1_000}s`,
    observed: `${caughtUp.filter(Boolean).length}/${rows.length}`, scenarioId, status: rows.length === 0 ? STATUS.UNKNOWN : pass(caughtUp.every(Boolean)),
  });
  await assertFidelity(ctx, { label: 'after-recovery', members: all, rows, scenarioId, signer });
  await digestGate(ctx, scenarioId, 'after-recovery');
}

// ---------------------------------------------------------------------------------------
// S3-04 leader TERM (quiet) / S3-05 leader KILL with writes in flight.

export async function leaderFault(base, params) {
  const ctx = context(base, params);
  const mode = params.mode === 'kill' ? 'kill' : 'term';
  const scenarioId = mode === 'kill' ? 'S3-05' : 'S3-04';
  const all = ctx.target.nodes.map((node) => node.id);
  const pre = await gateSettled(ctx, scenarioId, 'before-fault');
  if (!pre.settled) return;
  const oldLeader = pre.leader.id;
  const survivors = all.filter((id) => id !== oldLeader);
  const signer = harnessSigner(`${ctx.seed}/${scenarioId}`);
  const organization = `Harness${randomBytes(3).toString('hex')}`;

  const before = await commitWrites(ctx, { count: Number(params.writesBefore ?? 3), label: 'before-fault', organization, scenarioId, signer, visibleOn: all });

  // In flight: a concurrent burst at the leader, then the fault as soon as the answers are in.
  const inFlightCount = Number(params.inFlight ?? 0);
  const burst = inFlightCount > 0
    ? await Promise.all(Array.from({ length: inFlightCount }, (_, index) => submitWrite(ctx.http, ctx.target, ctx.run, {
      leaderUrl: pre.leader.url, message: `oak harness ${scenarioId} in-flight ${index} ${ctx.run.id}`, organization, signer,
    })))
    : [];
  await ctx.run.event('scenario.fault', { burst: burst.map((row) => row.httpStatus), oldLeader, scenarioId });
  if (!(await injectStop(ctx, scenarioId, oldLeader, mode))) return;

  const election = await gateSettled(ctx, scenarioId, 'new-leader', { deadlineMs: Number(params.electionSeconds ?? 90) * 1_000, members: survivors });
  if (!election.settled) {
    await restartMember(ctx, scenarioId, oldLeader);
    await gateSettled(ctx, scenarioId, 'after-recovery', { deadlineMs: Number(params.recoverySeconds ?? 180) * 1_000 });
    return;
  }

  // Committed before the fault: preserved on the survivors.
  await assertFidelity(ctx, { label: 'before-fault-preserved', members: survivors, rows: before, scenarioId, signer });

  const accepted = burst.filter((row) => (row.httpStatus === 200 || row.httpStatus === 202) && row.operationId);
  if (inFlightCount > 0) {
    ctx.run.assert({
      assertionId: 'in-flight.accepted', evidence: 'ledger.ndjson', kind: 'diagnostic', expected: `${inFlightCount} burst writes accepted (202) before the fault`,
      observed: `${accepted.length}/${inFlightCount}; statuses ${burst.map((row) => row.httpStatus).join(',')}`, scenarioId, status: pass(accepted.length === inFlightCount),
    });
    const statusAfter = await Promise.all(accepted.map((row) => ctx.http.request(`${election.leader.url}/v1/ops/operations/${encodeURIComponent(row.operationId)}`)));
    ctx.run.assert({
      assertionId: 'in-flight.status-after-failover', kind: 'diagnostic',
      expected: 'the new leader can report the outcome of operations the old leader accepted',
      note: 'ProposalQueryHandler reads the leader-local queue; a status lost on failover leaves clients only the state to poll',
      observed: `http ${statusAfter.map((response) => response.status).join(',')}`, scenarioId,
      status: accepted.length === 0 ? STATUS.UNKNOWN : pass(statusAfter.every((response) => response.status === 200)),
    });
    const states = await resolveByState(ctx, accepted, survivors);
    const count = (state) => states.filter((entry) => entry.state === state).length;
    await ctx.run.writeJson(`reads/${scenarioId}-in-flight.json`, accepted.map((row, index) => ({ proposalId: row.proposalId, state: states[index].state, storagePath: row.storagePath })));
    ctx.run.assert({
      assertionId: 'in-flight.no-divergence', evidence: `reads/${scenarioId}-in-flight.json`,
      expected: 'each accepted in-flight write is on every survivor or on none (APPLIED or ABSENT, never DIVERGENT)',
      observed: `APPLIED=${count('APPLIED')} ABSENT=${count('ABSENT')} DIVERGENT=${count('DIVERGENT')} UNREADABLE=${count('UNREADABLE')}`,
      scenarioId, status: count('UNREADABLE') ? STATUS.UNKNOWN : pass(count('DIVERGENT') === 0),
    });

    // Same-ID retry against the new leader: ABSENT must commit once; APPLIED must not duplicate.
    const leaderUrl = election.leader.url;
    const retried = await Promise.all(accepted.map((row) => resubmit(ctx.http, ctx.target, ctx.run, row, { leaderUrl })));
    const retryVerdicts = await Promise.all(retried.map((row) => (row.operationId
      ? reconcile(ctx.http, ctx.target, ctx.run, row.operationId, { deadlineMs: ctx.terminalMs }) : Promise.resolve(null))));
    const absentIdx = states.map((entry, index) => (entry.state === 'ABSENT' ? index : -1)).filter((index) => index >= 0);
    const recovered = absentIdx.filter((index) => retryVerdicts[index]?.outcome === OUTCOME.COMMITTED);
    ctx.run.assert({
      assertionId: 'retry.absent-commits', evidence: 'ledger.ndjson',
      expected: 'every in-flight write lost with the old leader commits when resent with the same proposalId',
      observed: `${recovered.length}/${absentIdx.length} committed on retry${absentIdx.length ? `; answers ${absentIdx.map((index) => `${retried[index].httpStatus}/${retryVerdicts[index]?.outcome ?? '-'}`).join(',')}` : ''}`,
      scenarioId, status: absentIdx.length === 0 ? STATUS.PASS : pass(recovered.length === absentIdx.length),
    });
    await sleep(2_000);
    const copies = await Promise.all(accepted.map((row) => copiesOf(ctx, row, survivors)));
    const duplicated = copies.filter((counts) => counts.some((count) => count !== null && count > 1)).length;
    ctx.run.assert({
      assertionId: 'retry.one-effect', evidence: 'ledger.ndjson',
      expected: 'after the retries, each in-flight proposal has exactly one node on every survivor',
      observed: `${accepted.length - duplicated}/${accepted.length} single; copies ${brief(copies.map((counts) => counts.join('/')))}`,
      scenarioId, status: copies.some((counts) => counts.includes(null)) ? STATUS.UNKNOWN : pass(duplicated === 0 && copies.every((counts) => counts.every((count) => count === 1))),
    });
  }

  await restartMember(ctx, scenarioId, oldLeader);
  const post = await gateSettled(ctx, scenarioId, 'after-recovery', { deadlineMs: Number(params.recoverySeconds ?? 180) * 1_000 });
  ctx.run.assert({
    assertionId: 'old-leader-follows', expected: `restarted member ${oldLeader} rejoins as FOLLOWER of the new leader`,
    observed: post.settled ? `leader is member ${post.leader.id}` : 'not settled', scenarioId,
    status: post.settled ? pass(post.leader.id !== oldLeader) : STATUS.UNKNOWN,
  });
  await assertFidelity(ctx, { label: 'after-recovery', members: all, rows: before, scenarioId, signer });
  await digestGate(ctx, scenarioId, 'after-recovery');
}

// ---------------------------------------------------------------------------------------
// Q4-01/02/03 quorum envelope: progress at exactly a majority, none below it, full recovery.

export async function quorumEnvelope(base, params) {
  const ctx = context(base, params);
  const all = ctx.target.nodes.map((node) => node.id);
  const majority = Math.floor(all.length / 2) + 1;
  const pre = await gateSettled(ctx, 'Q4-01', 'before-fault');
  if (!pre.settled) return;
  const followers = all.filter((id) => id !== pre.leader.id);
  const firstStops = followers.slice(0, all.length - majority);
  const lastStop = followers[all.length - majority];
  const signer = harnessSigner(`${ctx.seed}/Q4`);
  const organization = `Harness${randomBytes(3).toString('hex')}`;

  // Q4-01: down to exactly a majority.
  for (const id of firstStops) if (!(await injectStop(ctx, 'Q4-01', id, 'term'))) return;
  const atMajority = all.filter((id) => !firstStops.includes(id));
  const q1 = await gateSettled(ctx, 'Q4-01', 'majority', { deadlineMs: 30_000, members: atMajority });
  const committed = q1.settled ? await commitWrites(ctx, { count: 1, label: 'at-majority', organization, scenarioId: 'Q4-01', signer, visibleOn: atMajority }) : [];

  // Q4-02: one below a majority. A write must not commit; a refused write must never appear.
  if (!(await injectStop(ctx, 'Q4-02', lastStop, 'term'))) return;
  const alive = atMajority.filter((id) => id !== lastStop);
  await sleep(Number(params.quorumLossSettleSeconds ?? 10) * 1_000);
  const aliveTarget = subset(ctx.target, alive);
  // Q4 only ever stops followers, so the pre-fault leader is still running: submit there.
  const attempt = await submitWrite(ctx.http, aliveTarget, ctx.run, { leaderUrl: pre.leader.url, message: `oak harness Q4-02 no-quorum ${ctx.run.id}`, organization, signer });
  const accepted = (attempt.httpStatus === 200 || attempt.httpStatus === 202) && Boolean(attempt.operationId);
  let duringOutcome = null;
  if (accepted) {
    duringOutcome = await reconcile(ctx.http, aliveTarget, ctx.run, attempt.operationId, { deadlineMs: Number(params.noQuorumSeconds ?? 45) * 1_000 });
  }
  const visibleDuring = attempt.storagePath ? (await readEverywhere(ctx.http, aliveTarget, attempt.storagePath)).map((read) => read.status) : [];
  ctx.run.assert({
    assertionId: 'no-commit-without-quorum', evidence: 'ledger.ndjson',
    expected: `with ${alive.length}/${all.length} members a write is refused or stays uncommitted, and its path is not readable`,
    observed: `http ${attempt.httpStatus}${duringOutcome ? ` → ${duringOutcome.outcome} (${duringOutcome.state ?? duringOutcome.reason})` : ''}; reads ${visibleDuring.join(',') || 'n/a'}; body ${brief(attempt.body, 160)}`,
    scenarioId: 'Q4-02', status: attempt.httpStatus === 0 ? STATUS.UNKNOWN
      : pass(duringOutcome?.outcome !== OUTCOME.COMMITTED && !visibleDuring.includes(200)),
  });

  // Q4-03: restore every member; sentinel progress; the no-quorum write is resolved consistently.
  for (const id of [lastStop, ...firstStops]) await restartMember(ctx, 'Q4-03', id);
  const post = await gateSettled(ctx, 'Q4-03', 'after-recovery', { deadlineMs: Number(params.recoverySeconds ?? 180) * 1_000 });
  if (!post.settled) return;
  const sentinel = await commitWrites(ctx, { count: 1, label: 'sentinel', organization, scenarioId: 'Q4-03', signer, visibleOn: all });
  if (attempt.storagePath) {
    const [final] = await resolveByState(ctx, [attempt], all, accepted ? ctx.convergenceMs : 5_000);
    ctx.run.assert({
      assertionId: 'no-quorum-write.resolved', evidence: 'ledger.ndjson',
      expected: accepted ? 'the accepted no-quorum write ends on every member or on none (never DIVERGENT)' : 'the refused write never appears',
      observed: `${final.state}${accepted ? '' : ' (refused at submit)'}`, scenarioId: 'Q4-03',
      status: final.state === 'UNREADABLE' ? STATUS.UNKNOWN : pass(accepted ? final.state !== 'DIVERGENT' : final.state === 'ABSENT'),
    });
  }
  await assertFidelity(ctx, { label: 'after-recovery', members: all, rows: [...committed, ...sentinel], scenarioId: 'Q4-03', signer });
  await digestGate(ctx, 'Q4-03', 'after-recovery');
}

// ---------------------------------------------------------------------------------------
// R6-01 / R6-02 all-member graceful / hard restart preserving stores.

export async function clusterRestart(base, params) {
  const ctx = context(base, params);
  const mode = params.mode === 'kill' ? 'kill' : 'term';
  const scenarioId = mode === 'kill' ? 'R6-02' : 'R6-01';
  const all = ctx.target.nodes.map((node) => node.id);
  const pre = await gateSettled(ctx, scenarioId, 'before-fault');
  if (!pre.settled) return;
  const signer = harnessSigner(`${ctx.seed}/${scenarioId}`);
  const organization = `Harness${randomBytes(3).toString('hex')}`;

  const registration = await registerWallet(ctx.http, ctx.target, ctx.run, signer);
  const rows = await commitWrites(ctx, { count: Number(params.writes ?? 4), label: 'before-restart', organization, scenarioId, signer, visibleOn: all });
  let deleted = null;
  if (rows.length > 1 && registration.httpStatus >= 200 && registration.httpStatus < 300) {
    deleted = rows.pop();
    const del = await submitDelete(ctx.http, ctx.target, ctx.run, { contentPath: deleted.storagePath, signer });
    const verdict = del.operationId ? await reconcile(ctx.http, ctx.target, ctx.run, del.operationId, { deadlineMs: ctx.terminalMs }) : null;
    ctx.run.assert({
      assertionId: 'delete.committed', evidence: 'ledger.ndjson', expected: 'one signed delete COMMITTED before the restart',
      observed: `http ${del.httpStatus} → ${verdict?.outcome ?? '-'}`, scenarioId, status: verdict ? pass(verdict.outcome === OUTCOME.COMMITTED) : STATUS.FAIL,
    });
  }
  const before = await digestGate(ctx, scenarioId, 'before-restart');

  if (mode === 'kill') {
    const results = await Promise.all(all.map((id) => ctx.faults.member('kill', id)));
    await ctx.run.event('cluster.killed', { exits: results.map((r) => r.exitCode) });
  } else {
    for (const id of [...all].reverse()) await ctx.faults.member('stop', id);
  }
  const downs = await Promise.all(all.map((id) => waitMemberDown(ctx.http, ctx.target.nodes[id], { deadlineMs: 60_000 })));
  ctx.run.assert({
    assertionId: 'all-down', expected: `all ${all.length} members ${mode === 'kill' ? 'SIGKILLed' : 'stopped by SIGTERM'}`,
    observed: downs.map((down, id) => `${id}:${down.down}`).join(' '), scenarioId, status: pass(downs.every((down) => down.down)),
  });
  if (!downs.every((down) => down.down)) return;

  for (const id of all) await restartMember(ctx, scenarioId, id);
  const post = await gateSettled(ctx, scenarioId, 'after-restart', { deadlineMs: Number(params.recoverySeconds ?? 180) * 1_000 });
  if (!post.settled) return;
  await assertFidelity(ctx, { label: 'after-restart', members: all, rows, scenarioId, signer });
  if (deleted) {
    const [state] = await resolveByState(ctx, [deleted], all, 5_000);
    ctx.run.assert({
      assertionId: 'delete.survives', expected: 'the node deleted before the restart is absent on every member after it',
      observed: state.state, scenarioId, status: state.state === 'UNREADABLE' ? STATUS.UNKNOWN : pass(state.state === 'ABSENT'),
    });
  }
  const after = await digestGate(ctx, scenarioId, 'after-restart');
  const beforeDigest = before && !before.unknown.length && before.equal ? Object.values(before.digests)[0] : null;
  const afterDigest = after && !after.unknown.length && after.equal ? Object.values(after.digests)[0] : null;
  ctx.run.assert({
    assertionId: 'digest.unchanged-by-restart', evidence: 'exports/',
    expected: 'the strict state digest after the restart equals the digest before it (no write lost, none added)',
    observed: beforeDigest && afterDigest ? (beforeDigest === afterDigest ? `identical ${afterDigest.slice(0, 16)}…` : `${beforeDigest.slice(0, 16)}… → ${afterDigest.slice(0, 16)}…`) : 'a digest is missing',
    scenarioId, status: beforeDigest && afterDigest ? pass(beforeDigest === afterDigest) : STATUS.UNKNOWN,
  });
  await commitWrites(ctx, { count: 1, label: 'sentinel', organization, scenarioId, signer, visibleOn: all });
}

export const FAULT_SCENARIOS = Object.freeze({
  'cluster-restart': clusterRestart,
  convergence,
  'duplicate-proposal': duplicateProposal,
  'follower-fault': followerFault,
  'leader-fault': leaderFault,
  'quorum-envelope': quorumEnvelope,
});
