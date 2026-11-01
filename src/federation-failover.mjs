// Enterprise-federation 3x2 failover scenario (modes/mock/validators/tests/routing/federation-3x2-failover.sh).
//
// ONE bounded fault against the running federation clusters: the cluster-A member that cluster B's
// directory mount for enterprise A reads from (its activeEndpoint) is stopped gracefully with the
// root-bound member control (lifecycle/member.sh under config/fed-3x2-cluster-a.env) and restarted
// with the same control (the launch record's jar). No other member is ever signalled.
//
//   F0 preflight   six members up, one jar sha256, one directory epoch/digest, A owns nsA1, B's mounts
//                  verified; the victim = the A endpoint most B members use; its pid and command line
//   F1 baseline    one nsA1 write committed on all A members and read by every B member through the mount
//   F2 fault       `member.sh stop <victim>` (graceful SIGTERM; member.sh escalates after 30 s)
//   F3 during      (a) A has a leader among the survivors and commits a second nsA1 write on both
//                  within 90 s; (b) every B mount for A is verified and available on another endpoint
//                  within 90 s; (c) until then B reads of the baseline are the content or a 503, never
//                  missing (each outcome counted); afterwards both writes read on every B member
//   F4 recovery    `member.sh start <victim>`; UP within 120 s with its peers' charterDigest, clusterId
//                  and directory digest, serving both writes, on the recorded jar
//   F5 end state   six members up, no other pid changed, no 5xx but F3's mount 503s, log scan counts
//
// Evidence: $FED_3X2_ROOT/evidence/failover-<UTC>/ in the smoke's format plus failover.json and the
// member control output. On abort everything is left as it is (a stopped victim stays stopped; the
// report prints the restart command). Never --fresh, never another member.

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { Abort, STATUS, configFromEnv, createFederationSession } from './federation-session.mjs';
import { buildWrite } from './tx.mjs';

export const FAILOVER_DEFAULTS = Object.freeze({
  failoverDeadlineMs: 90_000,
  recoveryDeadlineMs: 120_000,
  stopDeadlineMs: 60_000,
});

// Endpoint URLs as the directory lists them (127.0.0.1, no trailing slash) for comparison.
export function normalizeEndpoint(value) {
  if (!value) return null;
  try {
    const url = new URL(String(value));
    const host = url.hostname === 'localhost' ? '127.0.0.1' : url.hostname;
    return `${url.protocol}//${host}${url.port ? `:${url.port}` : ''}`;
  } catch {
    return String(value).replace(/\/+$/, '');
  }
}

// observations: [{ reader, activeEndpoint }] from B members. The victim is the A member most B
// members read from; ties go to the lowest member index. Endpoints that are not A members are ignored.
export function chooseVictim(observations, aMembers) {
  const votes = new Map(aMembers.map((member) => [member.index, []]));
  const unmapped = [];
  for (const { activeEndpoint, reader } of observations) {
    const member = aMembers.find((m) => normalizeEndpoint(m.url) === normalizeEndpoint(activeEndpoint));
    if (member) votes.get(member.index).push(reader);
    else unmapped.push({ activeEndpoint: activeEndpoint ?? null, reader });
  }
  let victim = null;
  for (const member of aMembers) {
    const count = votes.get(member.index).length;
    if (count > 0 && (!victim || count > votes.get(victim.index).length)) victim = member;
  }
  return {
    unanimous: Boolean(victim) && votes.get(victim.index).length === observations.length,
    unmapped,
    victim,
    votes: Object.fromEntries([...votes].map(([index, readers]) => [index, readers])),
  };
}

// A B read of A content known committed: the content (every known message), the mount's 503, or a
// violation: `missing` (answered, but without the content) or `other` (any other status).
export function classifyRead(response, knownMessages) {
  if (response.status === 503) return 'unavailable';
  if (response.status !== 200) return 'other';
  const items = Array.isArray(response.json?.content) ? response.json.content : [];
  return knownMessages.every((message) => items.some((item) => item.message === message)) ? 'content' : 'missing';
}

