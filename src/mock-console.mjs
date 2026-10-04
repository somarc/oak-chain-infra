// Interactive control console for the local mock validator cluster.
//
// The console is a view plus a dispatcher. It never signals processes or edits runtime
// state itself: every mutation runs one of the lifecycle scripts (start-cluster.sh,
// stop-cluster.sh, member.sh), which remain usable on their own for recovery.
// Mock-local only: it probes 127.0.0.1 ports derived from the same env/launch record the
// scripts use, and shows the runtime root it controls on every frame.

import { execFile, spawn } from 'node:child_process';
import { open, readdir, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

const DEFAULT_INTERVAL_MS = 2_000;
const PROBE_TIMEOUT_MS = 1_500;
const MAX_OUTPUT_LINES = 500;
const MAX_MEMBERS = 5;
const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
// CSI/OSC escapes, plus the bare carriage returns progress output uses.
const ANSI_PATTERN = /\u001b\[[0-9;?]*[ -/]*[@-~]|\u001b\][^\u0007]*\u0007|\u001b[()][A-Za-z0-9]/g;
const STYLES = Object.freeze({
  accent: '\u001b[36m',
  amber: '\u001b[38;5;214m',
  bold: '\u001b[1m',
  dim: '\u001b[2m',
  green: '\u001b[32m',
  red: '\u001b[31m',
  reset: '\u001b[0m',
  yellow: '\u001b[33m',
});
const KEY = Object.freeze({
  ctrlC: '\u0003',
  down: '\u001b[B',
  escape: '\u001b',
  up: '\u001b[A',
});

function option(options, name, fallback = undefined) {
  return Object.prototype.hasOwnProperty.call(options, name) ? options[name] : fallback;
}

function flag(options, name) {
  const value = option(options, name, false);
  if (typeof value === 'string') return value.toLowerCase() !== 'false';
  return Boolean(value);
}

function paint(enabled, names, text) {
  if (!enabled) return String(text);
  return `${names.split(' ').map((name) => STYLES[name]).join('')}${text}${STYLES.reset}`;
}

export function stripAnsi(text) {
  return String(text).replace(ANSI_PATTERN, '');
}

function tildePath(value, home) {
  const text = String(value);
  return home && (text === home || text.startsWith(`${home}/`)) ? `~${text.slice(home.length)}` : text;
}

export function formatDuration(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const days = Math.floor(total / 86_400);
  const hours = Math.floor((total % 86_400) / 3_600);
  const minutes = Math.floor((total % 3_600) / 60);
  const seconds = total % 60;
  if (days > 0) return `${days}d${String(hours).padStart(2, '0')}h`;
  if (hours > 0) return `${hours}h${String(minutes).padStart(2, '0')}m`;
  if (minutes > 0) return `${minutes}m${String(seconds).padStart(2, '0')}s`;
  return `${seconds}s`;
}

// ps etime: [[dd-]hh:]mm:ss
export function parseEtime(value) {
  const match = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(String(value).trim());
  if (!match) return null;
  const [, days = '0', hours = '0', minutes, seconds] = match;
  return (((Number(days) * 24 + Number(hours)) * 60 + Number(minutes)) * 60 + Number(seconds)) * 1000;
}

export function parseLaunchRecord(text) {
  const record = {};
  for (const line of String(text ?? '').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq > 0) record[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
  return record;
}

async function readText(file) {
  try {
    return await readFile(file, 'utf8');
  } catch (_error) {
    return null;
  }
}

async function pidFileIds(pidDir) {
  try {
    return (await readdir(pidDir))
      .map((name) => /^validator-(\d+)\.pid$/.exec(name))
      .filter(Boolean)
      .map((match) => Number(match[1]));
  } catch (_error) {
    return [];
  }
}

function toPort(value, name) {
  const port = Number(value);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    throw new Error(`Invalid ${name}: ${value}`);
  }
  return port;
}

const MEMBERSHIP_KEYS = [
  ['OAK_CLUSTER_SIZE', 'size'],
  ['OAK_VALIDATOR_HTTP_BASE_PORT', 'httpBase'],
  ['OAK_VALIDATOR_HTTP_PORT_STEP', 'step'],
  ['AERON_CLUSTER_BASE_PORT', 'aeronBase'],
];

// Same precedence the lifecycle scripts use: explicit option, then environment, then the
// launch record of the running cluster, then script defaults.
export async function resolveConsoleConfig({ options = {}, env = process.env, repoRoot }) {
  const home = env.HOME || os.homedir();
  const explicitRoot = option(options, 'runtime-root');
  const runtimeRoot = String(explicitRoot || env.CLUSTER_RUNTIME_ROOT || path.join(home, 'oak-chain'));
  const pidDir = explicitRoot ? path.join(runtimeRoot, 'pids') : (env.PID_DIR || path.join(runtimeRoot, 'pids'));
  const logDir = explicitRoot ? path.join(runtimeRoot, 'logs') : (env.LOG_DIR || path.join(runtimeRoot, 'logs'));
  const launchRecordPath = path.join(pidDir, 'cluster-launch.env');
  const launch = parseLaunchRecord(await readText(launchRecordPath));
  const pick = (key, fallback) => env[key] || launch[key] || fallback;

  let size;
  let sizeSource;
  const sizeOption = option(options, 'cluster-size');
  if (sizeOption !== undefined && sizeOption !== true) {
    size = Number(sizeOption);
    sizeSource = 'option';
  } else if (env.OAK_CLUSTER_SIZE) {
    size = Number(env.OAK_CLUSTER_SIZE);
    sizeSource = 'env';
  } else if (launch.OAK_CLUSTER_SIZE) {
    size = Number(launch.OAK_CLUSTER_SIZE);
    sizeSource = 'launch record';
  } else if ((await pidFileIds(pidDir)).some((id) => id >= 3)) {
    size = 5;
    sizeSource = 'pid files';
  } else {
    size = 3;
    sizeSource = 'default';
  }
  if (size !== 3 && size !== 5) {
    throw new Error(`Unsupported cluster size ${size} (mock clusters are 3 or 5 members)`);
  }

  const config = {
    aeronBase: toPort(pick('AERON_CLUSTER_BASE_PORT', 9000), 'AERON_CLUSTER_BASE_PORT'),
    clusterName: pick('OAK_CLUSTER_NAME', 'single-cluster'),
    home,
    httpBase: toPort(pick('OAK_VALIDATOR_HTTP_BASE_PORT', 8090), 'OAK_VALIDATOR_HTTP_BASE_PORT'),
    intervalMs: Number(option(options, 'interval-ms', DEFAULT_INTERVAL_MS)) || DEFAULT_INTERVAL_MS,
    ipfsApi: String(pick('IPFS_API_HTTP', 'http://127.0.0.1:5001')).replace(/\/+$/, ''),
    launch,
    launchRecordPath,
    lifecycleDir: String(
      option(options, 'lifecycle-dir')
        || env.OAK_LIFECYCLE_DIR
        || path.join(repoRoot, 'modes/mock/validators/lifecycle'),
    ),
    logDir,
    opsPort: toPort(pick('OPS_PROXY_PORT', 8787), 'OPS_PROXY_PORT'),
    pidDir,
    runtimeRoot,
    size,
    sizeSource,
    step: Number(pick('OAK_VALIDATOR_HTTP_PORT_STEP', 2)) || 2,
    walletFile: env.CLUSTER_WALLET_FILE || path.join(runtimeRoot, 'cluster-keystore.properties'),
    warnings: [],
  };

  for (const [key, field] of MEMBERSHIP_KEYS) {
    const recorded = launch[key];
    const effective = String(config[field]);
    if (recorded && recorded !== effective) {
      config.warnings.push(
        `${key}=${effective} differs from the running cluster's launch record (${recorded}); member restarts will be refused`,
      );
    }
  }

  config.childEnv = {
    ...env,
    CLUSTER_RUNTIME_ROOT: runtimeRoot,
    LOG_DIR: logDir,
    NO_COLOR: '1',
    OAK_TUI: '0',
    PID_DIR: pidDir,
  };
  if (sizeSource === 'option') config.childEnv.OAK_CLUSTER_SIZE = String(size);
  return config;
}

async function readPid(file) {
  const text = await readText(file);
  const pid = Number(String(text ?? '').trim());
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

async function probeHttp(fetchImpl, url, { method = 'GET', timeoutMs = PROBE_TIMEOUT_MS } = {}) {
  try {
    const response = await fetchImpl(url, {
      headers: { Accept: 'application/json' },
      method,
      signal: AbortSignal.timeout(timeoutMs),
    });
    let json = null;
    try {
      json = await response.json();
    } catch (_error) {
      json = null;
    }
    return { code: response.status, json };
  } catch (_error) {
    return { code: 0, json: null };
  }
}

function defaultPs(pids) {
  return new Promise((resolve) => {
    if (pids.length === 0) {
      resolve(new Map());
      return;
    }
    execFile('ps', ['-o', 'pid=,etime=', '-p', pids.join(',')], { timeout: 2_000 }, (_error, stdout) => {
      const ages = new Map();
      String(stdout ?? '').split('\n').forEach((line) => {
        const [pid, etime] = line.trim().split(/\s+/);
        const ms = parseEtime(etime ?? '');
        if (pid && ms !== null) ages.set(Number(pid), ms);
      });
      resolve(ages);
    });
  });
}

export function memberState({ alive, httpCode, pid }) {
  if (httpCode === 200) return alive ? 'up' : 'untracked';
  if (httpCode > 0) return alive ? 'unhealthy' : 'untracked';
  if (alive) return 'starting';
  return pid ? 'crashed' : 'stopped';
}

export function quorumSummary(config, members) {
  const voting = members.filter((member) => member.id < config.size);
  const running = voting.filter((member) => ['up', 'unhealthy', 'untracked'].includes(member.state)).length;
  const need = Math.floor(config.size / 2) + 1;
  const leader = voting.find((member) => String(member.role).toUpperCase() === 'LEADER');
  const healthy = voting.some((member) => member.clusterHealthy === true);
  return { healthy, leader: leader ? leader.id : null, need, running, size: config.size };
}

export async function probeCluster(config, deps = {}) {
  const fetchImpl = deps.fetchImpl ?? globalThis.fetch;
  const psImpl = deps.psImpl ?? defaultPs;
  const timeoutMs = deps.timeoutMs ?? PROBE_TIMEOUT_MS;
  const extraIds = (await pidFileIds(config.pidDir)).filter((id) => id >= config.size && id < MAX_MEMBERS);
  const ids = [...Array(config.size).keys(), ...new Set(extraIds)].sort((a, b) => a - b);
  const pidFile = (name) => path.join(config.pidDir, name);

  const [members, ops, ipfs, sidecarPids, walletText] = await Promise.all([
    Promise.all(ids.map(async (id) => {
      const port = config.httpBase + id * config.step;
      const pid = await readPid(pidFile(`validator-${id}.pid`));
      const alive = pidAlive(pid);
      const health = await probeHttp(fetchImpl, `http://127.0.0.1:${port}/health`, { timeoutMs });
      const json = health.json && typeof health.json === 'object' ? health.json : {};
      return {
        alive,
        clusterHealthy: typeof json.clusterHealthy === 'boolean' ? json.clusterHealthy : null,
        httpCode: health.code,
        id,
        pid,
        port,
        reachable: json.reachableCount ?? null,
        role: json.currentRole ?? null,
        state: memberState({ alive, httpCode: health.code, pid }),
        total: json.totalMembers ?? null,
      };
    })),
    (async () => {
      const pid = await readPid(pidFile('ops-proxy.pid'));
      const probe = await probeHttp(fetchImpl, `http://127.0.0.1:${config.opsPort}/ops/v1/overview`, { timeoutMs });
      return { alive: pidAlive(pid), code: probe.code, pid };
    })(),
    probeHttp(fetchImpl, `${config.ipfsApi}/api/v0/version`, { method: 'POST', timeoutMs }),
    Promise.all(['caffeinate.pid', 'validator-watchdog.pid', 'load-bottleneck-observer.pid']
      .map(async (name) => readPid(pidFile(name)))),
    readText(config.walletFile),
  ]);

  const ages = await psImpl(members.filter((member) => member.alive).map((member) => member.pid));
  members.forEach((member) => {
    member.uptimeMs = member.alive ? (ages.get(member.pid) ?? null) : null;
  });

  const [sleepPid, watchdogPid, observerPid] = sidecarPids;
  const sidecar = (pid) => (pid === null ? null : pidAlive(pid));
  const walletMatch = /^walletAddress=(.+)$/m.exec(walletText ?? '');
  return {
    at: Date.now(),
    ipfs: { code: ipfs.code },
    members,
    ops,
    quorum: quorumSummary(config, members),
    sidecars: { observer: sidecar(observerPid), sleep: sidecar(sleepPid), watchdog: sidecar(watchdogPid) },
    wallet: walletMatch ? walletMatch[1].trim() : null,
  };
}

// ---------------------------------------------------------------------------------------
// Key handling: pure state transitions. Actions are dispatched by the runner.

export function initialUiState() {
  return { build: false, confirm: null, fresh: false, message: null, selected: 0, view: 'ops' };
}

function memberIds(snapshot, config) {
  return snapshot?.members?.map((member) => member.id) ?? [...Array(config.size).keys()];
}

function quorumWarning(snapshot, config, memberId) {
  const member = snapshot?.members?.find((entry) => entry.id === memberId);
  const quorum = snapshot?.quorum;
  if (!member || !quorum || memberId >= config.size) return '';
  if (!['up', 'unhealthy', 'starting'].includes(member.state)) return '';
  const after = quorum.running - (member.state === 'starting' ? 0 : 1);
  if (after >= quorum.need) return '';
  return ` Leaves ${after}/${quorum.size} running; quorum needs ${quorum.need}.`;
}

function clusterFullyUp(snapshot, config) {
  const members = snapshot?.members?.filter((member) => member.id < config.size) ?? [];
  return members.length === config.size
    && members.every((member) => member.state === 'up')
    && snapshot.ops?.code === 200;
}

function runAction(label, script, args) {
  return { args, label, script, type: 'run' };
}

// A dispatched operation takes over the pane so its output is what you watch, and the
// fresh/build toggles apply to one start only (a lingering fresh would wipe again).
function withDispatch(result) {
  if (result.action?.type !== 'run') return result;
  const state = { ...result.state, view: 'ops' };
  if (result.action.script === 'start-cluster.sh') {
    state.fresh = false;
    state.build = false;
  }
  return { ...result, state };
}

export function handleKey(state, key, ctx) {
  return withDispatch(reduceKey(state, key, ctx));
}

function reduceKey(state, key, ctx) {
  const { busy = false, config, snapshot } = ctx;
  const next = { ...state, message: null };

  if (state.confirm) {
    if (key === 'y' || key === 'Y') {
      return { action: state.confirm.action, state: { ...next, confirm: null } };
    }
    return { action: null, state: { ...next, confirm: null, message: { text: 'cancelled', tone: 'dim' } } };
  }

  const ids = memberIds(snapshot, config);
  const selected = ids.includes(state.selected) ? state.selected : ids[0] ?? 0;
  const confirm = (prompt, action, danger = false) => ({
    action: null,
    state: { ...next, confirm: { action, danger, prompt } },
  });
  const blocked = () => ({
    action: null,
    state: { ...next, message: { text: 'an operation is running; wait for it to finish', tone: 'yellow' } },
  });
  const root = tildePath(config.runtimeRoot, config.home);

  switch (key) {
    case 'q':
    case KEY.ctrlC:
      if (busy) {
        return confirm('An operation is still running. Interrupt it and quit?', { interrupt: true, type: 'quit' }, true);
      }
      return { action: { interrupt: false, type: 'quit' }, state: next };
    case KEY.up:
    case KEY.down: {
      const index = Math.max(0, ids.indexOf(selected));
      const delta = key === KEY.up ? -1 : 1;
      const target = ids[(index + delta + ids.length) % ids.length];
      return { action: null, state: { ...next, selected: target ?? selected } };
    }
    case 'f':
      return { action: null, state: { ...next, fresh: !state.fresh } };
    case 'b':
      return { action: null, state: { ...next, build: !state.build } };
    case 'l':
      return { action: null, state: { ...next, view: state.view === 'ops' ? 'member' : 'ops' } };
    case 's': {
      if (busy) return blocked();
      if (!state.fresh && clusterFullyUp(snapshot, config)) {
        return {
          action: null,
          state: { ...next, message: { text: 'cluster already running; nothing to start', tone: 'yellow' } },
        };
      }
      const args = ['--cluster-size', String(config.size)];
      if (state.fresh) args.push('--fresh');
      if (state.build) args.push('--build');
      const action = runAction(`start cluster${state.fresh ? ' (fresh)' : ''}${state.build ? ' + build' : ''}`, 'start-cluster.sh', args);
      if (state.fresh) {
        return confirm(`Fresh start wipes validator runtime state under ${root} (keystores kept). Continue?`, action, true);
      }
      return { action, state: next };
    }
    case 'x':
      if (busy) return blocked();
      return confirm(`Stop every validator and the OPS proxy under ${root}?`, runAction('stop cluster', 'stop-cluster.sh', []), true);
    case 'u':
      if (busy) return blocked();
      return { action: runAction(`start validator-${selected}`, 'member.sh', ['start', String(selected)]), state: next };
    case 't':
    case 'r': {
      if (busy) return blocked();
      const verb = key === 't' ? 'stop' : 'restart';
      const action = runAction(`${verb} validator-${selected}`, 'member.sh', [verb, String(selected)]);
      const warning = quorumWarning(snapshot, config, selected);
      if (warning) return confirm(`${verb === 'stop' ? 'Stop' : 'Restart'} validator-${selected}?${warning}`, action, true);
      return { action, state: next };
    }
    case 'k': {
      if (busy) return blocked();
      const action = runAction(`kill validator-${selected}`, 'member.sh', ['kill', String(selected)]);
      return confirm(`Hard-kill validator-${selected} (SIGKILL, simulated crash)?${quorumWarning(snapshot, config, selected)}`, action, true);
    }
    default:
      if (/^[0-9]$/.test(key)) {
        const id = Number(key);
        if (ids.includes(id)) return { action: null, state: { ...next, selected: id } };
        return { action: null, state: { ...next, message: { text: `no member ${id}`, tone: 'yellow' } } };
      }
      return { action: null, state: next };
  }
}

export function splitKeys(chunk) {
  const keys = [];
  const text = String(chunk);
  for (let index = 0; index < text.length;) {
    if (text[index] === '\u001b' && text[index + 1] === '[' && index + 2 < text.length) {
      keys.push(text.slice(index, index + 3));
      index += 3;
    } else {
      keys.push(text[index]);
      index += 1;
    }
  }
  return keys;
}

// ---------------------------------------------------------------------------------------
// Rendering: returns plain lines (optionally styled). Width is enforced on free text; the
// runner also disables terminal autowrap so a long styled line clips instead of wrapping.

function fit(text, width) {
  const chars = Array.from(String(text));
  return chars.length <= width ? chars.join('') : `${chars.slice(0, Math.max(0, width - 1)).join('')}…`;
}

function visibleLength(text) {
  return Array.from(stripAnsi(text)).length;
}

const ANSI_STICKY = new RegExp(ANSI_PATTERN.source, 'y');

// Truncate to a visible width without splitting escape sequences.
export function clip(line, width) {
  if (visibleLength(line) <= width) return line;
  let out = '';
  let visible = 0;
  let index = 0;
  while (index < line.length && visible < width - 1) {
    ANSI_STICKY.lastIndex = index;
    const escape = ANSI_STICKY.exec(line);
    if (escape) {
      out += escape[0];
      index += escape[0].length;
      continue;
    }
    const char = String.fromCodePoint(line.codePointAt(index));
    out += char;
    index += char.length;
    visible += 1;
  }
  return `${out}…${line.includes('\u001b[') ? STYLES.reset : ''}`;
}

function spread(left, right, width) {
  const gap = width - visibleLength(left) - visibleLength(right);
  return gap >= 2 ? `${left}${' '.repeat(gap)}${right}` : `${left}  ${right}`;
}

const STATE_STYLE = {
  crashed: ['✕', 'red', 'crashed'],
  starting: ['◌', 'yellow', 'starting'],
  stopped: ['○', 'dim', 'stopped'],
  unhealthy: ['◐', 'yellow', 'unhealthy'],
  untracked: ['▲', 'yellow', 'untracked'],
  up: ['●', 'green', 'up'],
};

function serviceMark(color, ok, label) {
  if (ok === null) return paint(color, 'dim', `○ ${label}`);
  return ok ? `${paint(color, 'green', '●')} ${label}` : `${paint(color, 'red', '✕')} ${label}`;
}

function shortWallet(wallet) {
  if (!wallet) return 'none';
  return wallet.length > 14 ? `${wallet.slice(0, 6)}…${wallet.slice(-4)}` : wallet;
}

function clock(now) {
  return new Date(now).toTimeString().slice(0, 8);
}

export function formatLaunched(iso, now) {
  if (!iso) return '';
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return String(iso);
  return `${new Date(at).toTimeString().slice(0, 5)} (${formatDuration(Math.max(0, now - at))} ago)`;
}

// What the pane shows before this session has run anything: either a cold-start hint or a
// summary of the cluster the console attached to.
function idlePane(config, snapshot, { color, now }) {
  const members = snapshot.members.filter((member) => member.id < config.size);
  const live = members.filter((member) => ['up', 'unhealthy', 'starting'].includes(member.state));
  const down = members.filter((member) => ['stopped', 'crashed'].includes(member.state));
  const crashed = down.filter((member) => member.state === 'crashed');
  const root = tildePath(config.runtimeRoot, config.home);
  const launched = formatLaunched(config.launch.LAUNCHED_AT, now);

  if (live.length === 0) {
    const header = paint(color, 'dim', ' OPERATION  none yet · press s to start the cluster');
    const lines = crashed.length > 0
      ? [`${crashed.map((member) => `validator-${member.id}`).join(', ')} left stale pid files (crashed or killed outside the scripts); s starts the cluster cleanly.`]
      : [];
    return { header, lines };
  }

  const header = ` ${paint(color, 'bold', 'ATTACHED')}  ${paint(color, 'green', '●')} cluster already running · ${live.length}/${config.size} up${launched ? ` · launched ${launched}` : ''}`;
  const lines = [
    `Picked up the cluster running under ${root}${launched ? `, launched ${launched}` : ''}.`,
  ];
  if (down.length > 0) {
    down.forEach((member) => {
      lines.push(`validator-${member.id} is ${member.state === 'crashed' ? 'down (crashed, stale pid file)' : 'stopped'}: select it and press u to bring it back.`);
    });
  } else {
    lines.push('Nothing to start. Act on it from here:');
  }
  lines.push(
    '',
    '  member   ↑↓ or 0-4 select · t stop · k kill (crash) · r restart · u start',
    `  cluster  x stop all · ${down.length > 0 ? 's start missing members' : 'f then s for a fresh restart'}`,
    '  logs     l switches this pane to the selected member\'s log',
  );
  return { header, lines };
}

export function renderStatusLines(config, snapshot, { color = false, now = Date.now(), selected = null, width = 100 } = {}) {
  const lines = [];
  const rule = paint(color, 'accent', '─'.repeat(Math.max(20, width)));
  const root = tildePath(config.runtimeRoot, config.home);
  const launchedText = formatLaunched(config.launch.LAUNCHED_AT, now);
  const launched = launchedText ? ` · launched ${launchedText}` : '';

  lines.push(spread(`${paint(color, 'bold accent', ' OAK CHAIN')} ${paint(color, 'dim', 'mock console')}`, paint(color, 'dim', clock(now)), width));
  lines.push(` cluster ${paint(color, 'bold', config.clusterName)} · ${config.size} members ${paint(color, 'dim', `(${config.sizeSource})`)} · runtime ${paint(color, 'bold', root)}`);
  lines.push(paint(color, 'dim', fit(` ports http ${config.httpBase}+${config.step}n · aeron ${config.aeronBase} · ops :${config.opsPort} · ipfs ${config.ipfsApi}${launched}`, width)));
  const warnings = [...config.warnings];
  if (snapshot.members.some((member) => member.state === 'untracked')) {
    warnings.push(`validator ports answer but ${root} tracks no pid for them: a cluster may be running under another CLUSTER_RUNTIME_ROOT`);
  }
  if (snapshot.members.some((member) => member.id >= config.size && member.alive)) {
    warnings.push(`members outside the ${config.size}-member membership are running`);
  }
  warnings.forEach((warning) => lines.push(paint(color, 'yellow', fit(` ▲ ${warning}`, width))));
  lines.push(rule);

  const { quorum } = snapshot;
  let quorumText;
  if (quorum.running === 0) {
    quorumText = paint(color, 'dim', 'cluster stopped');
  } else {
    const ok = quorum.running >= quorum.need;
    const mark = ok ? paint(color, 'green', '✔') : paint(color, 'red', '✕');
    const leader = quorum.leader === null ? paint(color, 'yellow', 'no leader') : `leader ${paint(color, 'yellow', quorum.leader)}`;
    const health = quorum.healthy ? paint(color, 'green', 'healthy') : paint(color, 'yellow', 'not healthy');
    quorumText = `quorum ${mark} ${quorum.running}/${quorum.size} running · need ${quorum.need} · ${leader} · ${health}`;
  }
  lines.push(spread(paint(color, 'bold', ' MEMBERS'), quorumText, width));
  lines.push(paint(color, 'dim', `    id ${'state'.padEnd(13)}${'role'.padEnd(12)}${'http'.padEnd(8)}${'pid'.padEnd(9)}${'uptime'.padEnd(9)}aeron view`));
  snapshot.members.forEach((member) => {
    const [glyph, tone, label] = STATE_STYLE[member.state];
    const marker = member.id === selected ? paint(color, 'accent bold', '▸') : ' ';
    const role = member.role ? String(member.role) : '—';
    const roleText = role.toUpperCase() === 'LEADER' ? paint(color, 'yellow bold', role.padEnd(10)) : role.padEnd(10);
    const view = member.reachable !== null && member.total !== null ? `${member.reachable}/${member.total}` : '—';
    const outside = member.id >= config.size ? paint(color, 'yellow', '  outside membership') : '';
    const idText = member.id === selected ? paint(color, 'bold', String(member.id)) : String(member.id);
    lines.push([
      `  ${marker} ${idText} `,
      ` ${paint(color, tone, `${glyph} ${label.padEnd(10)}`)}`,
      ` ${roleText}`,
      `  :${String(member.port).padEnd(5)}`,
      `  ${String(member.alive ? member.pid : '—').padEnd(7)}`,
      `  ${(member.uptimeMs === null ? '—' : formatDuration(member.uptimeMs)).padEnd(7)}`,
      `  ${view}${outside}`,
    ].join(''));
  });

  const opsOk = snapshot.ops.code === 200 ? true : (snapshot.ops.alive || snapshot.ops.pid ? false : null);
  const ipfsOk = snapshot.ipfs.code === 200 ? true : false;
  lines.push([
    paint(color, 'bold', ' SERVICES '),
    ` ${serviceMark(color, opsOk, `ops :${config.opsPort}`)}`,
    `   ${serviceMark(color, ipfsOk, 'ipfs')}`,
    `   ${serviceMark(color, snapshot.sidecars.sleep, 'sleep-guard')}`,
    `   ${serviceMark(color, snapshot.sidecars.watchdog, 'watchdog')}`,
    `   ${serviceMark(color, snapshot.sidecars.observer, 'observer')}`,
    `   wallet ${paint(color, 'amber', shortWallet(snapshot.wallet))}`,
  ].join(''));
  return lines.map((line) => clip(line, width));
}

function operationHeader(op, { color, now, spinnerFrame }) {
  if (!op) return paint(color, 'dim', ' OPERATION  none yet · press s to start the cluster');
  const command = paint(color, 'dim', `${op.script} ${op.args.join(' ')}`.trim());
  if (op.endedAt === null) {
    const spin = paint(color, 'accent', SPINNER[spinnerFrame % SPINNER.length]);
    return ` OPERATION  ${spin} ${paint(color, 'bold', op.label)}  ${formatDuration(now - op.startedAt)}  ${command}`;
  }
  const duration = formatDuration(op.endedAt - op.startedAt);
  if (op.code === 0) return ` OPERATION  ${paint(color, 'green', '✔')} ${op.label} · ${duration}  ${command}`;
  return ` OPERATION  ${paint(color, 'red', '✕')} ${op.label} · exit ${op.code} · ${duration}  ${command}`;
}

// Say which run the visible log lines belong to, so an old tail is never mistaken for live.
function memberLogNote(snapshot, memberId, mtimeMs, { color, now }) {
  if (mtimeMs === null) return '';
  const member = snapshot.members.find((entry) => entry.id === memberId);
  const lastWrite = paint(color, 'dim', ` · last write ${clock(mtimeMs)} (${formatDuration(now - mtimeMs)} ago)`);
  if (!member || !member.alive) return `${paint(color, 'yellow', ' · member down: previous run')}${lastWrite}`;
  if (member.uptimeMs !== null && mtimeMs < now - member.uptimeMs) {
    return `${paint(color, 'yellow', ' · earlier run; nothing from the current process yet')}${lastWrite}`;
  }
  return lastWrite;
}

export function renderConsole(view) {
  const {
    color = false,
    config,
    height = 30,
    memberLog = [],
    memberLogMtime = null,
    now = Date.now(),
    op = null,
    output = [],
    snapshot,
    spinnerFrame = 0,
    ui,
    width = 100,
  } = view;
  const busy = Boolean(op && op.endedAt === null);
  const top = renderStatusLines(config, snapshot, { color, now, selected: ui.selected, width });
  const rule = paint(color, 'accent', '─'.repeat(Math.max(20, width)));

  const idle = !op && output.length === 0 ? idlePane(config, snapshot, { color, now }) : null;
  let header;
  let source;
  if (ui.view === 'member') {
    header = ` LOG  ${paint(color, 'bold', `validator-${ui.selected}.log`)}${memberLogNote(snapshot, ui.selected, memberLogMtime, { color, now })}  ${paint(color, 'dim', tildePath(config.logDir, config.home))}`;
    source = memberLog;
  } else if (idle) {
    ({ header, lines: source } = idle);
  } else {
    header = operationHeader(op, { color, now, spinnerFrame });
    source = output;
  }

  const toggle = (enabled) => (enabled ? paint(color, 'green', '● on ') : paint(color, 'dim', '○ off'));
  const toggles = ` next start  ${paint(color, 'bold', '[f]')} fresh ${toggle(ui.fresh)}   ${paint(color, 'bold', '[b]')} build ${toggle(ui.build)}`;
  const message = ui.message ? paint(color, ui.message.tone, ui.message.text) : '';

  let keys;
  if (ui.confirm) {
    keys = paint(color, ui.confirm.danger ? 'red bold' : 'yellow bold', fit(` ? ${ui.confirm.prompt}  [y/N]`, width));
  } else {
    const mutate = (text) => (busy ? paint(color, 'dim', text) : text);
    const k = (text) => paint(color, 'bold', text);
    keys = [
      mutate(` ${k('s')} start  ${k('x')} stop all`),
      paint(color, 'dim', ' │ '),
      `${k('↑↓')}/${k('0-4')} select  `,
      mutate(`${k('u')} up  ${k('t')} stop  ${k('k')} kill  ${k('r')} restart`),
      paint(color, 'dim', ' │ '),
      `${k('l')} ${ui.view === 'ops' ? 'member log' : 'op output'}  ${k('q')} quit`,
    ].join('');
  }

  const fixed = top.length + 1 + 1 + 1 + 2;
  const paneHeight = Math.max(3, height - fixed);
  const pane = source.slice(-paneHeight).map((line) => `${paint(color, 'dim', ' │')} ${fit(line, width - 4)}`);
  while (pane.length < paneHeight) pane.push(paint(color, 'dim', ' │'));

  return [...top, rule, header, ...pane, rule, spread(toggles, message, width), keys].map((line) => clip(line, width));
}

// ---------------------------------------------------------------------------------------
// Runner

async function tailLines(file, maxLines) {
  let handle;
  try {
    handle = await open(file, 'r');
    const { mtimeMs, size } = await handle.stat();
    const length = Math.min(size, 64 * 1024);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, size - length);
    const lines = buffer.toString('utf8').split(/\r?\n|\r/).map(stripAnsi).filter((line) => line.length > 0).slice(-maxLines);
    return { lines: lines.length > 0 ? lines : ['(log is empty: reset by a fresh start, or nothing written yet)'], mtimeMs };
  } catch (_error) {
    return { lines: [`(no log yet: ${file})`], mtimeMs: null };
  } finally {
    await handle?.close();
  }
}

function colorEnabled(options, stdout) {
  if (flag(options, 'no-color') || process.env.NO_COLOR !== undefined) return false;
  if (flag(options, 'color')) return true;
  return Boolean(stdout.isTTY);
}

export async function runMockConsole(options = {}, { repoRoot, env = process.env } = {}) {
  const { stdin, stdout } = process;
  let config = await resolveConsoleConfig({ env, options, repoRoot });
  const color = colorEnabled(options, stdout);

  if (flag(options, 'once') || !stdin.isTTY || !stdout.isTTY) {
    const snapshot = await probeCluster(config);
    stdout.write(`${renderStatusLines(config, snapshot, { color, width: stdout.columns || 160 }).join('\n')}\n`);
    return;
  }

  let ui = initialUiState();
  let snapshot = await probeCluster(config);
  let op = null;
  let child = null;
  let memberLog = [];
  let memberLogMtime = null;
  let spinnerFrame = 0;
  let polling = false;
  let pendingPartial = '';
  const output = [];

  const pushOutput = (text) => {
    const lines = `${pendingPartial}${text}`.split(/\r?\n|\r/);
    pendingPartial = lines.pop() ?? '';
    lines.map(stripAnsi).forEach((line) => output.push(line));
    if (output.length > MAX_OUTPUT_LINES) output.splice(0, output.length - MAX_OUTPUT_LINES);
  };

  const draw = () => {
    const width = stdout.columns || 100;
    const height = stdout.rows || 30;
    const lines = renderConsole({
      color, config, height, memberLog, memberLogMtime, now: Date.now(), op, output, snapshot, spinnerFrame, ui, width,
    }).slice(0, height);
    // Erase each line before writing it: with autowrap off the cursor parks on the last
    // column, so a trailing erase-to-end-of-line would delete a full-width line's last cell.
    stdout.write(`\u001b[H${lines.map((line) => `\u001b[2K${line}`).join('\n')}\u001b[J`);
  };

  const poll = async () => {
    if (polling) return;
    polling = true;
    try {
      config = await resolveConsoleConfig({ env, options, repoRoot });
      snapshot = await probeCluster(config);
      if (ui.view === 'member') {
        ({ lines: memberLog, mtimeMs: memberLogMtime } = await tailLines(path.join(config.logDir, `validator-${ui.selected}.log`), 200));
      }
    } catch (error) {
      ui = { ...ui, message: { text: `probe failed: ${error.message}`, tone: 'red' } };
    } finally {
      polling = false;
      draw();
    }
  };

  const runScript = (action) => {
    const scriptPath = path.join(config.lifecycleDir, action.script);
    output.push('', `── ${action.label} · ${clock(Date.now())} · ${action.script} ${action.args.join(' ')}`.trim());
    pendingPartial = '';
    op = { args: action.args, code: null, endedAt: null, label: action.label, script: action.script, startedAt: Date.now() };
    const current = op;
    child = spawn('bash', [scriptPath, ...action.args], {
      cwd: config.lifecycleDir,
      detached: true,
      env: config.childEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (text) => { pushOutput(text); draw(); });
    child.stderr.on('data', (text) => { pushOutput(text); draw(); });
    child.on('error', (error) => {
      pushOutput(`failed to run ${scriptPath}: ${error.message}\n`);
      current.code = 127;
      current.endedAt = Date.now();
      draw();
    });
    child.on('exit', (code, signal) => {
      if (pendingPartial) pushOutput('\n');
      current.code = code ?? (signal ? `signal ${signal}` : 1);
      current.endedAt = Date.now();
      child = null;
      void poll();
    });
  };

  let finish;
  const done = new Promise((resolve) => { finish = resolve; });
  const timers = [];
  let restored = false;
  const restore = () => {
    if (restored) return;
    restored = true;
    timers.forEach((timer) => clearInterval(timer));
    try {
      stdin.setRawMode(false);
    } catch (_error) {
      // stdin may already be closed.
    }
    stdin.pause();
    stdout.write('\u001b[?7h\u001b[?25h\u001b[?1049l');
  };
  const quit = (interrupt) => {
    if (child) {
      if (interrupt) {
        try {
          process.kill(-child.pid, 'SIGTERM');
        } catch (_error) {
          // Already gone.
        }
      }
      child.stdout?.destroy();
      child.stderr?.destroy();
      child.unref();
    }
    restore();
    finish();
  };

  process.once('exit', restore);
  for (const signal of ['SIGTERM', 'SIGHUP']) {
    process.once(signal, () => { quit(true); process.exit(0); });
  }

  stdout.write('\u001b[?1049h\u001b[?25l\u001b[?7l\u001b[2J');
  stdin.setRawMode(true);
  stdin.setEncoding('utf8');
  stdin.resume();
  stdin.on('data', (chunk) => {
    for (const key of splitKeys(chunk)) {
      const busy = Boolean(op && op.endedAt === null);
      const previousView = ui.view;
      const previousSelected = ui.selected;
      const result = handleKey(ui, key, { busy, config, snapshot });
      ui = result.state;
      if (result.action?.type === 'quit') {
        quit(result.action.interrupt);
        return;
      }
      if (result.action?.type === 'run') runScript(result.action);
      if (ui.view === 'member' && (previousView !== 'member' || previousSelected !== ui.selected)) void poll();
    }
    draw();
  });
  stdout.on('resize', draw);

  timers.push(setInterval(() => { void poll(); }, config.intervalMs));
  timers.push(setInterval(() => {
    if (op && op.endedAt === null) {
      spinnerFrame += 1;
      draw();
    }
  }, 120));
  draw();
  await done;
}
