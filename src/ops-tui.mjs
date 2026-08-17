import { readdir, open } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const DEFAULT_OPS_URL = 'http://127.0.0.1:8787';
const DEFAULT_INTERVAL_MS = 2_000;
const DEFAULT_TIMEOUT_MS = 3_000;
const ERROR_PATTERN = /\b(error|warn(?:ing)?|fatal|exception|unhealthy|failure)\b|timed out|timeout exception|failed to/i;
const ANSI = Object.freeze({
  bold: '\u001b[1m',
  cyan: '\u001b[36m',
  dim: '\u001b[2m',
  green: '\u001b[32m',
  red: '\u001b[31m',
  reset: '\u001b[0m',
  white: '\u001b[97m',
  yellow: '\u001b[33m',
});

function option(options, name, fallback = undefined) {
  return Object.prototype.hasOwnProperty.call(options, name) ? options[name] : fallback;
}

function flag(options, name) {
  const value = option(options, name, false);
  if (typeof value === 'string') return value.toLowerCase() !== 'false';
  return Boolean(value);
}

function numberOption(options, name, fallback) {
  const value = Number(option(options, name, fallback));
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`Invalid --${name} value: ${option(options, name)}`);
  }
  return value;
}

function normalizeUrl(value) {
  return String(value || '').replace(/\/+$/, '');
}

function colorEnabled(options) {
  if (flag(options, 'no-color') || process.env.NO_COLOR !== undefined) return false;
  if (flag(options, 'color') || process.env.FORCE_COLOR === '1') return true;
  return Boolean(process.stdout.isTTY);
}

function paint(enabled, color, value) {
  return enabled ? `${ANSI[color]}${value}${ANSI.reset}` : String(value);
}

function heading(enabled, value) {
  return enabled ? `${ANSI.bold}${ANSI.cyan}${value}${ANSI.reset}` : String(value);
}

function paintStatus(enabled, status, value) {
  const normalized = String(status || 'unknown').toLowerCase();
  if (['healthy', 'up', 'ok', 'active'].includes(normalized)) {
    return paint(enabled, 'green', value);
  }
  if (['warn', 'warning', 'degraded'].includes(normalized)) {
    return paint(enabled, 'yellow', value);
  }
  if (normalized === 'unknown') return paint(enabled, 'dim', value);
  return paint(enabled, 'red', value);
}

function unwrap(payload) {
  if (payload && typeof payload === 'object' && payload.data && typeof payload.data === 'object') {
    return payload.data;
  }
  return payload ?? {};
}