// The root-bound member control: lifecycle/member.sh for cluster A, run with the fed-3x2 cluster-a
// pack loaded by the same guard the wrappers use. The jar comes from the launch record (the
// environment's OAK_CONSENSUS_JAR is unset so member.sh cannot refuse or override it).
const MEMBER_CONTROL_SCRIPT = 'set -euo pipefail; source "$1/lib/fed-3x2.sh"; fed_3x2_load_cluster_env "$2" a; '
  + 'unset OAK_CONSENSUS_JAR OAK_CONSENSUS_JAR_SHA256; exec "$1/member.sh" "$3" "$4"';

export function memberControlCommand({ configDir, fedRoot, lifecycleDir }, action, index) {
  if (!['start', 'stop'].includes(action)) throw new Error(`member control action must be start or stop, got ${action}`);
  if (!Number.isInteger(index) || index < 0) throw new Error(`member index must be a non-negative integer, got ${index}`);
  const argv = ['bash', '-c', MEMBER_CONTROL_SCRIPT, 'fed-member-control', lifecycleDir, configDir, action, String(index)];
  const quote = (value) => (/^[\w@%+=:,./-]+$/.test(value) ? value : `'${value.replaceAll("'", "'\\''")}'`);
  return { argv, display: `FED_3X2_ROOT=${quote(fedRoot)} ${argv.map(quote).join(' ')}`, env: { FED_3X2_ROOT: fedRoot } };
}

