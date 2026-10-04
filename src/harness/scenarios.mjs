// Scenario implementations. Campaign files (modes/mock/campaigns/*.json) choose a scenario
// and its parameters; scenarios only observe, act and record assertions.

import { randomBytes } from 'node:crypto';

import { classifyOperation, harnessSigner, OUTCOME, reconcile, submitWrite } from './client.mjs';
import { STATUS } from './evidence.mjs';
import { findLeader, leadersIn, sampleCluster } from './observe.mjs';
import { compareAcrossNodes, compareExpected, readEverywhere, VOLATILE_PROPERTIES, waitPresentEverywhere } from './oracle.mjs';
import { processState } from './target.mjs';

const pass = (ok) => (ok ? STATUS.PASS : STATUS.FAIL);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function brief(value, max = 300) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

async function pool(items, concurrency, worker) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, concurrency) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index], index);
    }
  }));
  return results;
}

// ---------------------------------------------------------------------------------------
// P0: provenance, topology, leader/quorum parity, observability contract, idle window

export async function preflight({ http, manifest, run, target }, params) {
  const { processes, provenance } = manifest;
  const size = target.size;

  // P0-01 provenance
  const jar = provenance.jar;
  run.assert({
    assertionId: 'jar.sha256', expected: 'consensus jar SHA-256 recorded', evidence: 'manifest.json#provenance.jar',
    observed: jar.sha256 ?? `missing (${jar.error})`, scenarioId: 'P0-01', status: jar.sha256 ? STATUS.PASS : STATUS.UNKNOWN,
  });
  const repos = provenance.repos;
  const heads = [repos.jackrabbitOak.head, repos.oakChainInfra.head];
  run.assert({
    assertionId: 'repos.head', expected: 'HEAD recorded for jackrabbit-oak and oak-chain-infra', evidence: 'manifest.json#provenance.repos',
    observed: `jackrabbit-oak ${repos.jackrabbitOak.head?.slice(0, 10) ?? '?'} (${repos.jackrabbitOak.dirtyCount ?? '?'} dirty), oak-chain-infra ${repos.oakChainInfra.head?.slice(0, 10) ?? '?'} (${repos.oakChainInfra.dirtyCount ?? '?'} dirty)`,
    scenarioId: 'P0-01', status: heads.every(Boolean) ? STATUS.PASS : STATUS.UNKNOWN,
  });
  const startTimes = processes.map((proc) => (proc.startedAt ? Date.parse(proc.startedAt) : null));
  const jarAge = jar.mtimeMs ?? null;
  const ranCurrentJar = jarAge !== null && startTimes.every((value) => value !== null && value >= jarAge);
  run.assert({
    assertionId: 'processes.after-jar', expected: 'every validator started after the current jar was built (so it runs that jar)',
    evidence: 'manifest.json#processes', note: 'process start vs jar mtime; a process older than the jar may run a previous build',
    observed: `jar ${jar.mtime ?? '?'}; starts ${processes.map((proc) => proc.startedAt ?? '?').join(', ')}`,
    scenarioId: 'P0-01', status: jarAge === null || startTimes.includes(null) ? STATUS.UNKNOWN : pass(ranCurrentJar),
  });
  const configNames = ['', '/sources', '/delta', '/coverage'];
  let configCaptured = 0;
  for (const node of target.nodes) {
    for (const suffix of configNames) {
      const response = await http.request(`${node.url}/v1/config/osgi${suffix}`);
      if (response.status === 200) configCaptured += 1;
      await run.writeJson(`config/node-${node.id}-osgi${suffix.replace('/', '-') || ''}.json`, response.json ?? { error: response.error, status: response.status });
    }
  }
  run.assert({
    assertionId: 'config.captured', evidence: 'config/', expected: `effective OSGi config, sources, delta and coverage from ${size} nodes`,
    kind: 'diagnostic', observed: `${configCaptured}/${size * configNames.length} captured`, scenarioId: 'P0-01',
    status: pass(configCaptured === size * configNames.length),
  });

  // P0-02 process/topology map
  processes.forEach((proc, index) => {
    const node = target.nodes[index];
    const identity = Boolean(proc.pid) && proc.commandNamesStore;
    run.assert({
      assertionId: `node-${node.id}.process`, evidence: 'manifest.json#processes',
      expected: `pid file names a live process whose command line names ${node.storeDir}`,
      observed: proc.pid ? `pid ${proc.pid}${proc.commandNamesStore ? '' : ' (command line does not name the store)'}` : 'no live pid',
      scenarioId: 'P0-02', status: pass(identity),
    });
    run.assert({
      assertionId: `node-${node.id}.listener`, evidence: 'manifest.json#processes', expected: `:${node.port} is served by the pid-file process`,
      observed: `listeners ${proc.listenerPids.join(',') || 'none'}`, scenarioId: 'P0-02',
      status: pass(Boolean(proc.pid) && proc.listenerPids.includes(proc.pid)),
    });
  });

  // P0-03 leader/quorum parity across synchronized rounds
  const rounds = [];
  for (let round = 0; round < (params.parityRounds ?? 3); round += 1) {
    const sample = await sampleCluster(http, target);
    rounds.push(sample);
    await run.appendSample({ kind: 'parity', round, ...sample });
    if (round + 1 < (params.parityRounds ?? 3)) await sleep(1_000);
  }
  const leaderUrls = rounds.map((sample) => leadersIn(sample).map((node) => node.url));
  const oneLeader = leaderUrls.every((urls) => urls.length === 1) && new Set(leaderUrls.flat()).size === 1;
  const leaderUrl = oneLeader ? leaderUrls[0][0] : null;
  run.assert({
    assertionId: 'one-leader', evidence: 'samples.ndjson', expected: `exactly one LEADER in each of ${rounds.length} rounds, same node throughout`,
    observed: leaderUrls.map((urls) => urls.join('+') || 'none').join(' | '), scenarioId: 'P0-03', status: pass(oneLeader),
  });
  const agreement = rounds.flatMap((sample) => sample.nodes.map((node) => [node.consensus.currentLeader, node.aeron.currentLeader]));
  const agreed = Boolean(leaderUrl) && agreement.every(([consensus, aeron]) => consensus === leaderUrl && aeron === leaderUrl);
  run.assert({
    assertionId: 'leader-agreement', evidence: 'samples.ndjson', expected: 'every node names the same leader on /v1/consensus/status and /v1/aeron/cluster-state',
    observed: brief([...new Set(agreement.flat().map(String))]), scenarioId: 'P0-03', status: leaderUrl ? pass(agreed) : STATUS.UNKNOWN,
  });
  const lastRound = rounds.at(-1);
  const need = Math.floor(size / 2) + 1;
  const counts = (field) => lastRound.nodes.map((node) => node.health[field]);
  run.assert({
    assertionId: 'members', evidence: 'samples.ndjson', expected: `totalMembers=${size} on every node`,
    observed: counts('totalMembers').join(','), scenarioId: 'P0-03', status: pass(counts('totalMembers').every((value) => value === size)),
  });
  run.assert({
    assertionId: 'reachable', evidence: 'samples.ndjson', expected: `reachableCount=${size} on every node`,
    observed: counts('reachableCount').join(','), scenarioId: 'P0-03', status: pass(counts('reachableCount').every((value) => value === size)),
  });
  run.assert({
    assertionId: 'healthy', evidence: 'samples.ndjson', expected: 'clusterHealthy=true on every node',
    observed: counts('clusterHealthy').join(','), scenarioId: 'P0-03', status: pass(counts('clusterHealthy').every((value) => value === true)),
  });
  const quorumOk = lastRound.nodes.every((node) => node.aeron.hasQuorum === true && node.aeron.quorumRequired === need);
  run.assert({
    assertionId: 'quorum', evidence: 'samples.ndjson', expected: `hasQuorum=true and required=${need} on every node`,
    note: 'derived from HTTP-probe reachability, not native Aeron quorum (cross-lane finding)',
    observed: lastRound.nodes.map((node) => `${node.aeron.hasQuorum}/${node.aeron.quorumRequired}`).join(','), scenarioId: 'P0-03', status: pass(quorumOk),
  });
  const positions = lastRound.nodes.map((node) => node.aeron.logPosition);
  const knownPositions = positions.filter((value) => value !== null);
  run.assert({
    assertionId: 'log-position', evidence: 'samples.ndjson', expected: 'Aeron log position equal on every node when idle',
    kind: 'diagnostic', observed: positions.join(','), scenarioId: 'P0-03',
    status: knownPositions.length === positions.length ? pass(new Set(knownPositions).size === 1) : STATUS.UNKNOWN,
  });

  // P0-04 observability contract
  const roleMismatch = lastRound.nodes.filter((node) => !(node.health.role && node.health.role === node.consensus.role && node.consensus.role === node.aeron.role));
  run.assert({
    assertionId: 'role-surfaces', evidence: 'samples.ndjson', expected: 'role identical on /health, /v1/consensus/status and /v1/aeron/cluster-state',
    observed: lastRound.nodes.map((node) => `${node.id}:${node.health.role}/${node.consensus.role}/${node.aeron.role}`).join(' '),
    scenarioId: 'P0-04', status: pass(roleMismatch.length === 0),
  });
  const leaderMetricOk = lastRound.nodes.every((node) => node.metrics.isLeader === (String(node.health.role).toUpperCase() === 'LEADER' ? 1 : 0));
  run.assert({
    assertionId: 'prometheus.is-leader', evidence: 'samples.ndjson', expected: 'oak_consensus_is_leader matches API role on every node',
    observed: lastRound.nodes.map((node) => `${node.id}:${node.metrics.isLeader}`).join(' '), scenarioId: 'P0-04',
    status: lastRound.nodes.some((node) => node.metrics.isLeader === null) ? STATUS.UNKNOWN : pass(leaderMetricOk),
  });
  const reachableMetricOk = lastRound.nodes.every((node) => node.metrics.reachable === node.health.reachableCount);
  run.assert({
    assertionId: 'prometheus.reachable', evidence: 'samples.ndjson', expected: 'oak_validators_reachable equals API reachableCount on every node',
    observed: lastRound.nodes.map((node) => `${node.id}:${node.metrics.reachable}/${node.health.reachableCount}`).join(' '), scenarioId: 'P0-04',
    status: lastRound.nodes.some((node) => node.metrics.reachable === null) ? STATUS.UNKNOWN : pass(reachableMetricOk),
  });
  const ops = await http.request(`http://127.0.0.1:${target.opsPort}/ops/v1/overview`);
  const opsLeader = ops.json?.data?.leader ?? ops.json?.leader ?? null;
  const leaderMember = lastRound.nodes.find((node) => node.url === leaderUrl)?.aeron.memberId ?? null;
  run.assert({
    assertionId: 'ops-proxy.leader', evidence: 'samples.ndjson', expected: `OPS overview names member ${leaderMember ?? '?'} as LEADER`,
    kind: 'diagnostic', note: 'known: edge-worker OPS leader detection (cross-lane issue)',
    observed: ops.status === 200 ? `nodeId ${opsLeader?.nodeId} role ${opsLeader?.role}` : `http ${ops.status}`, scenarioId: 'P0-04',
    status: ops.status !== 200 || leaderMember === null ? STATUS.UNKNOWN : pass(opsLeader?.nodeId === leaderMember && String(opsLeader?.role).toUpperCase() === 'LEADER'),
  });

  // P0-05 idle quietness (abbreviated window)
  const idleSeconds = Number(params.idleSeconds ?? 0);
  if (idleSeconds > 0) {
    const pidsAt = async () => (await Promise.all(target.nodes.map(processState))).map((proc) => proc.pid);
    const basePids = await pidsAt();
    const leaderSeen = new Set();
    const pending = new Set();
    const deadline = Date.now() + idleSeconds * 1_000;
    let pidsStable = true;
    while (Date.now() < deadline) {
      const leader = await findLeader(http, target);
      leaderSeen.add(leader?.url ?? 'none');
      if (leader) {
        const stats = await http.request(`${leader.url}/v1/proposals/queue/stats`);
        const data = stats.json?.data ?? stats.json ?? {};
        pending.add(data.pendingCount ?? 'unknown');
      }
      const pids = await pidsAt();
      if (pids.join() !== basePids.join()) pidsStable = false;
      await sleep(2_000);
    }
    const note = `abbreviated window: ${idleSeconds}s of the charter's 30 min`;
    run.assert({ assertionId: 'pids-stable', expected: 'no validator PID change', note, observed: pidsStable ? `stable ${basePids.join(',')}` : 'changed', scenarioId: 'P0-05', status: pass(pidsStable) });
    run.assert({ assertionId: 'leader-stable', expected: 'no leadership change', note, observed: [...leaderSeen].join(' → '), scenarioId: 'P0-05', status: pass(leaderSeen.size === 1 && !leaderSeen.has('none')) });
    run.assert({ assertionId: 'queue-baseline', expected: 'leader pendingCount stays 0', kind: 'diagnostic', note, observed: [...pending].join(','), scenarioId: 'P0-05', status: pass(pending.size === 1 && pending.has(0)) });
  }
}

