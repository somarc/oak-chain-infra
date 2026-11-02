// Fault controller (charter §9 item 7): one approved, scoped fault at a time, through
// lifecycle/member.sh. member.sh checks PID identity (the pid's command line must name this
// root's validator-N store), refuses to start over a port held by another root, enforces the
// launch-record membership and refuses the protected live root. This module never signals a
// process itself and never sets OAK_ALLOW_LIVE_ROOT.
//
// Recovery is judged from the cluster, not from member.sh's exit code: a member is "down" when
// its pid is gone and its HTTP port refuses, "up" when /health answers 200, and the cluster is
// "settled" when every live member answers, exactly one is LEADER and all agree on it.

import { execFile } from 'node:child_process';
import path from 'node:path';

import { normalizeNodeUrl } from './http.mjs';
import { processState } from './target.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function tail(text, max = 1_500) {
  const value = String(text ?? '');
  return value.length > max ? `…${value.slice(-max)}` : value;
}

export const FAULT_ACTIONS = Object.freeze({
  kill: { env: { KILL_WAIT_SECONDS: '15' }, signal: 'SIGKILL' },
  start: { env: {}, signal: null },
  stop: { env: { STOP_ESCALATE: 'false', STOP_WAIT_SECONDS: '45' }, signal: 'SIGTERM' },
});

export function createFaultController(target, { execFileImpl = execFile, run, timeoutMs = 120_000 } = {}) {
  if (target.isLegacyRoot) throw new Error(`Refusing a fault controller on the long-lived legacy root ${target.runtimeRoot}`);
  const memberScript = path.join(target.lifecycleDir, 'member.sh');

  function exec(action, id) {
    const { env: actionEnv } = FAULT_ACTIONS[action];
    const env = {
      ...process.env,
      ...actionEnv,
      CLUSTER_RUNTIME_ROOT: target.runtimeRoot,
      LOG_DIR: target.logDir,
      PID_DIR: target.pidDir,
    };
    delete env.OAK_ALLOW_LIVE_ROOT;
    return new Promise((resolve) => {
      execFileImpl(memberScript, [action, String(id)], { env, timeout: timeoutMs }, (error, stdout, stderr) => {
        resolve({ exitCode: error ? (typeof error.code === 'number' ? error.code : 1) : 0, stderr: String(stderr ?? ''), stdout: String(stdout ?? '') });
      });
    });
  }

  async function member(action, id) {
    if (!FAULT_ACTIONS[action]) throw new Error(`Unknown fault action ${action}`);
    const node = target.nodes[id];
    if (!node) throw new Error(`No member ${id} in a ${target.size}-member cluster`);
    const before = await processState(node);
    await run?.event(`fault.${action}.begin`, { member: id, pidBefore: before.pid, signal: FAULT_ACTIONS[action].signal });
    const started = Date.now();
    const result = await exec(action, id);
    const after = await processState(node);
    const record = {
      elapsedMs: Date.now() - started,
      exitCode: result.exitCode,
      member: id,
      pidAfter: after.pid,
      pidBefore: before.pid,
      stderr: tail(result.stderr),
      stdout: tail(result.stdout),
    };
    await run?.event(`fault.${action}.end`, record);
    return record;
  }

  return { member, memberScript };
}

async function healthOf(http, node) {
  const response = await http.request(`${node.url}/health`, { timeout: 2_000 });
  return { role: String(response.json?.currentRole ?? '').toUpperCase() || null, status: response.status };
}

export async function waitMemberDown(http, node, { deadlineMs = 60_000, intervalMs = 1_000 } = {}) {
  const started = Date.now();
  let last = null;
  while (Date.now() - started <= deadlineMs) {
    const [proc, health] = await Promise.all([processState(node), healthOf(http, node)]);
    last = { listener: proc.listenerPids, pid: proc.pid, status: health.status };
    if (health.status === 0 && proc.listenerPids.length === 0) return { down: true, elapsedMs: Date.now() - started, last };
    await sleep(intervalMs);
  }
  return { down: false, elapsedMs: Date.now() - started, last };
}

// Settled: every listed member answers /health 200, exactly one LEADER among them, and each
// names that leader on /v1/consensus/status. Returns the leader node when settled.
export async function waitSettled(http, target, { deadlineMs = 120_000, intervalMs = 2_000, members = target.nodes.map((node) => node.id) } = {}) {
  const started = Date.now();
  let last = null;
  while (Date.now() - started <= deadlineMs) {
    const nodes = members.map((id) => target.nodes[id]);
    const views = await Promise.all(nodes.map(async (node) => {
      const [health, consensus] = await Promise.all([
        healthOf(http, node),
        http.request(`${node.url}/v1/consensus/status`, { timeout: 2_000 }),
      ]);
      return { id: node.id, leaderUrl: normalizeNodeUrl(consensus.json?.currentLeader), role: health.role, status: health.status, url: node.url };
    }));
    const leaders = views.filter((view) => view.role === 'LEADER');
    const allUp = views.every((view) => view.status === 200);
    const agreed = leaders.length === 1 && views.every((view) => view.leaderUrl === leaders[0].url);
    last = views.map((view) => `${view.id}:${view.status}/${view.role ?? '-'}`).join(' ');
    if (allUp && agreed) {
      return { elapsedMs: Date.now() - started, last, leader: target.nodes[leaders[0].id], settled: true };
    }
    await sleep(intervalMs);
  }
  return { elapsedMs: Date.now() - started, last, leader: null, settled: false };
}