export function createMemberControl(config, env) {
  return async (action, index) => {
    const { argv, display, env: extra } = memberControlCommand(config, action, index);
    const childEnv = { ...env, ...extra };
    delete childEnv.OAK_CONSENSUS_JAR;
    delete childEnv.OAK_CONSENSUS_JAR_SHA256;
    // Asynchronous, so B reads keep being sampled while member.sh waits for the graceful stop.
    // No timeout of our own: member.sh bounds a stop (STOP_WAIT_SECONDS, then SIGKILL).
    return new Promise((resolve) => {
      const child = spawn(argv[0], argv.slice(1), { env: childEnv, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '';
      child.stdout.on('data', (chunk) => { output += chunk; });
      child.stderr.on('data', (chunk) => { output += chunk; });
      child.on('error', (error) => resolve({ code: null, command: argv, display, output: `${output}\n${error.message}` }));
      child.on('close', (code) => resolve({ code, command: argv, display, output }));
    });
  };
}

export async function runFederationFailover(config, deps = {}) {
  const env = deps.env ?? process.env;
  const fo = { ...FAILOVER_DEFAULTS, ...config.options };
  if (!deps.memberControl) {
    for (const key of ['lifecycleDir', 'configDir']) if (!config[key]) throw new Error(`config.${key} is required for the member control`);
    if (!existsSync(path.join(config.lifecycleDir, 'member.sh'))) throw new Error(`no member.sh in ${config.lifecycleDir}`);
  }
  const memberControl = deps.memberControl ?? createMemberControl(config, env);
  const s = createFederationSession(config, deps, {
    dirName: (stamp) => `failover-${stamp}`, initialPhase: 'F0', scenario: 'federation failover', title: 'Federation 3x2 failover',
  });
  const { A, B, addr, allMembers, assert, call, committed, contentOn, federationViews, leaderOf, log, snapshot, submit, waitFor, wallets } = s;
  const sleep = deps.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const facts = { readOutcomes: null, start: null, stop: null, timings: {}, victim: null };
  const message = (what) => `[fed failover ${s.nonce}] ${what}`;
  const mountOf = (health) => (health?.sharding?.remoteMounts ?? []).find((m) => String(m.enterpriseId ?? '').toLowerCase() === A.enterpriseId);
  // B reads of A content known committed (the baseline) while the victim stops and until every B
  // mount has failed over: each must be the content or a 503 (classifyRead); every outcome is counted.
  const counts = { content: 0, missing: 0, other: 0, unavailable: 0 };
  const reads = [];
  const readB = async (member, known) => {
    const response = await call(`fault-window b${member.index} reads nsA1`, 'GET', `${member.url}/v1/wallets/content?wallet=${addr.nsA1}`, { allow5xx: (status) => status === 503 });
    const outcome = classifyRead(response, known);
    counts[outcome] += 1;
    reads.push({ at: response.at, code: response.json?.code ?? null, member: member.url, outcome, phase: s.phase, seq: response.seq, status: response.status });
  };
  let victim = null;
  let stopped = false;
  let restarted = false;
  let aborted = null;
  const controlDisplay = (action) => (victim ? (deps.memberControl ? `member.sh ${action} ${victim.index}` : memberControlCommand(config, action, victim.index).display) : null);

  try {
    // ── F0 preflight ──────────────────────────────────────────────────────────────────────────
    s.phase = 'F0';
    log('━━ F0 preflight');
    const up = await waitFor('all members answer /health/local', async () => {
      const codes = {};
      for (const member of allMembers) codes[member.url] = (await call(`F0 health/local ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health/local`, { tolerate: true })).status;
      return { codes, done: Object.values(codes).every((code) => code === 200) };
    });
    assert('members-up', { expected: 'all 6 members answer /health/local 200', observed: up.codes, ok: up.ok });
    if (!up.ok) throw new Abort('not every member is up');
    const jarShas = s.clusters.map((cluster) => cluster.launchRecord.OAK_CONSENSUS_JAR_SHA256 || null);
    const jarOk = jarShas.every((sha) => sha && sha === jarShas[0]) && (!s.manifest.jar.sha256 || s.manifest.jar.sha256 === jarShas[0]);
    assert('same-jar', { expected: 'both launch records pin one OAK_CONSENSUS_JAR sha256 (= the env jar, when given)', observed: { env: s.manifest.jar.sha256, records: jarShas }, ok: jarShas.every(Boolean) ? jarOk : null });
    if (!jarOk) throw new Abort('the clusters do not run one recorded jar');

    const views = await federationViews('F0 federation');
    const epochs = new Set(views.map(({ view }) => view.status?.directoryEpoch ?? null));
    const digests = new Set(views.map(({ view }) => view.directoryDigest ?? null));
    const epoch = [...epochs][0];
    const directoryOk = epochs.size === 1 && Number(epoch) >= 1 && digests.size === 1 && !digests.has(null);
    assert('directory-uniform', { expected: 'one directory epoch (>= 1) and digest on all 6 members', observed: views.map(({ member, view }) => `${member.cluster.label}${member.index}:${view.status?.directoryEpoch}/${view.directoryDigest}`), ok: directoryOk });
    if (!directoryOk) throw new Abort('the directory is not committed uniformly');
    const entryA = (views[0].view.directory?.entries ?? []).find((entry) => String(entry.enterpriseId).toLowerCase() === A.enterpriseId);
    const nsOk = Boolean(entryA?.namespaces?.includes(addr.nsA1)) && entryA?.status === 'ACTIVE';
    assert('nsA1-owned-by-A', { expected: `enterprise A ACTIVE and owns ${addr.nsA1}`, observed: entryA ? { namespaces: entryA.namespaces, status: entryA.status } : null, ok: nsOk });
    if (!nsOk) throw new Abort('enterprise A does not own nsA1 in the committed directory');
    const peers = {
      charterDigest: views.find(({ member }) => member.cluster === A).view.charterDigest,
      clusterId: views.find(({ member }) => member.cluster === A).view.clusterId,
      directoryDigest: [...digests][0],
    };

    const leaderBefore = await leaderOf(A);
    const observations = [];
    for (const member of B.members) {
      const response = await call(`F0 health b${member.index}`, 'GET', `${member.url}/health`);
      const mount = mountOf(response.json);
      observations.push({ activeEndpoint: mount?.activeEndpoint ?? null, available: mount?.available === true, reader: member.url, seq: response.seq, verified: mount?.verified === true });
    }
    const mountsOk = observations.every((o) => o.verified && o.available && o.activeEndpoint);
    assert('b-mounts-ready', { expected: 'every B member mounts enterprise A verified and available with an activeEndpoint', observed: observations.map((o) => `${o.reader}->${o.activeEndpoint}(${o.verified}/${o.available})`), ok: mountsOk });
    if (!mountsOk) throw new Abort('B mounts of enterprise A are not ready');
    const choice = chooseVictim(observations, A.members);
    victim = choice.victim;
    assert('victim-chosen', {
      expected: 'the A member most B mounts read from (activeEndpoint)', note: choice.unanimous ? 'all B members agree' : `B members disagree; unmapped: ${JSON.stringify(choice.unmapped)}`,
      observed: victim ? { leader: victim.index === leaderBefore.index, victim: victim.url, votes: choice.votes } : choice, ok: Boolean(victim),
    });
    if (!victim) throw new Abort('no B mount reads from a member of cluster A');
    const before = s.memberProcess(A, victim.index);
    const pidOk = Boolean(before.pid && before.command && before.command.includes(`${A.runtimeRoot}/validator-${victim.index}`));
    assert('victim-pid', { expected: `a pid whose command line names ${A.runtimeRoot}/validator-${victim.index}`, observed: before, ok: pidOk });
    if (!pidOk) throw new Abort(`refusing to fault validator-${victim.index}: its pid file does not name its own store`);
    const othersBefore = s.memberFacts;
    facts.victim = {
      activeEndpointByB: Object.fromEntries(observations.map((o) => [o.reader, o.activeEndpoint])), command: before.command,
      index: victim.index, leaderBefore: leaderBefore.url, pid: before.pid, unanimous: choice.unanimous, url: victim.url, votes: choice.votes,
      wasLeader: victim.index === leaderBefore.index,
    };
    log(`  🎯 victim: cluster A validator-${victim.index} ${victim.url} (pid ${before.pid}, ${facts.victim.wasLeader ? 'leader' : 'follower'})`);
    await snapshot('F0-preflight');

    // ── F1 baseline ──────────────────────────────────────────────────────────────────────────
    s.phase = 'F1';
    log('━━ F1 baseline write');
    const m1 = buildWrite({ key: wallets.nsA1.privateKey, message: message('baseline nsA1 before the fault') });
    const w1 = await submit('F1 nsA1 -> A leader', A, await leaderOf(A), m1, '/v1/propose-write', { follow: false, retryNoQuorum: false });
    assert('baseline-accepted', { evidence: `requests.ndjson#${w1.seq}`, expected: '202', observed: s.observedOf(w1), ok: w1.status === 202 });
    if (w1.status !== 202) throw new Abort('the baseline write was not accepted');
    const c1 = await committed('F1 baseline', A, m1.proposalId);
    assert('baseline-committed', { evidence: `requests.ndjson#${c1.seq}`, expected: 'COMMITTED', observed: c1.verdict?.outcome ?? c1.state, ok: c1.verdict?.outcome === 'COMMITTED' });
    const v1 = await contentOn('F1 baseline on A', A.members, addr.nsA1, m1.message);
    assert('baseline-visible-a', { expected: 'baseline on all 3 A members', observed: v1.seen, ok: v1.ok });
    const r1 = await contentOn('F1 baseline on B', B.members, addr.nsA1, m1.message);
    assert('baseline-read-by-b', { expected: 'baseline read through the mount on all 3 B members', observed: r1.seen, ok: r1.ok });
    if (!(c1.verdict?.outcome === 'COMMITTED' && v1.ok && r1.ok)) throw new Abort('the baseline is not committed and readable everywhere');
    await snapshot('F1-baseline');

    // ── F2 fault ─────────────────────────────────────────────────────────────────────────────
    s.phase = 'F2';
    log(`━━ F2 fault: stop cluster A validator-${victim.index}`);
    const still = s.memberProcess(A, victim.index);
    if (still.pid !== before.pid) throw new Abort(`validator-${victim.index} pid changed before the fault (${before.pid} -> ${still.pid})`);
    const stopStartedAt = new Date();
    const stopping = memberControl('stop', victim.index);
    stopped = true;
    let stopDone = false;
    stopping.finally(() => { stopDone = true; });
    // Sample B reads while member.sh performs the graceful stop.
    while (!stopDone) {
      for (const member of B.members) await readB(member, [m1.message]);
      if (!stopDone) await Promise.race([stopping, sleep(s.opts.pollMs)]);
    }
    const stop = await stopping;
    facts.stop = { ...stop, endedAt: new Date().toISOString(), startedAt: stopStartedAt.toISOString() };
    s.write('member-stop.log', stop.output ?? '');
    const faultAt = stopStartedAt.getTime();
    assert('victim-stopped', { evidence: 'member-stop.log; failover.json', expected: `member.sh stop ${victim.index} exits 0`, observed: { code: stop.code, command: stop.display ?? stop.command }, ok: stop.code === 0 && /stopped|not running/.test(stop.output ?? '') });
    assert('graceful-stop', { evidence: 'member-stop.log', expected: 'SIGTERM sufficed (no SIGKILL escalation)', kind: 'diagnostic', observed: /SIGKILL/.test(stop.output ?? '') ? 'escalated to SIGKILL' : 'graceful', ok: !/SIGKILL/.test(stop.output ?? '') });
    if (stop.code !== 0) throw new Abort(`member.sh stop ${victim.index} failed (exit ${stop.code})`);
    const down = await waitFor('victim down', async () => {
      const response = await call(`F2 victim health/local a${victim.index}`, 'GET', `${victim.url}/health/local`, { tolerate: true });
      const proc = s.memberProcess(A, victim.index);
      return { done: response.status === 0 && !proc.command, proc, status: response.status };
    }, { deadlineMs: fo.stopDeadlineMs });
    assert('victim-down', { expected: 'the victim no longer answers and has no running pid', observed: { http: down.status, process: down.proc }, ok: down.ok });
    const others = othersBefore.filter((fact) => !(fact.cluster === 'a' && fact.index === victim.index));
    const othersNow = others.map((fact) => ({ member: `${fact.cluster}${fact.index}`, after: s.memberProcess(s.clusters.find((c) => c.label === fact.cluster), fact.index).pid, before: fact.pid }));
    assert('others-untouched', { expected: 'the other 5 members keep their pids', observed: othersNow, ok: othersNow.every((o) => o.before && o.before === o.after) });
    if (!down.ok) throw new Abort('the victim did not go down');

    // ── F3 during the fault ──────────────────────────────────────────────────────────────────
    s.phase = 'F3';
    log('━━ F3 during the fault');
    const survivors = A.members.filter((m) => m.index !== victim.index);
    const remaining = () => Math.max(0, faultAt + fo.failoverDeadlineMs - Date.now());
    const failedOverAt = {};
    const lastMounts = {};
    // (b) + (c): sample B reads of the baseline and B mounts until every mount has failed over.
    const watchB = async () => {
      for (;;) {
        for (const member of B.members) await readB(member, [m1.message]);
        for (const member of B.members) {
          if (failedOverAt[member.url]) continue;
          const response = await call(`F3 b${member.index} health`, 'GET', `${member.url}/health`);
          const mount = mountOf(response.json);
          const active = normalizeEndpoint(mount?.activeEndpoint);
          const activeState = (mount?.endpoints ?? []).find((e) => normalizeEndpoint(e.url) === active);
          lastMounts[member.url] = { activeEndpoint: mount?.activeEndpoint ?? null, available: mount?.available, seq: response.seq, verified: mount?.verified, activeVerified: activeState?.verified };
          if (mount?.verified === true && mount?.available === true && active && active !== normalizeEndpoint(victim.url) && activeState?.verified !== false) {
            failedOverAt[member.url] = { activeEndpoint: mount.activeEndpoint, ms: Date.now() - faultAt };
          }
        }
        if (B.members.every((m) => failedOverAt[m.url]) || remaining() === 0) return;
        await sleep(s.opts.pollMs);
      }
    };
    // (a): a leader among the survivors and a second write committed on both.
    const m2 = buildWrite({ key: wallets.nsA1.privateKey, message: message('second nsA1 write during the fault') });
    const writeA = async () => {
      const leader = await leaderOf(A, { deadlineMs: remaining(), members: survivors });
      facts.timings.leaderMs = Date.now() - faultAt;
      assert('a-leader-within-deadline', { expected: `one leader among the 2 survivors within ${fo.failoverDeadlineMs} ms of the fault`, observed: { changed: leader.url !== facts.victim.leaderBefore, leader: leader.url, ms: facts.timings.leaderMs }, ok: facts.timings.leaderMs <= fo.failoverDeadlineMs });
      const w2 = await submit('F3 nsA1 -> surviving leader', A, leader, m2, '/v1/propose-write', { follow: false, retryNoQuorum: false });
      assert('fault-write-accepted', { evidence: `requests.ndjson#${w2.seq}`, expected: '202', observed: s.observedOf(w2), ok: w2.status === 202 });
      if (w2.status !== 202) return false;
      const c2 = await committed('F3 fault write', A, m2.proposalId, { deadlineMs: remaining(), members: survivors });
      assert('fault-write-committed', { evidence: `requests.ndjson#${c2.seq}`, expected: 'COMMITTED', observed: c2.verdict?.outcome ?? c2.state, ok: c2.verdict?.outcome === 'COMMITTED' });
      const v2 = await contentOn('F3 fault write on survivors', survivors, addr.nsA1, [m1.message, m2.message], { deadlineMs: remaining() });
      facts.timings.faultWriteVisibleMs = Date.now() - faultAt;
      assert('fault-write-on-survivors', { expected: 'both writes on the 2 surviving A members', observed: v2.seen, ok: v2.ok });
      return c2.verdict?.outcome === 'COMMITTED' && v2.ok;
    };
    const [watched, written] = await Promise.allSettled([watchB(), writeA()]);
    for (const outcome of [watched, written]) if (outcome.status === 'rejected') throw outcome.reason;
    const allFailedOver = B.members.every((m) => failedOverAt[m.url] && failedOverAt[m.url].ms <= fo.failoverDeadlineMs);
    facts.timings.mountFailoverMs = failedOverAt;
    assert('b-mount-failover', { expected: `every B mount for A verified and available on an endpoint other than ${victim.url} within ${fo.failoverDeadlineMs} ms`, observed: allFailedOver ? failedOverAt : lastMounts, ok: allFailedOver });
    facts.readOutcomes = { counts, reads };
    const codes = [...new Set(reads.filter((r) => r.outcome === 'unavailable').map((r) => r.code))];
    assert('b-reads-never-missing', {
      evidence: 'failover.json readOutcomes', expected: 'each B read of the committed baseline, from the stop until every mount failed over, is the content or a 503; never missing',
      note: `503 codes: ${codes.join(',') || 'none'}`, observed: counts, ok: counts.missing === 0 && counts.other === 0,
    });
    assert('b-reads-sampled', { expected: 'B reads were sampled during the fault', kind: 'diagnostic', observed: reads.length, ok: reads.length > 0 });
    if (!allFailedOver || written.value !== true) throw new Abort('the fault was not absorbed within the deadline');
    const both = await contentOn('F3 both writes on B', B.members, addr.nsA1, [m1.message, m2.message], { deadlineMs: fo.failoverDeadlineMs });
    assert('b-reads-both-writes', { expected: 'both writes read through the failed-over mount on all 3 B members', observed: both.seen, ok: both.ok });
    await snapshot('F3-during-fault', false, { tolerateMember: (member) => member.cluster === A && member.index === victim.index });

    // ── F4 recovery ──────────────────────────────────────────────────────────────────────────
    s.phase = 'F4';
    log(`━━ F4 recovery: start cluster A validator-${victim.index}`);
    const startStartedAt = new Date();
    const start = await memberControl('start', victim.index);
    restarted = start.code === 0;
    facts.start = { ...start, endedAt: new Date().toISOString(), startedAt: startStartedAt.toISOString() };
    s.write('member-start.log', start.output ?? '');
    assert('victim-restarted', { evidence: 'member-start.log; failover.json', expected: `member.sh start ${victim.index} exits 0`, observed: { code: start.code, command: start.display ?? start.command }, ok: start.code === 0 });
    if (start.code !== 0) throw new Abort(`member.sh start ${victim.index} failed (exit ${start.code})`);
    const recoveryEnd = startStartedAt.getTime() + fo.recoveryDeadlineMs;
    const left = () => Math.max(0, recoveryEnd - Date.now());
    const back = await waitFor('victim UP', async () => {
      const response = await call(`F4 victim health/local a${victim.index}`, 'GET', `${victim.url}/health/local`, { tolerate: true });
      return { done: response.status === 200, status: response.status };
    }, { deadlineMs: left() });
    facts.timings.recoveryUpMs = Date.now() - startStartedAt.getTime();
    assert('victim-up', { expected: `/health/local 200 within ${fo.recoveryDeadlineMs} ms of the start`, observed: { http: back.status, ms: facts.timings.recoveryUpMs }, ok: back.ok });
    if (!back.ok) throw new Abort('the victim did not come back');
    // A member still catching up may answer 5xx: recorded and counted here, failed only at the deadline.
    const recovery5xx = [];
    const identity = await waitFor('victim identity', async () => {
      const response = await call(`F4 victim federation a${victim.index}`, 'GET', `${victim.url}/v1/federation`, { tolerate: true });
      if (response.status >= 500 || response.status === 0) recovery5xx.push({ seq: response.seq, status: response.status });
      const v = response.json ?? {};
      const observed = { charterDigest: v.charterDigest, clusterId: v.clusterId, directoryDigest: v.directoryDigest };
      return { done: Object.keys(peers).every((key) => observed[key] === peers[key]), observed, seq: response.seq };
    }, { deadlineMs: left() });
    assert('victim-identity', { evidence: `requests.ndjson#${identity.seq}`, expected: peers, observed: identity.observed, ok: identity.ok });
    const served = await contentOn('F4 victim serves both writes', [victim], addr.nsA1, [m1.message, m2.message], { deadlineMs: left(), tolerateDown: true });
    assert('victim-serves-both-writes', { expected: 'both writes on the restarted member', observed: served.seen, ok: served.ok });
    assert('victim-recovery-5xx', { expected: 'no 5xx or silence from the restarted member while it catches up', kind: 'diagnostic', observed: recovery5xx, ok: recovery5xx.length === 0 });
    const after = s.memberProcess(A, victim.index);
    const jar = A.launchRecord.OAK_CONSENSUS_JAR || null;
    facts.victim.after = after;
    assert('victim-new-process', { expected: 'a new pid whose command line names the same store', observed: { after: after.pid, before: before.pid }, ok: Boolean(after.pid && after.pid !== before.pid && after.command?.includes(`${A.runtimeRoot}/validator-${victim.index}`)) });
    assert('victim-same-jar', { expected: `command line runs the recorded jar ${jar}`, observed: after.command, ok: jar ? Boolean(after.command?.includes(jar)) : null });
    const healed = await waitFor('B mounts after recovery', async () => {
      const rows = [];
      for (const member of B.members) {
        const response = await call(`F4 b${member.index} health`, 'GET', `${member.url}/health`);
        const mount = mountOf(response.json);
        rows.push({ activeEndpoint: mount?.activeEndpoint ?? null, available: mount?.available === true, member: member.url, verified: mount?.verified === true });
      }
      return { done: rows.every((r) => r.available && r.verified), rows };
    }, { deadlineMs: left() });
    assert('b-mounts-after-recovery', { expected: 'every B mount for A verified and available', kind: 'diagnostic', observed: healed.rows, ok: healed.ok });
    await snapshot('F4-recovery');

    // ── F5 end state ─────────────────────────────────────────────────────────────────────────
    s.phase = 'F5';
    log('━━ F5 end state');
    const health = [];
    for (const member of allMembers) health.push(`${member.cluster.label}${member.index}:${(await call(`F5 health/local ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health/local`)).status}`);
    assert('members-up', { expected: 'all 6 members answer /health/local 200', observed: health, ok: health.every((h) => h.endsWith(':200')) });
    const othersEnd = others.map((fact) => ({ after: s.memberProcess(s.clusters.find((c) => c.label === fact.cluster), fact.index).pid, before: fact.pid, member: `${fact.cluster}${fact.index}` }));
    assert('no-other-restarts', { expected: 'every member but the victim keeps its F0 pid', observed: othersEnd, ok: othersEnd.every((o) => o.before && o.before === o.after) });
    await snapshot('F5-end');
  } catch (error) {
    if (!(error instanceof Abort)) throw error;
    const restartHint = stopped && !restarted ? `cluster A validator-${victim.index} is (or may be) STOPPED; restart it with: ${controlDisplay('start')}` : 'clusters left running for inspection';
    aborted = await s.recordAbort(error, restartHint);
    if (stopped && !restarted) log(`⚠️  ${restartHint}`);
  }

  // Every 5xx but the 503s of the fault-window B reads (counted in readOutcomes) is unexpected.
  s.stats.unexpected5xx.push(...s.stats.allowed5xx.filter((row) => !row.label.startsWith('fault-window ')));
  s.write('failover.json', { ...facts, restartCommand: controlDisplay('start'), stopCommand: controlDisplay('stop'), victimLeftStopped: stopped && !restarted });
  return s.finish({
    aborted,
    extraReport: [
      `- Victim: ${victim ? `cluster A validator-${victim.index} ${victim.url}${facts.victim?.wasLeader ? ' (leader)' : ''}` : 'none'}`,
      `- B reads during the fault: ${JSON.stringify(facts.readOutcomes?.counts ?? null)}`,
      ...(stopped && !restarted ? [`- ⚠️ The victim is still STOPPED. Restart: \`${controlDisplay('start')}\``] : []),
    ],
    extraSummary: { readOutcomes: facts.readOutcomes?.counts ?? null, timings: facts.timings, victim: facts.victim, victimLeftStopped: stopped && !restarted },
    finalPhase: 'F5',
    logScanKind: 'diagnostic',
    seal: deps.seal ?? true,
    tolerated5xx: 'no 5xx except 503 answers to the fault-window B reads of A content (F2 stop until F3 mount failover)',
  });
}

// CLI: tests/routing/federation-3x2-failover.sh passes the topology as FED_SMOKE_CONFIG (JSON).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let config;
  try {
    config = configFromEnv(process.env, { script: 'tests/routing/federation-3x2-failover.sh' });
    const seconds = (name) => Number(process.env[name] || 0) * 1000;
    if (seconds('FED_FAILOVER_SECONDS') > 0) config.options.failoverDeadlineMs = seconds('FED_FAILOVER_SECONDS');
    if (seconds('FED_RECOVERY_SECONDS') > 0) config.options.recoveryDeadlineMs = seconds('FED_RECOVERY_SECONDS');
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
  runFederationFailover(config).then(
    (summary) => process.exit(summary.status === STATUS.PASS ? 0 : 1),
    (error) => {
      process.stderr.write(`❌ ${error.message}\n`);
      process.exit(2);
    },
  );
}