async function fetchJson(opsUrl, endpoint, options) {
  const authToken = String(
    option(options, 'auth-token', '')
      || process.env.OAK_CLI_AUTH_TOKEN
      || process.env.OAK_OPS_API_AUTH_TOKEN
      || process.env.OPS_API_AUTH_TOKEN
      || '',
  ).trim();
  const headers = { Accept: 'application/json' };
  if (authToken) headers.Authorization = authToken;

  const timeoutMs = numberOption(options, 'timeout-ms', DEFAULT_TIMEOUT_MS);
  const response = await fetch(`${opsUrl}${endpoint}`, {
    headers,
    signal: timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : undefined,
  });
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}`);
  }
  return unwrap(await response.json());
}

async function fetchSource(name, opsUrl, endpoint, options) {
  try {
    return { data: await fetchJson(opsUrl, endpoint, options), name, ok: true };
  } catch (error) {
    return {
      error: error instanceof Error ? error.message : String(error),
      name,
      ok: false,
    };
  }
}

async function tailFile(filePath, maxBytes = 64 * 1024) {
  const handle = await open(filePath, 'r');
  try {
    const stats = await handle.stat();
    const length = Math.min(stats.size, maxBytes);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, stats.size - length);
    return buffer.toString('utf8');
  } finally {
    await handle.close();
  }
}

async function collectLocalErrors(runtimeRoot, limit = 8) {
  const logDir = path.join(runtimeRoot, 'logs');
  let names;
  try {
    names = await readdir(logDir);
  } catch (_error) {
    return [];
  }

  const activeLogs = names.filter((name) => (
    /^start-validator-\d+\.log$/.test(name)
    || ['start-ops-proxy.log', 'validator-watchdog.log', 'load-bottleneck-observer.log', 'ipfs-daemon.log'].includes(name)
  ));
  const matches = [];
  await Promise.all(activeLogs.map(async (name) => {
    try {
      const text = await tailFile(path.join(logDir, name));
      text.split(/\r?\n/).forEach((line) => {
        if (ERROR_PATTERN.test(line)) matches.push(`[${name}] ${line.trim()}`);
      });
    } catch (_error) {
      // A rotating log may disappear between directory listing and read.
    }
  }));
  return matches.filter(Boolean).slice(-limit);
}

export async function createOpsSnapshot(options = {}) {
  const opsUrl = normalizeUrl(
    option(options, 'ops-url', '') || process.env.OAK_OPS_URL || DEFAULT_OPS_URL,
  );
  const specs = [
    ['overview', '/ops/v1/overview'],
    ['health', '/ops/v1/health'],
    ['cluster', '/ops/v1/cluster'],
    ['queue', '/ops/v1/queue'],
    ['signals', '/ops/v1/signals'],
    ['events', '/ops/v1/events/recent?limit=8'],
  ];
  const sources = Object.fromEntries(
    (await Promise.all(specs.map(([name, endpoint]) => fetchSource(name, opsUrl, endpoint, options))))
      .map((source) => [source.name, source]),
  );
  const runtimeRoot = String(option(options, 'runtime-root', process.env.CLUSTER_RUNTIME_ROOT || `${process.env.HOME}/oak-chain`));
  const localErrors = flag(options, 'no-local-logs')
    ? []
    : await collectLocalErrors(runtimeRoot);

  return {
    generatedAt: new Date().toISOString(),
    localErrors,
    opsUrl,
    sources,
  };
}

function truncate(value, width) {
  const text = String(value ?? 'unknown').replace(/\s+/g, ' ').trim();
  if (text.length <= width) return text;
  return `${text.slice(0, Math.max(1, width - 1))}…`;
}

function statusMark(status) {
  const normalized = String(status || 'unknown').toLowerCase();
  if (['healthy', 'up', 'ok', 'active'].includes(normalized)) return '●';
  if (['warn', 'warning', 'degraded'].includes(normalized)) return '▲';
  return normalized === 'unknown' ? '○' : '✕';
}

function sourceData(snapshot, name) {
  return snapshot.sources[name]?.ok ? snapshot.sources[name].data : {};
}

function renderSourceFailures(snapshot) {
  return Object.values(snapshot.sources)
    .filter((source) => !source.ok)
    .map((source) => `${source.name}: ${source.error}`);
}

export function renderOpsBoard(snapshot, options = {}) {
  const width = Math.max(72, Number(option(options, 'width', process.stdout.columns || 100)));
  const colors = colorEnabled(options);
  const overview = sourceData(snapshot, 'overview');
  const health = sourceData(snapshot, 'health');
  const cluster = sourceData(snapshot, 'cluster');
  const queue = sourceData(snapshot, 'queue');
  const signals = sourceData(snapshot, 'signals');
  const eventsPayload = sourceData(snapshot, 'events');
  const nodes = Array.isArray(cluster.nodes) ? cluster.nodes : [];
  const events = Array.isArray(eventsPayload.events) ? eventsPayload.events : [];
  const signalList = Array.isArray(signals.signals) ? signals.signals : [];
  const noteworthySignals = signalList.filter((entry) => entry.severity !== 'ok').slice(0, 6);
  const failures = renderSourceFailures(snapshot);
  const overall = health.status || overview.status || cluster.clusterState || 'unknown';
  const line = '─'.repeat(width);
  const rows = [];

  rows.push(`${heading(colors, 'OAK CHAIN OPS BOARD')}  ${paintStatus(colors, overall, `${statusMark(overall)} ${String(overall).toUpperCase()}`)}  ${paint(colors, 'dim', snapshot.generatedAt)}`);
  rows.push(`${paint(colors, 'dim', 'source')} ${paint(colors, 'white', snapshot.opsUrl)}  ${paint(colors, 'dim', `refresh ${numberOption(options, 'interval-ms', DEFAULT_INTERVAL_MS)}ms`)}`);
  rows.push(paint(colors, 'cyan', line));
  rows.push(heading(colors, 'CLUSTER'));
  const nodeCount = overview.cluster?.nodeCount ?? (nodes.length > 0 ? nodes.length : '?');
  rows.push(`state=${paintStatus(colors, cluster.clusterState ?? overall, cluster.clusterState ?? overall)}  term=${paint(colors, 'white', cluster.term ?? overview.leader?.term ?? '?')}  leader=${paint(colors, 'yellow', cluster.leaderNodeId ?? overview.leader?.nodeId ?? '?')}  reachable=${paint(colors, 'green', `${overview.cluster?.reachableNodes ?? '?'} / ${nodeCount}`)}`);
  rows.push(paint(colors, 'dim', 'node  role       status     endpoint                  wallet'));
  nodes.forEach((node) => {
    const role = String(node.role ?? '?');
    const styledRole = role.toUpperCase() === 'LEADER'
      ? paint(colors, 'yellow', role.padEnd(10))
      : paint(colors, 'white', role.padEnd(10));
    const paddedStatus = `${statusMark(node.status)} ${node.status ?? '?'}`.padEnd(10);
    rows.push(`${paint(colors, 'cyan', String(node.nodeId ?? '?').padEnd(5))} ${styledRole} ${paintStatus(colors, node.status, paddedStatus)} ${paint(colors, 'white', String(node.url ?? '?').padEnd(25))} ${paint(colors, 'dim', truncate(node.wallet, 22))}`);
  });
  if (nodes.length === 0) rows.push(paint(colors, 'yellow', 'no node telemetry available'));

  rows.push(paint(colors, 'cyan', line));
  rows.push(heading(colors, 'FLOW + TELEMETRY'));
  const backpressure = queue.backpressureActive;
  rows.push(`queue pending=${paint(colors, 'white', queue.pendingCount ?? overview.queue?.pending ?? '?')}  mempool=${paint(colors, 'white', queue.mempoolCount ?? overview.queue?.mempool ?? '?')}  epoch-depth=${paint(colors, 'white', queue.epochQueueDepth ?? '?')}  backpressure=${paintStatus(colors, backpressure === false ? 'ok' : (backpressure === true ? 'warn' : 'unknown'), backpressure ?? '?')}`);
  rows.push(`signals ok=${paint(colors, 'green', signals.summary?.ok ?? '?')}  warn=${paint(colors, 'yellow', signals.summary?.warn ?? '?')}  critical=${paint(colors, 'red', signals.summary?.critical ?? '?')}  unknown=${paint(colors, 'dim', signals.summary?.unknown ?? '?')}`);
  noteworthySignals.forEach((entry) => {
    rows.push(paintStatus(colors, entry.severity, `${statusMark(entry.severity)} ${entry.label ?? entry.id}: ${entry.value ?? '?'}${entry.unit ? ` ${entry.unit}` : ''} (${entry.severity})`));
  });
  if (noteworthySignals.length === 0) rows.push(paint(colors, 'green', '● no warning or critical telemetry signals'));

  rows.push(paint(colors, 'cyan', line));
  rows.push(heading(colors, 'RECENT EVENTS'));
  events.slice(0, 6).forEach((event) => {
    rows.push(truncate(`${event.timestamp || event.createdAt || ''} ${event.type || event.eventType || 'event'} ${event.message || event.path || event.proposalId || ''}`, width));
  });
  if (events.length === 0) rows.push(paint(colors, 'dim', 'no recent governed events'));

  rows.push(paint(colors, 'cyan', line));
  rows.push(heading(colors, 'ERROR AGGREGATION (local active logs)'));
  snapshot.localErrors.forEach((entry) => rows.push(paint(colors, 'red', truncate(entry, width))));
  if (snapshot.localErrors.length === 0) rows.push(paint(colors, 'green', '● no matching warning/error lines in active local logs'));
  failures.forEach((failure) => rows.push(paint(colors, 'red', `✕ telemetry source ${truncate(failure, width - 19)}`)));
  rows.push(paint(colors, 'cyan', line));
  rows.push(`${paint(colors, 'bold', 'q')} quit  ${paint(colors, 'bold', 'r')} refresh  ${paint(colors, 'dim', '|  lifecycle remains explicit: oak-chain mock up|down|status')}`);
  return `${rows.join('\n')}\n`;
}

export async function runOpsBoard(options = {}) {
  const intervalMs = numberOption(options, 'interval-ms', DEFAULT_INTERVAL_MS);
  const once = flag(options, 'once') || !process.stdin.isTTY || !process.stdout.isTTY;

  const render = async (clear = false) => {
    const snapshot = await createOpsSnapshot(options);
    if (clear) process.stdout.write('\u001b[2J\u001b[H');
    process.stdout.write(renderOpsBoard(snapshot, options));
  };

  if (once) {
    await render(false);
    return;
  }

  let stopped = false;
  let timer = null;
  let rendering = false;
  const schedule = () => {
    if (!stopped) timer = setTimeout(refresh, intervalMs);
  };
  const refresh = async () => {
    if (rendering || stopped) return;
    rendering = true;
    try {
      await render(true);
    } catch (error) {
      process.stdout.write(`\u001b[2J\u001b[HOak Chain OPS board refresh failed: ${error.message}\n`);
    } finally {
      rendering = false;
      schedule();
    }
  };
  const stop = () => {
    stopped = true;
    if (timer) clearTimeout(timer);
    process.stdin.setRawMode(false);
    process.stdin.pause();
    process.stdout.write('\u001b[?25h\n');
  };

  process.stdout.write('\u001b[?25l');
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (key) => {
    if (key === 'q' || key === '\u0003') stop();
    if (key === 'r') {
      if (timer) clearTimeout(timer);
      void refresh();
    }
  });
  await refresh();
}