// ---------------------------------------------------------------------------------------
// F1-01 one write (+ F1-01b value fidelity): accepted ≠ committed; prove the value everywhere

const FIDELITY_MESSAGE = 'F1-01b {"quote":"a \\"b\\" c","path":"/x"} ünïcødé ✓ back\\slash & = + %';

export async function oneWrite({ http, run, seed, target }, params) {
  const signer = harnessSigner(seed);
  const wallet = signer.address;
  const organization = `Harness${randomBytes(3).toString('hex')}`;
  const cases = [
    { message: `oak harness F1-01 ${run.id} plain ascii`, scenarioId: 'F1-01' },
    ...(params.valueFidelity === false ? [] : [{ message: `${FIDELITY_MESSAGE} ${run.id}`, scenarioId: 'F1-01b' }]),
  ];
  for (const testCase of cases) {
    const { scenarioId } = testCase;
    await run.event('scenario.start', { scenarioId });
    const row = await submitWrite(http, target, run, { message: testCase.message, organization, signer });
    const accepted = (row.httpStatus === 200 || row.httpStatus === 202) && row.operationId && row.storagePath;
    run.assert({
      assertionId: 'accepted', evidence: 'ledger.ndjson', expected: 'HTTP 202 with operationId and storagePath (accepted, not yet committed)',
      observed: `http ${row.httpStatus}${row.error ? ` (${row.error})` : ''} op=${row.operationId ?? '-'} path=${row.storagePath ?? '-'}`, scenarioId,
      status: row.httpStatus === 0 ? STATUS.UNKNOWN : pass(Boolean(accepted)),
    });
    if (!accepted) continue;

    const verdict = await reconcile(http, target, run, row.operationId, { deadlineMs: (params.terminalSeconds ?? 90) * 1_000 });
    run.assert({
      assertionId: 'terminal', evidence: 'timeline.ndjson', expected: `COMMITTED within ${params.terminalSeconds ?? 90}s`,
      observed: `${verdict.outcome}${verdict.reason ? ` (${verdict.reason})` : ''} after ${verdict.elapsedMs}ms; state ${verdict.state} durability ${verdict.status?.durabilityState ?? '?'}`,
      scenarioId, status: verdict.outcome === OUTCOME.UNKNOWN ? STATUS.UNKNOWN : pass(verdict.outcome === OUTCOME.COMMITTED),
    });
    if (verdict.outcome !== OUTCOME.COMMITTED) continue;

    const visible = await waitPresentEverywhere(http, target, row.storagePath, { deadlineMs: (params.convergenceSeconds ?? 60) * 1_000 });
    await run.writeJson(`reads/${scenarioId}.json`, { reads: visible.reads, storagePath: row.storagePath });
    run.assert({
      assertionId: 'visible-everywhere', evidence: `reads/${scenarioId}.json`, expected: `node present on all ${target.size} validators within ${params.convergenceSeconds ?? 60}s`,
      observed: visible.present ? `present after ${visible.elapsedMs}ms` : `missing on ${visible.reads.filter((read) => read.status !== 200).map((read) => read.id).join(',')}`,
      scenarioId, status: pass(visible.present),
    });
    if (!visible.present) continue;

    const expected = { contentType: 'page', message: testCase.message, 'oak:proposalId': row.proposalId, organization, wallet: wallet.toLowerCase() };
    const fidelity = compareExpected(visible.reads, expected);
    run.assert({
      assertionId: 'value-fidelity', evidence: `reads/${scenarioId}.json`, expected: 'stored properties equal the submitted values on every validator',
      observed: fidelity.equal ? 'all equal' : brief(fidelity.mismatches.map((m) => `node ${m.id} ${m.name}: expected ${JSON.stringify(m.expected)} got ${JSON.stringify(m.observed)}`)),
      scenarioId, status: pass(fidelity.equal),
    });
    const strict = compareAcrossNodes(visible.reads);
    const onlyVolatile = strict.differing.every((entry) => VOLATILE_PROPERTIES.includes(entry.name));
    run.assert({
      assertionId: 'strict-equality', evidence: `reads/${scenarioId}.json`, expected: 'every property identical across validators',
      note: strict.equal ? '' : (onlyVolatile ? 'only per-node apply timestamps differ (orientation §12 item 1)' : ''),
      observed: strict.equal ? 'identical' : brief(strict.differing.map((entry) => `${entry.name} ${JSON.stringify(entry.values)}`)),
      scenarioId, status: pass(strict.equal),
    });
    const semantic = compareAcrossNodes(visible.reads, { ignore: VOLATILE_PROPERTIES });
    run.assert({
      assertionId: 'semantic-equality', evidence: `reads/${scenarioId}.json`, expected: `identical ignoring ${VOLATILE_PROPERTIES.join(', ')}`,
      kind: 'diagnostic', observed: semantic.equal ? 'identical' : brief(semantic.differing.map((entry) => entry.name)), scenarioId, status: pass(semantic.equal),
    });
  }
}

// ---------------------------------------------------------------------------------------
// Reconcile writes accepted by an earlier run (read-only): did every 202 become a
// committed, identical value on every validator?

export async function reconcileAccepted({ acceptedRecords, http, run, target }, params) {
  const scenarioId = 'RECONCILE';
  const records = acceptedRecords.filter((record) => /^20[02]$/.test(String(record.httpCode)) && record.proposalId && record.storagePath);
  const sample = Number(params.sample ?? 0);
  const selected = sample > 0 ? records.slice(0, sample) : records;
  let leader = await findLeader(http, target);

  const results = await pool(selected, Number(params.concurrency ?? 6), async (record) => {
    let status = leader ? await http.request(`${leader.url}/v1/ops/operations/${encodeURIComponent(record.proposalId)}`) : null;
    if (!status || status.status === 404) {
      leader = await findLeader(http, target);
      status = leader ? await http.request(`${leader.url}/v1/ops/operations/${encodeURIComponent(record.proposalId)}`) : null;
    }
    const verdict = classifyOperation(status?.status === 200 ? status.json : null);
    const reads = await readEverywhere(http, target, record.storagePath);
    const strict = compareAcrossNodes(reads);
    const semantic = compareAcrossNodes(reads, { ignore: VOLATILE_PROPERTIES });
    const identity = reads.every((read) => read.properties?.['oak:proposalId'] === record.proposalId);
    const messages = reads.map((read) => read.properties?.message ?? null);
    const result = {
      differing: strict.differing.map((entry) => entry.name),
      identity,
      missing: strict.missing,
      outcome: verdict?.outcome ?? OUTCOME.UNKNOWN,
      proposalId: record.proposalId,
      reason: verdict?.reason ?? (status ? `ops http ${status.status}${status.json?.state ? ` state ${status.json.state}` : ''}` : 'no leader'),
      semanticEqual: semantic.equal,
      storagePath: record.storagePath,
      truncatedMessage: messages.some((message) => typeof message === 'string' && message.endsWith('\\')),
    };
    await run.appendSample({ kind: 'reconcile', ...result });
    return result;
  });

  const by = (predicate) => results.filter(predicate).length;
  const outcomes = Object.values(OUTCOME).map((outcome) => `${outcome}=${by((r) => r.outcome === outcome)}`).join(' ');
  const total = results.length;
  run.assert({
    assertionId: 'accepted-terminal', evidence: 'samples.ndjson', expected: `all ${total} accepted operations COMMITTED`,
    observed: outcomes, scenarioId, status: total > 0 ? pass(by((r) => r.outcome === OUTCOME.COMMITTED) === total) : STATUS.UNKNOWN,
  });
  run.assert({
    assertionId: 'visible-everywhere', evidence: 'samples.ndjson', expected: `every accepted path present on all ${target.size} validators`,
    observed: `${by((r) => r.missing.length === 0)}/${total} present everywhere`, scenarioId, status: pass(by((r) => r.missing.length === 0) === total),
  });
  run.assert({
    assertionId: 'proposal-identity', evidence: 'samples.ndjson', expected: 'oak:proposalId on every validator equals the accepted proposalId',
    observed: `${by((r) => r.identity)}/${total}`, scenarioId, status: pass(by((r) => r.identity) === total),
  });
  const differingNames = {};
  results.forEach((r) => r.differing.forEach((name) => { differingNames[name] = (differingNames[name] ?? 0) + 1; }));
  run.assert({
    assertionId: 'strict-equality', evidence: 'samples.ndjson', expected: 'every property identical across validators for every write',
    note: Object.keys(differingNames).every((name) => VOLATILE_PROPERTIES.includes(name)) && Object.keys(differingNames).length > 0 ? 'only per-node apply timestamps differ (orientation §12 item 1)' : '',
    observed: `${by((r) => r.differing.length === 0 && r.missing.length === 0)}/${total} identical; differing properties ${brief(differingNames)}`,
    scenarioId, status: pass(by((r) => r.differing.length === 0 && r.missing.length === 0) === total),
  });
  run.assert({
    assertionId: 'semantic-equality', evidence: 'samples.ndjson', expected: `identical ignoring ${VOLATILE_PROPERTIES.join(', ')}`,
    kind: 'diagnostic', observed: `${by((r) => r.semanticEqual)}/${total}`, scenarioId, status: pass(by((r) => r.semanticEqual) === total),
  });
  run.assert({
    assertionId: 'message-truncation', evidence: 'samples.ndjson', expected: 'no stored message ends in a dangling backslash (escaped-quote truncation)',
    kind: 'diagnostic', note: 'generator messages are JSON; MessageDispatcher.extractJsonField truncates at the first escaped quote',
    observed: `${by((r) => r.truncatedMessage)}/${total} truncated`, scenarioId, status: pass(by((r) => r.truncatedMessage) === 0),
  });
}

export const SCENARIOS = Object.freeze({
  'one-write': oneWrite,
  preflight,
  'reconcile-accepted': reconcileAccepted,
});
